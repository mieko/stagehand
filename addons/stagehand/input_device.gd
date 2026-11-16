extends RefCounted
## Deliver native events and track the synthetic cursor. Hold lifetimes belong to Input.

var _viewport: Viewport
var _mouse_position := Vector2.ZERO
var _mouse_known := false


func _init(viewport: Viewport) -> void:
	_viewport = viewport


func cursor() -> Vector2:
	return _mouse_position if _mouse_known else _viewport.get_mouse_position()


func apply(entry: Dictionary, down: bool, holds: Dictionary) -> void:
	var event: InputEvent = entry.event.duplicate()
	event.pressed = down

	if down:
		holds[entry.id] = entry
	else:
		holds.erase(entry.id)

	_deliver(event)


func move(position: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.screen_relative = relative
	event.button_mask = Input.get_mouse_button_mask()
	_deliver(event)


func scroll(plan: Dictionary) -> void:
	for axis: int in range(2):
		var amount: float = plan.vertical if axis == 0 else plan.horizontal
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
			event.position = plan.position
			event.global_position = plan.position
			event.pressed = down
			event.button_mask = Input.get_mouse_button_mask()
			if down:
				event.button_mask |= 1 << (button - 1)

			_deliver(event)


func _deliver(event: InputEvent) -> void:
	# Input handlers can synchronously reenter, so expose this position before dispatch.
	if event is InputEventMouse:
		_mouse_position = event.position
		_mouse_known = true

	Input.parse_input_event(event)
	Input.flush_buffered_events()


func release_all(holds: Dictionary) -> void:
	for entry: Dictionary in holds.values():
		if not holds.has(entry.id):
			continue

		if entry.event is InputEventMouseButton:
			entry = entry.duplicate()
			entry.event = entry.event.duplicate()
			entry.event.position = cursor()
			entry.event.global_position = cursor()

		apply(entry, false, holds)
