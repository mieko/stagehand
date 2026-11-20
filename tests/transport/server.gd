extends "res://addons/stagehand/bridge.gd"


func _ready() -> void:
	app_name = "Greeter Demo"
	register_object(self, "Fixture", "Fixture", { "echo": _echo })

	var game_doc := "res://served/game.md"
	var custom_client := "res://served/client.mjs"
	var result: Error
	if FileAccess.file_exists(custom_client):
		result = serve_client(game_doc, custom_client, "res://served/api.md")
	else:
		result = serve_client(game_doc)

	if result == OK:
		var token := OS.get_environment("STAGEHAND_TOKEN")
		result = start_local() if token.is_empty() else start(token)

	if result != OK:
		push_error(error_string(result))
		get_tree().quit(1)

		return

	print("STAGEHAND_READY ", get_port())


func _echo(params: Dictionary) -> Variant:
	return params.get("value")
