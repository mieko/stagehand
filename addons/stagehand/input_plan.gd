extends RefCounted
## Validate descriptors and prepare plans without delivering events or claiming Input.

const Failure = preload("failure.gd")


static func event(params: Dictionary, down: bool, cursor: Vector2) -> Variant:
	var event: InputEvent
	var id: String
	var kinds := 0

	for kind: String in ["action", "key", "button"]:
		if params.has(kind):
			kinds += 1

	if kinds != 1:
		return Failure.new(Failure.INVALID_PARAMS, "Expected exactly one of action, key, or button")

	for flag: String in ["physical", "shift", "ctrl", "alt", "meta"]:
		if params.has(flag) and not params[flag] is bool:
			return Failure.new(Failure.INVALID_PARAMS, "Input flags must be booleans")

	if params.has("action"):
		if not params.action is String or not InputMap.has_action(params.action):
			return Failure.new(Failure.INVALID_PARAMS, "Unknown InputMap action")

		var strength: Variant = params.get("strength", 1.0)
		if (
			not (strength is float or strength is int)
			or not is_finite(strength) or strength < 0 or strength > 1
		):
			return Failure.new(Failure.INVALID_PARAMS, "Action strength must be in 0..1")

		event = InputEventAction.new()
		event.action = params.action
		event.strength = strength if down else 0.0
		id = "action:" + params.action
	elif params.has("key"):
		if not params.key is String:
			return Failure.new(Failure.INVALID_PARAMS, "Expected key name")

		var code := OS.find_keycode_from_string(params.key.to_upper())
		if code == KEY_NONE:
			return Failure.new(Failure.INVALID_PARAMS, "Unknown key name")

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
			return Failure.new(
				Failure.INVALID_PARAMS,
				"Expected left, right, or middle mouse button",
			)

		event = InputEventMouseButton.new()
		event.button_index = buttons[params.button]
		var position: Variant = params.get("position", cursor)
		if not position is Vector2 or not position.is_finite():
			return Failure.new(Failure.INVALID_PARAMS, "Expected finite Vector2 button position")

		event.position = position
		event.global_position = position
		id = "button:" + str(params.button)
	else:
		return Failure.new(Failure.INVALID_PARAMS, "Expected action, key, or button")

	event.pressed = down

	return { "id": id, "event": event }


static func sequence(params: Dictionary, cursor: Vector2, manual: Dictionary) -> Variant:
	var ticks: Variant = params.get("ticks")
	var events: Variant = params.get("events", [])
	var budget: Variant = params.get("max_wall_ms", 10000)
	if not (ticks is float or ticks is int) or ticks < 1 or ticks > 3600 or ticks != floor(ticks):
		return Failure.new(Failure.INVALID_PARAMS, "ticks must be an integer in 1..3600")

	if not events is Array or events.size() > 256:
		return Failure.new(Failure.INVALID_PARAMS, "Expected at most 256 scheduled events")

	if (
		not (budget is float or budget is int)
		or not is_finite(budget) or budget < 1 or budget > 60000
	):
		return Failure.new(Failure.INVALID_PARAMS, "max_wall_ms must be in 1..60000")

	var compiled: Array = []
	for item: Variant in events:
		if (
			not item is Dictionary or not item.get("input") is Dictionary
			or not item.get("pressed") is bool
		):
			return Failure.new(Failure.INVALID_PARAMS, "Each event needs input and pressed")

		var at: Variant = item.get("at_tick")
		if not (at is float or at is int) or at < 0 or at >= ticks or at != floor(at):
			return Failure.new(
				Failure.INVALID_PARAMS,
				"at_tick must be an integer inside the sequence",
			)

		var entry: Variant = event(item.input, item.pressed, cursor)
		if entry is Failure:
			return entry

		if manual.has(entry.id):
			return Failure.new(
				Failure.INPUT_CONFLICT,
				"A sequence cannot change an independently held input",
			)

		compiled.append(
			{ "at": int(at), "order": compiled.size(), "down": item.pressed, "entry": entry }
		)

	compiled.sort_custom(
		func(a, b):
			return a.at < b.at or (a.at == b.at and a.order < b.order),
	)

	return { "ticks": int(ticks), "events": compiled, "budget": budget }


