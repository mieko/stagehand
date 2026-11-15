extends Node
## Synthetic main-window events. This is global Input, not a virtual character device.

const Failure = preload("failure.gd")

var bridge: Node
var handle: String
var _writer: WebSocketPeer
var _manual: Dictionary = { }
var _held: Dictionary = { }
var _sequence: Dictionary = { }
var _last_result: Dictionary = { }
var _next_action := 0
var _mouse_position := Vector2.ZERO
var _mouse_known := false


func _init(owner: Node) -> void:
	bridge = owner
	process_mode = PROCESS_MODE_ALWAYS
	process_physics_priority = -10000


func _ready() -> void:
	handle = bridge.register_object(
		self,
		"Input",
		"builtin",
		{
			"actions": actions,
			"press": press,
			"release": release,
			"move_mouse": move_mouse,
			"sequence": sequence,
			"move_mouse_to": move_mouse_to,
			"scroll": scroll,
			"cancel": cancel,
			"status": status,
		},
		observe_input,
		["completed"],
	)
	bridge.connection_closed.connect(_disconnected)


func actions(_params: Dictionary) -> Dictionary:
	var result: Array = []
	for action: StringName in InputMap.get_actions():
		var bindings: Array = []
		for event: InputEvent in InputMap.action_get_events(action):
			bindings.append(event.as_text())
		result.append(
			{
				"name": str(action),
				"deadzone": InputMap.action_get_deadzone(action),
				"bindings": bindings,
			}
		)

	return {
		"actions": result,
		"sequence_clock": "physics_ticks",
		"mouse_move_clock": "wall_ms",
		"target": "main_window",
		"absolute_cursor_polling": false,
		"scroll": "wheel_factors",
		"gamepad": false,
		"touch": false,
	}


func _claim() -> Variant:
	var peer: WebSocketPeer = bridge.request_peer()
	if _writer != null and _writer != peer:
		return bridge.fail(-32030, "Input is owned by another connection")

	_writer = peer

	return null


func _event(params: Dictionary, down: bool) -> Variant:
	var event: InputEvent
	var id: String
	var kinds := 0
	for kind: String in ["action", "key", "button"]:
		if params.has(kind):
			kinds += 1
	if kinds != 1:
		return bridge.fail(-32602, "Expected exactly one of action, key, or button")

	for flag: String in ["physical", "shift", "ctrl", "alt", "meta"]:
		if params.has(flag) and not params[flag] is bool:
			return bridge.fail(-32602, "Input flags must be booleans")

	if params.has("action"):
		if not params.action is String or not InputMap.has_action(params.action):
			return bridge.fail(-32602, "Unknown InputMap action")

		var strength: Variant = params.get("strength", 1.0)
		if (
			not (strength is float or strength is int)
			or not is_finite(strength) or strength < 0 or strength > 1
		):
			return bridge.fail(-32602, "Action strength must be in 0..1")

		event = InputEventAction.new()
		event.action = params.action
		event.strength = strength if down else 0.0
		id = "action:" + params.action
	elif params.has("key"):
		if not params.key is String:
			return bridge.fail(-32602, "Expected key name")

		var code := OS.find_keycode_from_string(params.key.to_upper())
		if code == KEY_NONE:
			return bridge.fail(-32602, "Unknown key name")

		event = InputEventKey.new()
		if params.get("physical", false):
			event.physical_keycode = code
		else:
			event.keycode = code
		event.shift_pressed = bool(params.get("shift", false))
		event.ctrl_pressed = bool(params.get("ctrl", false))
		event.alt_pressed = bool(params.get("alt", false))
		event.meta_pressed = bool(params.get("meta", false))
		id = "key:%d:%s" % [code, params.get("physical", false)]
	elif params.has("button"):
		var buttons := {
			"left": MOUSE_BUTTON_LEFT,
			"right": MOUSE_BUTTON_RIGHT,
			"middle": MOUSE_BUTTON_MIDDLE,
		}
		if not buttons.has(params.button):
			return bridge.fail(-32602, "Expected left, right, or middle mouse button")

		event = InputEventMouseButton.new()
		event.button_index = buttons[params.button]
		var position: Variant = params.get("position", _cursor())
		if not position is Vector2 or not position.is_finite():
			return bridge.fail(-32602, "Expected finite Vector2 button position")

		event.position = position
		event.global_position = position
		id = "button:" + str(params.button)
	else:
		return bridge.fail(-32602, "Expected action, key, or button")

	event.pressed = down

	return { "id": id, "event": event }


