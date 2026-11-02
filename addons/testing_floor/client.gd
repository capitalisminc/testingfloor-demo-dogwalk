class_name TestingFloorClient
extends Node
## Testing Floor's Godot client: gameplay events, session state, tracked objects,
## movement and recording delivery, following the shared SDK contract.
##
## The [code]TestingFloor[/code] autoload is one of these, configured from project
## settings and the engine. Tests create their own and replace the clock, the
## transport and the recording source. Call [method start] once after setting
## the configuration, then [method tick] every frame with unscaled real time.

## The attached recording changed: a recording started, was suspended, resumed,
## replaced or closed. The argument is empty when no recording is attached.
signal recording_changed(recording: Dictionary)

const SDK_VERSION := "0.2.0"
const COMPLETION_RECORD := "$tf_telemetry_complete"
const STATE_RECORD := "$tf_state"
const OBJECTS_RECORD := "$tf_objects"
const SCHEMA := 2
const EVENT_BYTES := 32768
## Below the collector's 1 MiB request limit, with room for the envelope.
const REQUEST_BYTES := 1048576 - 8192
const OBJECT_SAMPLES_PER_RECORD := 300
const OBJECT_RECORD_BYTES := 20480
const KEYFRAME_SECONDS := 300.0
const STATE_POLL_SECONDS := 1.0
const RECORDING_POLL_MS := 250
const STATUS_CAPABILITIES := ["recording_lease_v1", "dynamic_recording_attachment"]

enum DeliveryState { DISABLED, NOT_CONFIGURED, OK, NETWORK_DOWN, REJECTED }

# Configuration. Set before start().
var write_key := ""
var endpoint := "https://dataentry.testingfloor.com"
var enabled := true
## Collect during ordinary Play in the editor, without a recording.
var enable_in_editor := false
## Collect in the editor while the desktop app records it.
var enable_in_editor_while_recording := true
var batch_max_events := 50
var flush_interval_seconds := 0.25
var queue_max_events := 4096
var max_tracked_objects := 256
var object_checks_per_second := 4.0
var object_min_distance := 0.25
var movement_tracking := false
var movement_min_ping_distance := 0.5
var movement_min_ping_interval := 0.5
var movement_start_grace := 0.05
var movement_stop_grace := 0.25
var movement_min_step := 0.005
var movement_min_ping_rotation := 5.0
var movement_min_step_rotation := 0.1
var movement_min_ping_fov := 2.0
var movement_min_step_fov := 0.05
var movement_min_ping_camera_distance := 0.5
var movement_min_step_camera_distance := 0.005
var movement_min_ping_ortho_width := 0.5
var movement_min_step_ortho_width := 0.005

# Record context. The autoload fills these from the engine; unset values are left out.
var app_version := ""
var engine_name := ""
var os_name := ""
var locale := ""
var device_model := ""
var screen_size := Vector2i.ZERO
var device_id := ""
var user_id := ""

# Seams. The autoload sets engine-backed ones; tests replace them.
var is_editor := false
var is_automation := false
## Wall-clock Unix time in milliseconds.
var clock_ms: Callable = func() -> int: return int(Time.get_unix_time_from_system() * 1000.0)
## func(body: String, done: Callable) sends one request and calls done(http_status) once, 0 for a network failure.
var transport: Callable
## func(now_ms: int) -> Dictionary returns the current handoff, as TestingFloorRecording.resolve does.
var recording_source: Callable

# Game hooks.
## func() -> Dictionary of small values added to every event, such as the level and health.
var context_provider: Callable
## func() -> Dictionary of values that stay true until they change. Sent as session state.
var state_provider: Callable
## func() -> Dictionary with any of player_position, camera_position, camera_rotation,
## camera_fov, camera_ortho_width, camera_focus and viewport_size.
var activity_source: Callable
## func(properties: Dictionary) runs last over each event's merged properties and may change them.
var event_processor: Callable

var play_session_id := ""
var dropped_events := 0
var delivery_state: DeliveryState = DeliveryState.DISABLED

var _started := false
var _shutdown := false
var _seconds := 0.0
var _seq := 0
var _queue: Array[Dictionary] = []
var _in_flight: Array[Dictionary] = []
var _request_open := false
var _request := 0
var _flush_requested := false
var _last_flush := 0.0
var _next_retry := 0.0
var _retry_delay := 1.0
var _warned := {}

var _recording := {}
var _exposed := {}
var _admitted := false
var _closed := false
var _suspended := false
var _interrupted := false
var _completed := {}
var _recording_drops := {}
var _next_recording_poll := 0
var _refreshing := false

var _direct_state := {}
var _sent_state := {}
var _state_keyframe_due := true
var _state_keyframe_at := 0.0
var _next_state_poll := 0.0
var _last_level := {}

var _objects := {}
var _removals: Array[Dictionary] = []
var _kind_counts := {}
var _objects_keyframe_due := true
var _objects_keyframe_at := 0.0
var _next_object_check := -1.0
var _last_object_time := 0

