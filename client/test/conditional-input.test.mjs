import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { connect, gdPredicate } from '../../addons/stagehand/client.mjs';
import { launchFixture } from './fixture.mjs';

let fixture, game, input, script, scene, capsule, nativeTree;
const forward = {action: 'move_forward'};
const backward = {action: 'move_back'};
const shutdownEvaluator = `extends RefCounted

func _init() -> void:
    var tree: SceneTree = Engine.get_main_loop()
    var root: Node = tree.current_scene
    var bridge: Node = root.get_node("Stagehand")
    bridge.connection_closed.connect(Callable(root, "press_after_close"))
    bridge.stop()
    tree.create_timer(0.05).timeout.connect(Callable(root, "report_input"))

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {"matched": false, "value": null}
`;

before(async () => {
  fixture = await launchFixture({builtins: ['Input', 'Script', 'SceneTree', 'Object']});
  game = await connect(fixture.url, {token: fixture.token});

  input = await game.root('Input');
  script = await game.root('Script');
  const tree = await game.root('SceneTree');
  ({scene} = await tree.invoke('current'));
  nativeTree = await scene.call('get_tree');
  capsule = (await tree.invoke('query', {root: scene, name: 'Capsule'})).nodes[0].node;
});

async function physicsFrames(count = 2) {
  let resolve;
  const reached = new Promise((done) => { resolve = done; });
  const stop = await nativeTree.subscribe('physics_frame', () => {
    if (--count === 0) resolve();
  });

  try {
    await reached;
  } finally {
    await stop();
  }
}

function evaluate(body, bindings = {}) {
  const source = `extends RefCounted\n\nfunc evaluate(bindings: Dictionary) -> Variant:\n${body}\n`;

  return script.invoke('evaluate', {source, bindings});
}

after(async () => {
  game?.close();
  await fixture?.stop();
});

test('plan validation finishes before input is delivered or existing holds change', async () => {
  const invalidInput = {action: 'missing_action'};
  const events = [
    {at_tick: 0, pressed: true, input: forward},
    {at_tick: 1, pressed: true, input: invalidInput},
  ];
  const predicate = gdPredicate('false');
  const requests = [
    ['sequence', {ticks: 2, events}],
    ['hold_until', {
      ...predicate,
      hold: [forward, invalidInput],
      max_simulation_seconds: 1,
    }],
    ['hold_until', {
      ...predicate,
      hold: [forward],
      max_simulation_seconds: 1,
      response: {ticks: 2, events},
    }],
  ];

  await input.invoke('press', {action: 'jump'});

  try {
    for (const [operation, params] of requests) {
      const eventsBefore = await scene.get('event_count');
      await assert.rejects(input.invoke(operation, params), {code: -32602});

      const {value: state} = await input.observe();
      assert.equal(state.active_action, null);
      assert.deepEqual(state.held_inputs, ['action:jump']);
      assert.equal(await scene.get('forward_held'), false);
      assert.equal(await scene.get('event_count'), eventsBefore);
    }
  } finally {
    await input.invoke('release', {action: 'jump'});
  }
});

