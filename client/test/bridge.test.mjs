import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { networkInterfaces } from 'node:os';
import { launchFixture } from './fixture.mjs';
import { connect, RpcError, GodotValue } from '../client.mjs';

let fixture, client, url, token, objects;
const graphical = process.env.STAGEHAND_GRAPHICAL === '1';
const interfaceAddress = Object.values(networkInterfaces())
  .flat()
  .find((entry) => entry.family === 'IPv4' && !entry.internal)?.address;

before(
  async () => {
    fixture = await launchFixture();
    ({ url, token } = fixture);
    client = await connect(url, { token });
    objects = (await client.objects()).filter((object) => object.kind === 'probe');
  },
  { timeout: 40_000 },
);

after(async () => {
  client?.close();
  await fixture?.stop();
});

test('handshake describes the live instance and discovers registered objects', async () => {
  assert.equal(client.session.protocol, 1);
  assert.match(client.session.instance, /^[a-f0-9]{32}$/);
  assert.equal(typeof client.session.engine.hash, 'string');
  assert.ok(client.session.clock.physics_tick >= 0);
  assert.deepEqual(
    objects.map((object) => object.label),
    ['A', 'B'],
  );
  assert.notEqual(objects[0].id, objects[1].id);
  assert.equal(objects[0].operation_info.increment.returns, 'integer count');

  const features = await (await fixtureScene()).get('runtime_features');

  assert.equal(typeof features.mono, 'boolean');
  assert.equal(typeof features.csharp, 'boolean');
  if (process.env.STAGEHAND_REQUIRE_NON_DOTNET === '1')
    assert.deepEqual(features, { mono: false, csharp: false });
  console.log('Runtime features:', features);
});

test('core roots advertise their API versions', async () => {
  const registry = await client.builtin('Registry');
  const roots = await registry.invoke('list');
  const versions = {
    Registry: '1.0.0',
    Runtime: '2.0.0',
    SceneTree: '2.0.0',
    Object: '1.0.0',
    Screen: '1.0.0',
    Input: '1.1.0',
    Script: '1.0.0',
    PropertyRecorder: '1.0.0',
  };

  for (const [label, version] of Object.entries(versions)) {
    assert.equal(roots.find((object) => object.label === label).version, version);
    assert.equal(client.session.objects.find((object) => object.label === label).version, version);

    const root = await client.builtin(label);

    assert.equal((await root.describe()).version, version);
  }
});

test('Registry lists current roots through ordinary object operations', async () => {
  const registry = await client.builtin('Registry');
  const descriptor = await registry.describe();

  assert.equal(descriptor.kind, 'Registry');
  assert.ok(descriptor.operations.includes('list'));
  assert.ok(client.session.objects.some((object) => object.id === registry.id));

  const roots = await registry.invoke('list');

  assert.deepEqual(roots, await client.objects());
  assert.deepEqual((await registry.observe()).value, roots);
  assert.equal(roots.find((object) => object.label === 'Registry').id, registry.id);

  await registry.call('unregister_object', registry.id);

  assert.ok((await registry.invoke('list')).some((object) => object.id === registry.id));
});

test('Registry remains available with optional builtins disabled', async () => {
  const isolated = await launchFixture({ builtins: [] });
  const connection = await connect(isolated.url, { token: isolated.token });

  try {
    const registry = await connection.builtin('Registry');
    const roots = await registry.invoke('list');

    assert.deepEqual(roots.map((object) => object.label), ['Registry', 'A', 'B']);
    assert.equal(await connection.findObject('Input'), null);
    assert.equal(roots[0].version, '1.0.0');
    assert.ok(roots
      .filter((object) => object.kind === 'probe')
      .every((object) => !Object.hasOwn(object, 'version')));
  } finally {
    connection.close();
    await isolated.stop();
  }
});