var _movement_baseline := {}
var _moving := false
var _movement_started := 0.0
var _last_movement := 0.0
var _last_ping := 0.0
var _segment := {}
var _run := {}
var _teleports := {}
var _next_teleport := 0


#region Lifecycle

## Starts the play session: resolves the recording and begins accepting events.
func start(now_seconds := 0.0) -> void:
	if _started:
		return
	if play_session_id.is_empty():
		play_session_id = new_uuid()
	_seconds = now_seconds
	_last_flush = now_seconds
	_state_keyframe_at = now_seconds
	_objects_keyframe_at = now_seconds
	if not enabled or is_automation:
		delivery_state = DeliveryState.DISABLED
	elif write_key.strip_edges().is_empty() or endpoint.strip_edges().is_empty() or not transport.is_valid():
		delivery_state = DeliveryState.NOT_CONFIGURED
	else:
		delivery_state = DeliveryState.OK
	_started = true
	_refresh_recording(true)


## Runs one update with monotonic real time in seconds: recording refresh, state
## and object checks, movement, the flush timer and retries.
func tick(now_seconds: float) -> void:
	_seconds = now_seconds
	if not _started:
		return
	_refresh_recording(false)
	if is_collecting():
		var sample := _activity()
		if movement_tracking and _teleports.is_empty():
			_sample_movement(now_seconds, sample)
		if now_seconds - _state_keyframe_at >= KEYFRAME_SECONDS:
			_state_keyframe_due = true
		if now_seconds >= _next_state_poll:
			_next_state_poll = now_seconds + STATE_POLL_SECONDS
			_poll_state(sample)
		if now_seconds - _objects_keyframe_at >= KEYFRAME_SECONDS:
			_objects_keyframe_due = true
		if now_seconds >= _next_object_check:
			var interval := 1.0 / clampf(object_checks_per_second if is_finite(object_checks_per_second) else 4.0, 1.0, 10.0)
			_next_object_check = now_seconds + interval
			_check_objects()
	if not _queue.is_empty() and not _request_open and now_seconds >= _next_retry and (_flush_requested
			or _queue.size() >= maxi(1, batch_max_events) or now_seconds - _last_flush >= maxf(0.0, flush_interval_seconds)):
		_send_next()


## Sends queued records now, one request at a time.
func flush() -> void:
	_flush_requested = true
	_send_next()


## Ends the play session: sends pending state and object changes, completes an
## attached recording and flushes. Await [method drain] afterwards to give
## delivery a bounded time.
func shutdown() -> void:
	if not _started or _shutdown:
		return
	if is_collecting():
		_send_buffered_records()
	_shutdown = true
	_finish_recording("play_exit")
	flush()


## Waits up to [param timeout_seconds] (at most 5) for queued records to be sent.
func drain(timeout_seconds := 2.0) -> void:
	var deadline := Time.get_ticks_msec() + int(clampf(timeout_seconds, 0.0, 5.0) * 1000.0)
	while pending_count() > 0 and Time.get_ticks_msec() < deadline and is_inside_tree():
		await get_tree().process_frame
		tick(Time.get_ticks_usec() / 1000000.0)


## For a game's own automated tests: collects even in an automated run and sends
## every request to [param fake_transport], func(body: String, done: Callable),
## instead of the network. Nothing reaches Testing Floor.
func use_test_transport(fake_transport: Callable) -> void:
	transport = fake_transport
	is_automation = false
	if write_key.strip_edges().is_empty():
		write_key = "test-only-never-transmitted"
	if _started and not _shutdown and enabled:
		delivery_state = DeliveryState.OK


## Whether the SDK accepts events now, including the editor recording policy.
func is_collecting() -> bool:
	return _started and not _shutdown and enabled and not is_automation \
		and (delivery_state == DeliveryState.OK or delivery_state == DeliveryState.NETWORK_DOWN) and _policy_permits()


## Why collection is inactive, or an empty string while collecting: shutdown,
## automation, master_disabled, missing_configuration, collector_rejected or
## editor_policy_disabled.
func collection_reason() -> String:
	if is_collecting():
		return ""
	if _shutdown:
		return "shutdown"
	if is_automation:
		return "automation"
	if not enabled:
		return "master_disabled"
	if delivery_state == DeliveryState.NOT_CONFIGURED:
		return "missing_configuration"
	if delivery_state == DeliveryState.REJECTED:
		return "collector_rejected"
	return "editor_policy_disabled"


## The attached recording, or an empty Dictionary while none is attached,
## suspended or closed.
func get_recording() -> Dictionary:
	return _exposed.duplicate()


## The live desktop handoff, even when collection is off. QR suppression follows it.
func get_recording_handoff() -> Dictionary:
	if _recording.is_empty() or _closed:
		return {}
	if _recording.lease_version != 0 and not TestingFloorRecording.has_live_lease(_recording, _now_ms()):
		return {}
	return _recording.duplicate()


