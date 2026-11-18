extends RefCounted
## One HTTP connection upgraded to a bounded RFC 6455 text-message stream.
## WebSocketPeer expects to read the HTTP upgrade itself. Stagehand reads the request for
## routing and Origin validation, so this peer handles frames on the same TCP connection.

const Http = preload("http.gd")

enum State {
	HANDSHAKE,
	OPEN,
	CLOSING,
	CLOSED,
}
enum Opcode {
	CONTINUATION = 0,
	TEXT = 1,
	BINARY = 2,
	CLOSE = 8,
	PING = 9,
	PONG = 10,
}

const MESSAGE_LIMIT := 8 * 1024 * 1024
const WRITE_QUEUE_LIMIT := 2 * MESSAGE_LIMIT
const WRITE_QUEUE_FRAMES := 512
const IO_PER_POLL := 128 * 1024
const FRAMES_PER_POLL := 64
const OPERATIONS_TIMEOUT_MS := 5000

var state := State.HANDSHAKE
var _tcp: StreamPeerTCP
var _http: Http

var _rx := PackedByteArray()
var _read_at := 0
var _read_deadline: int
var _opcode := -1
var _final := false
var _remaining := 0
var _mask_key := 0
var _mask_shift := 0
var _control := PackedByteArray()
var _fragmented := false
var _message := PackedByteArray()
var _utf8 := Utf8.new()
var _received: Array[PackedByteArray] = []

var _tx: Array[PackedByteArray] = []
var _write_at := 0
var _write_budget := IO_PER_POLL
var _queued_bytes := 0
var _write_deadline := 0
var _close_deadline := 0
var _close_after_write := false


func _init(tcp: StreamPeerTCP, http: Http) -> void:
	_tcp = tcp
	_tcp.set_no_delay(true)
	_http = http
	_read_deadline = Time.get_ticks_msec() + OPERATIONS_TIMEOUT_MS


func poll() -> void:
	_write_budget = IO_PER_POLL
	_tcp.poll()
	var now := Time.get_ticks_msec()
	if (
		_tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED
		or (_read_deadline > 0 and now >= _read_deadline)
		or (_write_deadline > 0 and now >= _write_deadline)
		or (_close_deadline > 0 and now >= _close_deadline)
	):
		abort()
		return

	if not _close_after_write:
		_read(now)

	if state != State.CLOSED:
		flush()

	if _close_after_write and _tx.is_empty():
		abort()


func take_messages() -> Array[PackedByteArray]:
	var messages := _received
	_received = []
	return messages


func send_text(bytes: PackedByteArray) -> Error:
	if state != State.OPEN:
		return ERR_UNAVAILABLE

	if bytes.size() > MESSAGE_LIMIT:
		return ERR_OUT_OF_MEMORY

	var frames := maxi(1, ceili(float(bytes.size()) / IO_PER_POLL))
	if (
		_tx.size() + frames > WRITE_QUEUE_FRAMES
		or _queued_bytes + bytes.size() + 10 * frames > WRITE_QUEUE_LIMIT
	):
		return ERR_OUT_OF_MEMORY

	if bytes.is_empty():
		_queue_frame(Opcode.TEXT, true, bytes)
		return OK

	for offset: int in range(0, bytes.size(), IO_PER_POLL):
		var end := mini(offset + IO_PER_POLL, bytes.size())
		var opcode := Opcode.TEXT if offset == 0 else Opcode.CONTINUATION
		_queue_frame(opcode, end == bytes.size(), bytes.slice(offset, end))

	return OK


func close(code: int, reason: String) -> void:
	if state != State.OPEN:
		if state == State.HANDSHAKE:
			abort()
		return

	_begin_close(PackedByteArray([code >> 8, code & 255]) + reason.to_utf8_buffer())


func abort() -> void:
	if state == State.CLOSED:
		return

	state = State.CLOSED
	_tcp.disconnect_from_host()
	_tx.clear()
	_rx.clear()
	_message.clear()
	_received.clear()


func _read(now: int) -> void:
	var limit := Http.MAX_HEADER_BYTES if state == State.HANDSHAKE else IO_PER_POLL
	var count := mini(_tcp.get_available_bytes(), limit - _rx.size())
	if count > 0:
		var read := _tcp.get_partial_data(count)
		if read[0] != OK:
			abort()
			return

		_rx.append_array(read[1])

	if state == State.HANDSHAKE:
		_handshake()
		return

	for _index: int in FRAMES_PER_POLL:
		if not _read_frame() or _close_after_write or state == State.CLOSED:
			break

	if _read_at > 0:
		_rx = _rx.slice(_read_at)
		_read_at = 0

	if _read_deadline == 0 and (not _rx.is_empty() or _opcode != -1 or _fragmented):
		_read_deadline = now + OPERATIONS_TIMEOUT_MS


