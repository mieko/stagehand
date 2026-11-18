extends RefCounted
## Object references stay live handles; native value types use Godot's JSON codec.

const Failure = preload("failure.gd")

var bridge: Node
var _native_codec: RefCounted
var _from_native: Callable
var _to_native: Callable

const COMPONENTS := {
	"Vector2": 2,
	"Vector2i": 2,
	"Vector3": 3,
	"Vector3i": 3,
	"Vector4": 4,
	"Vector4i": 4,
	"Rect2": 4,
	"Rect2i": 4,
	"Plane": 4,
	"Quaternion": 4,
	"Color": 4,
	"Transform2D": 6,
	"AABB": 6,
	"Basis": 9,
	"Transform3D": 12,
	"Projection": 16,
}

const PACKED := {
	"PackedByteArray": 1,
	"PackedInt32Array": 1,
	"PackedInt64Array": 1,
	"PackedFloat32Array": 1,
	"PackedFloat64Array": 1,
	"PackedStringArray": 1,
	"PackedVector2Array": 2,
	"PackedVector3Array": 3,
	"PackedVector4Array": 4,
	"PackedColorArray": 4,
}


func _init(owner: Node) -> void:
	bridge = owner
	_native_codec = owner.native_codec

	# COMPAT SHIM: direct JSON conversion calls fail compilation on Godot 4.3.
	# Without 4.3 support, use JSON.from_native/to_native and remove this dispatch.
	_from_native = Callable(_native_codec, "from_native")
	_to_native = Callable(_native_codec, "to_native")


