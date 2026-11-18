extends RefCounted

const Bridge = preload("res://addons/stagehand/bridge.gd")
const Recorder = preload("res://addons/stagehand/property_recorder.gd")
const Failure = preload("res://addons/stagehand/failure.gd")
const Codec = preload("res://addons/stagehand/values.gd")
const Fixture = preload("res://fixture.gd")

var failures := 0
var _fixture: Fixture
var _recorder: Recorder


class CodecProbe extends Codec:
	var calls := 0


	func encode(value: Variant, depth: int = 0) -> Variant:
		calls += 1
		return super.encode(value, depth)


func run(fixture: Fixture) -> void:
	_fixture = fixture

	var bridge := Bridge.new()
	fixture.add_child(bridge)
	_recorder = Recorder.new()
	bridge.add_child(_recorder)
	_recorder.install(bridge)

	_test_admission()
	_test_symbols()
	_test_property_schema()
	_test_resolution()
	_test_fixed_snapshots()
	_test_fixed_storage()
	_test_getter_lifecycle()
	_test_snapshots()
	_test_types()
	_test_value_changes_and_budget()
	_test_nested_snapshots()
	_test_pages()
	_test_failures()
	_test_byte_bound()
	await _test_physics_and_process()
	await _test_physics_resolution()
	await _test_signal_lifetime()
	await _test_quiet_freed_target()
	failures += await preload("res://access_tests.gd").new().run(fixture, _recorder)

	print("PROPERTY_RECORDING_NATIVE failures=", failures)
	fixture.get_tree().quit(0 if failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _track(property: String, target: Object = null) -> Dictionary:
	return { "object": _fixture if target == null else target, "property": property }


func _start(properties: Array, extra: Dictionary = { }) -> Variant:
	_recorder.stop()
	_recorder.discard()

	var params := {
		"tracks": properties.map(_track),
		"phase": "signal",
		"source": _fixture,
		"signal": "measured",
	}
	params.merge(extra, true)

	return _recorder.start(params)


func _test_admission() -> void:
	_check(
		not _recorder.is_processing() and not _recorder.is_physics_processing(),
		"An idle recorder must not run per-frame sampling callbacks",
	)

	_check(_recorder.start({ }) is Failure, "Empty track selections must fail")

	_check(_start(["unknown"]) is Failure, "Unknown properties must fail before starting")

	_check(_recorder.status().state == "empty", "Rejected capture must leave no retained state")

	_check(_start(["counter"], { "max_samples": 1.5 }) is Failure, "Fractional limits must fail")

	_check(
		_start(["counter"], { "signal": "missing" }) is Failure,
		"Unknown sampling signals must fail",
	)

	_start(["counter"])

	_check(_recorder.start({ }) is Failure, "A second start must not replace an active capture")

	_check(_recorder.discard() is Failure, "Discard must not silently stop an active capture")

	_recorder.stop()

	_check(_recorder.status().stop_reason == "requested", "Explicit stop needs a visible reason")

	_check(
		_recorder.start({ }) is Failure,
		"Stopped data needs explicit discard before another start",
	)


func _test_symbols() -> void:
	_recorder.discard()

	var started: Dictionary = _recorder.start(
		{
			"tracks": [{ "object": _fixture, "property": &"counter" }],
			"phase": &"signal",
			"source": _fixture,
			"signal": &"measured",
			"max_samples": 1,
		}
	)

	_check(
		started.phase is String and started.phase == "signal",
		"Internal phase identifiers must retain their public string representation",
	)

	_check(
		started.signal is String and started.tracks[0].property is String,
		"Cached engine names must not change metadata into native symbol values",
	)

	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "sample_limit",
		"Symbol names must select the real sampling signal",
	)


