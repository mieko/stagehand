extends RefCounted
## HTTP/1.1 admission and the fixed Stagehand discovery routes.
## WebSocketPeer reads the upgrade request internally. Its API exposes no incoming Origin.
## Reading the request here lets one listener check Origin and serve the client and docs.

const MAX_HEADER_BYTES := 8192
const MARKDOWN_MIME := "text/markdown; charset=utf-8"
const WEBSOCKET_ACCEPT_SUFFIX := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

static var _field_name := RegEx.create_from_string("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
static var _websocket_key := RegEx.create_from_string("^[A-Za-z0-9+/]{21}[AQgw]==$")

var _routes: Dictionary
var _allowed_hosts := PackedStringArray()


func _init(assets: Dictionary, port: int, bind_address: String, app_name: String) -> void:
	_routes = assets.duplicate()
	_routes["/"] = { "mime": MARKDOWN_MIME, "bytes": _discovery(app_name, assets).to_utf8_buffer() }

	if bind_address in ["localhost", "::1"] or bind_address.begins_with("127."):
		_allowed_hosts = _loopback_hosts(bind_address, port)


func respond(head: PackedByteArray) -> Dictionary:
	for byte: int in head:
		if (byte < 32 and byte != 9 and byte != 10 and byte != 13) or byte > 126:
			return _response("400 Bad Request")

	var lines := head.get_string_from_ascii().split("\r\n")
	var request := lines[0].split(" ")
	if request.size() != 3 or request[2] != "HTTP/1.1" or not request[1].begins_with("/"):
		return _response("400 Bad Request")

	var headers := _headers(lines)
	var host: String = headers.get("host", "")
	if host.is_empty():
		return _response("400 Bad Request")

	if not _allowed_hosts.is_empty() and host.to_lower() not in _allowed_hosts:
		return _response("403 Forbidden")

	if headers.has("transfer-encoding") or headers.get("content-length", "0") != "0":
		return _response("400 Bad Request")

	var method := request[0]
	var target := request[1]
	if method != "GET" and method != "HEAD":
		return _response(
			"405 Method Not Allowed",
			"",
			PackedByteArray(),
			false,
			"Allow: GET, HEAD\r\n",
		)

	if target == "/rpc":
		if method != "GET":
			return _response(
				"405 Method Not Allowed",
				"",
				PackedByteArray(),
				true,
				"Allow: GET\r\n",
			)

		return _upgrade(headers)

	if _routes.has(target):
		var asset: Dictionary = _routes[target]
		return _response("200 OK", asset.mime, asset.bytes, method == "HEAD")

	return _response("404 Not Found")


static func _discovery(app_name: String, assets: Dictionary) -> String:
	var display_name := app_name.strip_edges().xml_escape()
	var subject := "this game" if display_name.is_empty() else display_name

	var markdown := "# Stagehand\n\n"
	markdown += "Stagehand lets external tools inspect and control " + subject
	markdown += " through a JavaScript API.\n\n"

	if not assets.is_empty():
		markdown += "This server provides the client and documentation "
		markdown += "matching the installed integration:\n\n"
		markdown += "- [JavaScript client](./client.mjs)\n"
		markdown += "- [Stagehand API](./api.md)\n"
		if assets.has("/game.md"):
			var label := "Game API" if display_name.is_empty() else display_name + " API"
			label = label.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
			markdown += "- [%s](./game.md)\n" % label

		markdown += "\n"

	markdown += "Stagehand clients connect using this server’s HTTP or HTTPS base address. "
	markdown += "RPC communication\nuses WebSocket at `/rpc`.\n"

	return markdown


static func header_too_large() -> Dictionary:
	return _response("431 Request Header Fields Too Large")


static func _headers(lines: PackedStringArray) -> Dictionary:
	var headers: Dictionary = { }
	for index: int in range(1, lines.size()):
		var line := lines[index]
		var colon := line.find(":")
		if colon < 1:
			return { }

		var name := line.left(colon).to_lower()
		var value := line.substr(colon + 1)
		if _field_name.search(name) == null or "\r" in value or "\n" in value:
			return { }

		if headers.has(name) and name not in ["connection", "upgrade"]:
			return { }

		value = value.strip_edges()
		headers[name] = headers[name] + "," + value if headers.has(name) else value

	return headers


static func _loopback_hosts(bind_address: String, port: int) -> PackedStringArray:
	var hosts := PackedStringArray(["localhost", "127.0.0.1", "[::1]"])
	if bind_address.begins_with("127.") and bind_address != "127.0.0.1":
		hosts.append(bind_address)

	var explicit_port := PackedStringArray()
	for host: String in hosts:
		explicit_port.append("%s:%d" % [host, port])

	return hosts + explicit_port if port == 80 else explicit_port


static func _upgrade(headers: Dictionary) -> Dictionary:
	if headers.has("origin"):
		return _response("403 Forbidden")

	if (
		not _has_token(headers.get("connection", ""), "upgrade")
		or not _has_token(headers.get("upgrade", ""), "websocket")
	):
		return _response("400 Bad Request")

	if headers.get("sec-websocket-version") != "13":
		return _response(
			"426 Upgrade Required",
			"",
			PackedByteArray(),
			false,
			"Sec-WebSocket-Version: 13\r\n",
		)

	var key: String = headers.get("sec-websocket-key", "")
	if _websocket_key.search(key) == null:
		return _response("400 Bad Request")

	var accept := Marshalls.raw_to_base64((key + WEBSOCKET_ACCEPT_SUFFIX).sha1_buffer())
	var head := "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
	head += "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	return { "upgrade": true, "head": head.to_ascii_buffer(), "body": PackedByteArray() }


static func _has_token(value: String, expected: String) -> bool:
	for token: String in value.to_lower().split(","):
		if token.strip_edges() == expected:
			return true

	return false


static func _response(
	status: String,
	mime := "",
	body := PackedByteArray(),
	head_only := false,
	extra := "",
) -> Dictionary:
	var head := "HTTP/1.1 %s\r\nConnection: close\r\nContent-Length: %d\r\n" % [status, body.size()]
	head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
	if not mime.is_empty():
		head += "Content-Type: %s\r\n" % mime

	head += extra + "\r\n"
	return {
		"upgrade": false,
		"head": head.to_ascii_buffer(),
		"body": PackedByteArray() if head_only else body,
	}