func _handshake() -> void:
	var end := _rx.get_string_from_ascii().find("\r\n\r\n")
	if end < 0 and _rx.size() < Http.MAX_HEADER_BYTES:
		return

	var response := (Http.header_too_large()
		if end < 0
		else _http.respond(_rx.slice(0, end)))
	_queue(response.head)
	if not response.body.is_empty():
		_queue(response.body)

	_read_deadline = 0
	if response.upgrade:
		_rx = _rx.slice(end + 4)
		state = State.OPEN
	else:
		state = State.CLOSING
		_close_after_write = true


func _read_frame() -> bool:
	if _opcode == -1 and not _read_header():
		return false

	var count := mini(_remaining, _rx.size() - _read_at)
	if count > 0:
		var payload := _unmask(count)
		if _opcode >= Opcode.CLOSE:
			_control.append_array(payload)
		elif state == State.OPEN:
			if not _utf8.accept(payload):
				return _reject(1007, "Invalid UTF-8")

			_message.append_array(payload)

	if _remaining > 0:
		return false

	_finish_frame()
	_opcode = -1
	return true


func _read_header() -> bool:
	var available := _rx.size() - _read_at
	if available < 2:
		return false

	var flags := _rx[_read_at]
	var opcode := flags & 15
	var final := (flags & 128) != 0
	var size_byte := _rx[_read_at + 1]
	var length := size_byte & 127
	if (flags & 112) != 0 or (size_byte & 128) == 0:
		return _reject(1002, "Invalid frame flags")

	if opcode >= Opcode.CLOSE and (not final or length > 125):
		return _reject(1002, "Invalid control frame")

	var size_bytes := 2 if length == 126 else (8 if length == 127 else 0)
	if available < 6 + size_bytes:
		return false

	if size_bytes > 0:
		if size_bytes == 8 and (_rx[_read_at + 2] & 128) != 0:
			return _reject(1002, "Invalid frame length")

		length = 0
		for offset: int in range(2, 2 + size_bytes):
			length = (length << 8) | _rx[_read_at + offset]
			if length > MESSAGE_LIMIT:
				return _reject(1009, "Message exceeds the 8 MiB limit")

		if length < (126 if size_bytes == 2 else 65536):
			return _reject(1002, "Noncanonical frame length")

	match opcode:
		Opcode.CONTINUATION, Opcode.TEXT, Opcode.BINARY:
			if (opcode == Opcode.CONTINUATION) != _fragmented:
				return _reject(1002, "Unexpected message fragment")

			if opcode == Opcode.BINARY:
				return _reject(1003, "Expected a JSON text message")

			if _message.size() + length > MESSAGE_LIMIT:
				return _reject(1009, "Message exceeds the 8 MiB limit")
		Opcode.CLOSE, Opcode.PING, Opcode.PONG:
			pass
		_:
			return _reject(1002, "Unknown frame opcode")

	_opcode = opcode
	_final = final
	_remaining = length
	_mask_key = _rx.decode_u32(_read_at + 2 + size_bytes)
	_mask_shift = 0
	_read_at += 6 + size_bytes
	return true


func _unmask(count: int) -> PackedByteArray:
	var result := _rx.slice(_read_at, _read_at + count)
	var key := (_mask_key >> _mask_shift) | (_mask_key << (32 - _mask_shift))
	key &= 0xFFFFFFFF

	var complete_words := count & ~3
	for offset: int in range(0, complete_words, 4):
		result.encode_u32(offset, result.decode_u32(offset) ^ key)

	for offset: int in range(complete_words, count):
		result[offset] ^= (key >> ((offset & 3) << 3)) & 255

	_mask_shift = (_mask_shift + count * 8) & 31
	_read_at += count
	_remaining -= count
	return result


