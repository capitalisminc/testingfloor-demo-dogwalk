extends TestingFloorClient
## The TestingFloor autoload. It configures the client from the testing_floor/*
## project settings and the engine, sends over HTTP, reads the desktop app's
## handoff, keeps the player IDs, ticks every frame and draws the optional QR
## marker.

const QR := preload("res://addons/testing_floor/third_party/qr_code/qr_code.gd")
const SETTINGS := "testing_floor/"
## Where the desktop app writes the editor handoff, inside Godot's per-project cache folder.
const SIDECAR := "res://.godot/TestingFloor/recording-payload.json"
const QR_INTERVAL := 15.0
const AUTOMATION_ARGUMENTS := ["--tf-test", "--testing-floor-automation"]

## Show the QR marker that lets Testing Floor match a recording to this run
## without a desktop handoff. Off by default; --forceqr turns it on.
var qr_heartbeats := false
## When the window is closed, wait up to two seconds for delivery before quitting.
## Off by default, because it turns off SceneTree.auto_accept_quit.
var quit_after_delivery := false

var _http: HTTPRequest
var _pending_done: Callable
var _qr: TextureRect
var _qr_sequence := 0
var _next_qr := 0.0
var _arguments := PackedStringArray()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_arguments = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	is_editor = OS.has_feature("editor")
	is_automation = _automation()
	_configure()
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_http_completed)
	transport = _send
	recording_source = _discover
	start(_now_seconds())
	if quit_after_delivery:
		get_tree().auto_accept_quit = false
	_update_qr()


func _process(_delta: float) -> void:
	screen_size = Vector2i(get_viewport().get_visible_rect().size)
	tick(_now_seconds())
	_update_qr()


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if quit_after_delivery:
		quit()
	else:
		# Godot quits right after this, so the last send may not finish. Use quit()
		# or quit_after_delivery to wait for delivery.
		shutdown()


## Completes the session, waits up to [param timeout_seconds] for delivery, then quits.
func quit(exit_code := 0, timeout_seconds := 2.0) -> void:
	shutdown()
	await drain(timeout_seconds)
	get_tree().quit(exit_code)


func _now_seconds() -> float:
	return Time.get_ticks_usec() / 1000000.0


func _automation() -> bool:
	for argument in _arguments:
		if argument in AUTOMATION_ARGUMENTS or argument.contains("gut_cmdln") or argument.contains("GdUnit"):
			return true
	return false


func _setting(name: String, default: Variant) -> Variant:
	return ProjectSettings.get_setting(SETTINGS + name, default)


func _configure() -> void:
	write_key = str(_setting("write_key", "")).strip_edges()
	var environment_key := OS.get_environment("TESTING_FLOOR_WRITE_KEY").strip_edges()
	if not environment_key.is_empty():
		write_key = environment_key
	endpoint = str(_setting("endpoint", endpoint)).strip_edges().trim_suffix("/")
	enabled = bool(_setting("enabled", true))
	enable_in_editor = bool(_setting("enable_in_editor", false))
	enable_in_editor_while_recording = bool(_setting("enable_in_editor_while_recording", true))
	movement_tracking = bool(_setting("movement_tracking", false))
	object_checks_per_second = float(_setting("object_checks_per_second", object_checks_per_second))
	max_tracked_objects = int(_setting("max_tracked_objects", max_tracked_objects))
	qr_heartbeats = bool(_setting("qr_heartbeats", false))
	quit_after_delivery = bool(_setting("quit_after_delivery", false))
	app_version = str(_setting("app_version", "")).strip_edges()
	if app_version.is_empty():
		app_version = str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	var version := Engine.get_version_info()
	engine_name = "Godot %d.%d.%d" % [version.major, version.minor, version.patch]
	os_name = operating_system_family(OS.get_name())
	locale = language_tag(OS.get_locale())
	var model := OS.get_model_name()
	device_model = "" if model.is_empty() or model == "GenericDevice" else model
	if enabled and not is_automation:
		user_id = str(_setting("user_id", "")).strip_edges()
		if user_id.is_empty():
			user_id = _load_or_create_id("user://testing_floor/profile-id")
		device_id = str(_setting("device_id", "")).strip_edges()
		if device_id.is_empty():
			device_id = _load_or_create_id(_installation_id_path())


