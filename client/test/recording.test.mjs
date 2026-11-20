import assert from 'node:assert/strict';
import { test } from 'node:test';
import { connect } from '../../addons/stagehand/client.mjs';
import { launchFixture } from './fixture.mjs';

async function recording(t, {
  builtins = ['PropertyRecorder', 'Script', 'SceneTree', 'Object'], ...options
} = {}) {
  const fixture = await launchFixture({fixture: 'recording', builtins, ...options});
  let game = await connect(fixture.url, {token: fixture.token});
  t.after(async () => {
    game.close();
    await fixture.stop();
  });

  const recorder = await game.root('PropertyRecorder');
  const {scene} = await (await game.root('SceneTree')).current();

  const reconnect = async () => {
    game.close();
    game = await connect(fixture.url, {token: fixture.token});

    return game;
  };

  return {fixture, game, recorder, scene, reconnect};
}

test('native recorder checks cover snapshots, boundaries, bounds and real animation reads', async t => {
  const {game, fixture, scene} = await recording(t);
  const script = await game.root('Script');
  if (process.env.STAGEHAND_REQUIRE_NON_DOTNET === '1') {
    const features = await script.evaluate({source: `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {"mono": OS.has_feature("mono"), "csharp": ClassDB.class_exists("CSharpScript")}
`});
    assert.deepEqual(features, {mono: false, csharp: false});
  }

  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> void:
    var suite: RefCounted = load("res://native_tests.gd").new()
    bindings.scene.set("_native_tests", suite)
    suite.call_deferred("run", bindings.scene)
`;
  await script.evaluate({source, bindings: {scene}});
  const output = await fixture.waitForOutput(/PROPERTY_RECORDING_NATIVE failures=\d+/, 20_000);
  assert.match(output, /PROPERTY_RECORDING_NATIVE failures=0/);
  if (output.includes('PROPERTY_RECORDING_MEMORY skipped=unavailable')) {
    t.diagnostic('Retained-storage memory measurement skipped: this engine has no memory counters');
  }
});

test('recorder retains aligned native pages after disconnect without a consumer wrapper', async t => {
  const {game, recorder, scene, reconnect} = await recording(t);
  assert.equal(recorder.remote.client, game);
  const indexed = await recorder.inspect({object: scene, indexed: 'global_transform:origin'});
  assert.equal(indexed.value.type, 'Vector3');

  await recorder.start({
    tracks: [
      {object: scene, property: 'counter'},
      {object: scene, property: 'payload'},
    ],
    phase: 'signal', source: scene, signal: 'measured', every_n: 2, max_samples: 70,
  });
  await scene.call('emit_samples', 140);
  const retained = await (await reconnect()).root('PropertyRecorder');
  const first = await retained.read();
  const next = await retained.read({offset: first.next_offset});

  assert.equal(first.status.count, 70);
  assert.equal(first.status.stop_reason, 'sample_limit');
  assert.equal(first.status.callbacks, 139);
  assert.equal(first.status.tracks[0].property, 'counter');
  assert.equal(first.samples.length, 32);
  assert.deepEqual(first.samples.map(row => row.values[0]),
    Array.from({length: 32}, (_, index) => index * 2));
  assert.equal(next.samples[0].callback_index, 64);
  assert.equal(first.samples[0].values[1].nested[0].type, 'Vector3');
  await retained.discard();
});

test('bounded recorder pages transfer large native snapshots', async t => {
  const {recorder, scene} = await recording(t);
  await scene.set('payload', 'x'.repeat(60_000));
  await recorder.start({
    tracks: [{object: scene, property: 'payload'}],
    phase: 'signal', source: scene, signal: 'measured', max_samples: 32,
  });
  await scene.call('emit_samples', 32);
  const page = await recorder.read();

  assert.equal(page.status.count, 32);
  assert.equal(page.samples.length, 32);
  assert.equal(page.samples[31].values[0].length, 60_000);
  await assert.rejects(recorder.read({limit: 1025}), /limit/);
});

test('script tracks share the local clock and snapshot mutable results without recompiling', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

var sample := {"twice": 0}

func _init() -> void:
    var fixture: Node = Engine.get_main_loop().current_scene
    fixture.set_meta("script_instances", fixture.get_meta("script_instances", 0) + 1)
    fixture.set_meta("evaluator", weakref(self))

func evaluate(bindings: Dictionary) -> Dictionary:
    bindings.scene.sample_reads += 1
    sample.twice = bindings.scene.counter * 2
    return sample
`;
  await recorder.start({
    tracks: [
      {object: scene, property: 'counter'},
      {source, bindings: {scene}, label: 'twice'},
    ],
    phase: 'signal', source: scene, signal: 'measured', every_n: 2, max_samples: 3,
  });
  await scene.call('emit_samples', 6);
  const page = await recorder.read();

  assert.deepEqual(page.samples.map(row => row.values),
    [[0, {twice: 0}], [2, {twice: 4}], [4, {twice: 8}]]);
  assert.equal(page.status.tracks[1].selector, 'script');
  assert.equal(page.status.tracks[1].label, 'twice');
  assert.equal(await scene.get('sample_reads'), 4); // Admission plus three sampled callbacks.
  assert.equal(await scene.call('get_meta', 'script_instances'), 1);

  const weak = await scene.call('get_meta', 'evaluator');
  assert.equal(await weak.call('get_ref'), null);
});