func _apply(entry: Dictionary, down: bool, holds: Dictionary) -> void:
	var event: InputEvent = entry.event.duplicate()
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

	if event is InputEventMouseButton:
		_mouse_position = event.position
		_mouse_known = true

	if down:
		holds[entry.id] = entry
	else:
		holds.erase(entry.id)


func press(params: Dictionary) -> Variant:
	return _standalone(params, true)


func release(params: Dictionary) -> Variant:
	return _standalone(params, false)


func _standalone(params: Dictionary, down: bool) -> Variant:
	if not _sequence.is_empty():
		return bridge.fail(-32030, "Cancel or await the active input sequence first")

	var entry: Variant = _event(params, down)
	if entry is Failure:
		return entry

	if not down and not _manual.has(entry.id):
		return bridge.fail(-32602, "This connection has no matching held input")

	var error: Variant = _claim()
	if error is Failure:
		return error

	if not down and not entry.event is InputEventMouseButton:
		entry = _manual[entry.id]

	_apply(entry, down, _manual)
	if _manual.is_empty():
		_writer = null

	return { "input": entry.id, "held": down, "physics_tick": Engine.get_physics_frames() }


func move_mouse(params: Dictionary) -> Variant:
	if not _sequence.is_empty():
		return bridge.fail(-32030, "Cancel or await the active input sequence first")

	var relative: Variant = params.get("relative", Vector2.ZERO)
	var position: Variant = params.get("position", _cursor())
	if (
		not relative is Vector2 or not position is Vector2
		or not relative.is_finite() or not position.is_finite()
	):
		return bridge.fail(-32602, "Expected finite Vector2 position/relative motion")

	var error: Variant = _claim()
	if error is Failure:
		return error

	_emit_mouse(position, relative)
	if _manual.is_empty():
		_writer = null

	return {
		"delivered": true,
		"physical_cursor_moved": false,
		"physics_tick": Engine.get_physics_frames(),
	}


func scroll(params: Dictionary) -> Variant:
	if not _sequence.is_empty():
		return bridge.fail(-32030, "Cancel or await the active input sequence first")

	var vertical: Variant = params.get("vertical", 0)
	var horizontal: Variant = params.get("horizontal", 0)
	for amount: Variant in [vertical, horizontal]:
		if not (amount is float or amount is int) or not is_finite(amount) or abs(amount) > 100:
			return bridge.fail(-32602, "Scroll factors must be finite numbers in -100..100")

	if vertical == 0 and horizontal == 0:
		return bridge.fail(-32602, "Expected a nonzero vertical or horizontal scroll factor")

	var position: Variant = params.get("position", _cursor())
	if not position is Vector2 or not position.is_finite():
		return bridge.fail(-32602, "Expected finite Vector2 scroll position")

	var error: Variant = _claim()
	if error is Failure:
		return error

	for axis: int in range(2):
		var amount: float = vertical if axis == 0 else horizontal
		if amount == 0:
			continue

		var button: int = (
			(MOUSE_BUTTON_WHEEL_DOWN if amount > 0 else MOUSE_BUTTON_WHEEL_UP)
			if axis == 0
			else (MOUSE_BUTTON_WHEEL_RIGHT if amount > 0 else MOUSE_BUTTON_WHEEL_LEFT)
		)
		for down: bool in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = button
			event.factor = abs(amount)
			event.position = position
			event.global_position = position
			event.pressed = down
			event.button_mask = Input.get_mouse_button_mask()
			if down:
				event.button_mask |= 1 << (button - 1)
			Input.parse_input_event(event)
			Input.flush_buffered_events()

	_mouse_position = position
	_mouse_known = true
	if _manual.is_empty():
		_writer = null

	return {
		"delivered": true,
		"physical_cursor_moved": false,
		"physics_tick": Engine.get_physics_frames(),
	}


