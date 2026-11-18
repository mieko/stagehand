extends Node
## One bounded, in-memory capture of readings at a shared Godot callback boundary.
## Internal names are interned; protocol dictionaries retain String keys.

const Buffer = preload("property_recording_buffer.gd")
const Reader = preload("property_reader.gd")
const Codec = preload("values.gd")
const Failure = preload("failure.gd")
const ScriptEndpoint = preload("script.gd")

enum State {
	EMPTY,
	RECORDING,
	STOPPED,
}
enum Phase {
	PHYSICS,
	PROCESS,
	SIGNAL,
}
enum StopReason {
	NONE,
	REQUESTED,
	SAMPLE_LIMIT,
	DURATION_LIMIT,
	BYTE_LIMIT,
	SAMPLE_TOO_LARGE,
	SOURCE_FREED,
	TRACK_ERROR,
	VALUE_ERROR,
	ENDPOINT_REMOVED,
}

const STATE_NAMES := ["empty", "recording", "stopped"]
const PHASE_NAMES := ["physics", "process", "signal"]
const STOP_REASON_NAMES := [
	"",
	"requested",
	"sample_limit",
	"duration_limit",
	"byte_limit",
	"sample_too_large",
	"source_freed",
	"track_error",
	"value_error",
	"endpoint_removed",
]

const MAX_TRACKS := 32
const MAX_SAMPLES := 10000
const MAX_BYTES := Buffer.MAX_BYTES
const MAX_SAMPLE_BYTES := Buffer.MAX_SAMPLE_BYTES
const PAGE_SIZE := 32

var _bridge: Node
var _codec: Codec
var _handle := ""
var _tracks: Array[Dictionary] = []
var _buffer: Buffer
var _every_n := 1
var _callbacks := 0
var _taking_sample := false
var _state: State = State.EMPTY
var _phase: Phase = Phase.PHYSICS
var _source: WeakRef
var _signal_name: StringName = &""
var _source_reference := ""
var _sample_limit := 3600
var _duration_usec := 60000000
var _started_usec := 0
var _stopped_usec := 0
var _stop_reason: StopReason = StopReason.NONE
var _error: Dictionary = { }
var _scripts: ScriptEndpoint
var _admitting := false
var _closing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 2147483647
	process_physics_priority = 2147483647
	set_process(false)
	set_physics_process(false)


func install(bridge: Node, scripts: ScriptEndpoint = null) -> void:
	_bridge = bridge
	_scripts = scripts
	_codec = Codec.new(bridge)
	_handle = bridge.register_object(
		self,
		"PropertyRecorder",
		"PropertyRecorder",
		{ "start": start, "stop": stop, "read": read, "discard": discard, "inspect": inspect },
		status,
		["stopped"],
		{ },
		true,
		"1.0.0",
	)


func start(params: Dictionary) -> Variant:
	if _admitting or _closing:
		return _bridge.fail(Failure.INVALID_PARAMS, "Recorder is preparing or closing a capture")

	if _state != State.EMPTY:
		return _bridge.fail(
			Failure.INVALID_PARAMS,
			"Stop and discard the retained capture before starting another",
		)

	_admitting = true
	var result: Variant = _start(params)
	if is_instance_valid(self):
		_admitting = false

	return result


func _start(params: Dictionary) -> Variant:
	var tracks: Variant = _prepare_tracks(params.get("tracks"))
	if not is_instance_valid(self):
		if tracks is Array:
			for track: Dictionary in tracks:
				track.reader.close()

		return Failure.new(Failure.UNKNOWN_HANDLE, "Recorder was freed during admission")

	if tracks is Failure:
		return tracks

	if not is_inside_tree():
		_close_tracks(tracks)
		return _bridge.fail(Failure.UNKNOWN_HANDLE, "Recorder was removed during admission")

	var timing: Variant = _prepare_timing(params)
	if timing is Failure:
		_close_tracks(tracks)
		return timing

	_tracks = tracks
	_phase = timing.phase
	_source = timing.source
	_signal_name = timing.signal_name
	_source_reference = _bridge.reference(_source.get_ref()) if _source != null else ""
	_sample_limit = timing.max_samples
	_duration_usec = int(timing.max_seconds * 1000000)
	_every_n = timing.every_n
	_buffer = Buffer.new(_tracks.size(), _sample_limit)
	_callbacks = 0

	_begin()

	return status()


func _prepare_tracks(specs: Variant) -> Variant:
	if not specs is Array or specs.is_empty() or specs.size() > MAX_TRACKS:
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected 1..32 reading tracks")

	var tracks: Array[Dictionary] = []
	for spec: Variant in specs:
		var track: Variant = _prepare_track(spec, tracks.size())
		if track is Failure:
			_close_tracks(tracks)
			return track

		tracks.append(track)

	for track: Dictionary in tracks:
		if track.target != null and track.target.get_ref() == null:
			_close_tracks(tracks)
			return _bridge.fail(Failure.UNKNOWN_HANDLE, "Track target was freed during admission")

	return tracks


