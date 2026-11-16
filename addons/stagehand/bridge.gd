extends Node
## Explicitly started Stagehand connection; no editor or debugger is required.

signal connection_closed(peer: WebSocketPeer)

const PROTOCOL_VERSION := 1
const MAX_PACKETS_PER_FRAME := 64
const MAX_MESSAGE_BYTES := 8 * 1024 * 1024
const MAX_PEERS := 8
const Values = preload("values.gd")
const Failure = preload("failure.gd")
const Builtins = preload("builtins.gd")
const InputEndpoint = preload("input.gd")

var _server := TCPServer.new()
var _rpc := JSONRPC.new()
var _peers: Dictionary = { }
var _objects: Dictionary = { }
var _next_object := 0
var _next_subscription := 0
var _token := ""
var _instance := ""
var _values: RefCounted
var _builtins: RefCounted
var _request_peer: WebSocketPeer
var _scene_id := 0
var _world_generation := 0
var _registry_handle := ""


func _init() -> void:
	_values = Values.new(self)
	_instance = Crypto.new().generate_random_bytes(16).hex_encode()
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

	_registry_handle = register_object(
		self,
		"Registry",
		"Registry",
		{ "list": _list_objects },
		_list_objects,
		[],
		{ },
		true,
		"1.0.0",
	)


func start(token: String, port: int = 0, bind_address: String = "127.0.0.1") -> Error:
	if token.is_empty() or _server.is_listening():
		return ERR_INVALID_PARAMETER

	var result := _server.listen(port, bind_address)
	if result != OK:
		return result

	_token = token
	set_process(true)

	return OK


func get_port() -> int:
	return _server.get_local_port()


func enable_builtins(
	names: PackedStringArray = ["Runtime", "SceneTree", "Object", "Screen", "Input"]
) -> void:
	if _builtins != null:
		return

	_builtins = Builtins.new(self)
	_builtins.install(names)

	if "Input" in names:
		var endpoint := InputEndpoint.new(self)
		endpoint.name = "InputEndpoint"
		add_child(endpoint)


func stop() -> void:
	for peer: WebSocketPeer in _peers.keys():
		connection_closed.emit(peer)
		peer.close(1001, "Stagehand connection stopped")

	_peers.clear()
	_prune_signals()

	_server.stop()
	set_process(false)


func _exit_tree() -> void:
	stop()
	_rpc.free()


## Operation callbacks receive one Dictionary and return a value or Failure.
func register_object(
	target: Object,
	label: String,
	kind: String,
	operations: Dictionary = { },
	observer: Callable = Callable(),
	events: PackedStringArray = [],
	operation_info: Dictionary = { },
	registered: bool = true,
	version: String = "",
) -> String:
	_next_object += 1
	var handle := "%s:%d" % [_instance, _next_object]
	_objects[handle] = {
		"target": weakref(target),
		"label": label,
		"kind": kind,
		"operations": operations,
		"observer": observer,
		"events": events,
		"registered": registered,
		"operation_info": operation_info,
		"version": version,
		"native_signals": { },
	}

	if target is Node and not target.tree_exiting.is_connected(_unregister_target):
		target.tree_exiting.connect(_unregister_target.bind(target), CONNECT_ONE_SHOT)

	if registered:
		_broadcast("objects.added", _describe(handle))

	return handle


func fail(code: int, message: String) -> Failure:
	return Failure.new(code, message)


func request_peer() -> WebSocketPeer:
	return _request_peer


func reference(target: Object) -> String:
	var fallback := ""
	for handle: String in _objects:
		if _objects[handle].target.get_ref() == target:
			if _objects[handle].registered:
				return handle

			fallback = handle

	if not fallback.is_empty():
		return fallback

	return register_object(target, target.get_class(), "object", { }, Callable(), [], { }, false)


func reference_type(handle: String) -> String:
	return _objects[handle].kind


func resolve_object(handle: Variant) -> Variant:
	if not handle is String or not _objects.has(handle):
		return fail(-32004, "Unknown or expired object")

	var target: Object = _objects[handle].target.get_ref()

	return target if is_instance_valid(target) else fail(-32004, "Unknown or expired object")


func unregister_object(handle: String) -> void:
	if handle == _registry_handle:
		return

	if _objects.has(handle):
		_disconnect_signals(_objects[handle])

	if not _objects.erase(handle):
		return

	for state: Dictionary in _peers.values():
		for subscription: String in state.subscriptions.keys():
			if state.subscriptions[subscription].object == handle:
				state.subscriptions.erase(subscription)

	_broadcast("objects.removed", { "object": handle })


func _unregister_target(target: Object) -> void:
	for handle: String in _objects.keys():
		if _objects[handle].target.get_ref() == target:
			unregister_object(handle)


func _disconnect_signals(entry: Dictionary) -> void:
	var target: Object = entry.target.get_ref()
	if is_instance_valid(target):
		for event: String in entry.native_signals:
			var callback: Callable = entry.native_signals[event]
			if target.is_connected(event, callback):
				target.disconnect(event, callback)

	entry.native_signals.clear()