## The $tf.os family for a Godot platform name, or the name itself when it has none.
static func operating_system_family(platform: String) -> String:
	match platform:
		"macOS", "Windows", "Linux", "iOS", "Android", "Web", "visionOS":
			return platform
		"FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return "Linux"
	return platform


## A BCP 47 tag such as en-US for a Godot locale such as en_US, or an empty string.
static func language_tag(godot_locale: String) -> String:
	var parts := godot_locale.split("_", false)
	if parts.is_empty() or parts[0].length() < 2 or parts[0].length() > 3:
		return ""
	var tag := parts[0].to_lower()
	for part in parts.slice(1):
		if part.length() == 4:
			tag += "-" + part.capitalize()
		elif part.length() == 2 or (part.length() == 3 and part.is_valid_int()):
			tag += "-" + part.to_upper()
	return tag


## The profile ID follows the game's saved data in user://, so it travels with
## the player's saves. The installation ID stays in this machine's settings folder.
func _installation_id_path() -> String:
	var project := str(ProjectSettings.get_setting("application/config/name", "game"))
	return OS.get_config_dir().path_join("TestingFloor").path_join(project.md5_text().substr(0, 16)).path_join("installation-id")


static func _load_or_create_id(path: String) -> String:
	if FileAccess.file_exists(path):
		var previous := FileAccess.get_file_as_string(path).strip_edges()
		if not previous.is_empty():
			return previous
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	var id := new_uuid()
	file.store_string(id)
	file.close()
	return id


func _discover(now_ms: int) -> Dictionary:
	var sidecar := ""
	if is_editor:
		var path := ProjectSettings.globalize_path(SIDECAR)
		if FileAccess.file_exists(path):
			sidecar = FileAccess.get_file_as_string(path)
	# Play from the Godot editor runs in a separate process, so the handoff is
	# project-scoped and editor_pid is not compared.
	return TestingFloorRecording.resolve(sidecar, TestingFloorRecording.launch_argument(_arguments), 0, now_ms)


func _send(body: String, done: Callable) -> void:
	_pending_done = done
	var error := _http.request(endpoint + "/v1/batch", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if error != OK:
		_pending_done = Callable()
		done.call(0)


func _http_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var done := _pending_done
	_pending_done = Callable()
	if done.is_valid():
		done.call(response_code if result == HTTPRequest.RESULT_SUCCESS else 0)


func _update_qr() -> void:
	var forced := "--forceqr" in _arguments or "-forceqr" in _arguments
	var suppressed: bool = get_recording_handoff().get("suppress_qr", false)
	var visible := not is_automation and ((qr_heartbeats and not suppressed) or forced)
	if not visible:
		if is_instance_valid(_qr):
			_qr.get_parent().get_parent().queue_free()
			_qr = null
		return
	if not is_instance_valid(_qr):
		var layer := CanvasLayer.new()
		layer.layer = 128
		add_child(layer)
		var root := Control.new()
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(root)
		_qr = TextureRect.new()
		_qr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		root.add_child(_qr)
		_qr.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		_qr.offset_left = -208
		_qr.offset_top = -208
		_qr.offset_right = -16
		_qr.offset_bottom = -16
		_next_qr = 0.0
	if _now_seconds() < _next_qr:
		return
	_qr_sequence += 1
	_qr.texture = ImageTexture.create_from_image(qr_image(play_session_id, clock_ms.call(), _qr_sequence))
	_next_qr = _now_seconds() + QR_INTERVAL


## The QR marker for one moment: inverted colors and a four-module quiet zone.
static func qr_image(session: String, unix_ms: int, sequence: int, module_size := 3) -> Image:
	var payload := "tfqr://sync/v1?s=%s&t=%d&q=%d" % [session.uri_encode(), unix_ms, sequence]
	var qr := QR.new(QR.ErrorCorrection.MEDIUM)
	qr.put_byte(payload.to_utf8_buffer())
	return QR.generate_image(qr.encode(), module_size, Color.BLACK, Color.WHITE, 4)
