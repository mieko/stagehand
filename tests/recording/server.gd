extends Node

const Bridge = preload("res://addons/stagehand/bridge.gd")


func _ready() -> void:
	var bridge := Bridge.new()
	bridge.name = &"Stagehand"
	add_child(bridge)
	var names := OS.get_environment("STAGEHAND_BUILTINS")
	var error: Error = bridge.enable_builtins(names.split(",") if not names.is_empty() else [])
	if error == OK:
		error = bridge.start(OS.get_environment("STAGEHAND_TOKEN"), 0)

	if error != OK:
		push_error(error_string(error))
		get_tree().quit(1)

		return

	print("STAGEHAND_READY ", bridge.get_port())
