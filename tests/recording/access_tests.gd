extends RefCounted

const Failure = preload("res://addons/stagehand/failure.gd")
const PoseModifier = preload("res://pose_modifier.gd")

var failures := 0
var _fixture: Node3D
var _recorder: Node


class Original extends RefCounted:
	func read_amount() -> int:
		return 13


class Replacement extends RefCounted:
	pass


func run(fixture: Node3D, recorder: Node) -> int:
	_fixture = fixture
	_recorder = recorder

	_test_properties_and_indexing()
	_test_arguments_and_resolution()
	_test_typed_arguments()
	_test_invalid_admission()
	_test_method_replacement()
	_test_target_and_path_loss()
	_test_getter_lifecycle()
	_test_animation_parameters()
	await _test_completed_pose()

	_recorder.stop()
	_recorder.discard()

	return failures


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _start(tracks: Array, extra: Dictionary = { }) -> Variant:
	_recorder.stop()
	_recorder.discard()

	var params := { "tracks": tracks, "phase": "signal", "source": _fixture, "signal": "measured" }
	params.merge(extra, true)

	return _recorder.start(params)


func _test_properties_and_indexing() -> void:
	var plain := { "object": _fixture, "property": "global_transform" }
	var indexed := { "object": _fixture, "indexed": "global_transform:origin" }

	_start([plain, indexed], { "max_samples": 1 })
	_fixture.measured.emit()

	var row: Dictionary = _recorder.read({ }).samples[0]
	_check(
		row.values[0] == _fixture.global_transform,
		"Plain native transform reading must remain supported",
	)

	_check(
		row.values[1] == row.values[0].origin,
		"Indexed paths must use native transform subproperties",
	)

	_check(
		_recorder.inspect(indexed).value == row.values[1],
		"Inspection must share indexed read semantics",
	)

	_check(
		_recorder.inspect({ "object": _fixture, "property": "counter" }).value == _fixture.counter,
		"Plain inspection must use the same property selector",
	)


func _test_arguments_and_resolution() -> void:
	var spec := { "object": _fixture, "method": "read_counter", "args": [2] }

	_start([spec], { "every_n": 3, "max_samples": 3 })

	var reads: int = _fixture.sample_reads

	spec.args[0] = 99
	_fixture.emit_samples(7)

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows.map(
			func(row):
				return row.values[0],
		)
		== [0, 6, 12],
		"Bound arguments must be reused without following caller mutations",
	)

	_check(
		_fixture.sample_reads - reads == 3,
		"Every-N skipping must also skip parameterized getters",
	)

	var nested := { "nested": { "number": 8 } }

	_start(
		[{ "object": _fixture, "method": "read_number", "args": [nested] }],
		{ "max_samples": 1 },
	)
	nested.nested.number = 27
	_fixture.measured.emit()

	_check(
		_recorder.read({ }).samples[0].values == [8],
		"Nested getter arguments must be frozen at binding",
	)

	var current: Variant = _recorder.inspect({ "object": _fixture, "method": "read_counter" }).value
	_check(
		current == _fixture.counter,
		"Reflected default getter arguments must work in one-shot inspection",
	)


func _test_typed_arguments() -> void:
	var numbers: Array[int] = [2, 3]
	var totals: Dictionary[String, int] = { "first": 2, "second": 3 }
	var packed := PackedInt32Array([7])
	var array_spec := { "object": _fixture, "method": "read_sum", "args": [numbers] }
	var dictionary_spec := { "object": _fixture, "method": "read_total", "args": [totals] }
	var packed_spec := { "object": _fixture, "method": "read_packed", "args": [packed] }

	_check(
		_recorder.inspect(array_spec).value == 5,
		"Typed array arguments must reach their native getter",
	)

	_check(
		_recorder.inspect(dictionary_spec).value == 5,
		"Typed dictionary arguments must reach their native getter",
	)

	_start([array_spec, dictionary_spec, packed_spec], { "max_samples": 1 })

	numbers[0] = 90
	totals.first = 90
	packed[0] = 90
	_fixture.measured.emit()

	_check(
		_recorder.read({ }).samples[0].values == [5, 5, 7],
		"Bound typed containers must preserve their argument types and independent snapshots",
	)

	var reads: int = _fixture.sample_reads

	for spec: Dictionary in [
		{ "object": _fixture, "method": "read_sum", "args": [[2, 3]] },
		{ "object": _fixture, "method": "read_total", "args": [{ "first": 2 }] },
	]:
		_check(
			_recorder.inspect(spec) is Failure,
			"Untyped arguments must fail before calling a typed getter",
		)

		_check(
			_start([spec]) is Failure,
			"Recording must reject the same incompatible typed argument",
		)

	_check(
		_fixture.sample_reads == reads,
		"Rejected typed arguments must never invoke their getter",
	)


func _test_invalid_admission() -> void:
	var selectors := [
		{ "property": "position", "method": "get_position" },
		{ "indexed": "global_transform:missing" },
		{ "indexed": "missing:origin" },
		{ "method": "missing" },
		{ "method": "read_counter", "args": ["wrong"] },
		{ "method": "read_counter", "args": [1, 2] },
		{ "method": "read_number", "args": [] },
		{ "property": "position", "args": [] },
	]

	for selector: Dictionary in selectors:
		selector["object"] = _fixture

		_check(
			_start([selector]) is Failure,
			"Invalid read selectors/arguments must fail before capture",
		)

		_check(
			_recorder.inspect(selector) is Failure,
			"Inspection must reject the same invalid read",
		)

	_check(_recorder.status().state == "empty", "Admission failures must not create a recording")


