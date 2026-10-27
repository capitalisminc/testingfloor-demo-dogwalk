extends SceneTree

const Client = preload("res://addons/testing_floor/client.gd")
const QR = preload("res://addons/testing_floor/third_party/qr_code/qr_code.gd")
var _failures: Array[String] = []
var _requests: Array[Dictionary] = []
var _response := 200
var _world_position := Vector3.ZERO

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures.append(description)
		push_error(description)

func _transport(payload: String, complete: Callable) -> void:
	_requests.append(JSON.parse_string(payload))
	complete.call(_response, true)

func _client() -> Node:
	var client := Client.new({"write_key": "offline-test", "test_transport": true, "ignore_environment": true,
		"device_id": "offline-device", "user_id": "offline-user", "app_version": "test"})
	client.transport = _transport
	root.add_child(client)
	client.set_process(false)
	return client

func _run() -> void:
	var client = _client()
	client.set_state("chapter", "forest")
	client.track("dog_barked", {"interaction.type": "bark"})
	client.flush()
	var first: Array = _requests.back().events
	_check(first.size() == 2 and first[0]["$name"] == "$tf_state" and first[1]["$name"] == "dog_barked", "State must precede the gameplay event that uses it")
	_check(first[0]["$tf"].keyframe and first[0].chapter == "forest", "First state record must contain a full keyframe")
	client.clear_state("chapter")
	client.track("chapter_ended")
	client.flush()
	_check(_requests.back().events[0].has("chapter") and _requests.back().events[0].chapter == null, "Cleared state must emit a tombstone")
	client.track_object("companion", func(): return _world_position, "pinda")
	client.set_object_state("pinda", "mood", 30.0)
	client.poll_objects()
	client.flush()
	var initial: Dictionary = _requests.back().events[0]
	_check(initial["sample.id"].has("pinda") and initial["state.value"].has(30.0), "An object must publish its initial position and state")
	_world_position = Vector3(0.1, 0, 0)
	client.poll_objects()
	_check(client.pending_count() == 0, "Sub-threshold object motion should not add samples")
	_world_position = Vector3(1, 0, 0)
	client.remove_object("pinda", "collected")
	client.poll_objects()
	client.flush()
	var removed: Dictionary = _requests.back().events[0]
	_check(removed["sample.x"].back() == 1.0 and removed["removed.reason"] == ["collected"], "Removal must retain the object's final position and reason")
	_response = 503
	client.track("retry_me")
	client.flush()
	var retry_id: String = _requests.back().events[0]["$id"]
	_check(client.pending_count() == 1, "Failed requests must remain queued")
	_response = 200
	client._next_retry = 0.0
	client.flush()
	_check(_requests.back().events[0]["$id"] == retry_id and client.pending_count() == 0, "Retry must preserve record identity and order")
	var recording_dir := OS.get_user_data_dir().path_join("testing-floor-test-" + Client.new_uuid())
	DirAccess.make_dir_recursive_absolute(recording_dir)
	client.recording = {"recording_uuid": "offline-recording", "telemetry_directory": recording_dir}
	client._registered = true
	client.track("last_recorded_action")
	var marker := FileAccess.open(recording_dir.path_join("closed.json"), FileAccess.WRITE)
	marker.store_string("{}")
	marker.close()
	client.track("after_recording")
	var before := _requests.size()
	client.flush()
	client.flush()
	client.flush()
	_check(_requests.size() == before + 3, "Recording completion must be sent in its own ordered request")
	_check(_requests[before].events.back()["$tf"].recording_uuid == "offline-recording", "Last recorded action must keep recording context")
	_check(_requests[before + 1].events.size() == 1 and _requests[before + 1].events[0]["$name"] == "$tf_telemetry_complete", "Completion marker must wait until earlier events are acknowledged")
	_check(not _requests[before + 2].events[0]["$tf"].has("recording_uuid"), "Later actions must not attach to a completed recording")
	DirAccess.remove_absolute(recording_dir.path_join("closed.json"))
	DirAccess.remove_absolute(recording_dir)
	client.reset_movement()
	client.activity_source = func(): return {"player_position": _world_position}
	_world_position = Vector3.ZERO
	client._sample_movement(10.0, client._activity())
	_world_position = Vector3(0.1, 0, 0)
	client._sample_movement(10.1, client._activity())
	_world_position = Vector3(0.4, 0, 0)
	client._sample_movement(10.3, client._activity())
	client._sample_movement(10.7, client._activity())
	client.flush()
	var movements: Array = _requests.back().events.filter(func(e): return e["$name"] == "player_moved")
	_check(movements.size() == 3 and movements[1]["movement.reason"] == "ping" and is_equal_approx(movements[1]["movement.distance"], 0.4), "Movement pings must accumulate real distance and include start/ping/end")
	client.record_teleport(_world_position, Vector3(100, 0, 0), "save_loaded")
	client.flush()
	_check(_requests.back().events[0]["$name"] == "player_teleported" and not client._moving, "Teleports must reset movement rather than inflate traveled distance")
	var qr := QR.new(QR.ErrorCorrection.MEDIUM)
	qr.put_byte("tfqr://sync/v1?s=offline-session&t=1793000000000&q=1".to_utf8_buffer())
	var modules: PackedByteArray = qr.encode()
	var image := QR.generate_image(modules, 3, Color.WHITE, Color.BLACK, 4)
	_check(image.get_width() > 100, "QR encoder must produce the synchronization payload")
	image.save_png("/private/tmp/dogwalk-sync-test.png")
	client.free()
	if _failures.is_empty():
		print("Telemetry checks passed: state, objects, retries, recording completion, movement and QR.")
	quit(0 if _failures.is_empty() else 1)