func pending_count() -> int:
	return _queue.size() + _in_flight.size()


func _policy_permits() -> bool:
	if not is_editor or enable_in_editor:
		return true
	return enable_in_editor_while_recording and not _exposed.is_empty() \
		and TestingFloorRecording.has_active_lease(_exposed, _now_ms())


func _now_ms() -> int:
	return clock_ms.call()

#endregion


#region Recording

func _refresh_recording(force: bool) -> void:
	if _shutdown or _refreshing:
		return
	_refreshing = true
	var now := _now_ms()
	var lease_ran_out: bool = not _recording.is_empty() and not _closed and not _suspended \
		and _recording.lease_version != 0 and not TestingFloorRecording.has_active_lease(_recording, now)
	var poll: bool = force or now >= _next_recording_poll or lease_ran_out
	var candidate := {}
	if poll:
		_next_recording_poll = now + RECORDING_POLL_MS
		candidate = recording_source.call(now) if recording_source.is_valid() else {}
		if not candidate.is_empty() and _completed.has(candidate.recording_uuid):
			candidate = {}
		if not candidate.is_empty() and not _recording.is_empty() and not _closed \
				and candidate.recording_uuid == _recording.recording_uuid:
			_recording = candidate
	_check_recording_closed()
	if poll:
		if not candidate.is_empty() and (_recording.is_empty() or _closed or candidate.recording_uuid != _recording.recording_uuid):
			if not _recording.is_empty() and not _closed:
				_interrupted = true
				if is_collecting():
					_send_buffered_records()
				_finish_recording("recording_replaced")
			_attach(candidate)
		elif not _recording.is_empty() and not _closed and _recording.lease_version != 0:
			if not TestingFloorRecording.has_active_lease(_recording, now):
				if not _suspended:
					_suspended = true
					_interrupted = true
					_exposed = {}
					reset_movement()
					_write_status("suspended", "lease_expired")
					recording_changed.emit({})
			elif _suspended:
				_suspended = false
				_exposed = _recording.duplicate()
				_reset_baselines()
				_write_status("attached", "none")
				recording_changed.emit(_exposed.duplicate())
				_send_keyframes()
			else:
				_exposed = _recording.duplicate()
	_refreshing = false


func _attach(recording: Dictionary) -> void:
	_recording = recording
	_closed = false
	_suspended = false
	_interrupted = false
	_admitted = false
	_exposed = {}
	var directory: String = recording.telemetry_directory
	if not directory.is_empty() and (not DirAccess.dir_exists_absolute(directory) or FileAccess.file_exists(directory.path_join("closed.json"))):
		# The desktop app closed this recording, or never prepared it: admit nothing.
		_closed = true
		_completed[recording.recording_uuid] = true
		return
	_admitted = true
	if not directory.is_empty():
		var registration := FileAccess.open(directory.path_join(play_session_id + ".session"), FileAccess.WRITE)
		if registration:
			registration.close()
		else:
			# A sandboxed game can read the directory but not write to it. Events still carry the recording.
			_warn_once("registration", "Testing Floor could not register this Play run in the recording's telemetry directory; events still carry the recording.")
	if recording.lease_version != 0 and not TestingFloorRecording.has_active_lease(recording, _now_ms()):
		_suspended = true
		_interrupted = true
		_write_status("suspended", "lease_expired")
		return
	_exposed = recording.duplicate()
	_reset_baselines()
	_write_status("attached", "none")
	recording_changed.emit(_exposed.duplicate())
	_send_keyframes()


func _check_recording_closed() -> void:
	if _recording.is_empty() or _closed or str(_recording.telemetry_directory).is_empty():
		return
	if not FileAccess.file_exists(str(_recording.telemetry_directory).path_join("closed.json")):
		return
	if _recording.lease_version != 0 and not TestingFloorRecording.has_active_lease(_recording, _now_ms()):
		_interrupted = true
	if is_collecting():
		_send_buffered_records()
	_finish_recording("closed")


func _finish_recording(reason: String) -> void:
	if _recording.is_empty() or _closed:
		return
	_closed = true
	var was_exposed := not _exposed.is_empty()
	_exposed = {}
	_completed[_recording.recording_uuid] = true
	reset_movement()
	_write_status("closed", reason)
	if was_exposed:
		recording_changed.emit({})
	if _admitted:
		# The completion marker bypasses the gameplay queue's capacity.
		_enqueue(COMPLETION_RECORD, {"interrupted": _interrupted}, false, true, _recording, _now_ms())
		_flush_requested = true