test('deep observations settle through the actual completion envelope limits', async () => {
  const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    var value: Variant = 1

    for _level: int in 14:
        value = [value]

    return {"matched": true, "value": value}
`;

  const action = await input.startHoldUntil({source, hold: [forward], max_simulation_seconds: 1});
  let result;
  let timer;

  try {
    result = await Promise.race([
      action.finished,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Completion was lost')), 1000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }

  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'unsupported_result');
  assert.deepEqual(await action.getStatus(), result);
});

for (const [encoding, expression] of [
  ['JSON escaping', 'String.chr(34).repeat(4 * 1024 * 1024)'],
  ['UTF-8 expansion', 'String.chr(0x4E00).repeat(3 * 1024 * 1024)'],
]) {
  test(`oversized ${encoding} observations fail without disconnecting subscribers`, async () => {
    const isolated = await launchFixture({builtins: ['Script', 'Input']});
    const driver = await connect(isolated.url, {token: isolated.token});
    const observer = await connect(isolated.url, {token: isolated.token});

    const control = await driver.root('Input');
    const watched = await observer.root('Input');
    let observed;
    const stop = await watched.subscribe('completed', ({value}) => { observed = value; });

    const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {"matched": true, "value": ${expression}}
`;

    try {
      const action = await control.startHoldUntil({
        source, hold: [forward], max_simulation_seconds: 1,
      });
      const result = await action.finished;

      assert.equal(result.status, 'failed');
      assert.equal(result.reason, 'unsupported_result');
      assert.match(result.error.message, /message.*limit/i);
      assert.equal(Object.hasOwn(result.condition, 'value'), false);
      assert.deepEqual(await action.getStatus(), result);
      assert.deepEqual(await watched.invoke('status', {action: action.action}), result);
      assert.deepEqual(observed, result);
    } finally {
      await stop().catch(() => {});
      driver.close();
      observer.close();
      await isolated.stop();
    }
  });
}

test('a local position predicate releases held input before the next movement tick', async () => {
  const before = await scene.get('input_ticks');
  const height = (await capsule.get('position')).args[1];
  const result = await input.holdUntil({
    ...gdPredicate({value: 'capsule.global_position.y', matched: 'value >= limit'}, {
      capsule, limit: height + 0.08,
    }),
    hold: [{key: 'W', physical: true}],
    max_simulation_seconds: 1,
  });

  assert.equal(result.status, 'completed');
  assert.equal(result.reason, 'condition_matched');
  assert.equal(result.condition.matched, true);
  assert.ok(result.condition.value >= height + 0.08);
  assert.equal(result.condition.phase, 'physics_before');
  assert.equal(result.applied_ticks, (await scene.get('input_ticks')) - before);
  assert.equal(result.inputs_released, true);
  assert.deepEqual(result.input.held_inputs, []);
});

test('an immediate match skips W and gives the response its full intervals', async () => {
  const forwardBefore = await scene.get('input_ticks');
  const backBefore = await scene.get('back_ticks');
  const result = await input.holdUntil({
    ...gdPredicate('true'),
    hold: [forward],
    max_simulation_seconds: 1,
    response: {ticks: 1, events: [{at_tick: 0, pressed: true, input: backward}]},
  });

  assert.equal((await scene.get('input_ticks')) - forwardBefore, 0);
  assert.equal((await scene.get('back_ticks')) - backBefore, 1);
  assert.equal(result.response_started, true);
  assert.equal(result.response_ticks, 1);
  assert.equal(result.condition.simulation_seconds, 0);
  assert.equal(result.finished_tick, result.condition.clock.physics_tick + 1);
});

test('false predicates finish at the simulation bound with their last observation', async () => {
  const result = await input.holdUntil({
    ...gdPredicate({value: 'capsule.position.y', matched: 'false'}, {capsule}),
    hold: [forward],
    max_simulation_seconds: 0.05,
  });

  assert.equal(result.status, 'completed');
  assert.equal(result.reason, 'simulation_time_limit');
  assert.equal(result.condition.matched, false);
  assert.ok(result.condition.simulation_seconds >= 0.05);
  assert.equal(result.response_started, false);
});

