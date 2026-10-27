class_name TestingFloorClient
extends Node

signal delivery_finished(response_code: int)

const SDK_VERSION := "0.1.0"
const EVENT_LIMIT := 32768
const BODY_LIMIT := 1040384
const KEYFRAME_SECONDS := 300.0
const MAX_OBJECTS := 512
const MAX_QUEUE := 5000

var context_provider: Callable
var activity_source: Callable
var state_provider: Callable
var transport: Callable
var session_id := ""
var device_id := ""
var user_id := ""
var app_version := ""
var enabled := false
var dropped_events := 0
var min_ping_interval := 0.1
var min_ping_distance := 0.25
var object_min_distance := 0.25
var recording: Dictionary = {}

var _options: Dictionary
var _endpoint := "https://dataentry.testingfloor.com"
var _write_key := ""
var _queue: Array[Dictionary] = []
var _in_flight: Array[Dictionary] = []
var _sequence := 0
var _last_state: Dictionary = {}
var _direct_state: Dictionary = {}
var _state_due := true
var _objects_due := true
var _next_state_poll := 0.0
var _next_object_poll := 0.0
var _next_keyframe := 0.0
var _next_flush := 0.0
var _next_retry := 0.0
var _retry_delay := 1.0
var _http: HTTPRequest
var _objects: Dictionary = {}
var _removals: Array[Dictionary] = []
var _last_activity: Dictionary = {}
var _movement_totals := Vector4.ZERO
var _ping_totals := Vector4.ZERO
var _moving := false
var _movement_started := 0.0
var _last_movement := 0.0
var _last_ping := 0.0
var _recording_closed := false
var _recording_dropped := 0
var _stopping := false
var _registered := false

func _init(options: Dictionary = {}) -> void:
	_options = options.duplicate(true)
	session_id = new_uuid()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings: Dictionary = {}
	var local_path := "res://addons/testing_floor/TestingFloor.local.json"
	if FileAccess.file_exists(local_path):
		var local: Variant = JSON.parse_string(FileAccess.get_file_as_string(local_path))
		if local is Dictionary:
			settings = local
	settings.merge(_options, true)
	_write_key = str(settings.get("write_key", "")).strip_edges()
	var environment_key := OS.get_environment("TESTING_FLOOR_WRITE_KEY")
	if not environment_key.is_empty() and not settings.get("ignore_environment", false):
		_write_key = environment_key.strip_edges()
	_endpoint = str(settings.get("endpoint", _endpoint)).trim_suffix("/")
	app_version = str(settings.get("app_version", ""))
	device_id = str(settings.get("device_id", _device_id()))
	user_id = str(settings.get("user_id", device_id))
	var arguments := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var automation := "--tf-test" in arguments or "--tf-capture-map" in arguments
	var editor_allowed: bool = not OS.has_feature("editor") or settings.get("enable_in_editor", false)
	enabled = settings.get("enabled", true) and editor_allowed and not automation and not _write_key.is_empty()
	if settings.get("test_transport", false) and transport.is_valid():
		enabled = settings.get("enabled", true) and not _write_key.is_empty()
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 10.0
	add_child(_http)
	_http.request_completed.connect(_http_completed)
	recording = _discover_recording(arguments)
	if enabled and not recording.is_empty():
		var directory: String = recording.get("telemetry_directory", "")
		if DirAccess.dir_exists_absolute(directory):
			var registration := FileAccess.open(directory.path_join(session_id + ".session"), FileAccess.WRITE)
			_registered = registration != null
			if registration:
				registration.close()
		if not _registered:
			recording = {}
	_next_keyframe = _now() + KEYFRAME_SECONDS

static func new_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20)]

static func timestamp() -> String:
	var milliseconds := int(Time.get_unix_time_from_system() * 1000.0)
	return Time.get_datetime_string_from_unix_time(milliseconds / 1000) + ".%03dZ" % (milliseconds % 1000)

static func vector_properties(prefix: String, position: Vector3) -> Dictionary:
	return {prefix + ".x": position.x, prefix + ".y": position.y, prefix + ".z": position.z}