func _test_snapshots() -> void:
	_start(["counter", "payload", "packed"])
	_fixture.counter = 10
	_fixture.measured.emit()

	_fixture.payload.nested[1].number = 9
	_fixture.packed[0] = Vector3(9, 9, 9)
	_fixture.counter = 20
	_fixture.measured.emit()
	_recorder.stop()

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows.size() == 2 and rows[0].values[0] == 10 and rows[1].values[0] == 20,
		"One signal must produce one aligned multi-track row",
	)

	_check(rows[0].values[1].nested[1].number == 1, "Nested containers must be snapshots")

	_check(rows[0].values[2][0] == Vector3.ONE, "Packed arrays must be snapshots")

	_check(rows[0].index == 0 and rows[1].index == 1, "Rows need contiguous chronological indices")

	_check(
		rows[1].elapsed_usec >= rows[0].elapsed_usec,
		"Elapsed timestamps must not run backwards",
	)

	rows[0].values[1].nested[1].number = 99
	rows[0].values[2][0] = Vector3(99, 99, 99)

	_check(
		_recorder.read({ }).samples[0].values[1].nested[1].number == 1,
		"Editing a returned page must not change retained samples",
	)

	_check(
		_recorder.read({ }).samples[0].values[2][0] == Vector3.ONE,
		"Editing a returned packed array must not change retained samples",
	)


func _test_resolution() -> void:
	_start(["counted", "counter"], { "every_n": 3, "max_samples": 3 })

	var reads: int = _fixture.sample_reads

	_fixture.emit_samples(7)

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows.size() == 3 and _recorder.status().callbacks == 7,
		"Every-N resolution must count callbacks while retaining only the aligned subset",
	)

	for index: int in rows.size():
		var callback := index * 3
		_check(
			rows[index].callback_index == callback and rows[index].values == [callback, callback],
			"All tracks must share the same selected callback",
		)

	_check(_fixture.sample_reads - reads == 3, "Skipped callbacks must not invoke getters")

	_check(_start(["counter"], { "every_n": 0 }) is Failure, "Resolution must be positive")


func _test_fixed_snapshots() -> void:
	_start(["captured_transform", "captured_color"])
	_fixture.measured.emit()

	_fixture.captured_transform.origin.y = 9
	_fixture.captured_color.r = 0.25
	_fixture.measured.emit()
	_recorder.stop()

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows[0].values[0] == Transform3D.IDENTITY and rows[0].values[1] == Color.RED,
		"Native value columns must preserve earlier transform/color values",
	)

	_check(
		rows[1].values[0].origin.y == 9 and rows[1].values[1].r == 0.25,
		"Native columns must retain subsequent fixed-size values without conversion loss",
	)


func _test_fixed_storage() -> void:
	_start(["position", "idle_position", "counter", "physics_tick"], { "max_samples": 2000 })

	var codec: Codec = _recorder.get("_codec")
	var probe := CodecProbe.new(codec.bridge)
	_recorder.set("_codec", probe)
	_fixture.emit_samples(2)

	var before := OS.get_static_memory_usage()
	_fixture.emit_samples(1000)

	var after := OS.get_static_memory_usage()
	_recorder.stop()
	_recorder.set("_codec", codec)

	if before > 0:
		_check(after == before, "Preallocated numeric capture must not grow retained storage")
	else:
		print("PROPERTY_RECORDING_MEMORY skipped=unavailable")

	_check(probe.calls == 0, "Capture must defer wire encoding until retrieval")


func _test_getter_lifecycle() -> void:
	_fixture.lifecycle_recorder = _recorder

	for action: StringName in [&"stop", &"discard", &"restart"]:
		_start(["counter", "lifecycle_value"])
		_fixture.measured.emit()

		_fixture.lifecycle_action = action
		_fixture.measured.emit()

		_check(_fixture.stopped_count == 1, "Getter-side stop must report only complete rows")

		if action == &"stop":
			_check(
				_recorder.status().count == 1,
				"No row may commit after stopped status is published",
			)

		else:
			_check(
				_recorder.status().count == 0,
				"Interrupted rows must not enter a replacement buffer",
			)

		if action == &"restart":
			_fixture.counter = 81
			_fixture.measured.emit()

			_check(
				_recorder.read({ }).samples[0].values == [81],
				"The next callback must sample only the restarted capture's tracks",
			)

	_fixture.lifecycle_recorder = null


