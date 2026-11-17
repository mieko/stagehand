extends RefCounted
## Bound native reads. Callers must select synchronous, side-effect-free getters.

enum Kind {
	PROPERTY,
	INDEXED,
	METHOD,
	SCRIPT,
}

const ObjectAccess = preload("object_access.gd")
const Buffer = preload("property_recording_buffer.gd")
const Failure = preload("failure.gd")
const SCHEMA_SIGNALS := [&"property_list_changed", &"script_changed"]

var target: WeakRef
var metadata: Dictionary = { }
var _bridge: Node
var _access: RefCounted
var _kind: Kind
var _name: StringName
var _path: NodePath
var _args: Array = []
var _dirty := false
var _scripts: RefCounted
var _evaluation: RefCounted


func _init(bridge: Node, scripts: RefCounted = null) -> void:
	_bridge = bridge
	_access = ObjectAccess.new(bridge)
	_scripts = scripts


func bind(spec: Dictionary) -> Variant:
	var error: Variant = _select(spec)
	if error is Failure:
		return error

	if _kind == Kind.SCRIPT:
		return _bind_script(spec)

	var object: Variant = spec.get("object")
	if not object is Object or not is_instance_valid(object):
		return _bridge.fail(Failure.INVALID_PARAMS, "Each read needs a live object reference")

	target = weakref(object)
	metadata.merge({ "object": _bridge.reference(object), "class": object.get_class() })
	if _kind == Kind.INDEXED:
		_path = NodePath(str(spec.indexed)).get_as_property_path()
		if _path.get_subname_count() == 0:
			return _bridge.fail(
				Failure.INVALID_PARAMS,
				"Expected a property path, not an empty node path",
			)

		_name = _path.get_subname(0)
	elif _kind == Kind.METHOD:
		error = _bind_arguments(spec.get("args", []))
		if error is Failure:
			return error

		metadata["args"] = _args

	for signal_name: StringName in SCHEMA_SIGNALS:
		object.connect(signal_name, invalidate)

	return _validated_read(object)


func _select(spec: Dictionary) -> Variant:
	var selectors: Array = ["property", "indexed", "method", "source"].filter(
		Callable.create(spec, "has"),
	)
	if (
		selectors.size() != 1 or (spec.has("args") and selectors[0] != "method")
		or (spec.has("bindings") and selectors[0] != "source")
	):
		return _bridge.fail(
			Failure.INVALID_PARAMS,
			"Choose one property, indexed path, method, or script source",
		)

	var selector: String = selectors[0]
	if selector == "source":
		if spec.has("object"):
			return _bridge.fail(Failure.INVALID_PARAMS, "Script readings use bindings, not object")

		_kind = Kind.SCRIPT
		metadata = { "selector": "script" }

		return null

	var name: Variant = spec[selector]
	if not (name is String or name is StringName or name is NodePath):
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected a selector name")

	if str(name).is_empty() or str(name).length() > 128:
		return _bridge.fail(Failure.INVALID_PARAMS, "Selector names must contain 1..128 characters")

	_kind = ["property", "indexed", "method"].find(selector)
	_name = StringName(str(name))
	metadata = { selector: str(name) }

	return null


func _bind_script(spec: Dictionary) -> Variant:
	if _scripts == null:
		return _bridge.fail(Failure.INVALID_PARAMS, "Enable Script to use scripted readings")

	var prepared: Variant = _scripts.prepare(spec)
	if prepared is Failure:
		return prepared

	_evaluation = prepared

	return read()


func close() -> void:
	var object: Object = target.get_ref() if target != null else null
	if object != null:
		for signal_name: StringName in SCHEMA_SIGNALS:
			if object.is_connected(signal_name, invalidate):
				object.disconnect(signal_name, invalidate)

	_evaluation = null


func _bind_arguments(args: Variant) -> Variant:
	if not args is Array:
		return _bridge.fail(Failure.INVALID_PARAMS, "Getter args must be an array of snapshot data")

	var buffer := Buffer.new(1, 1)
	buffer.begin(0, 0, 0, 0)
	if not buffer.write(0, args):
		return _bridge.fail(Failure.INVALID_PARAMS, buffer.message)

	# The buffer validates transferable data; native duplication preserves container typing.
	_args = args.duplicate(true)
	_freeze(_args)

	return null