func _write_status(status: String, reason: String) -> void:
	var directory: String = _recording.get("telemetry_directory", "")
	if directory.is_empty() or not DirAccess.dir_exists_absolute(directory):
		return
	var path := directory.path_join(play_session_id + ".status.json")
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"recording_uuid": _recording.recording_uuid, "session_id": play_session_id,
		"engine": engine_name, "sdk_version": SDK_VERSION, "state": status, "reason": reason,
		"interrupted": _interrupted, "capabilities": STATUS_CAPABILITIES, "updated_at_unix_ms": _now_ms(),
	}))
	file.close()
	if DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)


func _reset_baselines() -> void:
	_state_keyframe_due = true
	_objects_keyframe_due = true
	reset_movement()


func _send_keyframes() -> void:
	if not is_collecting():
		return
	_poll_state(_activity())
	_check_objects()


## Sends the state change and object rows that would wait for the next poll, so
## they go out with a recording before its completion marker.
func _send_buffered_records() -> void:
	_poll_state(_activity())
	_check_objects()

#endregion


#region Events

## Queues a gameplay event. Returns false when the event was not queued: while
## not collecting, for an empty name, or for a name beginning with $tf_, which
## the SDK's own records use.
func track(event_name: String, properties: Dictionary = {}) -> bool:
	if event_name.to_lower().begins_with("$tf_"):
		_warn_once("name:" + event_name, "Testing Floor refused the event name %s: names beginning with $tf_ are reserved for its own records." % event_name)
		if is_collecting():
			dropped_events += 1
		return false
	if not is_collecting() or event_name.strip_edges().is_empty():
		return false
	var sample := _activity()
	_poll_state(sample)
	var values := {}
	_merge(values, _dictionary(context_provider))
	_merge(values, _activity_properties(sample))
	_merge(values, properties)
	if event_processor.is_valid():
		var processed: Variant = event_processor.call(values)
		if processed is Dictionary:
			values = {}
			_merge(values, processed)
	_last_level = {}
	for key in values:
		if str(key).begins_with("game_level."):
			_last_level[key] = values[key]
	return _enqueue(event_name, values, false, false, _exposed, _now_ms())


## Sets one session-state value, overriding the state provider's value for the key.
func set_state(key: String, value: Variant) -> void:
	if _supported(value):
		_direct_state[key] = _normalized(value)


## Removes a value set with set_state. A key no source supplies any more is sent as null.
func clear_state(key: String) -> void:
	_direct_state.erase(key)


## Position fields for an event, such as vector_properties("target.position", v).
static func vector_properties(prefix: String, value: Variant) -> Dictionary:
	var point: Variant = _as_vector3(value)
	if point == null:
		return {}
	return {prefix + ".x": point.x, prefix + ".y": point.y, prefix + ".z": point.z}


func _enqueue(event_name: String, properties: Dictionary, keyframe: bool, control: bool, recording: Dictionary, time_ms: int) -> bool:
	var recording_uuid: String = recording.get("recording_uuid", "")
	var gameplay := event_name != COMPLETION_RECORD
	if not control and pending_count() >= maxi(1, queue_max_events):
		_note_dropped(1, 1 if not recording_uuid.is_empty() else 0, recording_uuid)
		return false
	var event := properties.duplicate(true)
	event["$id"] = new_uuid()
	event["$name"] = event_name
	event["$time"] = iso_time(time_ms)
	event["$schema"] = SCHEMA
	event["$session_id"] = play_session_id
	if not device_id.is_empty():
		event["$device_id"] = device_id
	if not user_id.is_empty():
		event["$user_id"] = user_id
	var context := _record_context()
	context["seq"] = _seq + 1
	if keyframe:
		context["keyframe"] = true
	if not recording_uuid.is_empty():
		context["recording_uuid"] = recording_uuid
		if int(recording.get("playtest_id", 0)) > 0:
			context["playtest_id"] = int(recording.playtest_id)
	event["$tf"] = context
	if JSON.stringify(event).to_utf8_buffer().size() > EVENT_BYTES:
		_note_dropped(1, 1 if not recording_uuid.is_empty() and gameplay else 0, recording_uuid)
		return false
	_seq += 1
	_queue.append({"event": event, "recording": recording_uuid, "gameplay": gameplay})
	return true


func _record_context() -> Dictionary:
	var context := {"sdk_version": SDK_VERSION, "editor": is_editor}
	for pair in [["engine", engine_name], ["os", os_name], ["locale", locale], ["app_version", app_version], ["device_model", device_model]]:
		if not str(pair[1]).is_empty():
			context[pair[0]] = pair[1]
	if screen_size.x > 0 and screen_size.y > 0:
		context["screen_width"] = screen_size.x
		context["screen_height"] = screen_size.y
	return context


func _note_dropped(count: int, recording_count: int, recording_uuid: String) -> void:
	if recording_count > 0 and not recording_uuid.is_empty():
		_recording_drops[recording_uuid] = int(_recording_drops.get(recording_uuid, 0)) + recording_count
	if count > 0:
		dropped_events += count
		# Keyframes let a reader recover from any lost record.
		_state_keyframe_due = true
		_objects_keyframe_due = true