func _test_property_schema() -> void:
	_start(["dynamic_value"])

	var reads: int = _fixture.property_list_reads
	_fixture.measured.emit()
	_fixture.measured.emit()

	_check(
		_fixture.property_list_reads == reads,
		"An unchanged property schema must not be enumerated for each sample",
	)

	_fixture.dynamic_available = false
	_fixture.notify_property_list_changed()
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "track_error" and _recorder.status().count == 2,
		"A notified property removal must stop without losing the completed prefix",
	)

	_fixture.dynamic_available = true
	_fixture.notify_property_list_changed()


func _test_types() -> void:
	_fixture.payload = [
		null,
		true,
		"value",
		9007199254740993,
		INF,
		Vector2(1, 2),
		Vector3i(3, 4, 5),
		Color.RED,
		Quaternion.IDENTITY,
		Transform2D.IDENTITY,
		Transform3D.IDENTITY,
		Basis.IDENTITY,
		Projection.IDENTITY,
		Plane(Vector3.UP, 1),
		AABB(Vector3.ZERO, Vector3.ONE),
		Rect2(Vector2.ZERO, Vector2.ONE),
		Vector4.ONE,
		{ 3: [Color.BLUE], "$godot": "literal" },
	]

	_start(["payload"], { "max_samples": 1 })
	_fixture.measured.emit()

	var row: Dictionary = _recorder.read({ }).samples[0]
	_check(
		row.values[0] == _fixture.payload,
		"Supported native values must retain their types and data",
	)

	_check(
		_recorder.status().stop_reason == "sample_limit",
		"Sample cap must stop rather than overwrite",
	)


func _test_value_changes_and_budget() -> void:
	var values := [
		"escaped\t\n\"\\é",
		{ "$godot": "literal", 4: PackedStringArray(["a\n", "é"]) },
		Transform3D(Basis.IDENTITY, Vector3(1e20, 0, 0)),
	]

	_start(["payload"])
	for value: Variant in values.slice(0, 2):
		_fixture.payload = value
		_fixture.measured.emit()
	_fixture.payload = values[2]
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "value_error" and _recorder.status().count == 2,
		"Invalid native components must refuse only the incomplete row",
	)

	var page: Dictionary = _recorder.read({ })
	_check(
		page.samples[0].values[0] == values[0] and page.samples[1].values[0] == values[1],
		"A property may change native value type without rewriting earlier rows",
	)

	var codec: Codec = _recorder.get("_codec")
	var wire_bytes := JSON.stringify(codec.encode(page.samples)).to_utf8_buffer().size()
	_check(
		wire_bytes <= page.status.bytes,
		"Escaped strings and native dictionary envelopes must fit the conservative wire charge",
	)


func _test_nested_snapshots() -> void:
	var nested: Variant = 1
	for level: int in 4:
		nested = { level: nested }
	_fixture.payload = nested

	_start(["payload"])
	_fixture.measured.emit()

	_check(
		_recorder.read({ }).samples[0].values[0] == nested,
		"Supported nested dictionary envelopes must remain retrievable",
	)

	_fixture.payload = { 0: nested }
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "track_error" and _recorder.status().count == 1,
		"Native dictionary envelopes exceeding the response nesting budget must be refused",
	)


func _test_pages() -> void:
	_start(["counter"], { "max_samples": 70 })
	_fixture.emit_samples(70)

	var first: Dictionary = _recorder.read({ })
	var next: Dictionary = _recorder.read({ "offset": first.next_offset })
	_check(
		first.samples.size() == 32 and next.samples[0].index == 32,
		"Pages must preserve chronology",
	)

	_check(_recorder.read({ "offset": 70 }).samples.is_empty(), "End reads must be empty")

	_check(_recorder.read({ "limit": 33 }) is Failure, "Oversized pages must fail explicitly")

	_fixture.measured.emit()

	_check(_recorder.status().count == 70, "Stopped capture must ignore later sampling signals")