test('Registry reports optional game versions and follows live root lifetimes', async () => {
  const registry = await client.builtin('Registry');
  const added = new Promise((resolve) => {
    const listener = (item) => {
      if (item.method === 'objects.added' && item.params.label === 'C') {
        client.off('notification', listener);
        resolve(item.params);
      }
    };

    client.on('notification', listener);
  });
  const id = await client.object(objects[0].id).invoke('spawn', { version: 'preview-7' });
  const root = client.object(id);

  try {
    assert.equal((await added).version, 'preview-7');
    assert.equal((await root.describe()).version, 'preview-7');

    const roots = await registry.invoke('list');

    assert.equal(roots.find((object) => object.id === id).version, 'preview-7');
    assert.equal(roots.find((object) => object.label === 'Registry').id, registry.id);
    assert.ok(!Object.hasOwn(roots.find((object) => object.label === 'A'), 'version'));
    assert.deepEqual(roots, await client.objects());

    const connection = await connect(url, { token });

    try {
      assert.equal(connection.session.objects.find((object) => object.id === id).version, 'preview-7');
    } finally {
      connection.close();
    }
  } finally {
    await root.invoke('remove');
  }

  assert.ok(!(await registry.invoke('list')).some((object) => object.id === id));
});

test('findObject returns the first current label match or null', async () => {
  const a = await client.findObject('A');

  assert.equal(a.id, objects[0].id);
  assert.equal(await a.invoke('echo', { value: 'hello' }), 'hello');
  assert.equal(await client.findObject('Missing'), null);

  const spawned = [];

  try {
    spawned.push(await a.invoke('spawn'));
    spawned.push(await a.invoke('spawn'));

    assert.equal((await client.findObject('C')).id, spawned[0]);
    await client.object(spawned[0]).invoke('remove');
    spawned.shift();

    assert.equal((await client.findObject('C')).id, spawned[0]);
  } finally {
    for (const id of spawned) await client.object(id).invoke('remove');
  }

  assert.equal(await client.findObject('C'), null);
});

test('the default listener is unavailable through a non-loopback interface', async (t) => {
  if (!interfaceAddress) {
    t.skip('No non-loopback IPv4 interface is available');

    return;
  }

  const remoteUrl = new URL(url);
  remoteUrl.hostname = interfaceAddress;

  await assert.rejects(
    connect(remoteUrl.href, { token, timeoutMs: 1_000 }),
    /Cannot open Stagehand connection|Stagehand connection timed out/,
  );
});

test('explicit interface and wildcard listeners accept remote-address clients with authentication', async (t) => {
  if (!interfaceAddress) {
    t.skip('No non-loopback IPv4 interface is available');

    return;
  }

  for (const bindAddress of [interfaceAddress, '0.0.0.0']) {
    const remote = await launchFixture({ bindAddress });
    let connection;

    try {
      const remoteUrl = new URL(remote.url);
      remoteUrl.hostname = interfaceAddress;
      connection = await connect(remoteUrl.href, { token: remote.token });
      const objects = await connection.objects();
      const probe = connection.object(objects.find((object) => object.kind === 'probe').id);

      assert.equal(await probe.invoke('increment', { amount: 2 }), 2);
      assert.equal((await probe.observe()).value.count, 2);
      await assert.rejects(
        connect(remoteUrl.href, { token: 'wrong' }),
        (error) => error instanceof RpcError && error.code === -32001,
      );
    } finally {
      connection?.close();
      await remote.stop();
    }
  }
});

test('routes concurrent calls and observations to B while A stays unchanged', async () => {
  const a = client.object(objects[0].id),
    b = client.object(objects[1].id);
  const [count, state] = await Promise.all([b.invoke('increment', { amount: 7 }), a.observe()]);

  assert.equal(count, 7);
  assert.equal(state.value.count, 0);
  assert.equal((await b.observe()).value.count, 7);
});

test('live registration emits a discoverable independently addressed object', async () => {
  const added = new Promise((resolve) => {
    const listener = (item) => {
      if (item.method === 'objects.added' && item.params.label === 'C') {
        client.off('notification', listener);
        resolve(item.params);
      }
    };
    client.on('notification', listener);
  });
  const handle = await client.object(objects[0].id).invoke('spawn');

  assert.equal((await added).id, handle);

  const created = client.object(handle);

  assert.equal((await created.observe()).value.count, 0);
  assert.equal(await created.invoke('increment'), 1);
  await created.invoke('remove');
});