func _count_lost(items: Array[Dictionary]) -> void:
	for item in items:
		_note_dropped(1, 1 if item.gameplay and not str(item.recording).is_empty() else 0, item.recording)

#endregion


#region Delivery

func _send_next() -> void:
	if _request_open or _queue.is_empty() or _seconds < _next_retry:
		return
	if delivery_state != DeliveryState.OK and delivery_state != DeliveryState.NETWORK_DOWN:
		return
	var batch: Array[Dictionary] = []
	var first: Dictionary = _queue[0]
	if first.event["$name"] == COMPLETION_RECORD:
		first.event["dropped_events"] = int(_recording_drops.get(first.recording, 0))
		batch.append(_queue.pop_front())
	else:
		var bytes := 64 + write_key.length()
		while not _queue.is_empty() and batch.size() < clampi(batch_max_events, 1, 2000):
			var next: Dictionary = _queue[0]
			if next.event["$name"] == COMPLETION_RECORD or next.recording != first.recording:
				break
			var size := JSON.stringify(next.event).to_utf8_buffer().size() + 1
			if not batch.is_empty() and bytes + size > REQUEST_BYTES:
				break
			bytes += size
			batch.append(_queue.pop_front())
	_in_flight = batch
	_request_open = true
	_last_flush = _seconds
	_request += 1
	var request := _request
	var events := []
	for item in batch:
		events.append(item.event)
	var body := JSON.stringify({"$write_key": write_key, "$sent_at": iso_time(_now_ms()), "events": events})
	transport.call(body, func(status: int) -> void: _complete_send(request, status))


func _complete_send(request: int, status: int) -> void:
	if request != _request or not _request_open:
		return
	_request_open = false
	var batch := _in_flight
	_in_flight = []
	if status >= 200 and status < 300:
		delivery_state = DeliveryState.OK
		_retry_delay = 1.0
		_next_retry = 0.0
		_flush_requested = not _queue.is_empty()
	elif status == 401 or status == 403:
		delivery_state = DeliveryState.REJECTED
		_warn_once("rejected", "Testing Floor rejected the write key. Collection stops for this play session.")
		_count_lost(batch)
		_count_lost(_queue)
		_queue.clear()
	elif status >= 400 and status < 500 and status != 408 and status != 429:
		delivery_state = DeliveryState.OK
		_retry_delay = 1.0
		_next_retry = 0.0
		_count_lost(batch)
		_flush_requested = not _queue.is_empty()
	else:
		delivery_state = DeliveryState.NETWORK_DOWN
		batch.append_array(_queue)
		_queue = batch
		_next_retry = _seconds + _retry_delay
		_retry_delay = minf(30.0, _retry_delay * 2.0)

#endregion


#region Session state

func _poll_state(sample: Dictionary) -> void:
	if not is_collecting():
		return
	var current := {}
	if sample.get("viewport_size") is Vector2i or sample.get("viewport_size") is Vector2:
		var viewport: Vector2 = Vector2(sample.viewport_size)
		if viewport.x > 0 and viewport.y > 0:
			current["viewport.width"] = int(viewport.x)
			current["viewport.height"] = int(viewport.y)
	if _number(sample.get("camera_ortho_width")):
		current["camera.projection"] = "orthographic"
	elif _number(sample.get("camera_fov")):
		current["camera.projection"] = "perspective"
		# Godot's Camera3D keeps its height by default, so its field of view is vertical.
		current["camera.fov_axis"] = "vertical"
	var provided := _dictionary(state_provider)
	for key in provided:
		if _valid_key(key) and _supported(provided[key]):
			current[str(key)] = _normalized(provided[key])
	for key in _direct_state:
		current[key] = _direct_state[key]
	var keyframe := _state_keyframe_due
	var changes := {}
	if keyframe:
		changes = current.duplicate(true)
	else:
		for key in current:
			if not _sent_state.has(key) or _sent_state[key] != current[key]:
				changes[key] = current[key]
		for key in _sent_state:
			if not current.has(key):
				changes[key] = null
	if changes.is_empty():
		return
	if _enqueue(STATE_RECORD, changes, keyframe, false, _exposed, _now_ms()):
		_sent_state = current
		if keyframe:
			_state_keyframe_due = false
			_state_keyframe_at = _seconds

#endregion


#region Tracked objects

## Tracks an object's path. [param position_source] returns a Vector3 or Vector2,
## or null once the object is gone. Without an id the SDK assigns kind#n. Returns
## the id, or an empty string when collection is disabled or the limit is reached.
func track_object(kind: String, position_source: Callable, id := "") -> String:
	if not _started or not enabled or is_automation or delivery_state == DeliveryState.NOT_CONFIGURED \
			or kind.is_empty() or not position_source.is_valid():
		return ""
	return _register_object(kind, position_source, null, id)


