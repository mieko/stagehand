extends "res://addons/stagehand/bridge.gd"


func _ready() -> void:
	app_name = "Greeter Demo"
	register_object(self, "Fixture", "Fixture", { "echo": _echo })
	var result := serve_client(
		"res://served/client.mjs",
		"res://served/api.md",
		"res://served/game.md",
	)
	if result == OK:
		result = start(OS.get_environment("STAGEHAND_TOKEN"), 0, "127.0.0.1")

	if result != OK:
		push_error(error_string(result))
		get_tree().quit(1)
		return

	print("STAGEHAND_READY ", get_port())


func _echo(params: Dictionary) -> Variant:
	return params.get("value")
