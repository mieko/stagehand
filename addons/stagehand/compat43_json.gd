extends RefCounted
## COMPAT SHIM: Godot 4.3 lacks JSON.from_native/to_native.
## Only Stagehand's already-validated native value subset is supported; never Objects.


func from_native(value: Variant) -> Variant:
	match typeof(value):
		TYPE_INT:
			return "i:" + str(value)
		TYPE_STRING_NAME:
			return "sn:" + str(value)
		TYPE_NODE_PATH:
			return "np:" + str(value)

	var args: Array = []
	match typeof(value):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			_append(args, value, 2)
		TYPE_VECTOR3, TYPE_VECTOR3I:
			_append(args, value, 3)
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION, TYPE_COLOR:
			_append(args, value, 4)
		TYPE_RECT2, TYPE_RECT2I:
			_append(args, value.position, 2)
			_append(args, value.size, 2)
		TYPE_AABB:
			_append(args, value.position, 3)
			_append(args, value.size, 3)
		TYPE_PLANE:
			_append(args, value.normal, 3)
			args.append(value.d)
		TYPE_TRANSFORM2D:
			_matrix(args, value, 3, 2)
		TYPE_BASIS:
			_matrix(args, value, 3, 3)
		TYPE_TRANSFORM3D:
			_matrix(args, value.basis, 3, 3)
			_append(args, value.origin, 3)
		TYPE_PROJECTION:
			_matrix(args, value, 4, 4)
		TYPE_PACKED_VECTOR2_ARRAY:
			_packed(args, value, 2)
		TYPE_PACKED_VECTOR3_ARRAY:
			_packed(args, value, 3)
		TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			_packed(args, value, 4)
		_:
			args = Array(value)

	return { "type": type_string(typeof(value)), "args": args }


func _append(args: Array, value: Variant, width: int) -> void:
	for index: int in width:
		args.append(value[index])


func _matrix(args: Array, value: Variant, columns: int, width: int) -> void:
	for column: int in columns:
		_append(args, value[column], width)


func _packed(args: Array, value: Variant, width: int) -> void:
	for item: Variant in value:
		_append(args, item, width)


func to_native(value: Variant, _allow_objects: bool = false) -> Variant:
	if value is String:
		if value.begins_with("i:"):
			return value.substr(2).to_int()

		if value.begins_with("sn:"):
			return StringName(value.substr(3))

		return NodePath(value.substr(3))

	var args: Array = value.args
	match value.type:
		"Vector2":
			return Vector2(args[0], args[1])
		"Vector2i":
			return Vector2i(args[0], args[1])
		"Vector3":
			return Vector3(args[0], args[1], args[2])
		"Vector3i":
			return Vector3i(args[0], args[1], args[2])
		"Vector4":
			return Vector4(args[0], args[1], args[2], args[3])
		"Vector4i":
			return Vector4i(args[0], args[1], args[2], args[3])
		"Rect2":
			return Rect2(args[0], args[1], args[2], args[3])
		"Rect2i":
			return Rect2i(args[0], args[1], args[2], args[3])
		"Plane":
			return Plane(Vector3(args[0], args[1], args[2]), args[3])
		"Quaternion":
			return Quaternion(args[0], args[1], args[2], args[3])
		"Color":
			return Color(args[0], args[1], args[2], args[3])
		"AABB":
			return AABB(_vector3(args, 0), _vector3(args, 3))
		"Basis":
			return _basis(args)
		"Transform2D":
			return Transform2D(
				Vector2(args[0], args[1]),
				Vector2(args[2], args[3]),
				Vector2(args[4], args[5]),
			)
		"Transform3D":
			return Transform3D(_basis(args), _vector3(args, 9))
		"Projection":
			return Projection(
				_vector4(args, 0),
				_vector4(args, 4),
				_vector4(args, 8),
				_vector4(args, 12),
			)
		"PackedByteArray":
			return PackedByteArray(args)
		"PackedInt32Array":
			return PackedInt32Array(args)
		"PackedInt64Array":
			return PackedInt64Array(args)
		"PackedFloat32Array":
			return PackedFloat32Array(args)
		"PackedFloat64Array":
			return PackedFloat64Array(args)
		"PackedStringArray":
			return PackedStringArray(args)
		"PackedVector2Array", "PackedVector3Array", "PackedVector4Array", "PackedColorArray":
			return _native_packed(value.type, args)

	return null


func _vector3(args: Array, offset: int) -> Vector3:
	return Vector3(args[offset], args[offset + 1], args[offset + 2])


func _vector4(args: Array, offset: int) -> Vector4:
	return Vector4(args[offset], args[offset + 1], args[offset + 2], args[offset + 3])


func _basis(args: Array) -> Basis:
	return Basis(_vector3(args, 0), _vector3(args, 3), _vector3(args, 6))


func _native_packed(type: String, args: Array) -> Variant:
	var width := 2 if type == "PackedVector2Array" else (3 if type == "PackedVector3Array" else 4)
	var items: Array = []
	for offset: int in range(0, args.size(), width):
		match type:
			"PackedVector2Array":
				items.append(Vector2(args[offset], args[offset + 1]))
			"PackedVector3Array":
				items.append(_vector3(args, offset))
			"PackedVector4Array":
				items.append(_vector4(args, offset))
			"PackedColorArray":
				items.append(
					Color(args[offset], args[offset + 1], args[offset + 2], args[offset + 3])
				)

	match type:
		"PackedVector2Array":
			return PackedVector2Array(items)
		"PackedVector3Array":
			return PackedVector3Array(items)
		"PackedVector4Array":
			return PackedVector4Array(items)
		_:
			return PackedColorArray(items)
