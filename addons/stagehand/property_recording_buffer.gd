extends RefCounted
## Preallocated native columns; row objects and wire encoding belong to retrieval.

enum Fault {
	NONE,
	INVALID_VALUE,
	NATIVE_VALUE,
	SAMPLE_SIZE,
	TOTAL_SIZE,
	CAPACITY,
}

const MAX_BYTES := 16 * 1024 * 1024
const MAX_SAMPLE_BYTES := 64 * 1024
const MAX_COMPONENT := 9007199254740991.0
const ROW_BYTES := 256
const FIXED_COMPONENTS := {
	TYPE_VECTOR2: 2,
	TYPE_VECTOR2I: 2,
	TYPE_VECTOR3: 3,
	TYPE_VECTOR3I: 3,
	TYPE_VECTOR4: 4,
	TYPE_VECTOR4I: 4,
	TYPE_RECT2: 4,
	TYPE_RECT2I: 4,
	TYPE_PLANE: 4,
	TYPE_QUATERNION: 4,
	TYPE_COLOR: 4,
	TYPE_TRANSFORM2D: 6,
	TYPE_AABB: 6,
	TYPE_BASIS: 9,
	TYPE_TRANSFORM3D: 12,
	TYPE_PROJECTION: 16,
}
const PACKED_COMPONENTS := {
	TYPE_PACKED_BYTE_ARRAY: 1,
	TYPE_PACKED_INT32_ARRAY: 1,
	TYPE_PACKED_INT64_ARRAY: 1,
	TYPE_PACKED_FLOAT32_ARRAY: 1,
	TYPE_PACKED_FLOAT64_ARRAY: 1,
	TYPE_PACKED_STRING_ARRAY: 1,
	TYPE_PACKED_VECTOR2_ARRAY: 2,
	TYPE_PACKED_VECTOR3_ARRAY: 3,
	TYPE_PACKED_VECTOR4_ARRAY: 4,
	TYPE_PACKED_COLOR_ARRAY: 4,
}

var count := 0
var bytes := 0
var fault: Fault = Fault.NONE
var message := ""
var _capacity: int
var _columns: Array[Array] = []
var _elapsed := PackedInt64Array()
var _physics := PackedInt64Array()
var _process := PackedInt64Array()
var _callbacks := PackedInt64Array()
var _sample_bytes := 0


func _init(tracks: int, capacity: int) -> void:
	_capacity = capacity
	_columns.resize(tracks)

	for index: int in tracks:
		var column: Array = []
		column.resize(capacity)
		_columns[index] = column

	_elapsed.resize(capacity)
	_physics.resize(capacity)
	_process.resize(capacity)
	_callbacks.resize(capacity)


func begin(elapsed: int, physics: int, process: int, callback: int) -> bool:
	fault = Fault.NONE
	_sample_bytes = ROW_BYTES
	if count == _capacity:
		_fail(Fault.CAPACITY, "Sample capacity reached")
		return false

	_elapsed[count] = elapsed
	_physics[count] = physics
	_process[count] = process
	_callbacks[count] = callback

	return true


func write(track: int, value: Variant) -> bool:
	var snapshot: Variant = _copy(value, 0)
	if fault != Fault.NONE:
		return false

	_columns[track][count] = snapshot

	return true


func commit() -> bool:
	if bytes + _sample_bytes > MAX_BYTES:
		_fail(Fault.TOTAL_SIZE, "Conservative sample-data budget reached")
		return false

	bytes += _sample_bytes
	count += 1

	return true


func abort() -> void:
	if count < _capacity:
		for column: Array in _columns:
			column[count] = null