test('subscription is ready before an immediately emitting operation runs', async () => {
  const b = client.object(objects[1].id);
  const events = [];
  const unsubscribe = await b.subscribe('changed', (event) => events.push(event));
  const result = await b.invoke('increment', { amount: 3 });

  assert.equal(result, 10);
  assert.equal(events.length, 1);
  assert.equal(events[0].object, b.id);
  assert.equal(events[0].value, 10);
  await unsubscribe();
  await b.invoke('increment');

  assert.equal(events.length, 1);
});

test('errors are structured; unauthorized clients cannot observe or invoke', async () => {
  await assert.rejects(
    connect(url, { token: 'wrong' }),
    (error) => error instanceof RpcError && error.code === -32001,
  );
  await assert.rejects(client.request('unknown'), { code: -32601 });
  await assert.rejects(
    client.request('object.call', { object: objects[0].id, method: 'increment', params: [] }),
    { code: -32602 },
  );
  await assert.rejects(client.object('expired').observe(), { code: -32004 });
});

test('object removal invalidates handles and emits its identity', async () => {
  const removed = new Promise((resolve) => {
    const listener = (item) => {
      if (item.method === 'objects.removed' && item.params.object === objects[1].id) {
        client.off('notification', listener);
        resolve(item.params);
      }
    };
    client.on('notification', listener);
  });

  assert.equal(await client.object(objects[1].id).invoke('remove'), true);
  assert.equal((await removed).object, objects[1].id);
  await assert.rejects(client.object(objects[1].id).observe(), { code: -32004 });

  assert.equal((await client.objects()).filter((object) => object.kind === 'probe').length, 1);
});

test('a fresh connection observes current state without replaying mutations', async () => {
  const next = await connect(url, { token });

  try {
    assert.equal(next.session.instance, client.session.instance);
    assert.equal((await next.object(objects[0].id).observe()).value.count, 0);
  } finally {
    next.close();
  }
});

test('scene queries return live object handles with production reflection', async () => {
  const tree = await client.builtin('SceneTree');
  const current = await tree.invoke('current');

  assert.equal(await current.scene.get('name'), 'Fixture');

  const { nodes } = await tree.invoke('query', { name: 'A' });

  assert.equal(nodes.length, 1);

  const a = nodes[0].node;
  const description = await a.inspect();

  assert.ok(description.properties.some((property) => property.name === 'count'));
  assert.equal(await a.get('count'), 0);
  assert.equal(await a.set('count', 20), 20);
  assert.equal(await a.call('increment', { amount: 2 }), 22);
  await assert.rejects(a.get('missing_property'), { code: -32602 });
  await assert.rejects(a.call('increment', {}, {}), { code: -32602 });
  await assert.rejects(a.call('increment', 'wrong type'), { code: -32602 });
  await assert.rejects(a.set('count', {}), { code: -32602 });
  await a.set('count', -1);

  try {
    await assert.rejects(a.observe(), { code: -32040 });
  } finally {
    await a.set('count', 22);
  }
});

test('viewport dimensions use native vectors; headless capture is explicitly unavailable', async () => {
  const screen = await client.builtin('Screen');
  const viewports = await screen.invoke('viewports');
  const viewport = viewports.find((entry) => entry.path.endsWith('/TestViewport')).viewport;
  const dimensions = await screen.invoke('dimensions', { viewport });

  assert.equal(dimensions.logical_size.type, 'Vector2');
  assert.deepEqual(dimensions.logical_size.args, [320, 240]);
  assert.ok(dimensions.viewport.id);
  if (!graphical) await assert.rejects(screen.invoke('capture'), { code: -32020 });
  else {
    const capture = await screen.capture({ viewport });
    const info = await client
      .object(objects[0].id)
      .invoke('image_info', { base64: capture.image.toString('base64') });

    assert.equal(info.error, 0);
    assert.equal(info.width, 320);
    assert.equal(info.height, 240);
    assert.ok(
      info.center.args[2] > 0.65 && info.center.args[0] < 0.2,
      'known blue scene is present',
    );
  }
});

