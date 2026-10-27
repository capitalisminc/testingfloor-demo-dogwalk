extends "res://addons/testing_floor/client.gd"

const QR = preload("res://addons/testing_floor/third_party/qr_code/qr_code.gd")
var _qr: TextureRect
var _next_qr := 0.0
var _qr_sequence := 0
var _quitting := false

func _ready() -> void:
	super._ready()
	get_tree().auto_accept_quit = false
	if not enabled:
		return
	print("Testing Floor session: ", session_id)
	var arguments := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if recording.get("suppress_qr", false) and not "--forceqr" in arguments:
		return
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	_qr = TextureRect.new()
	_qr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.add_child(_qr)
	_qr.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_qr.offset_left = -208
	_qr.offset_top = -208
	_qr.offset_right = -16
	_qr.offset_bottom = -16
	_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_refresh_qr()

func _process(delta: float) -> void:
	super._process(delta)
	if is_instance_valid(_qr) and _now() >= _next_qr:
		_refresh_qr()

func _refresh_qr() -> void:
	_qr_sequence += 1
	var payload := "tfqr://sync/v1?s=%s&t=%d&q=%d" % [session_id.uri_encode(),
		int(Time.get_unix_time_from_system() * 1000.0), _qr_sequence]
	var qr := QR.new(QR.ErrorCorrection.MEDIUM)
	qr.put_byte(payload.to_utf8_buffer())
	_qr.texture = ImageTexture.create_from_image(QR.generate_image(qr.encode(), 3, Color.WHITE, Color.BLACK, 4))
	_next_qr = _now() + 15.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()

func quit_game() -> void:
	if _quitting:
		return
	_quitting = true
	track("game_exited")
	await quit_after_flush()