test('invalid predicate results release input after a real held interval', async () => {
  const before = await scene.get('input_ticks');
  const result = await input.holdUntil({
    ...gdPredicate('false if fixture.input_ticks == before else 1', {fixture: scene, before}),
    hold: [forward],
    max_simulation_seconds: 1,
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'predicate_failed');
  assert.match(result.error.message, /matched/);
  assert.equal((await scene.get('input_ticks')) - before, 1);
  assert.deepEqual(result.input.held_inputs, []);
});

test('cancellation retains the last exact observation after the game mutates it', async () => {
  const source = `extends RefCounted

var observed: Array[Dictionary] = [{"packed": PackedInt32Array([1]), "nested": [{"x": 2}]}]

func evaluate(bindings: Dictionary) -> Dictionary:
    bindings.scene.set_meta("observed", observed)

    return {"matched": false, "value": observed}
`;
  const action = await input.startHoldUntil({
    source, bindings: {scene}, hold: [forward], max_simulation_seconds: 3,
  });

  await physicsFrames();
  await evaluate(`    bindings.scene.get_tree().paused = true
    var data: Array = bindings.scene.get_meta("observed")
    data[0].packed[0] = 99
    data[0].nested[0].x = 100

    return null`, {scene});

  try {
    await action.cancel();
    const result = await action.finished;

    assert.equal(result.status, 'cancelled');
    assert.equal(result.condition.value[0].packed.type, 'PackedInt32Array');
    assert.deepEqual(result.condition.value[0].packed.args, [1]);
    assert.equal(result.condition.value[0].nested[0].x, 2);
    assert.deepEqual(result.input.held_inputs, []);
  } finally {
    await nativeTree.set('paused', false);
    await scene.call('remove_meta', 'observed');
  }
});

test('paused operations keep wall cleanup live without sampling a predicate', async () => {
  await nativeTree.set('paused', true);

  try {
    const result = await input.holdUntil({
      ...gdPredicate('false'), hold: [forward], max_simulation_seconds: 1, max_wall_ms: 70,
    });

    assert.equal(result.reason, 'wall_time_budget');
    assert.equal(result.condition, null);
    assert.equal(result.applied_ticks, 0);
    assert.deepEqual(result.input.held_inputs, []);
  } finally {
    await nativeTree.set('paused', false);
  }
});

test('a slow true callback cannot begin a response after its wall deadline', async () => {
  const before = await scene.get('back_ticks');
  const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    OS.delay_msec(130)

    return {"matched": true, "value": 1}
`;
  const result = await input.holdUntil({
    source, hold: [forward], max_simulation_seconds: 1, max_wall_ms: 100,
    response: {ticks: 1, events: [{at_tick: 0, pressed: true, input: backward}]},
  });

  assert.equal(result.reason, 'wall_time_budget');
  assert.equal(result.condition.matched, true);
  assert.equal(result.response_started, false);
  assert.equal((await scene.get('back_ticks')) - before, 0);
});

test('freed bindings can intentionally satisfy a despawn predicate', async () => {
  const source = `extends RefCounted

var visits := 0

func evaluate(bindings: Dictionary) -> Dictionary:
    visits += 1

    if visits == 1:
        bindings.target.free()

    return {"matched": not is_instance_valid(bindings.target), "value": visits}
`;
  const node = await evaluate('    return Node3D.new()');
  const result = await input.holdUntil({
    source, bindings: {target: node}, hold: [forward], max_simulation_seconds: 1,
  });

  assert.equal(result.reason, 'condition_matched');
  assert.equal(result.condition.value, 1);
});

test('unsupported terminal values produce a failure completion', async () => {
  const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {"matched": true, "value": evaluate}
`;
  const result = await input.holdUntil({source, hold: [forward], max_simulation_seconds: 1});

  assert.equal(result.status, 'failed');
  assert.equal(result.reason, 'unsupported_result');
  assert.ok(!Object.hasOwn(result.condition, 'value'));
  assert.match(result.error.message, /transferable/);
});

test('terminal input delivery cannot recursively cancel or start another action', async () => {
  const action = await input.startHoldUntil({
    ...gdPredicate('false'), hold: [forward], max_simulation_seconds: 3,
  });

  await physicsFrames();
  await scene.set('reenter_on_release', true);
  await action.cancel();
  const result = await action.finished;
  const reentry = await scene.get('reentry_result');

  assert.equal(result.status, 'cancelled');
  assert.equal(reentry.cancel_status, 'running');
  assert.equal(reentry.start_error, -32030);
  assert.deepEqual(result.input.held_inputs, []);

  assert.equal((await input.sequence({ticks: 1})).status, 'completed');
});

test('a standalone event cannot clear ownership of a reentrantly started sequence', async () => {
  await scene.set('start_on_press', true);
  await input.invoke('press', forward);
  const action = await scene.get('reentry_action');
  const result = await input.invoke('cancel', {action});

  assert.equal(result.status, 'cancelled');
  assert.deepEqual(result.input.held_inputs, []);
});

test('a response tick is counted even when its simulation delta is zero', async () => {
  await evaluate('    Engine.time_scale = 0\n    return null');

  try {
    const result = await input.holdUntil({
      ...gdPredicate('true'), hold: [forward], max_simulation_seconds: 1,
      response: {ticks: 1, events: [{at_tick: 0, pressed: true, input: backward}]},
      max_wall_ms: 250,
    });

    assert.equal(result.reason, 'condition_matched');
    assert.equal(result.response_ticks, 1);
    assert.equal(result.simulation_seconds, 0);
  } finally {
    await evaluate('    Engine.time_scale = 1\n    return null');
  }
});

test('the saved previous delta is used when a predicate changes time scale', async () => {
  const source = `extends RefCounted

var visits := 0

func evaluate(_bindings: Dictionary) -> Dictionary:
    visits += 1
    Engine.time_scale = 2

    return {"matched": visits == 2, "value": visits}
`;
  const rate = await evaluate('    return Engine.physics_ticks_per_second');

  try {
    const result = await input.holdUntil({source, hold: [forward], max_simulation_seconds: 1});

    assert.equal(result.condition.value, 2);
    assert.ok(Math.abs(result.condition.simulation_seconds - 1 / rate) < 1e-8);
  } finally {
    await evaluate('    Engine.time_scale = 1\n    return null');
  }
});

test('a pause during gameplay does not erase the interval already scheduled', async () => {
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> Dictionary:
    bindings.scene.pause_after_tick = true
    return {"matched": false, "value": 1}
`;
  const rate = await evaluate('    return Engine.physics_ticks_per_second');

  try {
    const result = await input.holdUntil({
      source, bindings: {scene}, hold: [forward], max_simulation_seconds: 1, max_wall_ms: 100,
    });

    assert.equal(result.reason, 'wall_time_budget');
    assert.equal(result.applied_ticks, 1);
    assert.ok(Math.abs(result.simulation_seconds - 1 / rate) < 1e-8);
  } finally {
    await nativeTree.set('paused', false);
  }
});

test('a non-immediate reversal releases W and starts S at the trigger boundary', async () => {
  const before = await scene.get('input_ticks');
  const backBefore = await scene.get('back_ticks');
  const result = await input.holdUntil({
    ...gdPredicate({value: 'fixture.input_ticks', matched: 'value >= limit'}, {
      fixture: scene, limit: before + 2,
    }),
    hold: [forward], max_simulation_seconds: 1,
    response: {ticks: 3, events: [{at_tick: 0, pressed: true, input: backward}]},
  });

  assert.equal((await scene.get('input_ticks')) - before, 2);
  assert.equal((await scene.get('back_ticks')) - backBefore, 3);
  assert.equal(result.condition.value, before + 2);
  assert.equal(result.finished_tick, result.condition.clock.physics_tick + 3);
  assert.equal(result.response_ticks, 3);
});

test('disconnect cancels conditional work and releases the departing writer holds', async () => {
  const driver = await connect(fixture.url, {token: fixture.token});
  const control = await driver.root('Input');
  const action = await control.startHoldUntil({
    ...gdPredicate('false'), hold: [forward], max_simulation_seconds: 3,
  });
  let resolve;
  const completed = new Promise((done) => { resolve = done; });
  const stop = await input.subscribe('completed', (event) => {
    if (event.value.action === action.action) resolve(event.value);
  });

  try {
    await physicsFrames();
    driver.close();
    await assert.rejects(action.finished, /connection closed/);
    const result = await completed;

    assert.equal(result.reason, 'connection_closed');
    assert.equal(result.status, 'cancelled');
    assert.deepEqual(result.input.held_inputs, []);
  } finally {
    driver.close();
    await stop();
  }
});

test('a callback that stops its bridge cannot drive its retired action response', async () => {
  const isolated = await launchFixture({builtins: ['Script', 'Input']});
  const driver = await connect(isolated.url, {token: isolated.token});

  try {
    const evaluator = await driver.root('Script');
    const target = await evaluator.invoke('evaluate', {
      source: `extends RefCounted

func evaluate(_bindings: Dictionary) -> Variant:
    return Engine.get_main_loop().current_scene
`,
    });
    const control = await driver.root('Input');
    const source = `extends RefCounted

var visits := 0

func evaluate(bindings: Dictionary) -> Dictionary:
    visits += 1

    if visits == 2:
        bindings.scene.get_node("Stagehand").stop()
        var held := Input.is_action_pressed("move_forward")
        print("CONDITIONAL_STOP ", held, " ", bindings.scene.back_ticks)

    return {"matched": visits == 2, "value": visits}
`;
    const action = await control.startHoldUntil({
      source, bindings: {scene: target}, hold: [forward], max_simulation_seconds: 1,
      response: {ticks: 1, events: [{at_tick: 0, pressed: true, input: backward}]},
    });

    // A known cancellation can arrive before the close frame; otherwise the outcome is unknown.
    const outcome = await action.finished.then((result) => ({result}), (error) => ({error}));

    if (outcome.result) {
      assert.equal(outcome.result.status, 'cancelled');
      assert.equal(outcome.result.reason, 'connection_closed');
      assert.equal(outcome.result.response_started, false);
    } else {
      assert.match(outcome.error.message, /connection closed/);
    }

    await isolated.waitForOutput(/CONDITIONAL_STOP false 0/);
  } finally {
    driver.close();
    await isolated.stop();
  }
});

test('constructor-side shutdown cannot admit work for the departed peer', async () => {
  const isolated = await launchFixture({builtins: ['Script', 'Input']});
  const driver = await connect(isolated.url, {token: isolated.token});
  const observer = await connect(isolated.url, {token: isolated.token});

  try {
    const control = await driver.root('Input');

    await assert.rejects(control.startHoldUntil({
      source: shutdownEvaluator, hold: [forward], max_simulation_seconds: 1,
    }), /connection closed/);

    const output = await isolated.waitForOutput(/FIXTURE_INPUT_REPORT/);
    const report = JSON.parse(output.match(/FIXTURE_INPUT_REPORT (.+)/)[1]);

    assert.equal(report.held, false);
    assert.equal(report.input_ticks, 0);
    assert.equal(report.active, null);
  } finally {
    driver.close();
    observer.close();
    await isolated.stop();
  }
});

test('shutdown inside a raw RPC batch retires the remaining batch items', async () => {
  const isolated = await launchFixture({builtins: ['Script', 'Input']});
  const socket = new WebSocket(isolated.rpcUrl);
  await once(socket, 'open');

  try {
    const hello = once(socket, 'message');
    socket.send(JSON.stringify({
      jsonrpc: '2.0', id: 'hello', method: 'session.hello', params: {token: isolated.token},
    }));
    const session = JSON.parse((await hello)[0].data).result;
    const endpoint = session.objects.find((object) => object.label === 'Input');
    const closed = once(socket, 'close');

    socket.send(JSON.stringify([
      {
        jsonrpc: '2.0', id: 'stop', method: 'object.call',
        params: {
          object: endpoint.id,
          method: 'hold_until',
          params: {
            source: shutdownEvaluator, hold: [forward], max_simulation_seconds: 1,
          },
        },
      },
      {jsonrpc: '2.0', id: 'list', method: 'objects.list'},
    ]));
    await closed;

    const output = await isolated.waitForOutput(/FIXTURE_INPUT_REPORT/);
    const report = JSON.parse(output.match(/FIXTURE_INPUT_REPORT (.+)/)[1]);

    assert.equal(report.held, false);
    assert.equal(report.input_ticks, 0);
    assert.equal(report.active, null);
  } finally {
    socket.close();
    await isolated.stop();
  }
});