test('unsubscribe detaches local delivery before a delayed or rejected host acknowledgment', async () => {
  const a = client.object(objects[0].id),
    received = [];
  const unsubscribe = await a.subscribe('native_changed', (event) => received.push(event.value));
  const request = client.request.bind(client);
  let rejectAck, params;
  client.request = (method, value) => {
    if (method === 'object.unsubscribe') {
      params = value;

      return new Promise((_, reject) => {
        rejectAck = reject;
      });
    }

    return request(method, value);
  };

  const cancelling = unsubscribe();
  cancelling.catch(() => {});

  try {
    await a.invoke('emit_native', { value: 77 });

    assert.deepEqual(received, []);
    rejectAck(new Error('Delayed cleanup failed'));
    await assert.rejects(cancelling, /Delayed cleanup failed/);
    await a.invoke('emit_native', { value: 78 });

    assert.deepEqual(received, []);
  } finally {
    rejectAck?.(new Error('Test cleanup'));
    await cancelling.catch(() => {});
    client.request = request;
    if (params) await request('object.unsubscribe', params);
  }
});

test('native script signals are ready immediately and cleanly unsubscribe', async () => {
  const a = client.object(objects[0].id);
  const received = [];
  const unsubscribe = await a.subscribe('native_changed', (event) => received.push(event.value));
  await a.invoke('emit_native', { value: 42 });

  assert.deepEqual(received, [[42]]);
  await unsubscribe();
  await a.invoke('emit_native', { value: 43 });

  assert.deepEqual(received, [[42]]);
});

test('native signals preserve empty and arbitrary argument lists without mixing subscriptions', async () => {
  const a = client.object(objects[0].id);
  const empty = [];
  const payloads = [];
  const values = [null, 'two', [3], { four: 4 }, false];
  const stopEmpty = await a.subscribe('native_empty', (event) => empty.push(event.value));
  let stopPayload;

  try {
    stopPayload = await a.subscribe('native_payload', (event) => payloads.push(event.value));
    await a.call('emit_signal', 'native_empty');
    await a.call('emit_signal', 'native_payload', ...values);

    assert.deepEqual(empty, [[]]);
    assert.deepEqual(payloads, [values]);

    await stopPayload();
    stopPayload = null;
    await a.call('emit_signal', 'native_payload', ...values);
    await a.call('emit_signal', 'native_empty');

    assert.deepEqual(empty, [[], []]);
    assert.deepEqual(payloads, [values]);
  } finally {
    await stopEmpty();
    await stopPayload?.();
  }
});

test('Variant values preserve precision, native values, dictionaries, and live references', async () => {
  const a = client.object(objects[0].id);
  const values = [
    9223372036854775807n,
    Infinity,
    -Infinity,
    NaN,
    new GodotValue({ type: 'Vector3', args: [1, 2, 3] }),
    new GodotValue({ type: 'Transform3D', args: [1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 5, 6] }),
    new Map([
      [3, 'integer key'],
      ['$ref', 'ordinary reserved key'],
    ]),
    a,
  ];
  const result = await a.invoke('echo', { value: values });

  assert.equal(result[0], values[0]);
  assert.equal(result[1], Infinity);
  assert.equal(result[2], -Infinity);
  assert.ok(Number.isNaN(result[3]));
  assert.deepEqual(result[4].native, values[4].native);
  assert.deepEqual(result[5].native, values[5].native);
  assert.deepEqual(result[6], values[6]);
  assert.equal(result[7].id, a.id);
  await assert.rejects(a.invoke('unsupported'), { code: -32010 });
  await assert.rejects(a.invoke('large_output'), { code: -32010 });
  await assert.rejects(a.invoke('echo', { value: Array(1025).fill(0) }), { code: -32602 });
  await assert.rejects(
    a.invoke('echo', { value: new GodotValue({ type: 'Vector2', args: [1] }) }),
    { code: -32602 },
  );
  await assert.rejects(a.invoke('echo', { value: new GodotValue({ type: 'Node', props: [] }) }), {
    code: -32602,
  });
  await assert.rejects(a.invoke('echo', { value: 9223372036854775808n }), { code: -32602 });

  const cyclic = {};
  cyclic.self = cyclic;
  await assert.rejects(a.invoke('echo', { value: cyclic }), /cyclic or exceeds/);
});

async function fixtureScene() {
  return (await (await client.builtin('SceneTree')).invoke('current')).scene;
}

