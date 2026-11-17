extends RefCounted
## Shared synchronous GDScript preparation for evaluation inside Godot.

const Failure = preload("failure.gd")


class Evaluation extends RefCounted:
	var instance: RefCounted
	var bindings: Dictionary


	func run() -> Variant:
		var result: Variant = instance.call("evaluate", bindings)
		if (
			result is Object and is_instance_valid(result)
			and result.get_class() == "GDScriptFunctionState"
		):
			instance = null

			return Failure.new(
				Failure.INVALID_PARAMS,
				"Evaluator must not await signals or coroutines",
			)

		return result


var bridge: Node


func _init(owner: Node) -> void:
	bridge = owner


func evaluate(params: Dictionary) -> Variant:
	var evaluation: Variant = prepare(params)
	if evaluation is Failure:
		return evaluation

	return evaluation.run()


func prepare(params: Dictionary) -> Variant:
	var source: Variant = params.get("source")
	var bindings: Variant = params.get("bindings", { })
	if not source is String or source.strip_edges().is_empty() or not bindings is Dictionary:
		return bridge.fail(
			Failure.INVALID_PARAMS,
			"Expected GDScript source and an optional bindings dictionary",
		)

	var script := GDScript.new()
	script.source_code = source
	var error := script.reload()
	if error != OK:
		return bridge.fail(
			Failure.INVALID_PARAMS,
			"Cannot compile evaluator: " + error_string(error),
		)

	if not script.can_instantiate():
		return bridge.fail(Failure.INVALID_PARAMS, "Evaluator cannot be instantiated")

	var base := script.get_instance_base_type()
	if base != &"RefCounted" and not ClassDB.is_parent_class(base, &"RefCounted"):
		return bridge.fail(Failure.INVALID_PARAMS, "Evaluator must derive from RefCounted")

	var signature_error: Variant = _check_methods(script)
	if signature_error is Failure:
		return signature_error

	var evaluation := Evaluation.new()
	evaluation.instance = script.new()
	evaluation.bindings = bindings
	if evaluation.instance == null:
		return bridge.fail(Failure.INVALID_PARAMS, "Cannot construct evaluator")

	return evaluation


func _check_methods(script: GDScript) -> Variant:
	var found := false
	var constructor_checked := false

	for method: Dictionary in script.get_script_method_list():
		var args: Array = method.get("args", [])
		if method.name == &"_init" and not constructor_checked:
			constructor_checked = true

			if args.size() > method.get("default_args", []).size():
				return bridge.fail(
					Failure.INVALID_PARAMS,
					"Evaluator constructor must accept no arguments",
				)

		if method.name != &"evaluate" or found:
			continue

		found = true
		if args.size() != 1 or args[0].type not in [TYPE_NIL, TYPE_DICTIONARY]:
			return bridge.fail(
				Failure.INVALID_PARAMS,
				"Expected evaluate(bindings) with one Dictionary or Variant argument",
			)

		if args[0].get("hint", PROPERTY_HINT_NONE) == PROPERTY_HINT_DICTIONARY_TYPE:
			return bridge.fail(
				Failure.INVALID_PARAMS,
				"Evaluator bindings must accept an untyped Dictionary",
			)

	if not found:
		return bridge.fail(Failure.INVALID_PARAMS, "Evaluator must define evaluate(bindings)")

	return null
