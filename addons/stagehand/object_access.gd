extends RefCounted
## Reflected native access shared by Object operations and bound recorder readers.

const Failure = preload("failure.gd")

var bridge: Node


func _init(owner: Node) -> void:
	bridge = owner


func inspect_object(params: Dictionary) -> Variant:
	var target: Variant = params.get("target")
	if not target is Object or not is_instance_valid(target):
		return bridge.fail(Failure.INVALID_PARAMS, "Expected a live target reference")

	return {
		"class": target.get_class(),
		"properties": target.get_property_list(),
		"methods": target.get_method_list(),
		"signals": target.get_signal_list(),
	}


func _property(params: Dictionary) -> Variant:
	var target: Variant = params.get("target")
	if (
		not target is Object or not is_instance_valid(target)
		or not params.get("property") is String
	):
		return bridge.fail(Failure.INVALID_PARAMS, "Expected a live target and property name")

	for entry: Dictionary in target.get_property_list():
		if entry.name == params.property:
			return entry

	return bridge.fail(Failure.INVALID_PARAMS, "Unknown property: " + params.property)


func get_property(params: Dictionary) -> Variant:
	var property: Variant = _property(params)
	if property is Failure:
		return property

	return params.target.get(params.property)


func set_property(params: Dictionary) -> Variant:
	var property: Variant = _property(params)
	if property is Failure:
		return property

	if not params.has("value"):
		return bridge.fail(Failure.INVALID_PARAMS, "Missing property value")

	var error: Variant = _check_type(params.value, property)
	if error is Failure:
		return error

	params.target.set(params.property, params.value)

	return params.target.get(params.property)


func call_method(params: Dictionary) -> Variant:
	var target: Variant = params.get("target")
	var method: Variant = params.get("method")
	var args: Variant = params.get("args", [])
	if (
		not target is Object or not is_instance_valid(target)
		or not method is String or not args is Array
	):
		return bridge.fail(
			Failure.INVALID_PARAMS,
			"Expected a live target, method name, and argument array",
		)

	if not target.has_method(method):
		return bridge.fail(Failure.METHOD_NOT_FOUND, "Unknown reflected method")

	for info: Dictionary in target.get_method_list():
		if info.name == method and not (int(info.get("flags", 0)) & METHOD_FLAG_VARARG):
			var maximum: int = Callable(target, method).get_argument_count()
			var complete: bool = info.get("args", []).size() == maximum
			var minimum: int = maximum - info.get("default_args", []).size() if complete else 0
			if args.size() < minimum or args.size() > maximum:
				return bridge.fail(Failure.INVALID_PARAMS, "Incorrect argument count")

			if complete:
				for index: int in args.size():
					var error: Variant = _check_type(args[index], info.args[index])
					if error is Failure:
						return error

			break

	return target.callv(method, args)


func _check_type(value: Variant, info: Dictionary) -> Variant:
	var expected: int = info.get("type", TYPE_NIL)
	var class_name_hint: String = info.get("class_name", "")
	if (
		expected == TYPE_OBJECT and value is Object
		and ClassDB.class_exists(class_name_hint) and not value.is_class(class_name_hint)
	):
		return bridge.fail(Failure.INVALID_PARAMS, "Expected an object of class " + class_name_hint)

	if expected == TYPE_NIL or typeof(value) == expected:
		return null

	if (
		expected in [TYPE_INT, TYPE_FLOAT]
		and typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(value)
	):
		return null

	if expected == TYPE_OBJECT and value == null:
		return null

	if expected == TYPE_STRING_NAME and value is String:
		return null

	return bridge.fail(
		Failure.INVALID_PARAMS,
		"Expected " + type_string(expected) + ", received " + type_string(typeof(value)),
	)