test('standalone action press survives its response and a separate release', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const actions = await input.invoke('actions');

  assert.ok(actions.actions.some((action) => action.name === 'move_forward'));

  const before = await scene.get('input_ticks');
  await input.invoke('press', { action: 'move_forward', strength: 0.7 });
  await new Promise((resolve) => setTimeout(resolve, 60));

  assert.equal(await scene.get('forward_held'), true);
  assert.ok(Math.abs((await scene.get('last_strength')) - 0.7) < 0.001);
  assert.ok((await scene.get('input_ticks')) > before);
  await input.invoke('release', { action: 'move_forward' });
  await new Promise((resolve) => setTimeout(resolve, 30));

  assert.equal(await scene.get('forward_held'), false);
});

test('local sequence applies exactly the requested hold ticks and reports terminal outcome', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const before = await scene.get('input_ticks');
  const action = await input.startSequence({
    ticks: 12,
    events: [{ at_tick: 0, pressed: true, input: { key: 'W', physical: true } }],
  });

  assert.equal(action.status, 'accepted');

  const result = await action.finished;

  assert.equal(result.status, 'completed');
  assert.equal(result.reason, 'sequence_exhausted');
  assert.equal(result.applied_ticks, 12);
  assert.equal(result.finished_tick - result.started_tick, 12);
  assert.equal((await scene.get('input_ticks')) - before, 12);
  assert.equal(await scene.get('forward_held'), false);
  assert.equal((await action.getStatus()).status, 'completed');
});

test('sequence boundary order, overlapping actions, and standalone hold ownership', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  await input.invoke('press', { action: 'jump' });
  await assert.rejects(
    input.invoke('sequence', {
      ticks: 2,
      events: [{ at_tick: 0, pressed: false, input: { action: 'jump' } }],
    }),
    { code: -32030 },
  );

  const before = await scene.get('input_ticks');
  const result = await input.sequence({
    ticks: 5,
    events: [
      { at_tick: 0, pressed: true, input: { action: 'move_forward' } },
      { at_tick: 2, pressed: false, input: { action: 'move_forward' } },
      { at_tick: 2, pressed: true, input: { action: 'move_forward' } },
      { at_tick: 3, pressed: false, input: { action: 'move_forward' } },
    ],
  });

  assert.equal(result.applied_ticks, 5);
  assert.equal((await scene.get('input_ticks')) - before, 3);
  // Completion released only sequence-owned inputs; explicit release still succeeds.
  assert.equal((await input.invoke('release', { action: 'jump' })).held, false);
});

test('cancellation releases held input; a second writer cannot interleave', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const action = await input.startSequence({
    ticks: 300,
    events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
  });
  const other = await connect(url, { token });

  try {
    const otherInput = await other.builtin('Input');
    await assert.rejects(otherInput.invoke('press', { action: 'jump' }), { code: -32030 });
    await assert.rejects(otherInput.invoke('cancel', { action: action.action }), { code: -32030 });

    const result = await action.cancel();

    assert.equal(result.status, 'cancelled');
    assert.equal((await action.finished).reason, 'requested');
    await new Promise((resolve) => setTimeout(resolve, 30));

    assert.equal(await scene.get('forward_held'), false);
    await otherInput.invoke('press', { action: 'jump' });
    await otherInput.invoke('release', { action: 'jump' });
  } finally {
    other.close();
  }
});

test('disconnect releases standalone holds and cancels a scheduled hold', async () => {
  const other = await connect(url, { token });
  const input = await other.builtin('Input'),
    scene = await fixtureScene();
  await input.invoke('press', { action: 'jump' });

  const action = await input.startSequence({
    ticks: 300,
    events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
  });
  await new Promise((resolve) => setTimeout(resolve, 40));

  assert.equal(await scene.get('forward_held'), true);

  const closed = once(other, 'close');
  other.close();
  await closed;
  await assert.rejects(action.finished, /outcome is unknown/);
  await new Promise((resolve) => setTimeout(resolve, 50));

  assert.equal(await scene.get('forward_held'), false);

  const mainInput = await client.builtin('Input');

  assert.equal(
    (await mainInput.invoke('status', { action: action.action })).reason,
    'connection_closed',
  );
  await mainInput.invoke('press', { action: 'jump' });
  await mainInput.invoke('release', { action: 'jump' });
});

