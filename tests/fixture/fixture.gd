extends Node

const Bridge = preload("res://addons/stagehand/bridge.gd")


class Probe extends Node:
	signal native_changed(value: int)
	signal native_empty
	signal native_payload(first, second, third, fourth, fifth)

	var count := 0
	var handle := ""
	var bridge: Node


	func increment(params: Dictionary) -> int:
		count += int(params.get("amount", 1))
		bridge.publish(handle, "changed", count)

		return count


	func observe() -> Variant:
		if count < 0:
			return bridge.fail(-32040, "Negative fixture counter cannot be observed")

		return { "count": count, "name": name, "self": self }


	func remove(_params: Dictionary) -> bool:
		queue_free()

		return true


	func spawn(params: Dictionary) -> String:
		var other := Probe.new()
		other.name = "C"
		other.bridge = bridge
		get_parent().add_child(other)
		other.handle = bridge.register_object(
			other,
			"C",
			"probe",
			{ "increment": other.increment, "remove": other.remove },
			other.observe,
			["changed"],
			{ },
			true,
			params.get("version", ""),
		)

		return other.handle


	func emit_native(params: Dictionary) -> int:
		native_changed.emit(int(params.get("value", 0)))

		return 1


	func echo(params: Dictionary) -> Variant:
		return params.get("value")


	func unsupported(_params: Dictionary) -> Callable:
		return observe


	func large_output(_params: Dictionary) -> Array:
		var items: Array = []
		items.resize(1025)

		return items


	func image_info(params: Dictionary) -> Dictionary:
		var image := Image.new()
		var result := image.load_png_from_buffer(Marshalls.base64_to_raw(params.base64))

		return {
			"error": result,
			"width": image.get_width(),
			"height": image.get_height(),
			"center": image.get_pixel(image.get_width() / 2, image.get_height() / 2),
		}


	func retire(_params: Dictionary) -> bool:
		get_parent().retire_bridge()

		return true


var runtime_features := {
	"mono": OS.has_feature("mono"),
	"csharp": ClassDB.class_exists("CSharpScript"),
}

var input_ticks := 0
var last_strength := 0.0
var forward_held := false
var last_motion := Vector2.ZERO
var last_screen_motion := Vector2.ZERO
var last_position := Vector2.ZERO
var event_count := 0
var polled_mouse := Vector2.ZERO
var clicks := 0
var motion_samples: Array = []
var mouse_held := false
var heartbeat := 0
var wheel_events: Array = []


func _input(event: InputEvent) -> void:
	event_count += 1
	if event is InputEventMouseMotion:
		last_motion = event.relative
		last_screen_motion = event.screen_relative
		last_position = event.position
		polled_mouse = get_viewport().get_mouse_position()
		if motion_samples.size() >= 256:
			motion_samples.pop_front()
		motion_samples.append({ "position": event.position, "ms": Time.get_ticks_msec() })
	if event is InputEventMouseButton:
		mouse_held = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if event.button_index >= MOUSE_BUTTON_WHEEL_UP:
			wheel_events.append(
				{ "button": event.button_index, "factor": event.factor, "pressed": event.pressed }
			)


func _physics_process(_delta: float) -> void:
	heartbeat += 1
	forward_held = Input.is_action_pressed("move_forward")
	last_strength = Input.get_action_strength("move_forward")
	if forward_held:
		input_ticks += 1
		$TestViewport/Panel.color = Color(0.8, 0.15, 0.1)


func _ready() -> void:
	InputMap.add_action("move_forward")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_W
	InputMap.action_add_event("move_forward", key)
	InputMap.add_action("jump")
	$ClickTarget.pressed.connect(
		func():
			clicks += 1,
	)
	var bridge := Bridge.new()
	bridge.name = "Stagehand"
	add_child(bridge)
	var token := OS.get_environment("STAGEHAND_TOKEN")
	var bind_address := OS.get_environment("STAGEHAND_BIND_ADDRESS")
	var result: Error
	if bind_address.is_empty():
		result = bridge.start(token)
	else:
		result = bridge.start(token, 0, bind_address)

	if result != OK:
		push_error("Cannot start runtime control: %s" % error_string(result))
		get_tree().quit(1)

		return

	for label: String in ["A", "B"]:
		var probe := Probe.new()
		probe.name = label
		probe.bridge = bridge
		add_child(probe)
		probe.handle = bridge.register_object(
			probe,
			label,
			"probe",
			{
				"increment": probe.increment,
				"remove": probe.remove,
				"spawn": probe.spawn,
				"emit_native": probe.emit_native,
				"echo": probe.echo,
				"unsupported": probe.unsupported,
				"large_output": probe.large_output,
				"image_info": probe.image_info,
				"retire": probe.retire,
			},
			probe.observe,
			["changed"],
			{
				"increment": {
					"params": { "amount": "number; default 1" },
					"returns": "integer count",
				},
			},
		)
	if OS.has_environment("STAGEHAND_BUILTINS"):
		bridge.enable_builtins(OS.get_environment("STAGEHAND_BUILTINS").split(",", false))
	else:
		bridge.enable_builtins()
	print("STAGEHAND_READY ", bridge.get_port())


func retire_bridge() -> void:
	var before := heartbeat
	$Stagehand.queue_free()
	await get_tree().create_timer(0.1).timeout
	print(
		"FIXTURE_WITHOUT_BRIDGE ",
		JSON.stringify(
			{
				"advanced": heartbeat > before,
				"held": Input.is_action_pressed("move_forward"),
				"present": has_node("Stagehand"),
			},
		),
	)
