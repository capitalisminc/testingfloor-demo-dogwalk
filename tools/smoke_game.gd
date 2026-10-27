extends Node

var _records: Array[Dictionary] = []
var _live := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_live = "--tf-live-check" in OS.get_cmdline_user_args()
	_run.call_deferred()

func _transport(payload: String, complete: Callable) -> void:
	_records.append_array(JSON.parse_string(payload).events)
	complete.call(200, true)

func _run() -> void:
	get_tree().create_timer(35.0).timeout.connect(func(): get_tree().quit(2))
	if _live:
		TestingFloor.set_state("integration.test", true)
	else:
		TestingFloor.transport = _transport
		TestingFloor.enabled = true
	for frame in range(30):
		await get_tree().process_frame
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(640, 360))
	Settings.auto_save = false
	Context.debug.skip_launch_logos = true
	Context.debug.skip_wake_up = true
	for frame in range(5):
		await get_tree().process_frame
	var menu: Control = Context.menu_ui.main_menu
	menu.new_game_button.pressed.emit()
	await get_tree().create_timer(0.2).timeout
	Context.sequence_intro.stop()
	menu.transition_timer.stop()
	menu.start_gameplay()
	InputController.current_input_mode = InputController.input_modes.CONTROLLER
	var start: Vector3 = Context.chocomel.global_position
	Input.action_press("Move Right")
	await get_tree().create_timer(2.5).timeout
	Input.action_release("Move Right")
	Input.action_press("Action")
	await get_tree().process_frame
	Input.action_release("Action")
	await get_tree().create_timer(1.0).timeout
	Context.menu_ui.pause_menu.pause()
	await get_tree().create_timer(0.2).timeout
	Context.menu_ui.pause_menu.unpause()
	await get_tree().create_timer(0.2).timeout
	var shovel: CollectableItem = Context.interactable_nodes[Constants.interactable_ids.SHOVEL]
	shovel.item_state = GameStatus.item_states.HELD
	for repeat in range(5):
		shovel.item_state = GameStatus.item_states.HELD
	shovel.item_state = GameStatus.item_states.PLACED
	DogwalkTelemetry.begin_save_load()
	shovel.item_state = GameStatus.item_states.HELD
	DogwalkTelemetry.end_save_load()
	var distance := start.distance_to(Context.chocomel.global_position)
	TestingFloor.poll_objects()
	await TestingFloor.shutdown(5.0)
	var names := {}
	for event in _records:
		names[event["$name"]] = int(names.get(event["$name"], 0)) + 1
	var success := GameStatus.current_game_state == GameStatus.game_states.GAMEPLAY and distance > 0.5
	if not _live:
		for expected in ["new_game_started", "story_phase_changed", "player_moved", "$tf_objects", "game_paused", "game_resumed"]:
			success = success and names.has(expected)
	if not _live:
		success = success and names.get("item_picked_up", 0) == 1 and names.get("player_teleported", 0) == 1
	var result := {"ok": success, "live": _live, "distance_meters": distance,
		"session_id": TestingFloor.session_id, "event_counts": names, "pending_events": TestingFloor.pending_count()}
	DirAccess.make_dir_recursive_absolute("res://Artifacts")
	var file := FileAccess.open("res://Artifacts/smoke-game.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  ") + "\n")
	file.close()
	print("DOGWALK gameplay check: ", JSON.stringify(result))
	get_tree().quit(0 if success else 1)
