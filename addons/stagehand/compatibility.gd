extends RefCounted
## Select runtime implementations once, loading only the selected engine-specific code.


func apply(bridge: Node) -> void:
	var directory: String = get_script().resource_path.get_base_dir()
	var codec: RefCounted = JSON.new()
	if not codec.has_method("from_native"):
		# COMPAT SHIM: Godot 4.3 has no native JSON value conversion.
		codec = load(directory.path_join("compat43_json.gd")).new()

	bridge.native_codec = codec

	# COMPAT SHIM: Godot 4.3 cannot parse the native variadic signal collector.
	var version := Engine.get_version_info()
	var legacy: bool = version.major == 4 and version.minor < 5
	var factory := "compat43_signals.gd" if legacy else "native_signals.gd"
	bridge.signal_factory = load(directory.path_join(factory))