func _cursor() -> Vector2:
	return _mouse_position if _mouse_known else get_viewport().get_mouse_position()


func _emit_mouse(position: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.screen_relative = relative
	event.button_mask = Input.get_mouse_button_mask()
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	_mouse_position = position
	_mouse_known = true


func move_mouse_to(params: Dictionary) -> Variant:
	if not _sequence.is_empty():
		return bridge.fail(-32030, "An input operation is already active")

	var destination: Variant = params.get("position")
	var origin: Variant = params.get("from", _cursor())
	var duration: Variant = params.get("duration_ms")
	if (
		not destination is Vector2 or not origin is Vector2
		or not destination.is_finite() or not origin.is_finite()
	):
		return bridge.fail(-32602, "Expected finite Vector2 position and optional from")

	if (
		not (duration is float or duration is int)
		or not is_finite(duration) or duration < 1 or duration > 60000
	):
		return bridge.fail(-32602, "duration_ms must be in 1..60000")

	var error: Variant = _claim()
	if error is Failure:
		return error

	_next_action += 1
	var id := "%s:action:%d" % [handle, _next_action]
	_sequence = {
		"id": id,
		"kind": "mouse",
		"from": origin,
		"to": destination,
		"last_position": origin,
		"samples": 0,
		"duration_ms": duration,
		"elapsed": 0,
		"start_tick": Engine.get_physics_frames(),
		"simulation_seconds": 0.0,
		"wall_start": Time.get_ticks_msec(),
		"budget": duration + 1000,
	}

	_emit_mouse(origin, Vector2.ZERO)

	return { "action": id, "status": "accepted" }


func sequence(params: Dictionary) -> Variant:
	if not _sequence.is_empty():
		return bridge.fail(-32030, "An input sequence is already active")

	var ticks: Variant = params.get("ticks")
	var events: Variant = params.get("events", [])
	var budget: Variant = params.get("max_wall_ms", 10000)
	if not (ticks is float or ticks is int) or ticks < 1 or ticks > 3600 or ticks != floor(ticks):
		return bridge.fail(-32602, "ticks must be an integer in 1..3600")

	if not events is Array or events.size() > 256:
		return bridge.fail(-32602, "Expected at most 256 scheduled events")

	if (
		not (budget is float or budget is int)
		or not is_finite(budget) or budget < 1 or budget > 60000
	):
		return bridge.fail(-32602, "max_wall_ms must be in 1..60000")

	var compiled: Array = []
	for item: Variant in events:
		if (
			not item is Dictionary or not item.get("input") is Dictionary
			or not item.get("pressed") is bool
		):
			return bridge.fail(-32602, "Each event needs input and pressed")

		var at: Variant = item.get("at_tick")
		if not (at is float or at is int) or at < 0 or at >= ticks or at != floor(at):
			return bridge.fail(-32602, "at_tick must be an integer inside the sequence")

		var entry: Variant = _event(item.input, item.pressed)
		if entry is Failure:
			return entry

		if _manual.has(entry.id):
			return bridge.fail(-32030, "A sequence cannot change an independently held input")

		compiled.append(
			{ "at": int(at), "order": compiled.size(), "down": item.pressed, "entry": entry }
		)

	compiled.sort_custom(
		func(a, b):
			return a.at < b.at or (a.at == b.at and a.order < b.order),
	)
	var error: Variant = _claim()
	if error is Failure:
		return error

	_next_action += 1
	var id := "%s:action:%d" % [handle, _next_action]
	_sequence = {
		"id": id,
		"kind": "sequence",
		"ticks": int(ticks),
		"events": compiled,
		"elapsed": 0,
		"start_tick": -1,
		"simulation_seconds": 0.0,
		"wall_start": Time.get_ticks_msec(),
		"budget": budget,
	}

	return { "action": id, "status": "accepted" }


func _physics_process(delta: float) -> void:
	if _sequence.is_empty() or _sequence.kind != "sequence" or get_tree().paused:
		return

	if _sequence.elapsed == _sequence.ticks:
		_finish("completed", "sequence_exhausted")

		return

	if _sequence.start_tick < 0:
		_sequence.start_tick = Engine.get_physics_frames()

	for event: Dictionary in _sequence.events:
		if event.at == _sequence.elapsed:
			_apply(event.entry, event.down, _held)

	_sequence.elapsed += 1
	_sequence.simulation_seconds += delta


func _process(_delta: float) -> void:
	if _sequence.is_empty():
		return

	var wall_ms: int = Time.get_ticks_msec() - _sequence.wall_start
	if wall_ms >= _sequence.budget:
		_finish("failed", "wall_time_budget")
	elif _sequence.kind == "mouse":
		var fraction := clampf(float(wall_ms) / _sequence.duration_ms, 0.0, 1.0)
		var position: Vector2 = _sequence.from.lerp(_sequence.to, fraction)
		_emit_mouse(position, position - _sequence.last_position)
		_sequence.last_position = position
		_sequence.samples += 1
		if fraction == 1.0:
			_finish("completed", "destination_events_delivered")


func _release_all(holds: Dictionary) -> void:
	for entry: Dictionary in holds.values():
		if entry.event is InputEventMouseButton:
			entry = entry.duplicate()
			entry.event = entry.event.duplicate()
			entry.event.position = _cursor()
			entry.event.global_position = _cursor()
		_apply(entry, false, holds)


func _finish(outcome: String, reason: String) -> void:
	_release_all(_held)
	_last_result = {
		"action": _sequence.id,
		"kind": _sequence.kind,
		"status": outcome,
		"reason": reason,
		"applied_ticks": _sequence.elapsed,
		"started_tick": _sequence.start_tick,
		"finished_tick": Engine.get_physics_frames(),
		"inputs_released": true,
		"simulation_seconds": _sequence.simulation_seconds,
		"wall_ms": Time.get_ticks_msec() - _sequence.wall_start,
	}

	if _sequence.kind == "mouse":
		_last_result.merge(
			{
				"position": _sequence.last_position,
				"samples": _sequence.samples,
				"duration_ms": _sequence.duration_ms,
				"physical_cursor_moved": false,
			},
		)

	_sequence.clear()
	_last_result["input"] = observe_input()
	bridge.publish(handle, "completed", _last_result)

	if _manual.is_empty():
		_writer = null


func observe_input() -> Dictionary:
	var pressed: Array = []
	for action: StringName in InputMap.get_actions():
		if Input.is_action_pressed(action):
			pressed.append({ "action": str(action), "strength": Input.get_action_strength(action) })

	return {
		"active_action": _sequence.get("id"),
		"synthetic_position": _cursor(),
		"held_inputs": _manual.keys() + _held.keys(),
		"pressed_actions": pressed,
		"mouse_button_mask": Input.get_mouse_button_mask(),
	}


func status(params: Dictionary) -> Variant:
	if not _sequence.is_empty() and params.get("action") == _sequence.id:
		return { "action": _sequence.id, "status": "running", "applied_ticks": _sequence.elapsed }

	if not _last_result.is_empty() and params.get("action") == _last_result.action:
		return _last_result

	return bridge.fail(-32004, "Unknown action; only active and latest result are retained")


func cancel(params: Dictionary) -> Variant:
	if _sequence.is_empty() or params.get("action") != _sequence.id:
		return status(params)

	if _writer != bridge.request_peer():
		return bridge.fail(-32030, "Input is owned by another connection")

	_finish("cancelled", "requested")

	return _last_result


func _disconnected(peer: WebSocketPeer) -> void:
	if peer != _writer:
		return

	if not _sequence.is_empty():
		_finish("cancelled", "connection_closed")

	_release_all(_manual)
	_writer = null


func _exit_tree() -> void:
	_release_all(_held)
	_release_all(_manual)