func _prune_signals() -> void:
	for handle: String in _objects:
		var entry: Dictionary = _objects[handle]
		for event: String in entry.native_signals.keys():
			var used := false
			for state: Dictionary in _peers.values():
				for subscription: Dictionary in state.subscriptions.values():
					if subscription.object == handle and subscription.event == event:
						used = true

			if not used:
				var target: Object = entry.target.get_ref()
				if (
					is_instance_valid(target)
					and target.is_connected(event, entry.native_signals[event])
				):
					target.disconnect(event, entry.native_signals[event])
				entry.native_signals.erase(event)


func _listen_signal(handle: String, event: String) -> Variant:
	var entry: Dictionary = _objects[handle]
	if event in entry.events or entry.native_signals.has(event):
		return null

	var target: Object = entry.target.get_ref()
	if not target.has_signal(event):
		return fail(-32602, "Unknown registered event or signal")

	var callback := func(...args):
		publish(handle, event, args)

	if target.connect(event, callback) != OK:
		return fail(-32010, "Cannot subscribe to signal")

	entry.native_signals[event] = callback

	return null


func publish(handle: String, event: String, value: Variant) -> void:
	if (
		not _objects.has(handle)
		or (event not in _objects[handle].events and not _objects[handle].native_signals.has(event))
	):
		return

	for peer: WebSocketPeer in _peers:
		var state: Dictionary = _peers[peer]
		for subscription: String in state.subscriptions:
			var entry: Dictionary = state.subscriptions[subscription]
			if entry.object == handle and entry.event == event:
				_notify(
					peer,
					"object.event",
					{
						"subscription": subscription,
						"object": handle,
						"event": event,
						"value": value,
						"clock": _clock(),
					},
				)


func _clock() -> Dictionary:
	var scene := get_tree().current_scene
	var scene_id: int = scene.get_instance_id() if scene != null else 0

	if scene_id != _scene_id:
		_scene_id = scene_id
		_world_generation += 1

	return {
		"instance": _instance,
		"world_generation": _world_generation,
		"physics_tick": Engine.get_physics_frames(),
		"process_frame": Engine.get_process_frames(),
		"render_frame": Engine.get_frames_drawn(),
		"phase": "physics" if Engine.is_in_physics_frame() else "process",
		"monotonic_us": str(Time.get_ticks_usec()),
	}


func _process(_delta: float) -> void:
	if _server.is_connection_available():
		var peer := WebSocketPeer.new()
		peer.inbound_buffer_size = MAX_MESSAGE_BYTES
		peer.outbound_buffer_size = MAX_MESSAGE_BYTES
		var connection := _server.take_connection()
		if _peers.size() >= MAX_PEERS:
			connection.disconnect_from_host()
		elif peer.accept_stream(connection) == OK:
			_peers[peer] = {
				"authenticated": false,
				"subscriptions": { },
				"connected_ms": Time.get_ticks_msec(),
			}

	for peer: WebSocketPeer in _peers.keys():
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			connection_closed.emit(peer)
			_peers.erase(peer)
			_prune_signals()
			continue

		if (
			not _peers[peer].authenticated
			and Time.get_ticks_msec() - _peers[peer].connected_ms > 5000
		):
			peer.close(1008, "Authentication deadline")

		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue

		for packet: int in mini(peer.get_available_packet_count(), MAX_PACKETS_PER_FRAME):
			var bytes := peer.get_packet()
			if not peer.was_string_packet() or bytes.size() > MAX_MESSAGE_BYTES:
				peer.close(1009, "Expected a bounded JSON text message")
				break

			var parser := JSON.new()
			if parser.parse(bytes.get_string_from_utf8()) != OK:
				_send(peer, _rpc.make_response_error(JSONRPC.PARSE_ERROR, "Invalid JSON"))
			else:
				var response: Variant = _request(peer, parser.data)
				if response != null:
					_send(peer, response)

	for handle: String in _objects.keys():
		if _objects[handle].target.get_ref() == null:
			unregister_object(handle)


func _request(peer: WebSocketPeer, request: Variant) -> Variant:
	if request is Array:
		if request.is_empty() or request.size() > 64:
			return _rpc.make_response_error(
				JSONRPC.INVALID_REQUEST,
				"Batch must contain 1..64 requests",
			)

		var responses: Array = []
		for item: Variant in request:
			var response: Variant = (
				_rpc.make_response_error(JSONRPC.INVALID_REQUEST, "Nested batch")
				if item is Array
				else _request(peer, item)
			)
			if response != null:
				responses.append(response)

		return responses if not responses.is_empty() else null

	if (
		not request is Dictionary or request.get("jsonrpc") != "2.0"
		or not request.get("method") is String
	):
		return _rpc.make_response_error(JSONRPC.INVALID_REQUEST, "Expected a JSON-RPC 2.0 request")

	var id: Variant = request.get("id")
	if (
		request.has("id")
		and not (
			id == null or id is String
			or (id is float and is_finite(id) and id == floor(id)) or id is int
		)
	):
		return _rpc.make_response_error(JSONRPC.INVALID_REQUEST, "Invalid request ID")

	var result: Variant
	if not request.get("params", { }) is Dictionary:
		result = Failure.new(JSONRPC.INVALID_PARAMS, "This API uses named Dictionary parameters")
	else:
		var params: Variant = _values.decode(request.get("params", { }))
		if params is Failure:
			result = params
		elif not params is Dictionary:
			result = fail(JSONRPC.INVALID_PARAMS, "Expected named parameters")
		else:
			result = _dispatch(peer, request.method, params)

	if not request.has("id"):
		return null

	if result is Failure:
		return _rpc.make_response_error(result.code, result.message, id)

	var encoded: Variant = _values.encode(result)
	if encoded is Failure:
		return _rpc.make_response_error(encoded.code, encoded.message, id)

	return _rpc.make_response(encoded, id)