func _freeze(value: Variant) -> void:
	if value is Array:
		for item: Variant in value:
			_freeze(item)

		value.make_read_only()
	elif value is Dictionary:
		for key: Variant in value:
			_freeze(key)
			_freeze(value[key])

		value.make_read_only()


func invalidate() -> void:
	_dirty = true


func read() -> Variant:
	if _kind == Kind.SCRIPT:
		var evaluation := _evaluation

		return evaluation.run()

	var object: Object = target.get_ref()
	if object == null:
		return _bridge.fail(Failure.UNKNOWN_HANDLE, "Read target was freed")

	if _dirty:
		_dirty = false
		return _validated_read(object)

	var value: Variant
	match _kind:
		Kind.PROPERTY:
			value = object.get(_name)
		Kind.INDEXED:
			value = object.get_indexed(_path)
		Kind.METHOD:
			value = object.callv(_name, _args)

	return _checked_value(object, value)


func _validated_read(object: Object) -> Variant:
	var value: Variant
	match _kind:
		Kind.PROPERTY:
			value = _access.get_property({ "target": object, "property": str(_name) })
		Kind.INDEXED:
			if not _has_property(object):
				return _bridge.fail(
					Failure.INVALID_PARAMS,
					"Unknown indexed root property: " + str(_name),
				)

			value = object.get_indexed(_path)
		Kind.METHOD:
			var error: Variant = _check_container_arguments(object)
			if error is Failure:
				return error

			value = _access.call_method({ "target": object, "method": str(_name), "args": _args })

	return _checked_value(object, value)


func _check_container_arguments(object: Object) -> Variant:
	for method: Dictionary in object.get_method_list():
		if method.name != _name:
			continue

		var arguments: Array = method.get("args", [])
		for index: int in mini(arguments.size(), _args.size()):
			var info: Dictionary = arguments[index]
			# COMPAT SHIM: 4.3 lacks PROPERTY_HINT_DICTIONARY_TYPE.
			# Without 4.3 support, use the container hint enums here.
			if (
				info.type not in [TYPE_ARRAY, TYPE_DICTIONARY]
				or info.get("hint_string", "").is_empty()
			):
				continue

			if typeof(_args[index]) != info.type:
				continue

			if _container_hint(_args[index]) != info.hint_string:
				return _bridge.fail(
					Failure.INVALID_PARAMS,
					"Getter argument needs a matching typed container: " + info.hint_string,
				)

		return null

	return null


func _container_hint(value: Variant) -> String:
	if value is Array:
		return _element_hint(value.get_typed_builtin())

	if value is Dictionary:
		# COMPAT SHIM: named calls keep this file parseable on Godot 4.3.
		# Typed metadata gates this path to newer engines; dropping 4.3 allows direct calls.
		var key_type: int = Callable.create(value, "get_typed_key_builtin").call()
		var value_type: int = Callable.create(value, "get_typed_value_builtin").call()

		return _element_hint(key_type) + ";" + _element_hint(value_type)

	return ""


func _element_hint(type: int) -> String:
	return "Variant" if type == TYPE_NIL else type_string(type)


func _checked_value(object: Object, value: Variant) -> Variant:
	if not is_instance_valid(object):
		return _bridge.fail(Failure.UNKNOWN_HANDLE, "Read target was freed by its getter")

	# Native getters can refresh their property schema lazily during the read.
	if _dirty and _kind != Kind.METHOD:
		_dirty = false
		if not _has_property(object):
			return _bridge.fail(
				Failure.UNKNOWN_HANDLE,
				"Read property no longer exists: " + str(_name),
			)

	if _kind == Kind.INDEXED and value == null:
		return _bridge.fail(
			Failure.INVALID_PARAMS,
			"Indexed path is invalid or resolves to null; inspect its parent instead",
		)

	return value


func _has_property(object: Object) -> bool:
	return object.get_property_list().any(
		func(entry: Dictionary) -> bool:
			return entry.name == _name,
	)
