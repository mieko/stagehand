extends Node

const Bridge = preload("res://addons/stagehand/bridge.gd")


class Probe extends Node:
	const NEGATIVE_COUNTER := -32040

	signal native_changed(value: int)
	signal native_empty
	signal native_payload(
		first: Variant,
		second: Variant,
		third: Variant,
		fourth: Variant,
		fifth: Variant,
	)

	var count := 0
	var handle := ""
	var bridge: Node


	func increment(params: Dictionary) -> int:
		count += int(params.get("amount", 1))
		bridge.publish(handle, "changed", count)

		return count


	func observe() -> Variant:
		if count < 0:
			return bridge.fail(NEGATIVE_COUNTER, "Negative fixture counter cannot be observed")

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


	func configure_builtins(params: Dictionary) -> Variant:
		if params.has("names"):
			return bridge.enable_builtins(PackedStringArray(params.names))

		return bridge.enable_builtins()


	func builtin_configuration(params: Dictionary) -> Dictionary:
		var configuration: Dictionary = bridge.builtin_configuration()
		if params.get("mutate_copy", false):
			configuration.available.clear()
			configuration.selected.append("Changed copy")

		return configuration


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
var back_ticks := 0
var capsule := Node3D.new()
var reenter_on_release := false
var reentry_result: Dictionary = { }
var pause_after_tick := false
var start_on_press := false
var reentry_action := ""
var release_button_on_pointer := false
var button_release_position := Vector2.ZERO


func _input(event: InputEvent) -> void:
	event_count += 1
	if start_on_press and event.is_action_pressed("move_forward"):
		start_on_press = false
		var endpoint := $Stagehand/InputEndpoint
		endpoint.release({ "action": "move_forward" })
		var started: Dictionary = endpoint.sequence({ "ticks": 60 })
		reentry_action = started.action

	if reenter_on_release and event.is_action_released("move_forward"):
		reenter_on_release = false
		var endpoint := $Stagehand/InputEndpoint
		var active: Variant = endpoint.observe_input().active_action
		var cancelled: Variant = endpoint.cancel({ "action": active })
		var started: Variant = endpoint.sequence({ "ticks": 1 })
		reentry_result = { "cancel_status": cancelled.status, "start_error": started.code }

	var wheel: bool = event is InputEventMouseButton and event.button_index >= MOUSE_BUTTON_WHEEL_UP
	if release_button_on_pointer and (event is InputEventMouseMotion or wheel):
		release_button_on_pointer = false
		$Stagehand/InputEndpoint.release({ "button": "left" })

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
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			button_release_position = event.position

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
		capsule.position.y += _delta
		$TestViewport/Panel.color = Color(0.8, 0.15, 0.1)

	if Input.is_action_pressed("move_back"):
		back_ticks += 1
		capsule.position.y -= _delta

	if pause_after_tick:
		pause_after_tick = false
		get_tree().paused = true


func _ready() -> void:
	capsule.name = "Capsule"
	add_child(capsule)

	InputMap.add_action("move_forward")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_W
	InputMap.action_add_event("move_forward", key)

	InputMap.add_action("jump")

	InputMap.add_action("move_back")
	var back := InputEventKey.new()
	back.physical_keycode = KEY_S
	InputMap.action_add_event("move_back", back)

	$ClickTarget.pressed.connect(
		func() -> void:
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
				"configure_builtins": probe.configure_builtins,
				"builtin_configuration": probe.builtin_configuration,
				"unsupported": probe.unsupported,
				"large_output": probe.large_output,
				"image_info": probe.image_info,
				"retire": probe.retire,
			},
			probe.observe,
			["changed", "native_changed"] if label == "A" else ["changed"],
			{
				"increment": {
					"params": { "amount": "number; default 1" },
					"returns": "integer count",
				},
			},
		)

	if not OS.has_environment("STAGEHAND_SKIP_BUILTINS"):
		var setup_error: Error
		if OS.has_environment("STAGEHAND_BUILTINS"):
			setup_error = bridge.enable_builtins(
				OS.get_environment("STAGEHAND_BUILTINS").split(",", false)
			)
		else:
			setup_error = bridge.enable_builtins()

		if setup_error != OK:
			push_error("Cannot configure Stagehand: " + error_string(setup_error))
			get_tree().quit(1)

			return

	print("STAGEHAND_READY ", bridge.get_port())


func press_after_close(_peer: WebSocketPeer) -> void:
	var result: Variant = $Stagehand/InputEndpoint.press({ "action": "move_forward" })
	reentry_result["closed_press"] = result.code if result is Bridge.Failure else 0


func report_input() -> void:
	var state: Dictionary = $Stagehand/InputEndpoint.observe_input()
	print(
		"FIXTURE_INPUT_REPORT ",
		JSON.stringify(
			{
				"held": Input.is_action_pressed("move_forward"),
				"input_ticks": input_ticks,
				"active": state.active_action,
			}
		),
	)


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