func snapshot(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return bridge.fail(Failure.RESOURCE_LIMIT, "Value exceeds the maximum nesting depth")

	if value is Array or value is Dictionary:
		if value.size() > 1024:
			return bridge.fail(Failure.RESOURCE_LIMIT, "Snapshot collection exceeds 1024 entries")

		var copy: Variant = value.duplicate()
		if value is Dictionary:
			copy.clear()

		for key: Variant in (range(value.size()) if value is Array else value.keys()):
			var item: Variant = snapshot(value[key], depth + 1)
			var copied_key: Variant = snapshot(key, depth + 1)
			if item is Failure or copied_key is Failure:
				return item if item is Failure else copied_key

			copy[copied_key] = item

		return copy

	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
		return value.duplicate()

	return value


func encode(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return bridge.fail(Failure.RESOURCE_LIMIT, "Value exceeds the maximum nesting depth")

	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return value
		TYPE_INT:
			return (
				value
				if value >= -9007199254740991 and value <= 9007199254740991
				else { "$godot": _from_native.call(value) }
			)
		TYPE_FLOAT:
			if is_finite(value):
				return value

			return { "$godot": "f:nan" if is_nan(value) else ("f:inf" if value > 0 else "f:-inf") }
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return { "$godot": _from_native.call(value) }
		TYPE_OBJECT:
			if not is_instance_valid(value):
				return null

			var handle: String = bridge.reference(value)

			return { "$ref": handle, "$type": bridge.reference_type(handle) }
		TYPE_ARRAY, TYPE_DICTIONARY:
			if value.size() > 1024:
				return bridge.fail(
					Failure.RESOURCE_LIMIT,
					"Collection exceeds 1024 entries; request a smaller view",
				)

			if value is Array:
				var items: Array = []
				for item: Variant in value:
					var encoded: Variant = encode(item, depth + 1)
					if encoded is Failure:
						return encoded

					items.append(encoded)

				return items

			var result: Dictionary = { }
			for key: Variant in value:
				if not key is String or key in ["$ref", "$godot", "$dictionary"]:
					return _encode_dictionary(value, depth)

				var encoded: Variant = encode(value[key], depth + 1)
				if encoded is Failure:
					return encoded

				result[key] = encoded

			return result
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return bridge.fail(
				Failure.RESOURCE_LIMIT,
				"Value type is not transferable: " + type_string(typeof(value)),
			)
		_:
			var native: Variant = _from_native.call(value)
			var validated: Variant = _native(native)
			if validated is Failure:
				return bridge.fail(Failure.RESOURCE_LIMIT, validated.message)

			return { "$godot": native }


func _encode_dictionary(value: Dictionary, depth: int) -> Variant:
	var entries: Array = []
	for key: Variant in value:
		var encoded_key: Variant = encode(key, depth + 1)
		var encoded_value: Variant = encode(value[key], depth + 1)
		if encoded_key is Failure:
			return encoded_key

		if encoded_value is Failure:
			return encoded_value

		entries.append([encoded_key, encoded_value])

	return { "$dictionary": entries }


func decode(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return bridge.fail(Failure.INVALID_PARAMS, "Value exceeds the maximum nesting depth")

	if (value is Array or value is Dictionary) and value.size() > 1024:
		return bridge.fail(Failure.INVALID_PARAMS, "Collection exceeds 1024 entries")

	if value is Array:
		var items: Array = []
		for item: Variant in value:
			var decoded: Variant = decode(item, depth + 1)
			if decoded is Failure:
				return decoded

			items.append(decoded)

		return items

	if value is Dictionary:
		if value.has("$ref"):
			return bridge.resolve_object(value["$ref"])

		if value.has("$godot"):
			# Object construction is intentionally disabled. Existing objects are
			# addressed only through references issued by this runtime.
			return _native(value["$godot"])

		var result: Dictionary = { }
		if value.has("$dictionary"):
			if not value["$dictionary"] is Array:
				return bridge.fail(Failure.INVALID_PARAMS, "Expected dictionary entries")

			if value["$dictionary"].size() > 1024:
				return bridge.fail(Failure.INVALID_PARAMS, "Collection exceeds 1024 entries")

			for pair: Variant in value["$dictionary"]:
				if not pair is Array or pair.size() != 2:
					return bridge.fail(
						Failure.INVALID_PARAMS,
						"Expected a dictionary key/value pair",
					)

				var key: Variant = decode(pair[0], depth + 1)
				var item: Variant = decode(pair[1], depth + 1)
				if key is Failure:
					return key

				if item is Failure:
					return item

				result[key] = item
		else:
			for key: String in value:
				var item: Variant = decode(value[key], depth + 1)
				if item is Failure:
					return item

				result[key] = item

		return result

	return value


func _native(value: Variant) -> Variant:
	if value is String:
		if value == "f:inf":
			return INF

		if value == "f:-inf":
			return -INF

		if value == "f:nan":
			return NAN

		if value.begins_with("i:"):
			var text: String = value.substr(2)
			if not text.is_valid_int() or str(text.to_int()) != text:
				return bridge.fail(Failure.INVALID_PARAMS, "Expected a signed 64-bit integer")

		elif (
			value not in ["f:inf", "f:-inf", "f:nan"]
			and not value.begins_with("sn:") and not value.begins_with("np:")
		):
			return bridge.fail(Failure.INVALID_PARAMS, "Unknown native scalar encoding")

		return _to_native.call(value, false)

	if not value is Dictionary or not value.get("type") is String or not value.get("args") is Array:
		return bridge.fail(
			Failure.INVALID_PARAMS,
			"Expected a supported native value type and args",
		)

	var type: String = value.type
	var args: Array = value.args
	if COMPONENTS.has(type):
		if args.size() != COMPONENTS[type]:
			return bridge.fail(Failure.INVALID_PARAMS, "Incorrect native component count")

	elif PACKED.has(type):
		if args.size() > 1024 or args.size() % int(PACKED[type]) != 0:
			return bridge.fail(Failure.INVALID_PARAMS, "Invalid or oversized packed array")

	else:
		return bridge.fail(Failure.INVALID_PARAMS, "Native type is not transferable: " + type)

	for component: Variant in args:
		if type == "PackedStringArray":
			if not component is String:
				return bridge.fail(Failure.INVALID_PARAMS, "Expected packed string components")

		elif (
			not (component is float or component is int)
			or not is_finite(component) or absf(component) > 9007199254740991
		):
			return bridge.fail(
				Failure.INVALID_PARAMS,
				"Native components must be finite, JSON-safe numbers",
			)

	return _to_native.call(value, false)