func _prepare_track(spec: Variant, index: int) -> Variant:
	if not spec is Dictionary:
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected a reading specification")

	var reader := Reader.new(_bridge, _scripts)
	var value: Variant = reader.bind(spec)
	if value is Failure:
		reader.close()
		return value

	var label: Variant = spec.get(
		"label",
		str(spec.get("property", spec.get("indexed", spec.get("method", "script")))),
	)
	if not label is String or label.length() > 128:
		reader.close()
		return _bridge.fail(Failure.INVALID_PARAMS, "Track labels must be at most 128 characters")

	var metadata: Dictionary = reader.metadata.duplicate()
	metadata.merge({ "index": index, "label": label, "initial_type": type_string(typeof(value)) })

	return { &"target": reader.target, &"reader": reader, &"metadata": metadata }


func inspect(params: Dictionary) -> Variant:
	var reader := Reader.new(_bridge, _scripts)
	var value: Variant = reader.bind(params)
	reader.close()
	if value is Failure:
		return value

	return { "value": value, "access": reader.metadata }


func _prepare_timing(params: Dictionary) -> Variant:
	var phase_name: Variant = params.get("phase", "physics")
	var count: Variant = params.get("max_samples", 3600)
	var seconds: Variant = params.get("max_seconds", 60)
	var resolution: Variant = params.get("every_n", 1)
	if not (phase_name is String or phase_name is StringName):
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected physics, process or signal phase")

	var phase: int = PHASE_NAMES.find(str(phase_name))
	if phase == -1:
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected physics, process or signal phase")

	if not _integer_in(count, 1, MAX_SAMPLES) or not _number_in(seconds, 0.001, 600):
		return _bridge.fail(
			Failure.INVALID_PARAMS,
			"Expected max_samples 1..10000 and max_seconds 0.001..600",
		)

	if not _integer_in(resolution, 1, 10000):
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected every_n in 1..10000")

	var sampling: Variant = (
		_signal_source(params)
		if phase == Phase.SIGNAL
		else { "source": null, "signal_name": &"" }
	)
	if sampling is Failure:
		return sampling

	return {
		"phase": phase,
		"source": sampling.source,
		"signal_name": sampling.signal_name,
		"max_samples": int(count),
		"every_n": int(resolution),
		"max_seconds": float(seconds),
	}


func _signal_source(params: Dictionary) -> Variant:
	var source: Variant = params.get("source")
	var signal_name: Variant = params.get("signal")
	if (
		not source is Object or not is_instance_valid(source)
		or not (signal_name is String or signal_name is StringName)
	):
		return _bridge.fail(
			Failure.INVALID_PARAMS,
			"Signal sampling needs a live source and signal name",
		)

	var name := StringName(signal_name)
	for entry: Dictionary in source.get_signal_list():
		if entry.name == name and entry.args.is_empty():
			return { "source": weakref(source), "signal_name": name }

	return _bridge.fail(
		Failure.INVALID_PARAMS,
		"Expected an existing zero-argument sampling signal",
	)


func _integer_in(value: Variant, minimum: int, maximum: int) -> bool:
	return _number_in(value, minimum, maximum) and value == floor(value)


func _number_in(value: Variant, minimum: float, maximum: float) -> bool:
	return (
		(value is int or value is float) and is_finite(value)
		and value >= minimum and value <= maximum
	)


func _begin() -> void:
	_state = State.RECORDING
	_started_usec = Time.get_ticks_usec()

	if _source != null:
		_source.get_ref().connect(_signal_name, _capture)

	set_process(true)
	set_physics_process(_phase == Phase.PHYSICS)


func _physics_process(_delta: float) -> void:
	_capture()


func _process(_delta: float) -> void:
	if _stop_if_target_lost():
		return

	if Time.get_ticks_usec() - _started_usec >= _duration_usec:
		_finish(StopReason.DURATION_LIMIT)
	elif _source != null and _source.get_ref() == null:
		_finish(StopReason.SOURCE_FREED)
	elif _phase == Phase.PROCESS:
		_capture()


func _stop_if_target_lost() -> bool:
	for index: int in _tracks.size():
		if _tracks[index].target != null and _tracks[index].target.get_ref() == null:
			_error = { "track": index, "message": "Track target was freed" }
			_finish(StopReason.TRACK_ERROR)
			return true

	return false


func _capture() -> void:
	if _state != State.RECORDING or _taking_sample:
		return

	var callback := _callbacks
	_callbacks += 1
	var elapsed := Time.get_ticks_usec() - _started_usec
	if elapsed >= _duration_usec:
		_finish(StopReason.DURATION_LIMIT)
		return

	if callback % _every_n != 0:
		return

	_taking_sample = true
	_take_sample(elapsed, callback)
	_taking_sample = false


