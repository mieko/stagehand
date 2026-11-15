extends RefCounted

var code: int
var message: String


func _init(value: int, description: String) -> void:
	code = value
	message = description