func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func _device_id() -> String:
	var path := "user://testing_floor/device-id.txt"
	if FileAccess.file_exists(path):
		var previous := FileAccess.get_file_as_string(path).strip_edges()
		if not previous.is_empty():
			return previous
	DirAccess.make_dir_recursive_absolute("user://testing_floor")
	var id := new_uuid()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(id)
	return id

func _discover_recording(arguments: PackedStringArray) -> Dictionary:
	var candidates: Array[String] = []
	for argument in arguments:
		if argument.begins_with("--testing-floor="):
			candidates.append(argument.trim_prefix("--testing-floor="))
	var sidecar := "user://TestingFloor/recording-payload.json"
	if FileAccess.file_exists(sidecar):
		candidates.append(FileAccess.get_file_as_string(sidecar))
	for candidate in candidates:
		var value: Variant = JSON.parse_string(candidate)
		if not value is Dictionary or str(value.get("recording_uuid", "")).strip_edges().is_empty():
			continue
		var created: float = value.get("created_at_unix_ms", 0.0)
		if created > 0 and created < Time.get_unix_time_from_system() * 1000.0 - 43200000.0:
			continue
		return value
	return {}

func _process(_delta: float) -> void:
	if not enabled:
		return
	var now := _now()
	_check_recording_closed()
	if not _stopping:
		if now >= _next_keyframe:
			_state_due = true
			_objects_due = true
			_next_keyframe = now + KEYFRAME_SECONDS
		_sample_movement(now, _activity())
		if now >= _next_state_poll:
			_poll_state()
			_next_state_poll = now + 1.0
		if now >= _next_object_poll:
			poll_objects()
			_next_object_poll = now + 0.1
	if now >= _next_flush or _queue.size() >= 100 or _stopping:
		flush()

func _activity() -> Dictionary:
	if activity_source.is_valid():
		var sample: Variant = activity_source.call()
		if sample is Dictionary:
			return sample
	return {}

func _context() -> Dictionary:
	if context_provider.is_valid():
		var value: Variant = context_provider.call()
		if value is Dictionary:
			return value.duplicate(true)
	return {}

func _fill_activity(properties: Dictionary, sample: Dictionary) -> void:
	for field in ["player", "camera"]:
		var key: String = field + "_position"
		if sample.get(key) is Vector3 and sample[key].is_finite():
			properties.merge(vector_properties(field + ".position", sample[key]), true)
	if sample.get("camera_rotation") is Quaternion:
		var basis := Basis(sample.camera_rotation)
		properties.merge(vector_properties("camera.forward", -basis.z), true)
		var euler := basis.get_euler() * (180.0 / PI)
		properties.merge(vector_properties("camera.euler", euler), true)
	if sample.has("camera_fov") and is_finite(float(sample.camera_fov)):
		properties["camera.fov"] = sample.camera_fov

func track(event_name: String, properties: Dictionary = {}) -> bool:
	if not enabled or _stopping or event_name.strip_edges().is_empty() or event_name.begins_with("$"):
		return false
	_check_recording_closed()
	_poll_state()
	var values := _context()
	_fill_activity(values, _activity())
	values.merge(properties, true)
	return _enqueue(event_name, values)

func _enqueue(event_name: String, properties: Dictionary, keyframe := false, control := false) -> bool:
	if _queue.size() + _in_flight.size() >= MAX_QUEUE and not control:
		_note_drop()
		return false
	var record := properties.duplicate(true)
	record["$id"] = new_uuid()
	record["$name"] = event_name
	record["$time"] = timestamp()
	record["$schema"] = 2
	record["$session_id"] = session_id
	record["$device_id"] = device_id
	record["$user_id"] = user_id
	var platform := {
		"sdk_version": SDK_VERSION, "engine": "Godot " + str(Engine.get_version_info().string),
		"app_version": app_version, "os": OS.get_name(), "locale": OS.get_locale(),
		"seq": _sequence + 1
	}
	if keyframe:
		platform["keyframe"] = true
	if not recording.is_empty() and (not _recording_closed or control):
		platform["recording_uuid"] = recording.recording_uuid
		if int(recording.get("playtest_id", 0)) > 0:
			platform["playtest_id"] = int(recording.playtest_id)
	var viewport_size := get_viewport().get_visible_rect().size
	platform["screen_width"] = int(viewport_size.x)
	platform["screen_height"] = int(viewport_size.y)
	record["$tf"] = platform
	if JSON.stringify(record).to_utf8_buffer().size() > EVENT_LIMIT:
		_note_drop()
		return false
	_sequence += 1
	_queue.append(record)
	return true