test('scripted inspection requires Script; native reads remain independently available', async t => {
  const {recorder, scene} = await recording(t, {builtins: ['PropertyRecorder', 'SceneTree']});
  const source = 'extends RefCounted\nfunc evaluate(_bindings: Dictionary) -> int:\n\treturn 42\n';

  assert.equal((await recorder.inspect({object: scene, method: 'read_counter'})).value, 0);
  await assert.rejects(recorder.inspect({source}), /Enable Script/);
  await assert.rejects(recorder.start({tracks: [{source}]}), /Enable Script/);
  assert.equal((await recorder.remote.observe()).value.state, 'empty');
});

test('one-shot scripted inspection leaves the active capture unchanged', async t => {
  const {recorder, scene} = await recording(t);
  await recorder.start({
    tracks: [{object: scene, property: 'counter'}],
    phase: 'signal', source: scene, signal: 'measured',
  });
  await scene.call('emit_signal', 'measured');
  const observed = await recorder.inspect({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    return bindings.scene.counter + 7
`, bindings: {scene}});
  const page = await recorder.read();

  assert.equal(observed.value, 7);
  assert.equal(observed.access.selector, 'script');
  assert.equal(page.status.state, 'recording');
  assert.deepEqual(page.samples.map(row => row.values), [[0]]);
});

test('script readings at skeleton completion observe modified poses in their chosen space', async t => {
  const {game, recorder, scene} = await recording(t);
  const script = await game.root('Script');
  const skeleton = await script.evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> Skeleton3D:
    var skeleton := Skeleton3D.new()
    skeleton.position = Vector3(20, 0, 0)
    bindings.scene.add_child(skeleton)
    skeleton.add_bone("root")
    var modifier: SkeletonModifier3D = load("res://pose_modifier.gd").new()
    modifier.influence = 0.5
    skeleton.add_child(modifier)
    return skeleton
`, bindings: {scene}});
  let stopped;
  const finished = new Promise(resolve => { stopped = resolve; });
  const unsubscribe = await recorder.subscribe('stopped', stopped);

  try {
    await recorder.start({
      tracks: [
        {object: skeleton, method: 'get_bone_global_pose', args: [0]},
        {object: skeleton, property: 'global_position'},
        {source: `extends RefCounted

func evaluate(bindings: Dictionary) -> Vector3:
    return (bindings.skeleton.global_transform * bindings.skeleton.get_bone_global_pose(0)).origin
`, bindings: {skeleton}, label: 'world bone position'},
      ],
      phase: 'signal', source: skeleton, signal: 'skeleton_updated',
      max_samples: 1, max_seconds: 1,
    });
    await finished;
    const page = await recorder.read();

    assert.equal(page.status.stop_reason, 'sample_limit');
    const [pose, position, world] = page.samples[0].values;
    assert.deepEqual(pose.args.slice(-3), [0, 4, 0]);
    assert.deepEqual(world.args, [position.args[0], position.args[1] + 4, position.args[2]]);
  } finally {
    await unsubscribe();
  }
});