static func hold(params: Dictionary, cursor: Vector2, manual: Dictionary) -> Variant:
	var holds: Variant = params.get("hold")
	var limit: Variant = params.get("max_simulation_seconds")
	var budget: Variant = params.get("max_wall_ms", 10000)
	if not holds is Array or holds.is_empty() or holds.size() > 256:
		return Failure.new(Failure.INVALID_PARAMS, "hold must contain 1..256 input descriptors")

	if not (limit is float or limit is int) or not is_finite(limit) or limit <= 0:
		return Failure.new(
			Failure.INVALID_PARAMS,
			"max_simulation_seconds must be positive and finite",
		)

	var response: Variant = params.get("response", { "ticks": 1 })
	if not response is Dictionary:
		return Failure.new(Failure.INVALID_PARAMS, "response must be a finite input sequence")

	var response_params: Dictionary = response.duplicate()
	response_params["max_wall_ms"] = budget
	var compiled: Variant = sequence(response_params, cursor, manual)
	if compiled is Failure:
		return compiled

	var initial: Array = []
	for input: Variant in holds:
		if not input is Dictionary:
			return Failure.new(Failure.INVALID_PARAMS, "Expected input descriptors in hold")

		var entry: Variant = event(input, true, cursor)
		if entry is Failure:
			return entry

		if manual.has(entry.id):
			return Failure.new(
				Failure.INPUT_CONFLICT,
				"Conditional input cannot change an independently held input",
			)

		initial.append(entry)

	return {
		"initial": initial,
		"limit": float(limit),
		"budget": budget,
		"response": compiled if params.has("response") else null,
	}


static func motion(params: Dictionary, cursor: Vector2) -> Variant:
	var relative: Variant = params.get("relative", Vector2.ZERO)
	var position: Variant = params.get("position", cursor)
	if (
		not relative is Vector2 or not position is Vector2
		or not relative.is_finite() or not position.is_finite()
	):
		return Failure.new(
			Failure.INVALID_PARAMS,
			"Expected finite Vector2 position/relative motion",
		)

	return { "position": position, "relative": relative }


static func scroll(params: Dictionary, cursor: Vector2) -> Variant:
	var vertical: Variant = params.get("vertical", 0)
	var horizontal: Variant = params.get("horizontal", 0)
	for amount: Variant in [vertical, horizontal]:
		if not (amount is float or amount is int) or not is_finite(amount) or abs(amount) > 100:
			return Failure.new(
				Failure.INVALID_PARAMS,
				"Scroll factors must be finite numbers in -100..100",
			)

	if vertical == 0 and horizontal == 0:
		return Failure.new(
			Failure.INVALID_PARAMS,
			"Expected a nonzero vertical or horizontal scroll factor",
		)

	var position: Variant = params.get("position", cursor)
	if not position is Vector2 or not position.is_finite():
		return Failure.new(Failure.INVALID_PARAMS, "Expected finite Vector2 scroll position")

	return { "position": position, "vertical": vertical, "horizontal": horizontal }


static func mouse_move(params: Dictionary, cursor: Vector2) -> Variant:
	var destination: Variant = params.get("position")
	var origin: Variant = params.get("from", cursor)
	var duration: Variant = params.get("duration_ms")
	if (
		not destination is Vector2 or not origin is Vector2
		or not destination.is_finite() or not origin.is_finite()
	):
		return Failure.new(
			Failure.INVALID_PARAMS,
			"Expected finite Vector2 position and optional from",
		)

	if (
		not (duration is float or duration is int)
		or not is_finite(duration) or duration < 1 or duration > 60000
	):
		return Failure.new(Failure.INVALID_PARAMS, "duration_ms must be in 1..60000")

	return { "from": origin, "to": destination, "duration_ms": duration }