func rows(offset: int, end: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index: int in range(offset, end):
		var values: Array = []
		for column: Array in _columns:
			values.append(column[index])
		result.append(
			{
				"index": index,
				"elapsed_usec": _elapsed[index],
				"physics_frame": _physics[index],
				"process_frame": _process[index],
				"callback_index": _callbacks[index],
				"values": values,
			}
		)

	return result


func _copy(value: Variant, depth: int) -> Variant:
	if depth > 8:
		return _fail(
			Fault.INVALID_VALUE,
			"Track wire nesting exceeds 8 levels (or contains a cycle)",
		)

	var type := typeof(value)
	match type:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			_charge(48)
			return value
		TYPE_STRING:
			_charge(_string_bytes(value))
			return value
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			_charge(64 + _string_bytes(str(value)))
			return value
		TYPE_ARRAY:
			return _copy_array(value, depth)
		TYPE_DICTIONARY:
			return _copy_dictionary(value, depth)

	if FIXED_COMPONENTS.has(type):
		_charge(64 + 32 * int(FIXED_COMPONENTS[type]))
		if not _safe_native(value, type):
			return _fail(Fault.NATIVE_VALUE, "Native components must be finite, JSON-safe numbers")

		return value

	if PACKED_COMPONENTS.has(type):
		return _copy_packed(value, type)

	return _fail(Fault.INVALID_VALUE, "Track value is not snapshot data: " + type_string(type))


func _copy_array(value: Array, depth: int) -> Variant:
	if not _collection(value.size(), 16 + 4 * value.size()):
		return null

	var result: Array = []
	result.resize(value.size())
	for index: int in value.size():
		result[index] = _copy(value[index], depth + 1)
		if fault != Fault.NONE:
			return null

	return result


func _copy_dictionary(value: Dictionary, depth: int) -> Variant:
	if not _collection(value.size(), 64 + 8 * value.size()):
		return null

	var result: Dictionary = { }
	for key: Variant in value:
		# Native dictionary envelopes add an entries array and a key/value pair.
		var copied_key: Variant = _copy(key, depth + 2)
		var copied: Variant = _copy(value[key], depth + 2)
		if fault != Fault.NONE:
			return null

		result[copied_key] = copied

	return result


func _copy_packed(value: Variant, type: int) -> Variant:
	var components := int(PACKED_COMPONENTS[type])
	if not _collection(value.size() * components, 64):
		return null

	if type == TYPE_PACKED_STRING_ARRAY:
		for item: String in value:
			if not _charge(_string_bytes(item) + 2):
				return null
	else:
		if not _charge(32 * value.size() * components) or not _safe_packed(value, components):
			return null

	return value.duplicate()


func _collection(size: int, overhead: int) -> bool:
	if size > 1024:
		_fail(Fault.INVALID_VALUE, "Track collection exceeds 1024 components/entries")
		return false

	return _charge(overhead)


func _charge(size: int) -> bool:
	_sample_bytes += size
	if _sample_bytes > MAX_SAMPLE_BYTES:
		_fail(Fault.SAMPLE_SIZE, "Conservative sample-size budget reached")
		return false

	return true


func _string_bytes(value: String) -> int:
	if value.length() + 2 > MAX_SAMPLE_BYTES - _sample_bytes:
		return MAX_SAMPLE_BYTES + 1

	if value.is_empty():
		return 2

	# COMPAT SHIM: Godot 4.3 lacks is_valid_ascii_identifier().
	# When dropping 4.3, restore that fast path before escaped UTF-8 counting.
	return value.json_escape().to_utf8_buffer().size() + 2


func _safe_number(value: float) -> bool:
	return absf(value) <= MAX_COMPONENT


func _safe_components(value: Variant, count: int) -> bool:
	for index: int in count:
		if not _safe_number(value[index]):
			return false

	return true


func _safe_native(value: Variant, type: int) -> bool:
	match type:
		TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I, TYPE_RECT2I:
			return true
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_QUATERNION, TYPE_COLOR:
			return _safe_components(value, int(FIXED_COMPONENTS[type]))
		TYPE_RECT2:
			return _safe_components(value.position, 2) and _safe_components(value.size, 2)
		TYPE_PLANE:
			return _safe_components(value.normal, 3) and _safe_number(value.d)
		TYPE_AABB:
			return _safe_components(value.position, 3) and _safe_components(value.size, 3)
		TYPE_TRANSFORM3D:
			return _safe_native(value.basis, TYPE_BASIS) and _safe_components(value.origin, 3)
		TYPE_TRANSFORM2D, TYPE_BASIS:
			for index: int in 3:
				if not _safe_components(value[index], 2 if type == TYPE_TRANSFORM2D else 3):
					return false
		TYPE_PROJECTION:
			for index: int in 4:
				if not _safe_components(value[index], 4):
					return false

	return true


func _safe_packed(value: Variant, components: int) -> bool:
	for item: Variant in value:
		if components == 1:
			if not _safe_number(item):
				_fail(Fault.NATIVE_VALUE, "Packed components must be finite, JSON-safe numbers")
				return false
		elif not _safe_components(item, components):
			_fail(Fault.NATIVE_VALUE, "Packed components must be finite, JSON-safe numbers")
			return false

	return true


func _fail(kind: Fault, description: String) -> Variant:
	fault = kind
	message = description
	return null