test('a script can stop and replace capture without writing into either completed prefix', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    if bindings.scene.counter == 1:
        bindings.recorder.stop()
        bindings.recorder.discard()
        bindings.recorder.start({
            "tracks": [{"object": bindings.scene, "property": "counter"}],
            "phase": "signal", "source": bindings.scene, "signal": "measured", "max_samples": 1,
        })
    return 99
`;
  await recorder.start({
    tracks: [{source, bindings: {recorder, scene}}],
    phase: 'signal', source: scene, signal: 'measured',
  });
  await scene.call('emit_samples', 2);
  assert.equal((await recorder.read()).status.count, 0);

  await scene.set('counter', 82);
  await scene.call('emit_signal', 'measured');
  assert.deepEqual((await recorder.read()).samples.map(row => row.values), [[82]]);
});

test('evaluator admission cannot overwrite capture through a reentrant start', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    var nested: Variant = bindings.recorder.start({
        "tracks": [{"object": bindings.scene, "property": "counter"}],
    })
    return nested.code
`;
  await recorder.start({
    tracks: [{source, bindings: {recorder, scene}}],
    phase: 'signal', source: scene, signal: 'measured', max_samples: 1,
  });
  await scene.call('emit_signal', 'measured');
  const page = await recorder.read();

  assert.equal(page.status.stop_reason, 'sample_limit');
  assert.deepEqual(page.samples[0].values, [-32602]);
});

test('rejected admission releases evaluators before allowing another capture', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

var owner: Node
var fixture: Node

func evaluate(bindings: Dictionary) -> int:
    owner = bindings.recorder
    fixture = bindings.scene
    return 8

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE and is_instance_valid(owner):
        var restarted: Variant = owner.start({
            "tracks": [{"object": fixture, "property": "counter"}],
            "phase": "signal", "source": fixture, "signal": "measured",
        })
        fixture.set_meta("admission_restart_code", restarted.get("code"))
`;

  await assert.rejects(recorder.start({
    tracks: [{source, bindings: {recorder, scene}}], max_samples: 0,
  }), {code: -32602});

  assert.equal((await recorder.observe()).value.state, 'empty');
  assert.equal(await scene.call('get_meta', 'admission_restart_code'), -32602);
});

test('a later admission reading cannot leave an earlier native schema cached', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    bindings.scene.dynamic_available = false
    bindings.scene.notify_property_list_changed()
    return 1
`;
  await recorder.start({
    tracks: [
      {object: scene, property: 'dynamic_value'},
      {source, bindings: {scene}},
    ],
    phase: 'signal', source: scene, signal: 'measured',
  });
  await scene.call('emit_signal', 'measured');
  const page = await recorder.read();

  assert.equal(page.status.stop_reason, 'track_error');
  assert.equal(page.status.error.track, 0);
  assert.equal(page.status.count, 0);
  assert.deepEqual(page.samples, []);
});

test('native admission observes a getter removing its own property', async t => {
  const {recorder, scene} = await recording(t);
  await scene.set('remove_dynamic_on_read', true);

  await assert.rejects(recorder.start({
    tracks: [{object: scene, property: 'dynamic_value'}],
    phase: 'signal', source: scene, signal: 'measured',
  }), /Read property no longer exists/);

  const state = (await recorder.observe()).value;
  assert.equal(state.state, 'empty');
  assert.equal(state.count, 0);
});

test('inspection and failed admission release native readers before the next capture', async t => {
  const {game, recorder, scene} = await recording(t);
  const script = await game.root('Script');
  const connections = () => script.evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    return (
        bindings.scene.get_signal_connection_list("property_list_changed").size()
        + bindings.scene.get_signal_connection_list("script_changed").size()
    )
`, bindings: {scene}});
  const baseline = await connections();
  const track = {object: scene, property: 'counter'};

  assert.equal((await recorder.inspect(track)).value, 0);
  await assert.rejects(recorder.inspect({object: scene, property: 'missing'}));
  assert.equal(await connections(), baseline);

  for (const params of [
    {tracks: [track], max_samples: 0},
    {tracks: [{...track, label: 5}]},
    {tracks: [track, {object: scene, property: 'missing'}]},
  ]) {
    await assert.rejects(recorder.start(params));
    assert.equal(await connections(), baseline);
    assert.equal((await recorder.observe()).value.state, 'empty');
  }

  await recorder.start({
    tracks: [track], phase: 'signal', source: scene, signal: 'measured',
  });
  await scene.call('emit_signal', 'measured');
  await recorder.stop();

  assert.deepEqual((await recorder.read()).samples.map(row => row.values), [[0]]);
  assert.equal(await connections(), baseline);
});

test('script bindings own freed-object handling instead of a blanket liveness gate', async t => {
  const {game, recorder, scene} = await recording(t);
  const script = await game.root('Script');
  const target = await script.evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> Node:
    var target := Node.new()
    bindings.scene.add_child(target)
    return target
`, bindings: {scene}});
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> bool:
    return is_instance_valid(bindings.target)