## Tracks a Node3D's or Node2D's global position without keeping it alive. The
## SDK removes it as destroyed once the node is freed.
func track_node(kind: String, node: Node, id := "") -> String:
	if not is_instance_valid(node) or not (node is Node3D or node is Node2D):
		return ""
	if not _started or not enabled or is_automation or delivery_state == DeliveryState.NOT_CONFIGURED or kind.is_empty():
		return ""
	var reference := weakref(node)
	var source := func() -> Variant:
		var target: Variant = reference.get_ref()
		return target.global_position if is_instance_valid(target) and target.is_inside_tree() else null
	return _register_object(kind, source, reference, id)


## Sets a scalar state value for a tracked object. Only changed values are sent.
func set_object_state(id: String, key: String, value: Variant) -> void:
	if _objects.has(id) and not key.is_empty() and (value is String or value is bool or value is int or (value is float and is_finite(value))):
		_objects[id].state[key] = value


## Sends the object's final position with [param reason], such as destroyed or disabled.
func remove_object(id: String, reason := "removed") -> void:
	if not _objects.has(id):
		return
	var object: Dictionary = _objects[id]
	_objects.erase(id)
	if not is_collecting():
		return
	var final: Variant = _as_vector3(object.source.call())
	_removals.append({"id": id, "kind": object.kind, "position": final if final != null else object.known,
		"state": object.state.duplicate(), "reason": reason if not reason.is_empty() else "removed"})


func get_tracked_object_count() -> int:
	return _objects.size()


func _register_object(kind: String, source: Callable, reference: Variant, id: String) -> String:
	if id.is_empty():
		_kind_counts[kind] = int(_kind_counts.get(kind, 0)) + 1
		id = "%s#%d" % [kind, _kind_counts[kind]]
	if _objects.has(id):
		return id
	if _objects.size() >= maxi(0, max_tracked_objects):
		_warn_once("objects", "Testing Floor is already tracking %d objects; further objects are ignored." % max_tracked_objects)
		return ""
	_objects[id] = {"kind": kind, "source": source, "reference": reference, "known": null, "sent": null,
		"state": {}, "sent_state": {}}
	return id


func _check_objects() -> void:
	if not is_collecting():
		return
	var keyframe := _objects_keyframe_due
	var rows: Array[Dictionary] = []
	for removal in _removals:
		rows.append(removal)
	for id in _objects.keys():
		var object: Dictionary = _objects[id]
		if object.reference != null and object.reference.get_ref() == null:
			_objects.erase(id)
			rows.append({"id": id, "kind": object.kind, "position": object.known, "state": {}, "reason": "destroyed"})
			continue
		var point: Variant = _as_vector3(object.source.call())
		if point == null:
			_objects.erase(id)
			rows.append({"id": id, "kind": object.kind, "position": object.known, "state": {}, "reason": "gone"})
			continue
		object.known = point
		var row := {"id": id, "kind": object.kind, "position": null, "state": {}, "reason": ""}
		if keyframe or object.sent == null or (point as Vector3).distance_to(object.sent) >= object_min_distance:
			row.position = point
		for key in object.state:
			if keyframe or not object.sent_state.has(key) or object.sent_state[key] != object.state[key]:
				row.state[key] = object.state[key]
		if row.position != null or not row.state.is_empty():
			rows.append(row)
	if rows.is_empty():
		_objects_keyframe_due = false
		return
	var time := maxi(_now_ms(), _last_object_time + 1)
	_last_object_time = time
	var all_queued := true
	var start := 0
	while start < rows.size():
		var group: Array[Dictionary] = []
		var samples := 0
		var bytes := 0
		while start < rows.size():
			var row: Dictionary = rows[start]
			var row_samples := 1 if row.position != null else 0
			var row_bytes := 48 + str(row.id).length() * 2 + str(row.kind).length() + JSON.stringify(row.state).length() * 2
			if not group.is_empty() and (samples + row_samples > OBJECT_SAMPLES_PER_RECORD or bytes + row_bytes > OBJECT_RECORD_BYTES):
				break
			group.append(row)
			samples += row_samples
			bytes += row_bytes
			start += 1
		if _enqueue(OBJECTS_RECORD, _object_record(group), keyframe, false, _exposed, time):
			for row in group:
				if _objects.has(row.id):
					var object: Dictionary = _objects[row.id]
					if row.position != null:
						object.sent = row.position
					object.sent_state.merge(row.state, true)
				else:
					_removals.erase(row)
		else:
			all_queued = false
	if all_queued and keyframe:
		_objects_keyframe_due = false
		_objects_keyframe_at = _seconds


