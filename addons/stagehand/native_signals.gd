extends RefCounted


static func create(_target: Object, _event: String, listener: Callable) -> Callable:
	return func(...args):
		listener.call(args)