`;
  await recorder.start({
    tracks: [{source, bindings: {target}}],
    phase: 'signal', source: scene, signal: 'measured', max_samples: 2,
  });
  await scene.call('emit_signal', 'measured');
  const freed = await script.evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> bool:
    bindings.target.free()
    return not is_instance_valid(bindings.target)
`, bindings: {target}});
  assert.equal(freed, true);
  await scene.call('emit_signal', 'measured');

  assert.deepEqual((await recorder.read()).samples.map(row => row.values), [[true], [false]]);
});

test('admission rejects a native track freed by a later reading before connecting watchers', async t => {
  const {game, recorder, scene} = await recording(t);
  const script = await game.root('Script');
  const target = await script.evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> Node3D:
    var target := Node3D.new()
    bindings.scene.add_child(target)
    return target
`, bindings: {scene}});
  const source = `extends RefCounted

func evaluate(bindings: Dictionary) -> int:
    bindings.target.free()
    return 1
`;

  await assert.rejects(recorder.start({
    tracks: [
      {object: target, property: 'position'},
      {source, bindings: {target}},
    ],
    phase: 'signal', source: scene, signal: 'measured',
  }), {code: -32004});
  const state = (await recorder.observe()).value;
  assert.equal(state.state, 'empty');
  assert.equal(state.count, 0);
});

test('recorder runs under strict consumer declaration warnings', async t => {
  const {recorder, scene} = await recording(t, {strictDeclarations: true});
  assert.equal((await recorder.inspect({object: scene, property: 'counter'})).value, 0);
});

test('evaluator cleanup cannot discard retained samples or replace the closing capture', async t => {
  const {recorder, scene} = await recording(t);
  const source = `extends RefCounted

var owner: Node
var fixture: Node

func evaluate(bindings: Dictionary) -> int:
    owner = bindings.recorder
    fixture = bindings.scene
    return 8

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE and is_instance_valid(owner):
        owner.stop()
        var discarded: Variant = owner.discard()
        fixture.set_meta("cleanup_discard", discarded.code)
        var restarted: Variant = owner.start({"tracks": [{"object": fixture, "property": "counter"}]})
        fixture.set_meta("cleanup_restart", restarted.code)
`;
  await recorder.start({
    tracks: [{source, bindings: {recorder, scene}}],
    phase: 'signal', source: scene, signal: 'measured', max_samples: 1,
  });
  await scene.call('emit_signal', 'measured');
  const page = await recorder.read();

  assert.equal(page.status.stop_reason, 'sample_limit');
  assert.deepEqual(page.samples.map(row => row.values), [[8]]);
  assert.equal(await scene.call('get_meta', 'cleanup_discard'), -32602);
  assert.equal(await scene.call('get_meta', 'cleanup_restart'), -32602);
});

test('removing the recorder ends capture and releases its evaluator', async t => {
  const {game, recorder, scene} = await recording(t);
  const source = `extends RefCounted

func evaluate(_bindings: Dictionary) -> int:
    return 9
`;
  await recorder.start({
    tracks: [{source}], phase: 'signal', source: scene, signal: 'measured',
  });
  await scene.call('emit_signal', 'measured');

  const stopped = await (await game.root('Script')).evaluate({source: `extends RefCounted

func evaluate(bindings: Dictionary) -> Dictionary:
    var recorder: Node = bindings.recorder
    recorder.get_parent().remove_child(recorder)
    var stopped: Dictionary = recorder.status()
    recorder.free()
    return stopped
`, bindings: {recorder}});

  assert.equal(stopped.state, 'stopped');
  assert.equal(stopped.stop_reason, 'endpoint_removed');
  assert.equal(stopped.count, 1);
  assert.equal(await game.findObject('PropertyRecorder'), null);
});