test('wall budget and cleanup remain responsive while the scene is paused', async () => {
  const scene = await fixtureScene(),
    tree = await scene.call('get_tree');
  const input = await client.builtin('Input');
  await tree.set('paused', true);

  try {
    const result = await input.sequence({
      ticks: 60,
      max_wall_ms: 80,
      events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
    });

    assert.equal(result.status, 'failed');
    assert.equal(result.reason, 'wall_time_budget');
    assert.equal(result.applied_ticks, 0);
    assert.equal(await scene.get('forward_held'), false);
  } finally {
    await tree.set('paused', false);
  }
});

test('synthetic motion reaches actual input consumers with screen-relative fields', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const relative = new GodotValue({ type: 'Vector2', args: [12, -3] });
  const position = new GodotValue({ type: 'Vector2', args: [73, 81] });
  const before = await scene.get('event_count');

  assert.equal(
    (await input.invoke('move_mouse', { relative, position })).physical_cursor_moved,
    false,
  );
  assert.ok((await scene.get('event_count')) > before);
  assert.deepEqual((await scene.get('last_motion')).args, relative.args);
  assert.deepEqual((await scene.get('last_screen_motion')).args, relative.args);
  assert.deepEqual((await scene.get('last_position')).args, position.args);
  if (!graphical) assert.deepEqual((await scene.get('polled_mouse')).args, position.args);
  else
    console.log(
      'macOS synthetic event position / polled cursor:',
      position.args,
      (await scene.get('polled_mouse')).args,
    );
  await assert.rejects(input.invoke('press', { key: 'NOT_A_KEY' }), { code: -32602 });
  await assert.rejects(input.invoke('sequence', { ticks: 0 }), { code: -32602 });
});

test('mouse buttons reach GUI input and release polled button state', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const before = await scene.get('clicks');
  await input.invoke('press', {
    button: 'left',
    position: new GodotValue({ type: 'Vector2', args: [20, 20] }),
  });

  assert.equal(await scene.get('mouse_held'), true);
  await input.invoke('release', { button: 'left' });

  assert.equal(await scene.get('mouse_held'), false);
  assert.equal(await scene.get('clicks'), before + 1);
});

for (const operation of ['move_mouse', 'scroll']) {
  test(`${operation} exposes its cursor before reentrant button release`, async () => {
    const input = await client.builtin('Input');
    const scene = await fixtureScene();
    const origin = new GodotValue({type: 'Vector2', args: [20, 20]});
    const position = new GodotValue({type: 'Vector2', args: [160, 160]});
    await input.invoke('press', {button: 'left', position: origin});

    try {
      await scene.set('release_button_on_pointer', true);
      await input.invoke(operation, {position, ...(operation === 'scroll' ? {vertical: 1} : {})});

      assert.equal(await scene.get('mouse_held'), false);
      assert.deepEqual((await scene.get('button_release_position')).args, position.args);
      assert.deepEqual((await input.observe()).value.synthetic_position.args, position.args);
    } finally {
      await scene.set('release_button_on_pointer', false);
      if ((await input.observe()).value.held_inputs.includes('button:left')) {
        await input.invoke('release', {button: 'left'});
      }
    }
  });
}

test('scroll pulses reach a native ScrollContainer, preserve holds and obey Input ownership', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const scroll = (
    await (await client.builtin('SceneTree')).invoke('query', { name: 'ScrollTarget' })
  ).nodes[0].node;
  const position = new GodotValue({ type: 'Vector2', args: [280, 120] });
  await scroll.set('scroll_vertical', 0);
  await input.invoke('press', { key: 'W', physical: true });

  const other = await connect(url, { token });

  try {
    await assert.rejects(
      (await other.builtin('Input')).invoke('scroll', { vertical: 1, position }),
      { code: -32030 },
    );

    const result = await input.invoke('scroll', { vertical: 2.5, position });

    assert.equal(result.delivered, true);
    assert.ok((await scroll.get('scroll_vertical')) > 0);
    assert.deepEqual((await input.observe()).value.held_inputs, ['key:87:true']);
    assert.equal((await input.observe()).value.mouse_button_mask, 0);

    const events = await scene.get('wheel_events');

    assert.deepEqual(
      events.slice(-2).map((e) => [e.button, e.factor, e.pressed]),
      [
        [5, 2.5, true],
        [5, 2.5, false],
      ],
    );
    await input.invoke('scroll', { horizontal: 1.25, position });

    assert.equal((await scene.get('wheel_events')).at(-2).button, 7);

    const before = await scroll.get('scroll_vertical');
    await input.invoke('scroll', { vertical: -1, position });

    assert.ok((await scroll.get('scroll_vertical')) < before);
    await assert.rejects(input.invoke('scroll', { vertical: 'down' }), { code: -32602 });
    await assert.rejects(input.invoke('scroll', { vertical: 0 }), { code: -32602 });
  } finally {
    other.close();
    await input.invoke('release', { key: 'W', physical: true });
  }

  const action = await input.startMouseMove({ position, duration_ms: 1000 });
  await assert.rejects(input.invoke('scroll', { horizontal: 1, position }), { code: -32030 });
  await action.cancel();
  await action.finished;
});

