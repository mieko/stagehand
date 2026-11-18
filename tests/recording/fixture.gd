extends Node3D

signal measured

const Recorder = preload("res://addons/stagehand/property_recorder.gd")

var physics_tick := 0
var idle_tick := 0
var idle_position := Vector3.ZERO
var counter := 0
var sample_reads := 0
var counted: int:
	get:
		sample_reads += 1
		return counter

var lifecycle_recorder: Recorder
var lifecycle_action: StringName = &""
var stopped_count := -1
var lifecycle_value: int:
	get:
		if lifecycle_action != &"":
			_interrupt_recording()

		return counter

var captured_transform := Transform3D.IDENTITY
var captured_color := Color.RED
var dynamic_available := true
var remove_dynamic_on_read := false
var property_list_reads := 0
var payload: Variant = { "nested": [Vector3.ONE, { "number": 1 }] }
var packed := PackedVector3Array([Vector3.ONE])
# Keep the deferred test suite alive across its awaited checks.
var _native_tests: RefCounted


func _physics_process(_delta: float) -> void:
	physics_tick += 1
	position.x = physics_tick


func _process(_delta: float) -> void:
	idle_tick += 1
	idle_position.y = idle_tick


func emit_samples(count: int) -> void:
	for index: int in count:
		counter = index
		measured.emit()


func read_counter(scale: int = 1) -> int:
	sample_reads += 1
	return counter * scale


func read_number(settings: Dictionary) -> int:
	return settings.nested.number


func read_sum(values: Array[int]) -> int:
	sample_reads += 1

	var total := 0
	for value: int in values:
		total += value

	return total


func read_total(values: Dictionary[String, int]) -> int:
	sample_reads += 1

	var total := 0
	for value: int in values.values():
		total += value

	return total


func read_packed(values: PackedInt32Array) -> int:
	return values[0]


func read_lifecycle() -> int:
	if lifecycle_action != &"":
		_interrupt_recording()

	return counter


func _interrupt_recording() -> void:
	var action := lifecycle_action
	lifecycle_action = &""
	stopped_count = lifecycle_recorder.stop().count
	if action == &"stop":
		return

	lifecycle_recorder.discard()
	if action == &"restart":
		lifecycle_recorder.start(
			{
				"tracks": [{ "object": self, "property": "counter" }],
				"phase": "signal",
				"source": self,
				"signal": "measured",
				"max_samples": 1,
			}
		)


func _get_property_list() -> Array[Dictionary]:
	property_list_reads += 1
	if dynamic_available:
		return [{ "name": &"dynamic_value", "type": TYPE_INT }]

	return []


func _get(property: StringName) -> Variant:
	if property != &"dynamic_value" or not dynamic_available:
		return null

	if remove_dynamic_on_read:
		dynamic_available = false
		notify_property_list_changed()

	return 123