func _test_method_replacement() -> void:
	var target := Original.new()

	_start([{ "object": target, "method": "read_amount" }])
	_fixture.measured.emit()
	target.set_script(Replacement)
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "track_error" and _recorder.status().count == 1,
		"Script changes must revalidate methods and preserve the completed prefix",
	)


func _test_target_and_path_loss() -> void:
	var target: RefCounted = Original.new()
	var weak: WeakRef = weakref(target)

	_start([{ "object": target, "method": "read_amount" }])
	_fixture.measured.emit()
	target = null
	_fixture.measured.emit()

	_check(
		weak.get_ref() == null and _recorder.status().count == 1,
		"Bound methods must not keep RefCounted targets alive",
	)

	_check(_recorder.status().stop_reason == "track_error", "Lost method targets must stop visibly")

	_fixture.payload = { "nested": { "number": 8 } }

	_start([{ "object": _fixture, "indexed": "payload:nested:number" }])
	_fixture.measured.emit()

	_fixture.payload.nested.erase("number")
	_fixture.measured.emit()

	_check(
		_recorder.status().count == 1 and _recorder.status().stop_reason == "track_error",
		"A disappearing indexed leaf must not become a plausible null sample",
	)

	_fixture.payload = null

	_check(
		_recorder.inspect({ "object": _fixture, "property": "payload" }).value == null,
		"Plain nullable properties must remain distinguishable from invalid indexed reads",
	)


func _test_getter_lifecycle() -> void:
	_fixture.lifecycle_recorder = _recorder

	for action: StringName in [&"stop", &"discard", &"restart"]:
		_start([{ "object": _fixture, "method": "read_lifecycle" }])
		_fixture.measured.emit()

		_fixture.lifecycle_action = action
		_fixture.measured.emit()

		_check(_fixture.stopped_count == 1, "Method-side stop must report only completed rows")

		var expected := 1 if action == &"stop" else 0
		_check(
			_recorder.status().count == expected,
			"Method lifecycle changes must interrupt the current row",
		)

		if action == &"restart":
			_fixture.counter = 82
			_fixture.measured.emit()

			_check(
				_recorder.read({ }).samples[0].values == [82],
				"Restarted method capture must own its next row",
			)

	_fixture.lifecycle_recorder = null


func _test_animation_parameters() -> void:
	var blend := AnimationNodeBlendSpace1D.new()
	var args: Array = [AnimationNodeAnimation.new(), 0, -1]
	if Callable(blend, "add_blend_point").get_argument_count() > 3:
		args.append(&"Idle")

	blend.callv("add_blend_point", args)

	var first := AnimationTree.new()
	var second := AnimationTree.new()
	first.tree_root = blend
	second.tree_root = blend
	_fixture.add_child(first)
	_fixture.add_child(second)

	first.active = false
	second.active = false
	first.set("parameters/blend_position", 0.25)
	second.set("parameters/blend_position", -0.5)

	var spec := { "object": first, "property": "parameters/blend_position" }

	_start([spec], { "max_samples": 1 })
	_fixture.measured.emit()

	_check(
		_recorder.read({ }).samples[0].values == [0.25],
		"AnimationTree parameters must read the selected instance",
	)

	_check(
		_recorder.inspect(spec).value == 0.25 and second.get("parameters/blend_position") == -0.5,
		"Shared AnimationNode resources must not merge distinct instance parameter values",
	)

	_start([spec])
	_fixture.measured.emit()

	first.tree_root = AnimationNodeAnimation.new()
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "track_error" and _recorder.status().count == 1,
		"A lazily removed AnimationTree parameter must not append a stale or null value",
	)

	first.free()
	second.free()


func _test_completed_pose() -> void:
	var skeleton := Skeleton3D.new()
	_fixture.add_child(skeleton)
	skeleton.position = Vector3(20, 0, 0)
	skeleton.add_bone("root")

	var modifier := PoseModifier.new()
	modifier.influence = 0.5
	skeleton.add_child(modifier)

	var spec := { "object": skeleton, "method": "get_bone_global_pose", "args": [0] }
	var inspected: Array = []
	skeleton.skeleton_updated.connect(
		func():
			inspected.append(_recorder.inspect(spec).value),
	)

	_start([spec], { "source": skeleton, "signal": "skeleton_updated", "max_samples": 1 })

	for frame: int in 30:
		if _recorder.status().state == "stopped":
			break

		await _fixture.get_tree().process_frame

	var rows: Array = _recorder.read({ }).samples
	_check(rows.size() == 1, "Native skeleton completion must trigger bound getter capture")

	if not rows.is_empty():
		_check(
			rows[0].values[0] is Transform3D and rows[0].values[0].origin == Vector3(0, 4, 0),
			"Captured pose must include the modifier's influence and remain skeleton-relative",
		)

		_check(
			not inspected.is_empty() and inspected[0] == rows[0].values[0],
			"One-shot and recorded completion reads must observe the same modified pose",
		)

	skeleton.free()