func _note_drop() -> void:
	dropped_events += 1
	if not recording.is_empty() and not _recording_closed:
		_recording_dropped += 1
	_state_due = true
	_objects_due = true

func set_state(key: String, value: Variant) -> void:
	_direct_state[key] = value

func clear_state(key: String) -> void:
	_direct_state.erase(key)

func _scalar(value: Variant) -> bool:
	return value == null or value is String or value is bool or value is int or (value is float and is_finite(value))

func _poll_state() -> void:
	if not enabled:
		return
	var current := _direct_state.duplicate(true)
	current["camera.fov_axis"] = "vertical"
	if state_provider.is_valid():
		var provided: Variant = state_provider.call()
		if provided is Dictionary:
			current.merge(provided, true)
	for key in current.keys():
		if str(key).begins_with("$") or not _scalar(current[key]):
			current.erase(key)
	var changes := current.duplicate(true) if _state_due else {}
	if not _state_due:
		for key in current:
			if not _last_state.has(key) or _last_state[key] != current[key]:
				changes[key] = current[key]
	for key in _last_state:
		if not current.has(key):
			changes[key] = null
	if changes.is_empty() and not _state_due:
		return
	if _enqueue("$tf_state", changes, _state_due):
		_last_state = current
		_state_due = false

func track_node(kind: String, node: Node3D, id := "") -> String:
	if not is_instance_valid(node):
		return ""
	var weak := weakref(node)
	return track_object(kind, func() -> Variant:
		var target: Variant = weak.get_ref()
		return target.global_position if is_instance_valid(target) and target.is_inside_tree() else null,
		id if not id.is_empty() else str(node.get_path()))

func track_object(kind: String, position_source: Callable, id: String) -> String:
	if not enabled or _stopping or not position_source.is_valid() or id.is_empty() or kind.is_empty():
		return ""
	if _objects.has(id):
		return id
	if _objects.size() >= MAX_OBJECTS or _removals.size() >= MAX_QUEUE:
		return ""
	if not _removals.is_empty():
		poll_objects()
	for row in _removals:
		if row.id == id:
			return ""
	var point: Variant = position_source.call()
	_objects[id] = {"kind": kind, "source": position_source, "last": null,
		"known": point if point is Vector3 and point.is_finite() else null,
		"state": {}, "sent_state": {}}
	return id

func set_object_state(id: String, key: String, value: Variant) -> void:
	if _objects.has(id) and _scalar(value):
		_objects[id].state[key] = value

func remove_object(id: String, reason := "removed") -> void:
	if not _objects.has(id):
		return
	var object: Dictionary = _objects[id]
	var final: Variant = object.source.call()
	var samples: Array[Vector3] = []
	if object.last == null and object.known is Vector3:
		samples.append(object.known)
	if final is Vector3 and final.is_finite():
		samples.append(final)
	elif object.known is Vector3 and samples.is_empty():
		samples.append(object.known)
	if not samples.is_empty():
		_removals.append({"id": id, "kind": object.kind, "samples": samples,
			"state": object.state.duplicate(true), "reason": reason})
	_objects.erase(id)

func _append_row(properties: Dictionary, row: Dictionary) -> void:
	for point: Vector3 in row.samples:
		properties["sample.id"].append(row.id)
		properties["sample.kind"].append(row.kind)
		properties["sample.x"].append(snappedf(point.x, 0.01))
		properties["sample.y"].append(snappedf(point.y, 0.01))
		properties["sample.z"].append(snappedf(point.z, 0.01))
	for key in row.state:
		properties["state.id"].append(row.id)
		properties["state.key"].append(key)
		properties["state.value"].append(row.state[key])
	if not str(row.get("reason", "")).is_empty():
		properties["removed.id"].append(row.id)
		properties["removed.reason"].append(row.reason)