func _finish_frame() -> void:
	if _opcode < Opcode.CLOSE:
		_fragmented = not _final
		if _final and state == State.OPEN:
			if _utf8.remaining != 0:
				_reject(1007, "Incomplete UTF-8")
				return

			_received.append(_message)
			_message = PackedByteArray()
			_read_deadline = 0
		return

	match _opcode:
		Opcode.CLOSE:
			_receive_close()
		Opcode.PING:
			if (
				_tx.size() < WRITE_QUEUE_FRAMES
				and _queued_bytes + _control.size() + 2 <= WRITE_QUEUE_LIMIT
			):
				_queue_frame(Opcode.PONG, true, _control)
			else:
				close(1011, "Cannot deliver pong")

	_control = PackedByteArray()
	if not _fragmented:
		_read_deadline = 0


func _receive_close() -> void:
	if _control.size() == 1:
		_reject(1002, "Invalid close frame")
		return

	if _control.size() >= 2:
		var code := (_control[0] << 8) | _control[1]
		if not (
			(code >= 1000 and code <= 1014 and code not in [1004, 1005, 1006])
			or (code >= 3000 and code <= 4999)
		):
			_reject(1002, "Invalid close code")
			return

		var utf8 := Utf8.new()
		if not utf8.accept(_control.slice(2)) or utf8.remaining != 0:
			_reject(1007, "Invalid close reason")
			return

	if state == State.OPEN:
		_begin_close(_control)

	_close_after_write = true


func _reject(code: int, reason: String) -> bool:
	close(code, reason)
	_close_after_write = true
	_read_deadline = 0
	return false


func _begin_close(payload: PackedByteArray) -> void:
	# Keep any frame already partially written on the wire. Drop untouched frames.
	if _write_at > 0:
		_tx.resize(1)
		_queued_bytes = _tx[0].size() - _write_at
	else:
		_tx.clear()
		_queued_bytes = 0

	_queue_frame(Opcode.CLOSE, true, payload)
	state = State.CLOSING
	_close_deadline = Time.get_ticks_msec() + OPERATIONS_TIMEOUT_MS


func _queue_frame(opcode: int, final: bool, payload: PackedByteArray) -> void:
	var size := payload.size()
	var header := PackedByteArray([(128 if final else 0) | opcode])
	if size >= 65536:
		header.append_array(
			PackedByteArray(
				[127, 0, 0, 0, 0, size >> 24, (size >> 16) & 255, (size >> 8) & 255, size & 255]
			)
		)
	elif size >= 126:
		header.append_array(PackedByteArray([126, size >> 8, size & 255]))
	else:
		header.append(size)

	_queue(header + payload)


func _queue(bytes: PackedByteArray) -> void:
	if _tx.is_empty():
		_write_deadline = Time.get_ticks_msec() + OPERATIONS_TIMEOUT_MS

	_tx.append(bytes)
	_queued_bytes += bytes.size()


func flush() -> void:
	var starting_budget := _write_budget
	for _index: int in FRAMES_PER_POLL:
		if _write_budget == 0 or _tx.is_empty():
			break

		var bytes := _tx[0]
		var end := mini(_write_at + _write_budget, bytes.size())
		var written := _tcp.put_partial_data(bytes.slice(_write_at, end))
		if written[0] != OK:
			abort()
			return

		var count: int = written[1]
		_write_at += count
		_queued_bytes -= count
		_write_budget -= count
		if _write_at == bytes.size():
			_tx.pop_front()
			_write_at = 0
		else:
			break

	if _tx.is_empty():
		_write_deadline = 0
	elif _write_budget < starting_budget:
		_write_deadline = Time.get_ticks_msec() + OPERATIONS_TIMEOUT_MS


class Utf8:
	var remaining := 0
	var minimum := 0x80
	var maximum := 0xBF


	func accept(bytes: PackedByteArray) -> bool:
		var offset := 0
		while offset < bytes.size():
			if (
				remaining == 0 and offset + 4 <= bytes.size()
				and (bytes.decode_u32(offset) & 0x80808080) == 0
			):
				offset += 4
				continue

			var byte := bytes[offset]
			offset += 1
			if remaining > 0:
				if byte < minimum or byte > maximum:
					return false

				remaining -= 1
				minimum = 0x80
				maximum = 0xBF
			elif byte >= 0xF0 and byte <= 0xF4:
				remaining = 3
				minimum = 0x90 if byte == 0xF0 else 0x80
				maximum = 0x8F if byte == 0xF4 else 0xBF
			elif byte >= 0xE0 and byte <= 0xEF:
				remaining = 2
				minimum = 0xA0 if byte == 0xE0 else 0x80
				maximum = 0x9F if byte == 0xED else 0xBF
			elif byte >= 0xC2 and byte <= 0xDF:
				remaining = 1
			elif byte > 0x7F:
				return false

		return true