func _object_record(group: Array[Dictionary]) -> Dictionary:
	var columns := {"sample.id": [], "sample.kind": [], "sample.x": [], "sample.y": [], "sample.z": [],
		"removed.id": [], "removed.reason": [], "state.id": [], "state.key": [], "state.value": []}
	for row in group:
		if row.position != null:
			columns["sample.id"].append(row.id)
			columns["sample.kind"].append(row.kind)
			columns["sample.x"].append(snappedf(row.position.x, 0.01))
			columns["sample.y"].append(snappedf(row.position.y, 0.01))
			columns["sample.z"].append(snappedf(row.position.z, 0.01))
		if not str(row.reason).is_empty():
			columns["removed.id"].append(row.id)
			columns["removed.reason"].append(row.reason)
		for key in row.state:
			columns["state.id"].append(row.id)
			columns["state.key"].append(key)
			columns["state.value"].append(row.state[key])
	var record := {}
	for key in columns:
		if not columns[key].is_empty():
			record[key] = columns[key]
	record.merge(_last_level, true)
	return record

#endregion


#region Movement and teleports

## Starts a new movement baseline, such as after loading a save.
func reset_movement() -> void:
	_movement_baseline = {}
	_moving = false
	_segment = {}
	_run = {}


## Begins a teleport. Movement sampling stops until end_teleport or cancel_teleport.
func begin_teleport(reason := "") -> int:
	_next_teleport += 1
	_teleports[_next_teleport] = {"reason": reason, "start": _as_vector3(_activity().get("player_position")), "started": _seconds}
	return _next_teleport


## Ends a teleport, sending player_teleported from where it began to where the player is now.
func end_teleport(token: int) -> void:
	if not _teleports.has(token):
		return
	var teleport: Dictionary = _teleports[token]
	_teleports.erase(token)
	var finish: Variant = _as_vector3(_activity().get("player_position"))
	if teleport.start != null and finish != null:
		record_teleport(teleport.start, finish, teleport.reason, _seconds - teleport.started)
	else:
		reset_movement()


## Abandons a teleport without an event, resetting the movement baseline.
func cancel_teleport(token: int) -> void:
	_teleports.erase(token)
	reset_movement()


## Sends player_teleported for a jump that already happened, so paths break at it.
func record_teleport(start: Variant, finish: Variant, reason := "", duration := 0.0) -> void:
	reset_movement()
	var from: Variant = _as_vector3(start)
	var to: Variant = _as_vector3(finish)
	if from == null or to == null:
		return
	var properties := vector_properties("teleport.start.position", from)
	properties.merge(vector_properties("teleport.end.position", to), true)
	properties["teleport.kind"] = "teleport"
	properties["teleport.distance"] = (from as Vector3).distance_to(to)
	properties["teleport.duration"] = maxf(0.0, duration)
	if not reason.is_empty():
		properties["teleport.reason"] = reason
	track("player_teleported", properties)


func _sample_movement(now: float, sample: Dictionary) -> void:
	var metrics := _movement_metrics(sample)
	if metrics.is_empty():
		reset_movement()
		return
	if _movement_baseline.is_empty():
		_movement_baseline = metrics
		_last_ping = now
		return
	var step := {
		"distance": _distance(metrics.get("player"), _movement_baseline.get("player")),
		"rotation_degrees": _angle(metrics.get("rotation"), _movement_baseline.get("rotation")),
		"fov_delta": absf(float(metrics.get("fov", 0.0)) - float(_movement_baseline.get("fov", 0.0))) if metrics.has("fov") and _movement_baseline.has("fov") else 0.0,
		"camera_distance": _distance(metrics.get("camera"), _movement_baseline.get("camera")),
		"ortho_width_delta": absf(float(metrics.get("ortho", 0.0)) - float(_movement_baseline.get("ortho", 0.0))) if metrics.has("ortho") and _movement_baseline.has("ortho") else 0.0,
	}
	var minimum := {"distance": movement_min_step, "rotation_degrees": movement_min_step_rotation, "fov_delta": movement_min_step_fov,
		"camera_distance": movement_min_step_camera_distance, "ortho_width_delta": movement_min_step_ortho_width}
	var moved := false
	for key in step:
		if step[key] > 0.0 and step[key] >= minimum[key]:
			moved = true
		else:
			step[key] = 0.0
	if moved:
		_movement_baseline = metrics
		_last_movement = now
		if not _moving:
			_moving = true
			_movement_started = now
			_last_ping = now
			_segment = {}
			_run = {}
		_add(_segment, step)
		_add(_run, step)
		if now - _movement_started >= movement_start_grace and not _run.has("started"):
			_run["started"] = true
			_emit_movement("start", {}, 0.0)
	if _moving and now - _last_movement >= movement_stop_grace:
		if _run.has("started"):
			_emit_movement("stop", _run, now - _movement_started)
		_moving = false
		_segment = {}
		_run = {}
	elif _moving and _run.has("started") and now - _last_ping >= movement_min_ping_interval and (
			float(_segment.get("distance", 0.0)) >= movement_min_ping_distance
			or float(_segment.get("rotation_degrees", 0.0)) >= movement_min_ping_rotation
			or float(_segment.get("fov_delta", 0.0)) >= movement_min_ping_fov
			or float(_segment.get("camera_distance", 0.0)) >= movement_min_ping_camera_distance
			or float(_segment.get("ortho_width_delta", 0.0)) >= movement_min_ping_ortho_width):
		_emit_movement("ping", _segment, now - _last_ping)
		_segment = {}
		_last_ping = now