func poll_objects() -> void:
	if not enabled:
		return
	var rows: Array[Dictionary] = _removals.duplicate(true)
	var ended: Dictionary = {}
	for row in rows:
		ended[row.id] = true
	for id in _objects.keys():
		if ended.has(id):
			continue
		var object: Dictionary = _objects[id]
		var point: Variant = object.source.call()
		if point == null:
			remove_object(id, "gone")
			continue
		if not point is Vector3 or not point.is_finite():
			continue
		var samples: Array[Vector3] = []
		if object.last == null and object.known is Vector3:
			samples.append(object.known)
		if object.last == null or _objects_due or point.distance_to(object.last) >= object_min_distance:
			samples.append(point)
		var changes: Dictionary = {}
		for key in object.state:
			if _objects_due or not object.sent_state.has(key) or object.sent_state[key] != object.state[key]:
				changes[key] = object.state[key]
		object.known = point
		if not samples.is_empty() or not changes.is_empty():
			rows.append({"id": id, "kind": object.kind, "samples": samples, "state": changes})
	if rows.is_empty():
		return
	var all_written := true
	# Small object groups stay well below the collector's per-record byte limit.
	for start in range(0, rows.size(), 20):
		var properties := {"sample.id": [], "sample.kind": [], "sample.x": [], "sample.y": [], "sample.z": [],
			"state.id": [], "state.key": [], "state.value": [], "removed.id": [], "removed.reason": []}
		var group: Array[Dictionary] = rows.slice(start, mini(start + 20, rows.size()))
		for row in group:
			_append_row(properties, row)
		var context := _context()
		for key in context:
			if str(key).begins_with("game_level."):
				properties[key] = context[key]
		for key in properties.keys():
			if properties[key] is Array and properties[key].is_empty():
				properties.erase(key)
		if not _enqueue("$tf_objects", properties, _objects_due):
			all_written = false
			continue
		for row in group:
			if row.has("reason"):
				_removals.erase(row)
			elif _objects.has(row.id):
				var object: Dictionary = _objects[row.id]
				if not row.samples.is_empty():
					object.last = row.samples.back()
				object.sent_state.merge(row.state, true)
	if all_written:
		_objects_due = false

func reset_movement() -> void:
	_last_activity = {}
	_moving = false
	_movement_totals = Vector4.ZERO
	_ping_totals = Vector4.ZERO

func record_teleport(start: Vector3, finish: Vector3, reason: String) -> void:
	reset_movement()
	var properties := vector_properties("teleport.start.position", start)
	properties.merge(vector_properties("teleport.end.position", finish), true)
	properties.merge({"teleport.kind": "teleport", "teleport.reason": reason,
		"teleport.distance": start.distance_to(finish), "teleport.duration": 0.0}, true)
	track("player_teleported", properties)

func _sample_movement(now: float, sample: Dictionary) -> void:
	if sample.is_empty() or not sample.get("player_position") is Vector3:
		reset_movement()
		return
	if _last_activity.is_empty():
		_last_activity = sample
		_last_ping = now
		return
	var distance: float = sample.player_position.distance_to(_last_activity.get("player_position", sample.player_position))
	var camera_distance := 0.0
	var rotation := 0.0
	var fov := absf(float(sample.get("camera_fov", 0.0)) - float(_last_activity.get("camera_fov", 0.0)))
	if sample.get("camera_position") is Vector3 and _last_activity.get("camera_position") is Vector3:
		camera_distance = sample.camera_position.distance_to(_last_activity.camera_position)
	if sample.get("camera_rotation") is Quaternion and _last_activity.get("camera_rotation") is Quaternion:
		rotation = rad_to_deg(sample.camera_rotation.angle_to(_last_activity.camera_rotation))
	_last_activity = sample
	var step := Vector4(distance if distance >= 0.005 else 0.0, rotation if rotation >= 0.1 else 0.0,
		fov if fov >= 0.05 else 0.0, camera_distance if camera_distance >= 0.005 else 0.0)
	if not step.is_zero_approx():
		_movement_totals += step
		_ping_totals += step
		_last_movement = now
		if not _moving:
			_moving = true
			_movement_started = now
			_last_ping = now
			_emit_movement("start", Vector4.ZERO, 0.0)
	if _moving and now - _last_movement >= 0.25:
		_emit_movement("end", _movement_totals, now - _movement_started)
		_moving = false
		_movement_totals = Vector4.ZERO
		_ping_totals = Vector4.ZERO
	elif _moving and now - _last_ping >= min_ping_interval and (
		_ping_totals.x >= min_ping_distance or _ping_totals.y >= 5.0 or _ping_totals.z >= 2.0 or _ping_totals.w >= 0.5):
		_emit_movement("ping", _ping_totals, now - _last_ping)
		_ping_totals = Vector4.ZERO
		_last_ping = now

