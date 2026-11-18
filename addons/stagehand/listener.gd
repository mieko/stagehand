extends RefCounted
## One TCP listener, or both available loopback families sharing one port.

var _servers: Array[TCPServer] = []


func listen(port: int, address: String) -> Error:
	if is_listening():
		return ERR_ALREADY_IN_USE

	var addresses: Array[String] = [address]
	if address == "localhost":
		addresses = _loopbacks()
		if addresses.is_empty():
			return ERR_CANT_CREATE

	for host: String in addresses:
		var server := TCPServer.new()
		var result := server.listen(port, host)
		if result != OK:
			stop()
			return result

		_servers.append(server)
		port = server.get_local_port()

	return OK


func _loopbacks() -> Array[String]:
	var addresses: Array[String] = []
	for host: String in ["127.0.0.1", "::1"]:
		var probe := TCPServer.new()
		if probe.listen(0, host) == OK:
			addresses.append(host)
			probe.stop()

	return addresses


func is_listening() -> bool:
	return not _servers.is_empty()


func get_local_port() -> int:
	return _servers[0].get_local_port() if is_listening() else 0


func take_connection() -> StreamPeerTCP:
	for server: TCPServer in _servers:
		if server.is_connection_available():
			return server.take_connection()

	return null


func stop() -> void:
	for server: TCPServer in _servers:
		server.stop()

	_servers.clear()