test('one mouse-move request interpolates locally over wall time and completes at its destination', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  await scene.set('motion_samples', []);

  const from = new GodotValue({ type: 'Vector2', args: [10, 15] });
  const position = new GodotValue({ type: 'Vector2', args: [90, 55] });
  await input.invoke('press', { button: 'left', position: from });

  const started = performance.now();
  const action = await input.startMouseMove({ from, position, duration_ms: 160 });

  assert.equal(action.status, 'accepted');

  const result = await action.finished;

  assert.equal(result.reason, 'destination_events_delivered');
  assert.equal(result.physical_cursor_moved, false);
  assert.ok(result.wall_ms >= 160 && result.wall_ms < 1160);
  assert.ok(performance.now() - started >= 160);
  assert.ok(result.samples > 1);
  assert.deepEqual(result.position.args, position.args);
  assert.deepEqual(result.input.held_inputs, ['button:left']);
  assert.equal(result.input.mouse_button_mask, 1);

  const samples = await scene.get('motion_samples');

  assert.ok(samples.length > 2);
  assert.deepEqual(samples[0].position.args, from.args);
  assert.deepEqual(samples.at(-1).position.args, position.args);
  assert.ok(samples.some((sample) => sample.position.args[0] > 10 && sample.position.args[0] < 90));
  assert.ok(
    samples.every(
      (sample, index) =>
        index === 0 || sample.position.args[0] >= samples[index - 1].position.args[0],
    ),
  );
  await input.invoke('release', { button: 'left' });

  assert.equal(await scene.get('mouse_held'), false);
});

test('mouse movement shares ownership and cancellation; paused UI movement still runs', async () => {
  const input = await client.builtin('Input'),
    scene = await fixtureScene();
  const tree = await scene.call('get_tree');
  const position = new GodotValue({ type: 'Vector2', args: [30, 25] });
  const action = await input.startMouseMove({ position, duration_ms: 1000 });
  await assert.rejects(input.invoke('sequence', { ticks: 1 }), { code: -32030 });

  assert.equal((await action.cancel()).status, 'cancelled');

  const cancelled = await action.finished;
  const stopped = (await scene.get('motion_samples')).length;
  await new Promise((resolve) => setTimeout(resolve, 40));

  assert.equal((await scene.get('motion_samples')).length, stopped);
  assert.equal(cancelled.reason, 'requested');
  await tree.set('paused', true);

  try {
    const result = await input.moveMouseTo({ position, duration_ms: 60 });

    assert.equal(result.status, 'completed');
    assert.deepEqual(result.position.args, position.args);
  } finally {
    await tree.set('paused', false);
  }
  await assert.rejects(input.invoke('move_mouse_to', { position, duration_ms: -1 }), {
    code: -32602,
  });
});

test(
  'release capture contains the visible effect of real input',
  { skip: !graphical },
  async () => {
    const screen = await client.builtin('Screen');
    const viewport = (await screen.invoke('viewports')).find((entry) =>
      entry.path.endsWith('/TestViewport'),
    ).viewport;
    const capture = await screen.capture({ viewport });
    const info = await client
      .object(objects[0].id)
      .invoke('image_info', { base64: capture.image.toString('base64') });

    assert.equal(info.error, 0);
    assert.ok(
      info.center.args[0] > 0.75 && info.center.args[2] < 0.15,
      'input changed the rendered panel to red',
    );
  },
);

