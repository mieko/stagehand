extends RefCounted

const Failure = preload("failure.gd")

var bridge: Node
var _next_capture := 0


func _init(owner: Node) -> void:
	bridge = owner


func install(names: PackedStringArray) -> void:
	if "Runtime" in names:
		bridge.register_object(
			self,
			"Runtime",
			"Runtime",
			{ "info": runtime_info },
			runtime_observation,
			[],
			{ },
			true,
			"1.0.0",
		)

	if "SceneTree" in names:
		bridge.register_object(
			self,
			"SceneTree",
			"SceneTree",
			{ "current": current, "query": query },
			Callable(),
			[],
			{ },
			true,
			"1.0.0",
		)

	if "Object" in names:
		bridge.register_object(
			self,
			"Object",
			"Object",
			{
				"inspect": inspect_object,
				"get": get_property,
				"set": set_property,
				"call": call_method,
			},
			Callable(),
			[],
			{ },
			true,
			"1.0.0",
		)

	if "Screen" in names:
		bridge.register_object(
			self,
			"Screen",
			"Screen",
			{ "viewports": viewports, "dimensions": dimensions, "capture": capture },
			Callable(),
			[],
			{ },
			true,
			"1.0.0",
		)


func runtime_info(_params: Dictionary) -> Dictionary:
	return runtime_observation()


func runtime_observation() -> Dictionary:
	return {
		"engine": Engine.get_version_info(),
		"paused": bridge.get_tree().paused,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"time_scale": Engine.time_scale,
		"current_scene": bridge.get_tree().current_scene,
		"display_server": DisplayServer.get_name(),
	}


func current(_params: Dictionary) -> Dictionary:
	return { "root": bridge.get_tree().root, "scene": bridge.get_tree().current_scene }


func query(params: Dictionary) -> Variant:
	var parent: Variant = params.get("root", bridge.get_tree().root)
	if not parent is Node:
		return bridge.fail(-32602, "Query root must be a live Node reference")

	var limit: Variant = params.get("limit", 100)
	if not (limit is float or limit is int) or limit < 1 or limit > 1000 or limit != floor(limit):
		return bridge.fail(-32602, "Query limit must be an integer in 1..1000")

	var queue: Array[Node] = [parent]
	var nodes: Array = []
	var visited := 0

	while not queue.is_empty() and nodes.size() < limit and visited < 10000:
		var node: Node = queue.pop_front()
		visited += 1
		if node.name.match(str(params.get("name", "*"))) and (
				not params.has("class") or node.is_class(str(params["class"]))
			):
			nodes.append(
				{
					"node": node,
					"name": str(node.name),
					"path": str(node.get_path()),
					"class": node.get_class(),
					"groups": node.get_groups(),
					"parent": node.get_parent(),
				},
			)
		queue.append_array(node.get_children(bool(params.get("internal", false))))

	return { "nodes": nodes, "truncated": not queue.is_empty() }


func inspect_object(params: Dictionary) -> Variant:
	var target: Variant = params.get("target")
	if not target is Object or not is_instance_valid(target):
		return bridge.fail(-32602, "Expected a live target reference")

	return {
		"class": target.get_class(),
		"properties": target.get_property_list(),
		"methods": target.get_method_list(),
		"signals": target.get_signal_list(),
	}


func _property(params: Dictionary) -> Variant:
	var target: Variant = params.get("target")
	if not target is Object or not is_instance_valid(target) or not params.get("property") is String:
		return bridge.fail(-32602, "Expected a live target and property name")

	for entry: Dictionary in target.get_property_list():
		if entry.name == params.property:
			return entry

	return bridge.fail(-32602, "Unknown property: " + params.property)


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
		return bridge.fail(-32602, "Missing property value")

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
		return bridge.fail(-32602, "Expected a live target, method name, and argument array")

	if not target.has_method(method):
		return bridge.fail(-32601, "Unknown reflected method")

	for info: Dictionary in target.get_method_list():
		if info.name == method and not (int(info.get("flags", 0)) & METHOD_FLAG_VARARG):
			var maximum: int = Callable(target, method).get_argument_count()
			var complete: bool = info.get("args", []).size() == maximum
			var minimum: int = maximum - info.get("default_args", []).size() if complete else 0
			if args.size() < minimum or args.size() > maximum:
				return bridge.fail(-32602, "Incorrect argument count")

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
		return bridge.fail(-32602, "Expected an object of class " + class_name_hint)

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
		-32602,
		"Expected " + type_string(expected) + ", received " + type_string(typeof(value)),
	)


func viewports(_params: Dictionary) -> Variant:
	var result: Array = []
	var queue: Array[Node] = [bridge.get_tree().root]
	var visited := 0

	while not queue.is_empty() and result.size() < 100:
		visited += 1
		if visited > 10000:
			return bridge.fail(-32010, "Viewport scan exceeds 10000 nodes; query a smaller subtree")

		var node: Node = queue.pop_front()
		if node is Viewport:
			result.append(
				{
					"viewport": node,
					"path": str(node.get_path()),
					"size": node.get_visible_rect().size,
				}
			)
		queue.append_array(node.get_children())

	return result


func _viewport(params: Dictionary) -> Variant:
	var viewport: Variant = params.get("viewport", bridge.get_tree().root)

	return (
		viewport
		if viewport is Viewport
		else bridge.fail(-32602, "Expected a Viewport reference")
	)


func dimensions(params: Dictionary) -> Variant:
	var viewport: Variant = _viewport(params)
	if viewport is Failure:
		return viewport

	return {
		"viewport": viewport,
		"logical_size": viewport.get_visible_rect().size,
		"texture_size": viewport.get_texture().get_size(),
		"render_frame": Engine.get_frames_drawn(),
	}


func capture(params: Dictionary) -> Variant:
	var viewport: Variant = _viewport(params)
	if viewport is Failure:
		return viewport

	if DisplayServer.get_name() == "headless":
		return bridge.fail(-32020, "No rendered viewport in a headless display")

	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return bridge.fail(-32020, "Viewport has no rendered image")

	_next_capture += 1
	var clock: Dictionary = bridge._clock()

	return {
		"viewport": viewport,
		"width": image.get_width(),
		"height": image.get_height(),
		"capture": "%s:capture:%d" % [clock.instance, _next_capture],
		"clock": clock,
		"mime": "image/png",
		"base64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"render_frame": Engine.get_frames_drawn(),
		"physics_tick": Engine.get_physics_frames(),
		"phase": "last_rendered_image",
	}
