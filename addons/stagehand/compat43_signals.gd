extends RefCounted
## COMPAT SHIM: Godot 4.3 cannot parse variadic lambdas.
## Generate a fixed-arity collector from signal metadata, never client source.


static func create(target: Object, event: String, listener: Callable) -> Callable:
	for info: Dictionary in target.get_signal_list():
		if info.name == event:
			return _collector(listener, info.args.size())

	return Callable()


static func _collector(listener: Callable, arity: int) -> Callable:
	var arguments := PackedStringArray()
	var parameters := PackedStringArray()
	for index: int in arity:
		arguments.append("a%d" % index)
		parameters.append("a%d: Variant" % index)
	parameters.append("_keepalive: RefCounted")

	var script := GDScript.new()
	script.source_code = (
		(
			"extends RefCounted\nvar listener: Callable\n"
			+ "func receive(%s) -> void:\n\tlistener.call([%s])\n"
		)
		% [", ".join(parameters), ", ".join(arguments)]
	)
	if script.reload() != OK:
		return Callable()

	var receiver: RefCounted = script.new()
	receiver.set("listener", listener)

	return Callable(receiver, "receive").bind(receiver)