test('wire validation distinguishes malformed requests, notifications, and batches', async () => {
  const socket = new WebSocket(url);
  await once(socket, 'open');

  const exchange = async (value) => {
    const received = once(socket, 'message');
    socket.send(typeof value === 'string' ? value : JSON.stringify(value));

    return JSON.parse((await received)[0].data);
  };

  try {
    assert.equal((await exchange('{')).error.code, -32700);
    assert.equal((await exchange(1)).error.code, -32600);
    assert.equal(
      (await exchange({ jsonrpc: '2.0', id: 'unauth', method: 'objects.list' })).error.code,
      -32001,
    );

    const responses = await exchange([
      { jsonrpc: '2.0', id: 'hello', method: 'session.hello', params: { token } },
      { jsonrpc: '2.0', id: 'list', method: 'objects.list' },
      { jsonrpc: '2.0', method: 'unknown_notification' },
    ]);

    assert.deepEqual(
      responses.map((response) => response.id),
      ['hello', 'list'],
    );
    assert.equal(
      (await exchange([[{ jsonrpc: '2.0', id: 1, method: 'objects.list' }]]))[0].error.code,
      -32600,
    );
    assert.equal(
      (await exchange({ jsonrpc: '2.0', id: {}, method: 'objects.list' })).error.code,
      -32600,
    );
  } finally {
    socket.close();
  }
});

test(
  'builtins are optional; removing Input releases held state without disabling fixture objects',
  { timeout: 40_000 },
  async () => {
    const isolated = await launchFixture({ builtins: ['Input', 'Object', 'SceneTree'] });
    const connection = await connect(isolated.url, { token: isolated.token });

    try {
      await assert.rejects(connection.builtin('Screen'), /unavailable/);

      const probe = connection.object(
        (await connection.objects()).find((object) => object.label === 'A').id,
      );

      assert.equal(await probe.invoke('increment'), 1);

      const input = await connection.builtin('Input');
      const action = await input.startSequence({
        ticks: 300,
        events: [{ at_tick: 0, pressed: true, input: { action: 'move_forward' } }],
      });
      await input.call('queue_free');
      await assert.rejects(action.finished, /endpoint was removed/);

      const scene = (await (await connection.builtin('SceneTree')).invoke('current')).scene;
      await new Promise((resolve) => setTimeout(resolve, 30));

      assert.equal(await scene.get('forward_held'), false);
      assert.equal((await probe.observe()).value.count, 1);
    } finally {
      connection.close();
      await isolated.stop();
    }
  },
);

test('qualification records loopback RPC and bounded-action timing without transport benchmarks', async () => {
  const a = client.object(objects[0].id),
    samples = [];
  for (let i = 0; i < 10; i++) {
    const start = performance.now();
    await a.observe();
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  console.log(
    'RPC wall ms (10 sequential observations):',
    JSON.stringify({
      minimum: samples[0],
      median: samples[5],
      maximum: samples.at(-1),
      engine: client.session.engine.string,
      graphical,
    }),
  );
});

test('the standalone JS example observes, executes locally, and checks fixture movement', () => {
  const example = spawnSync(
    process.execPath,
    [fileURLToPath(new URL('../examples.mjs', import.meta.url))],
    {
      env: { ...process.env, STAGEHAND_URL: url, STAGEHAND_TOKEN: token },
      encoding: 'utf8',
      timeout: 10_000,
    },
  );

  assert.equal(example.status, 0, `${example.stdout}\n${example.stderr}`);
  assert.match(example.stdout, /Fresh input state/);
});

test('removing the bridge cleans held inputs and ordinary fixture physics continues', async () => {
  const input = await client.builtin('Input');
  await input.invoke('press', { action: 'move_forward' });

  const closed = once(client, 'close');
  await client.object(objects[0].id).invoke('retire');
  await closed;
  await new Promise((resolve) => setTimeout(resolve, 160));

  const match = fixture.output().match(/FIXTURE_WITHOUT_BRIDGE (\{.*\})/);

  assert.ok(match, fixture.output());
  assert.deepEqual(JSON.parse(match[1]), { advanced: true, held: false, present: false });
});