func _dispatch(peer: WebSocketPeer, method: String, params: Dictionary) -> Variant:
	var state: Dictionary = _peers[peer]
	if method == "session.hello":
		if params.get("token") != _token:
			return Failure.new(-32001, "Authentication failed")

		if params.get("protocol", 1) != PROTOCOL_VERSION:
			return fail(-32002, "Unsupported protocol version")

		state.authenticated = true

		return {
			"protocol": PROTOCOL_VERSION,
			"instance": _instance,
			"engine": Engine.get_version_info(),
			"clock": _clock(),
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"objects": _dispatch(peer, "objects.list", { }),
		}
	if not state.authenticated:
		return Failure.new(-32001, "Authenticate with session.hello first")

	if method == "objects.list":
		return _list_objects()

	if method == "object.unsubscribe":
		var removed: bool = state.subscriptions.erase(params.get("subscription", ""))
		_prune_signals()

		return removed

	if method not in ["object.describe", "object.observe", "object.call", "object.subscribe"]:
		return Failure.new(JSONRPC.METHOD_NOT_FOUND, "Unknown method: " + method)

	var handle: Variant = params.get("object")
	if not handle is String or not _objects.has(handle) or _objects[handle].target.get_ref() == null:
		return Failure.new(-32004, "Unknown or expired object")

	var entry: Dictionary = _objects[handle]
	match method:
		"object.describe":
			return _describe(handle)
		"object.observe":
			var value: Variant = entry.observer.call() if entry.observer.is_valid() else null
			if value is Failure:
				return value

			return { "object": handle, "value": value, "clock": _clock() }
		"object.call":
			var operation: Variant = params.get("method")
			if not operation is String or not entry.operations.has(operation):
				return Failure.new(JSONRPC.METHOD_NOT_FOUND, "Unknown registered operation")

			if not params.get("params", { }) is Dictionary:
				return Failure.new(
					JSONRPC.INVALID_PARAMS,
					"Operation parameters must be a Dictionary",
				)

			_request_peer = peer
			var result: Variant = entry.operations[operation].call(params.get("params", { }))
			_request_peer = null

			return result
		"object.subscribe":
			if state.subscriptions.size() >= 128:
				return fail(-32010, "Subscription limit reached")

			if not params.get("event") is String:
				return fail(-32602, "Expected event name")

			var error: Variant = _listen_signal(handle, params.event)
			if error is Failure:
				return error

			_next_subscription += 1
			var subscription := str(_next_subscription)
			state.subscriptions[subscription] = { "object": handle, "event": params.event }

			return subscription

	return Failure.new(JSONRPC.INTERNAL_ERROR, "Dispatch failed")


func _list_objects(_params: Dictionary = { }) -> Array[Dictionary]:
	var objects: Array[Dictionary] = []
	for handle: String in _objects:
		if _objects[handle].target.get_ref() != null and _objects[handle].registered:
			objects.append(_describe(handle))

	return objects


func _describe(handle: String) -> Dictionary:
	var entry: Dictionary = _objects[handle]

	var description := {
		"id": handle,
		"label": entry.label,
		"kind": entry.kind,
		"operations": entry.operations.keys(),
		"operation_info": entry.operation_info,
		"events": entry.events,
	}
	if not entry.version.is_empty():
		description["version"] = entry.version

	return description


func _send(peer: WebSocketPeer, value: Variant) -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	var message := JSON.stringify(value)
	if message.to_utf8_buffer().size() > MAX_MESSAGE_BYTES or peer.send_text(message) != OK:
		peer.close(1011, "Cannot deliver response")


func _notify(peer: WebSocketPeer, method: String, params: Dictionary) -> void:
	var encoded: Variant = _values.encode(params)
	if encoded is Failure:
		_send(
			peer,
			_rpc.make_notification(
				"stream.error",
				{
					"method": method,
					"subscription": params.get("subscription"),
					"object": params.get("object"),
					"code": encoded.code,
					"message": encoded.message,
				},
			),
		)
	else:
		_send(peer, _rpc.make_notification(method, encoded))


func _broadcast(method: String, params: Dictionary) -> void:
	for peer: WebSocketPeer in _peers:
		if _peers[peer].authenticated:
			_notify(peer, method, params)