func _take_sample(elapsed: int, callback: int) -> void:
	var buffer := _buffer
	var began := buffer.begin(
		elapsed,
		Engine.get_physics_frames(),
		Engine.get_process_frames(),
		callback,
	)
	if not began or not _fill_columns(buffer) or not buffer.commit():
		buffer.abort()
		if _state == State.RECORDING and _buffer == buffer:
			_finish(_sample_failure())

		return

	if buffer.count >= _sample_limit:
		_finish(StopReason.SAMPLE_LIMIT)


func _fill_columns(buffer: Buffer) -> bool:
	for index: int in _tracks.size():
		var value: Variant = _tracks[index].reader.read()
		if _state != State.RECORDING or _buffer != buffer:
			return false

		if value is Failure:
			_error = { "track": index, "message": value.message }
			return false

		if not buffer.write(index, value):
			_error = { "track": index, "message": buffer.message }
			return false

	return true


func _sample_failure() -> StopReason:
	match _buffer.fault:
		Buffer.Fault.CAPACITY:
			return StopReason.SAMPLE_LIMIT
		Buffer.Fault.SAMPLE_SIZE:
			return StopReason.SAMPLE_TOO_LARGE
		Buffer.Fault.TOTAL_SIZE:
			return StopReason.BYTE_LIMIT
		Buffer.Fault.NATIVE_VALUE:
			return StopReason.VALUE_ERROR

	return StopReason.TRACK_ERROR


func status() -> Dictionary:
	return {
		"state": STATE_NAMES[_state],
		"phase": PHASE_NAMES[_phase],
		"signal": str(_signal_name),
		"source": _source_reference,
		"tracks": _tracks.map(
			func(track: Dictionary) -> Dictionary:
				return track.metadata,
		),
		"count": _buffer.count if _buffer != null else 0,
		"bytes": _buffer.bytes if _buffer != null else 0,
		"byte_accounting": "conservative_wire_bound",
		"every_n": _every_n,
		"callbacks": _callbacks,
		"max_bytes": MAX_BYTES,
		"max_sample_bytes": MAX_SAMPLE_BYTES,
		"page_size": PAGE_SIZE,
		"max_samples": _sample_limit,
		"max_seconds": _duration_usec / 1000000.0,
		"started_usec": _started_usec,
		"stopped_usec": _stopped_usec,
		"stop_reason": STOP_REASON_NAMES[_stop_reason],
		"error": _error,
	}


func stop(_params: Dictionary = { }) -> Dictionary:
	if _state == State.RECORDING:
		_finish(StopReason.REQUESTED)

	return status()


func _finish(reason: StopReason) -> void:
	if _closing:
		return

	_closing = true
	_state = State.STOPPED
	_stop_reason = reason
	_stopped_usec = Time.get_ticks_usec()
	_disconnect_source()
	_close_tracks(_tracks)

	set_process(false)
	set_physics_process(false)

	var stopped := status()
	_closing = false
	_bridge.publish(_handle, "stopped", stopped)


func _close_tracks(tracks: Array) -> void:
	for track: Dictionary in tracks:
		track.reader.close()


func _disconnect_source() -> void:
	if _source != null and _source.get_ref() != null:
		_source.get_ref().disconnect(_signal_name, _capture)

	_source = null


func read(params: Dictionary) -> Variant:
	var offset: Variant = params.get("offset", 0)
	var limit: Variant = params.get("limit", PAGE_SIZE)
	var count: int = _buffer.count if _buffer != null else 0
	if not _integer_in(offset, 0, count) or not _integer_in(limit, 1, PAGE_SIZE):
		return _bridge.fail(Failure.INVALID_PARAMS, "Expected an existing offset and limit 1..32")

	var end := mini(int(offset) + int(limit), count)
	var rows: Array = _buffer.rows(int(offset), end) if _buffer != null else []
	var page: Dictionary = _codec.decode(_codec.encode({ "samples": rows }))

	return {
		"status": status(),
		"offset": int(offset),
		"next_offset": end,
		"samples": page.samples,
	}


func discard(_params: Dictionary = { }) -> Variant:
	if _closing:
		return _bridge.fail(Failure.INVALID_PARAMS, "Capture cleanup is still running")

	if _state == State.RECORDING:
		return _bridge.fail(Failure.INVALID_PARAMS, "Stop recording before discarding its samples")

	_buffer = null
	_callbacks = 0
	_tracks.clear()
	_state = State.EMPTY
	_started_usec = 0
	_stopped_usec = 0
	_stop_reason = StopReason.NONE
	_source_reference = ""
	_error = { }

	return status()


func _exit_tree() -> void:
	if _state == State.RECORDING:
		_finish(StopReason.ENDPOINT_REMOVED)
