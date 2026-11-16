extends Node
## Synthetic main-window events. This is global Input, not a virtual character device.

const Failure = preload("failure.gd")
const Values = preload("values.gd")
const InputPlan = preload("input_plan.gd")
const InputDevice = preload("input_device.gd")

var bridge: Node
var handle: String
var _writer: WebSocketPeer
var _manual: Dictionary = { }
var _held: Dictionary = { }
var _operation: Dictionary = { }
var _last_result: Dictionary = { }
var _next_action := 0
var _device: RefCounted
var _scripts: RefCounted
var _closing := false
var _values: RefCounted


func _init(owner: Node, scripts: RefCounted = null) -> void:
	bridge = owner
	_scripts = scripts
	_values = Values.new(owner)
	process_mode = PROCESS_MODE_ALWAYS
	process_physics_priority = -10000


func _ready() -> void:
	_device = InputDevice.new(get_viewport())

	var operations := {
		"actions": actions,
		"press": press,
		"release": release,
		"move_mouse": move_mouse,
		"sequence": sequence,
		"move_mouse_to": move_mouse_to,
		"scroll": scroll,
		"cancel": cancel,
		"status": status,
	}
	if _scripts != null:
		operations["hold_until"] = hold_until

	handle = bridge.register_object(
		self,
		"Input",
		"Input",
		operations,
		observe_input,
		["completed"],
		{ },
		true,
		"1.1.0",
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
	if _closing:
		return bridge.fail(
			Failure.INPUT_CONFLICT,
			"Input is releasing the previous operation's holds",
		)

	var peer: WebSocketPeer = bridge.request_peer()
	if peer == null:
		return bridge.fail(
			Failure.AUTHENTICATION_FAILED,
			"Input request connection is no longer active",
		)

	if _writer != null and _writer != peer:
		return bridge.fail(Failure.INPUT_CONFLICT, "Input is owned by another connection")

	_writer = peer

	return null


func press(params: Dictionary) -> Variant:
	return _standalone(params, true)


func release(params: Dictionary) -> Variant:
	return _standalone(params, false)


func _standalone(params: Dictionary, down: bool) -> Variant:
	if not _operation.is_empty():
		return bridge.fail(
			Failure.INPUT_CONFLICT,
			"Cancel or await the active input sequence first",
		)

	var entry: Variant = InputPlan.event(params, down, _device.cursor())
	if entry is Failure:
		return entry

	if not down and not _manual.has(entry.id):
		return bridge.fail(Failure.INVALID_PARAMS, "This connection has no matching held input")

	var error: Variant = _claim()
	if error is Failure:
		return error

	if not down and not entry.event is InputEventMouseButton:
		entry = _manual[entry.id]

	_device.apply(entry, down, _manual)
	_release_writer_if_idle()

	return { "input": entry.id, "held": down, "physics_tick": Engine.get_physics_frames() }


func move_mouse(params: Dictionary) -> Variant:
	if not _operation.is_empty():
		return bridge.fail(
			Failure.INPUT_CONFLICT,
			"Cancel or await the active input sequence first",
		)

	var plan: Variant = InputPlan.motion(params, _device.cursor())
	if plan is Failure:
		return plan

	var error: Variant = _claim()
	if error is Failure:
		return error

	_device.move(plan.position, plan.relative)
	_release_writer_if_idle()

	return {
		"delivered": true,
		"physical_cursor_moved": false,
		"physics_tick": Engine.get_physics_frames(),
	}


func scroll(params: Dictionary) -> Variant:
	if not _operation.is_empty():
		return bridge.fail(
			Failure.INPUT_CONFLICT,
			"Cancel or await the active input sequence first",
		)

	var plan: Variant = InputPlan.scroll(params, _device.cursor())
	if plan is Failure:
		return plan

	var error: Variant = _claim()
	if error is Failure:
		return error

	_device.scroll(plan)
	_release_writer_if_idle()

	return {
		"delivered": true,
		"physical_cursor_moved": false,
		"physics_tick": Engine.get_physics_frames(),
	}


func move_mouse_to(params: Dictionary) -> Variant:
	if not _operation.is_empty():
		return bridge.fail(Failure.INPUT_CONFLICT, "An input operation is already active")

	var plan: Variant = InputPlan.mouse_move(params, _device.cursor())
	if plan is Failure:
		return plan

	var error: Variant = _claim()
	if error is Failure:
		return error

	var accepted := _accept(
		"mouse",
		plan.duration_ms + 1000,
		{
			"from": plan.from,
			"to": plan.to,
			"last_position": plan.from,
			"samples": 0,
			"duration_ms": plan.duration_ms,
			"start_tick": Engine.get_physics_frames(),
		},
	)

	_device.move(plan.from, Vector2.ZERO)

	return accepted


func sequence(params: Dictionary) -> Variant:
	if not _operation.is_empty() or _closing:
		return bridge.fail(Failure.INPUT_CONFLICT, "An input sequence is already active")

	var plan: Variant = InputPlan.sequence(params, _device.cursor(), _manual)
	if plan is Failure:
		return plan

	var error: Variant = _claim()
	if error is Failure:
		return error

	return _accept("sequence", plan.budget, { "ticks": plan.ticks, "events": plan.events })


func hold_until(params: Dictionary) -> Variant:
	if _scripts == null:
		return bridge.fail(Failure.METHOD_NOT_FOUND, "Enable Script to use conditional input")

	if not _operation.is_empty() or _closing:
		return bridge.fail(Failure.INPUT_CONFLICT, "An input operation is already active")

	var evaluation: Variant = _scripts.prepare(params)
	if evaluation is Failure:
		return evaluation

	var plan: Variant = InputPlan.hold(params, _device.cursor(), _manual)
	if plan is Failure:
		return plan

	if not _operation.is_empty():
		return bridge.fail(
			Failure.INPUT_CONFLICT,
			"An input operation started during evaluator preparation",
		)

	var error: Variant = _claim()
	if error is Failure:
		return error

	return _accept(
		"hold_until",
		plan.budget,
		{
			"evaluation": evaluation,
			"initial": plan.initial,
			"response": plan.response,
			"limit": plan.limit,
			"pending_delta": 0.0,
			"pending_interval": false,
			"condition": null,
			"response_started": false,
			"response_ticks": 0,
			"waiting_seconds": 0.0,
			"initial_pressed": false,
		},
	)


func _accept(kind: String, budget: float, details: Dictionary) -> Dictionary:
	_next_action += 1
	var id := "%s:action:%d" % [handle, _next_action]
	_operation = {
		"id": id,
		"kind": kind,
		"elapsed": 0,
		"start_tick": -1,
		"simulation_seconds": 0.0,
		"wall_start": Time.get_ticks_msec(),
		"budget": budget,
	}
	_operation.merge(details, true)

	return { "action": id, "status": "accepted" }


func _physics_process(delta: float) -> void:
	if _operation.is_empty() or _closing:
		return

	if _operation.kind == "hold_until":
		_conditional_tick(delta)

		return

	if _operation.kind != "sequence" or get_tree().paused:
		return

	if _operation.elapsed == _operation.ticks:
		_finish("completed", "sequence_exhausted")

		return

	if _operation.start_tick < 0:
		_operation.start_tick = Engine.get_physics_frames()

	for event: Dictionary in _operation.events:
		if event.at == _operation.elapsed:
			var active := _operation
			_device.apply(event.entry, event.down, _held)
			if not _same_action(active):
				return

	_operation.elapsed += 1
	_operation.simulation_seconds += delta


func _same_action(action: Dictionary) -> bool:
	return is_instance_valid(self) and not _closing and _operation.get("id") == action.id


func _expired(action: Dictionary) -> bool:
	return Time.get_ticks_msec() - action.wall_start >= action.budget


func _conditional_tick(delta: float) -> void:
	var action := _operation
	action.simulation_seconds += action.pending_delta
	if action.response_started:
		action.response_ticks += int(action.pending_interval)
	else:
		action.waiting_seconds += action.pending_delta

	action.pending_delta = 0.0
	action.pending_interval = false

	if _expired(action):
		_finish("failed", "wall_time_budget")

		return

	if get_tree().paused:
		return

	if action.start_tick < 0:
		action.start_tick = Engine.get_physics_frames()

	if action.response_started:
		_response_tick(action, delta)

		return

	var result: Variant = action.evaluation.run()
	if not _same_action(action):
		return

	var error: Variant = _observe_condition(action, result)
	if error is Failure:
		_fail_condition(error)

		return

	if _expired(action):
		_finish("failed", "wall_time_budget")
	elif action.condition.matched:
		_begin_response(action, delta)
	elif action.waiting_seconds >= action.limit:
		_finish("completed", "simulation_time_limit")
	else:
		_hold_tick(action, delta)


func _observe_condition(action: Dictionary, result: Variant) -> Variant:
	if result is Failure:
		return result

	if not result is Dictionary or not result.get("matched") is bool or not result.has("value"):
		return bridge.fail(
			Failure.INVALID_PARAMS,
			"Predicate must return {matched: bool, value: Variant}",
		)

	var value: Variant = _values.snapshot(result.value)
	if value is Failure:
		return value

	action.condition = {
		"matched": result.matched,
		"value": value,
		"clock": bridge.clock(),
		"phase": "physics_before",
		"simulation_seconds": action.waiting_seconds,
	}

	return null


func _hold_tick(action: Dictionary, delta: float) -> void:
	if not action.initial_pressed:
		action.initial_pressed = true
		for entry: Dictionary in action.initial:
			_device.apply(entry, true, _held)
			if not _same_action(action):
				return

	action.elapsed += 1
	action.pending_delta = delta
	action.pending_interval = true


func _begin_response(action: Dictionary, delta: float) -> void:
	_device.release_all(_held)
	if not _same_action(action):
		return

	if _expired(action):
		_finish("failed", "wall_time_budget")

		return

	if action.response == null:
		_finish("completed", "condition_matched")

		return

	action.response_started = true
	_response_tick(action, delta)


func _response_tick(action: Dictionary, delta: float) -> void:
	if action.response_ticks == action.response.ticks:
		_finish("completed", "condition_matched")

		return

	for event: Dictionary in action.response.events:
		if event.at == action.response_ticks:
			_device.apply(event.entry, event.down, _held)
			if not _same_action(action):
				return

	action.elapsed += 1
	action.pending_delta = delta
	action.pending_interval = true


func _fail_condition(error: Failure) -> void:
	_operation["error"] = { "code": error.code, "message": error.message }
	_finish("failed", "predicate_failed")


func _process(_delta: float) -> void:
	if _operation.is_empty() or _closing:
		return

	var wall_ms: int = Time.get_ticks_msec() - _operation.wall_start
	if wall_ms >= _operation.budget:
		_finish("failed", "wall_time_budget")
	elif _operation.kind == "mouse":
		var active := _operation
		var fraction := clampf(float(wall_ms) / _operation.duration_ms, 0.0, 1.0)
		var position: Vector2 = _operation.from.lerp(_operation.to, fraction)
		_device.move(position, position - _operation.last_position)
		if not _same_action(active):
			return

		_operation.last_position = position
		_operation.samples += 1
		if fraction == 1.0:
			_finish("completed", "destination_events_delivered")


func _finish(outcome: String, reason: String) -> void:
	if _operation.is_empty() or _closing:
		return

	_closing = true
	var action := _operation
	_device.release_all(_held)

	_last_result = {
		"action": _operation.id,
		"kind": _operation.kind,
		"status": outcome,
		"reason": reason,
		"applied_ticks": _operation.elapsed,
		"started_tick": _operation.start_tick,
		"finished_tick": Engine.get_physics_frames(),
		"inputs_released": true,
		"simulation_seconds": _operation.simulation_seconds,
		"wall_ms": Time.get_ticks_msec() - _operation.wall_start,
	}

	if _operation.kind == "mouse":
		_last_result.merge(
			{
				"position": _operation.last_position,
				"samples": _operation.samples,
				"duration_ms": _operation.duration_ms,
				"physical_cursor_moved": false,
			},
		)

	if action.kind == "hold_until":
		_last_result.merge(
			{
				"condition": action.condition,
				"response_started": action.response_started,
				"response_ticks": action.response_ticks,
			}
		)
		if action.has("error"):
			_last_result["error"] = action.error

	_operation = { }
	_last_result["input"] = observe_input()
	var publication_clock: Dictionary = bridge.clock()
	if action.kind == "hold_until":
		_validate_completion(publication_clock)

	bridge.publish(handle, "completed", _last_result, publication_clock)

	_closing = false
	_release_writer_if_idle()


func _release_writer_if_idle() -> void:
	if _manual.is_empty() and _operation.is_empty() and not _closing:
		_writer = null


func _validate_completion(at: Dictionary) -> void:
	var error: Variant = bridge.publication_error(handle, "completed", _last_result, at)
	if error is Failure:
		_last_result.status = "failed"
		_last_result.reason = "unsupported_result"
		_last_result["error"] = { "code": error.code, "message": error.message }
		if _last_result.condition != null:
			_last_result.condition.erase("value")


func observe_input() -> Dictionary:
	var pressed: Array = []
	for action: StringName in InputMap.get_actions():
		if Input.is_action_pressed(action):
			pressed.append({ "action": str(action), "strength": Input.get_action_strength(action) })

	return {
		"active_action": _operation.get("id"),
		"synthetic_position": _device.cursor(),
		"held_inputs": _manual.keys() + _held.keys(),
		"pressed_actions": pressed,
		"mouse_button_mask": Input.get_mouse_button_mask(),
	}


func status(params: Dictionary) -> Variant:
	if not _operation.is_empty() and params.get("action") == _operation.id:
		var result := {
			"action": _operation.id,
			"status": "running",
			"applied_ticks": _operation.elapsed,
		}
		if _operation.kind == "hold_until":
			result["response_started"] = _operation.response_started
			result["response_ticks"] = _operation.response_ticks

		return result

	if not _last_result.is_empty() and params.get("action") == _last_result.action:
		return _last_result

	return bridge.fail(
		Failure.UNKNOWN_HANDLE,
		"Unknown action; only active and latest result are retained",
	)


func cancel(params: Dictionary) -> Variant:
	if _operation.is_empty() or params.get("action") != _operation.id or _closing:
		return status(params)

	if _writer != bridge.request_peer():
		return bridge.fail(Failure.INPUT_CONFLICT, "Input is owned by another connection")

	_finish("cancelled", "requested")

	return _last_result


func _disconnected(peer: WebSocketPeer) -> void:
	if peer != _writer:
		return

	var closing := _closing
	if not _operation.is_empty():
		_finish("cancelled", "connection_closed")

	_closing = true
	_device.release_all(_manual)
	_writer = null
	_closing = closing


func _exit_tree() -> void:
	_closing = true
	_device.release_all(_held)
	_device.release_all(_manual)
