import assert from 'node:assert/strict';
import {test} from 'node:test';
import {connect} from '../client.mjs';
import {launchFixture} from './fixture.mjs';

test('modern bridges leave legacy implementations unloaded', async t => {
  const fixture = await launchFixture({builtins: ['Script', 'Input', 'PropertyRecorder']});
  const game = await connect(fixture.url, {token: fixture.token});
  t.after(async () => {
    game.close();
    await fixture.stop();
  });
  const loaded = await (await game.builtin('Script')).evaluate({source: `extends RefCounted

func evaluate(_bindings: Dictionary) -> Dictionary:
    return {
        "json": ResourceLoader.has_cached("res://addons/stagehand/compat43_json.gd"),
        "signals": ResourceLoader.has_cached("res://addons/stagehand/compat43_signals.gd"),
    }
`});

  assert.deepEqual(loaded, {json: false, signals: false});
});

test('4.3 shims preserve native JSON values and arbitrary signal arity', async t => {
  const fixture = await launchFixture({builtins: ['Script']});
  const game = await connect(fixture.url, {token: fixture.token});
  t.after(async () => {
    game.close();
    await fixture.stop();
  });
  const script = await game.builtin('Script');
  const differences = await script.evaluate({source: `extends RefCounted

func evaluate(_bindings: Dictionary) -> Array:
    var codec: RefCounted = load("res://addons/stagehand/compat43_json.gd").new()
    var basis := Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 10))
    var values := [
        Vector2(1.25, -2), Vector2i(1, -2), Vector3(1, 2, 3), Vector3i(4, 5, 6),
        Vector4(1, 2, 3, 4), Vector4i(5, 6, 7, 8), Rect2(1, 2, 3, 4), Rect2i(1, 2, 3, 4),
        Plane(Vector3.UP, 2), Quaternion(0, 0, 0, 1), Color(0.25, 0.5, 0.75, 1),
        AABB(Vector3.ONE, Vector3(2, 3, 4)), basis,
        Transform2D(Vector2(2, 3), Vector2(4, 5), Vector2(6, 7)),
        Transform3D(basis, Vector3(11, 12, 13)), Projection.IDENTITY,
        PackedByteArray([1, 2]), PackedInt32Array([-3, 4]), PackedInt64Array([-5, 6]),
        PackedFloat32Array([1.25]), PackedFloat64Array([2.5]), PackedStringArray(["hello", "世界"]),
        PackedVector2Array([Vector2(1, 2)]), PackedVector3Array([Vector3(3, 4, 5)]),
        PackedVector4Array([Vector4(6, 7, 8, 9)]), PackedColorArray([Color.RED]),
        StringName("named"), NodePath("/root"), 9223372036854775807,
    ]
    var differences: Array = []
    for value: Variant in values:
        var native: Variant = JSON.from_native(value)
        if codec.from_native(value) != native or codec.to_native(native) != value:
            differences.append(type_string(typeof(value)))
    return differences
`});
  assert.deepEqual(differences, []);

  const collected = await script.evaluate({source: `extends RefCounted

func evaluate(_bindings: Dictionary) -> Array:
    var factory: GDScript = load("res://addons/stagehand/compat43_signals.gd")
    var observed: Array = []
    var receive := func(args: Array) -> void:
        observed.append(args)
    var target := RefCounted.new()
    target.add_user_signal("empty")
    var arguments: Array = []
    for index: int in 12:
        arguments.append({"name": "argument%d" % index, "type": TYPE_INT})
    target.add_user_signal("many", arguments)
    target.connect("empty", factory.create(target, "empty", receive))
    target.connect("many", factory.create(target, "many", receive))
    target.emit_signal("empty")
    target.emit_signal.callv(["many"] + range(12))
    return observed
`});
  assert.deepEqual(collected, [[], Array.from({length: 12}, (_, index) => index)]);
});
