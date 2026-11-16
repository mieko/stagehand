extends RefCounted

var factor: int


func _init(multiplier: int) -> void:
	factor = multiplier


func evaluate(bindings: Dictionary) -> Variant:
	return bindings.value * factor