func _emit_movement(reason: String, totals: Vector4, duration: float) -> void:
	var properties := {"movement.reason": reason, "movement.duration": maxf(0.0, duration)}
	if totals.x > 0:
		properties["movement.distance"] = totals.x
	if totals.y > 0:
		properties["movement.rotation_degrees"] = totals.y
	if totals.z > 0:
		properties["movement.fov_delta"] = totals.z
	if totals.w > 0:
		properties["movement.camera_distance"] = totals.w
	track("player_moved", properties)

func _check_recording_closed() -> void:
	if not _registered or _recording_closed:
		return
	if not FileAccess.file_exists(str(recording.telemetry_directory).path_join("closed.json")):
		return
	_poll_state()
	poll_objects()
	_enqueue("$tf_telemetry_complete", {"dropped_events": _recording_dropped}, false, true)
	_recording_closed = true
	_next_flush = 0.0

func flush() -> void:
	if not enabled or not _in_flight.is_empty() or _queue.is_empty() or _now() < _next_retry:
		return
	var marker: bool = _queue.front()["$name"] == "$tf_telemetry_complete"
	var bytes := 0
	while not _queue.is_empty() and _in_flight.size() < 100:
		var next: Dictionary = _queue.front()
		if not _in_flight.is_empty() and (marker or next["$name"] == "$tf_telemetry_complete"):
			break
		var size := JSON.stringify(next).to_utf8_buffer().size()
		if bytes + size > BODY_LIMIT and not _in_flight.is_empty():
			break
		bytes += size
		_in_flight.append(_queue.pop_front())
	var payload := JSON.stringify({"$write_key": _write_key, "$sent_at": timestamp(), "events": _in_flight})
	_next_flush = _now() + 2.0
	if transport.is_valid():
		transport.call(payload, _complete_send)
	else:
		var error := _http.request(_endpoint + "/v1/batch", ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)
		if error != OK:
			_complete_send(0, false)

func _http_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_complete_send(response_code, result == HTTPRequest.RESULT_SUCCESS)

func _complete_send(response_code: int, succeeded: bool) -> void:
	if succeeded and response_code >= 200 and response_code < 300:
		_in_flight.clear()
		_retry_delay = 1.0
		_next_retry = 0.0
	else:
		_queue = _in_flight + _queue
		_in_flight.clear()
		_next_retry = _now() + _retry_delay
		_retry_delay = minf(60.0, _retry_delay * 2.0)
		if response_code == 401 or response_code == 403:
			push_warning("Testing Floor rejected the telemetry write key. Check ignored local settings.")
	delivery_finished.emit(response_code)

func pending_count() -> int:
	return _queue.size() + _in_flight.size()

func shutdown(timeout_seconds := 2.0) -> void:
	if not enabled:
		return
	_poll_state()
	poll_objects()
	_stopping = true
	var deadline := _now() + maxf(0.0, timeout_seconds)
	while pending_count() > 0 and _now() < deadline:
		_check_recording_closed()
		flush()
		await get_tree().process_frame
	enabled = false

func quit_after_flush(exit_code := 0) -> void:
	await shutdown()
	get_tree().quit(exit_code)