func _movement_metrics(sample: Dictionary) -> Dictionary:
	var metrics := {}
	var player: Variant = _as_vector3(sample.get("player_position"))
	if player != null:
		metrics["player"] = player
	var camera: Variant = _as_vector3(sample.get("camera_position"))
	if camera != null:
		metrics["camera"] = camera
	var rotation: Variant = _as_basis(sample.get("camera_rotation"))
	if rotation != null:
		metrics["rotation"] = (rotation as Basis).get_rotation_quaternion()
	if _number(sample.get("camera_ortho_width")):
		metrics["ortho"] = float(sample.camera_ortho_width)
	elif _number(sample.get("camera_fov")):
		metrics["fov"] = float(sample.camera_fov)
	return metrics


func _emit_movement(reason: String, totals: Dictionary, duration: float) -> void:
	var properties := {"movement.reason": reason, "movement.duration": maxf(0.0, duration)}
	for key in ["distance", "rotation_degrees", "fov_delta", "camera_distance", "ortho_width_delta"]:
		if float(totals.get(key, 0.0)) > 0.0:
			properties["movement." + key] = totals[key]
	track("player_moved", properties)


static func _add(totals: Dictionary, step: Dictionary) -> void:
	for key in step:
		totals[key] = float(totals.get(key, 0.0)) + step[key]


static func _distance(a: Variant, b: Variant) -> float:
	return (a as Vector3).distance_to(b) if a is Vector3 and b is Vector3 else 0.0


static func _angle(a: Variant, b: Variant) -> float:
	return rad_to_deg((a as Quaternion).angle_to(b)) if a is Quaternion and b is Quaternion else 0.0

#endregion


#region Values

func _activity() -> Dictionary:
	return _dictionary(activity_source)


func _activity_properties(sample: Dictionary) -> Dictionary:
	var properties := vector_properties("player.position", sample.get("player_position"))
	properties.merge(vector_properties("camera.position", sample.get("camera_position")), true)
	var rotation: Variant = _as_basis(sample.get("camera_rotation"))
	if rotation != null:
		var basis: Basis = rotation
		properties.merge(vector_properties("camera.forward", -basis.z), true)
		properties.merge(vector_properties("camera.up", basis.y), true)
		properties.merge(vector_properties("camera.euler", basis.get_euler() * (180.0 / PI)), true)
	if _number(sample.get("camera_ortho_width")):
		properties["camera.ortho_width"] = float(sample.camera_ortho_width)
	elif _number(sample.get("camera_fov")):
		properties["camera.fov"] = float(sample.camera_fov)
	properties.merge(vector_properties("camera.focus", sample.get("camera_focus")), true)
	return properties


static func _dictionary(source: Callable) -> Dictionary:
	if not source.is_valid():
		return {}
	var value: Variant = source.call()
	return value if value is Dictionary else {}


## Copies supported values; drops nulls, empty keys, keys beginning with $, and
## nonfinite or custom values.
static func _merge(into: Dictionary, values: Dictionary) -> void:
	for key in values:
		if _valid_key(key) and values[key] != null and _supported(values[key]):
			into[str(key)] = _normalized(values[key])


static func _valid_key(key: Variant) -> bool:
	return (key is String or key is StringName) and not str(key).is_empty() and not str(key).begins_with("$")


static func _supported(value: Variant) -> bool:
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME, TYPE_BOOL, TYPE_INT, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_ARRAY:
			return (value as Array).all(func(item: Variant) -> bool: return item is String or item is StringName) \
				or (value as Array).all(func(item: Variant) -> bool: return item is int)
	return false


static func _normalized(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING_NAME:
			return str(value)
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return Array(value)
		TYPE_ARRAY:
			return (value as Array).map(func(item: Variant) -> Variant: return str(item) if item is StringName else item)
	return value


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _as_vector3(value: Variant) -> Variant:
	if value is Vector3 and (value as Vector3).is_finite():
		return value
	if value is Vector2 and (value as Vector2).is_finite():
		return Vector3(value.x, value.y, 0.0)
	return null


static func _as_basis(value: Variant) -> Variant:
	if value is Quaternion and (value as Quaternion).is_finite():
		return Basis(value)
	if value is Basis and (value as Basis).is_finite():
		return (value as Basis).orthonormalized()
	return null


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)


static func new_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20)]


## An ISO 8601 UTC time with exactly three fractional digits and a Z suffix.
static func iso_time(unix_ms: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix_ms / 1000) + ".%03dZ" % (unix_ms % 1000)

#endregion