func _test_failures() -> void:
	_fixture.payload = _fixture

	_start(["counter", "payload"])
	_fixture.measured.emit()

	_check(
		_recorder.status().count == 0 and _recorder.status().error.track == 1,
		"Unsupported values must identify the track and refuse the incomplete row",
	)

	var target := Node3D.new()
	_fixture.add_child(target)
	_recorder.discard()
	_recorder.start(
		{
			"tracks": [_track("position", target)],
			"phase": "signal",
			"source": _fixture,
			"signal": "measured",
		}
	)
	_fixture.measured.emit()
	target.free()
	_fixture.measured.emit()

	_check(
		_recorder.status().count == 1 and _recorder.status().stop_reason == "track_error",
		"A freed target must stop while preserving earlier rows",
	)

	_fixture.payload = "x".repeat(70000)

	_start(["payload"])
	_fixture.measured.emit()

	_check(
		_recorder.status().stop_reason == "sample_too_large",
		"An unretrievable row must be refused",
	)


func _test_byte_bound() -> void:
	_fixture.payload = "x".repeat(60000)

	_start(["payload"], { "max_samples": 1000 })
	_fixture.emit_samples(400)

	var status: Dictionary = _recorder.status()
	_check(
		status.stop_reason == "byte_limit" and status.bytes <= status.max_bytes,
		"Total byte cap must preserve the complete prefix without a ring-buffer overwrite",
	)


func _test_physics_and_process() -> void:
	_start(["physics_tick", "position"], { "phase": "physics", "max_samples": 3 })
	await _wait_for_stop()
	for row: Dictionary in _recorder.read({ }).samples:
		_check(
			row.values[0] == row.values[1].x,
			"Physics tracks must share the post-controller boundary",
		)

		_check(
			row.physics_frame is int and row.physics_frame >= 0
			and row.process_frame is int and row.process_frame >= 0,
			"Rows need both engine frame identifiers, including initial frame zero",
		)

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows.size() == 3 and rows[2].physics_frame == rows[0].physics_frame + 2,
		"Physics sampling must follow consecutive local steps",
	)

	_start(["idle_tick", "idle_position"], { "phase": "process", "max_samples": 2 })
	await _wait_for_stop()

	_check(_recorder.status().count == 2, "Process recording must be locally clocked")

	for row: Dictionary in _recorder.read({ }).samples:
		_check(
			row.values[0] == row.values[1].y,
			"Process properties must align after ordinary callbacks",
		)


func _test_physics_resolution() -> void:
	_start(["physics_tick", "position"], { "phase": "physics", "every_n": 2, "max_samples": 3 })
	await _wait_for_stop()

	var rows: Array = _recorder.read({ }).samples
	_check(
		rows.size() == 3 and rows[2].physics_frame == rows[0].physics_frame + 4,
		"Every-N physics sampling must follow actual local step intervals",
	)

	for row: Dictionary in rows:
		_check(
			row.values[0] == row.values[1].x,
			"Decimated physics tracks must retain their shared observation boundary",
		)


func _test_signal_lifetime() -> void:
	_start(["counter"], { "max_seconds": 0.001 })
	await _fixture.get_tree().create_timer(0.01, true, false, true).timeout

	_check(
		_recorder.status().stop_reason == "duration_limit",
		"A quiet signal capture must remain bounded",
	)

	var source := Node.new()
	source.add_user_signal("sample")
	_fixture.add_child(source)

	_start(["counter"], { "source": source, "signal": "sample" })
	source.free()
	await _wait_for_stop()

	_check(
		_recorder.status().stop_reason == "source_freed",
		"Lost signal sources must stop visibly",
	)


func _test_quiet_freed_target() -> void:
	var target := Node3D.new()
	_fixture.add_child(target)
	_recorder.discard()
	_recorder.start(
		{
			"tracks": [_track("position", target)],
			"phase": "signal",
			"source": _fixture,
			"signal": "measured",
		}
	)
	target.free()
	await _wait_for_stop()

	_check(
		_recorder.status().stop_reason == "track_error",
		"Lost targets must stop even without another signal",
	)


func _wait_for_stop() -> void:
	for frame: int in 30:
		if _recorder.status().state == "stopped":
			return

		if _recorder.status().phase == "physics":
			await _fixture.get_tree().physics_frame
		else:
			await _fixture.get_tree().process_frame

	_check(false, "Recording must stop within the fixture's bounded observation window")
