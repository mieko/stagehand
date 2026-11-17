extends RefCounted

const Failure = preload("failure.gd")
const ObjectAccess = preload("object_access.gd")
const PropertyRecorder = preload("property_recorder.gd")
const InputEndpoint = preload("input.gd")
const ScriptEndpoint = preload("script.gd")
const NAMES := ["Runtime", "SceneTree", "Object", "Screen", "Input", "Script", "PropertyRecorder"]

var bridge: Node
var native_signals_enabled := false
var _next_capture := 0
var _scripts: RefCounted
var _access: RefCounted


func _init(owner: Node) -> void:
	bridge = owner
	_access = ObjectAccess.new(owner)


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
			"2.0.0",
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
			"2.0.0",
		)

	if "Object" in names:
		native_signals_enabled = true
		bridge.register_object(
			self,
			"Object",
			"Object",
			{
				"inspect": _access.inspect_object,
				"get": _access.get_property,
				"set": _access.set_property,
				"call": _access.call_method,
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

	if "Script" in names:
		_scripts = ScriptEndpoint.new(bridge)
		bridge.register_object(
			_scripts,
			"Script",
			"Script",
			{ "evaluate": _scripts.evaluate },
			Callable(),
			[],
			{ },
			true,
			"1.0.0",
		)

	if "Input" in names:
		var endpoint := InputEndpoint.new(bridge, _scripts)
		endpoint.name = "InputEndpoint"
		bridge.add_child(endpoint)

	if "PropertyRecorder" in names:
		var recorder := PropertyRecorder.new()
		recorder.name = &"PropertyRecorder"
		bridge.add_child(recorder)
		recorder.install(bridge, _scripts)


func runtime_info(_params: Dictionary) -> Dictionary:
	return runtime_observation()


func runtime_observation() -> Dictionary:
	var version := Engine.get_version_info()
	var engine := { "name": "Godot" }

	for key: Variant in version:
		engine[str(key)] = version[key]

	return {
		"engine": engine,
		"save_directory": OS.get_user_data_dir(),
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
		return bridge.fail(Failure.INVALID_PARAMS, "Query root must be a live Node reference")

	var limit: Variant = params.get("limit", 100)
	if not (limit is float or limit is int) or limit < 1 or limit > 1000 or limit != floor(limit):
		return bridge.fail(Failure.INVALID_PARAMS, "Query limit must be an integer in 1..1000")

	var offset: Variant = params.get("offset", 0)
	if not (offset is float or offset is int) or offset < 0 or offset != floor(offset):
		return bridge.fail(Failure.INVALID_PARAMS, "Query offset must be a non-negative integer")

	var queue: Array[Node] = [parent]
	var nodes: Array = []
	var visited := 0
	var matched := 0

	while visited < queue.size():
		if visited >= 10000:
			return bridge.fail(
				Failure.RESOURCE_LIMIT,
				"Query exceeds 10000 nodes; use a smaller root",
			)

		var node: Node = queue[visited]
		visited += 1

		if node.name.match(str(params.get("name", "*"))) and (
				not params.has("class") or node.is_class(str(params["class"]))
			):
			if matched >= offset + limit:
				return { "nodes": nodes, "more": true }

			if matched >= offset:
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

			matched += 1

		queue.append_array(node.get_children(bool(params.get("internal", false))))

	return { "nodes": nodes, "more": false }


func viewports(_params: Dictionary) -> Variant:
	var result: Array = []
	var queue: Array[Node] = [bridge.get_tree().root]
	var visited := 0

	while not queue.is_empty() and result.size() < 100:
		visited += 1
		if visited > 10000:
			return bridge.fail(
				Failure.RESOURCE_LIMIT,
				"Viewport scan exceeds 10000 nodes; query a smaller subtree",
			)

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
		else bridge.fail(Failure.INVALID_PARAMS, "Expected a Viewport reference")
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
		return bridge.fail(Failure.IMAGE_UNAVAILABLE, "No rendered viewport in a headless display")

	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return bridge.fail(Failure.IMAGE_UNAVAILABLE, "Viewport has no rendered image")

	_next_capture += 1
	var clock: Dictionary = bridge.clock()

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
