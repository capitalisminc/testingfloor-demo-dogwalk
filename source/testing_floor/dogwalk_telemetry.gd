extends Node

const LEVEL_ID := "dogwalk_world"
var _level: Node
var _phase := "main_menu"
var _run_started := 0.0
var _paused := false
var _gate_open := false
var _poll_at := 0.0
var _dog_state := ""
var _child_state := "unknown"
var _item_states: Dictionary = {}
var _tracked: Array[String] = []
var _toppled: Dictionary = {}
var _restoring_save := false
var _save_origin := Vector3.ZERO

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	TestingFloor.context_provider = _context
	TestingFloor.activity_source = _activity
	TestingFloor.state_provider = _state
	GameStatus.game_state_changed.connect(_phase_changed)
	var arguments := OS.get_cmdline_user_args()
	if "--tf-capture-map" in arguments:
		add_child(load("res://tools/capture_map.gd").new())
	elif "--tf-smoke-test" in arguments:
		add_child(load("res://tools/smoke_game.gd").new())

func _process(_delta: float) -> void:
	if not is_instance_valid(Context.level) or not is_instance_valid(Context.chocomel):
		return
	if Context.level != _level:
		_bind_level()
	if _paused != get_tree().paused:
		_paused = get_tree().paused
		TestingFloor.reset_movement()
		TestingFloor.track("game_paused" if _paused else "game_resumed")
	if Time.get_ticks_msec() < _poll_at:
		return
	_poll_at = Time.get_ticks_msec() + 200.0
	_update_object_state()
	if GameStatus.gate_opened != _gate_open:
		_gate_open = GameStatus.gate_opened
		if _gate_open and _playing():
			TestingFloor.track("gate_opened", {"object.id": "gate"})
	var dog_state := _enum_name(Chocomel.character_states, Context.chocomel.current_character_state)
	if dog_state != _dog_state:
		if _playing() and (dog_state == "dig" or _dog_state == "dig"):
			TestingFloor.track("digging_started" if dog_state == "dig" else "digging_stopped")
		_dog_state = dog_state
	var currently_toppled: Dictionary = {}
	for entity in ToppleManager.toppled_entities:
		if not is_instance_valid(entity) or not entity.toppled:
			continue
		currently_toppled[entity.get_instance_id()] = true
		if not _toppled.has(entity.get_instance_id()):
			if _playing():
				var properties := TestingFloorClient.vector_properties("prop.position", entity.global_position)
				properties["prop.name"] = str(entity.name)
				TestingFloor.track("prop_toppled", properties)
	_toppled = currently_toppled

func _playing() -> bool:
	return _phase == "gameplay" and not _paused and not _restoring_save

func _enum_name(values: Dictionary, value: int) -> String:
	var key: Variant = values.find_key(value)
	return str(key).to_lower() if key != null else "unknown"

func _bind_level() -> void:
	for id in _tracked:
		TestingFloor.remove_object(id, "level_unloaded")
	_tracked.clear()
	_item_states.clear()
	_toppled.clear()
	_level = Context.level
	_phase = _enum_name(GameStatus.game_states, GameStatus.current_game_state)
	_gate_open = GameStatus.gate_opened
	_child_state = _enum_name(Pinda.character_states, Context.pinda.current_character_state)
	TestingFloor.reset_movement()
	_track_node("player", Context.chocomel, "chocomel")
	_track_node("companion", Context.pinda, "pinda")
	for key in Context.interactable_nodes:
		var node: Node = Context.interactable_nodes[key]
		if not is_instance_valid(node) or key in [Constants.interactable_ids.CHOCOMEL, Constants.interactable_ids.PINDA]:
			continue
		var id := _enum_name(Constants.interactable_ids, key)
		_track_node("collectible" if node is CollectableItem else "landmark", node, id)
		if node is CollectableItem:
			_item_states[key] = node.item_state
			node.item_state_changed.connect(_item_changed.bind(key))
	Context.chocomel.has_barked.connect(_barked)
	Context.chocomel.confirmed_interaction.connect(_dog_interaction)
	Context.chocomel.ended_interaction.connect(_interaction_ended)
	Context.pinda.call_for_help.connect(_help_requested)
	Context.pinda.entering_character_state.connect(_child_state_changed)
	Context.pinda.reached_point_of_interest.connect(_point_reached)
	_update_object_state()
	TestingFloor.track("level_loaded")

func _track_node(kind: String, node: Node3D, id: String) -> void:
	TestingFloor.track_node(kind, node, id)
	TestingFloor.set_object_state(id, "name", id.capitalize().replace("_", " "))
	_tracked.append(id)

func _phase_changed(new_phase: int, previous: int) -> void:
	if new_phase == previous:
		return
	_phase = _enum_name(GameStatus.game_states, new_phase)
	if not is_instance_valid(_level):
		return
	TestingFloor.reset_movement()
	if new_phase == GameStatus.game_states.INTRO:
		_run_started = Time.get_ticks_msec() / 1000.0
		TestingFloor.track("new_game_started")
	elif new_phase == GameStatus.game_states.GAMEPLAY and previous == GameStatus.game_states.LOADING:
		_run_started = Time.get_ticks_msec() / 1000.0
		TestingFloor.track("saved_game_continued")
	elif new_phase == GameStatus.game_states.ENDING:
		TestingFloor.track("level_completed")
	elif new_phase == GameStatus.game_states.MAIN_MENU:
		TestingFloor.track("returned_to_menu")
	TestingFloor.track("story_phase_changed", {"story.previous_phase": _enum_name(GameStatus.game_states, previous)})

func _item_changed(new_state: int, previous: int, key: int) -> void:
	_item_states[key] = new_state
	var id := _enum_name(Constants.interactable_ids, key)
	TestingFloor.set_object_state(id, "item.state", _enum_name(GameStatus.item_states, new_state))
	if new_state == previous or not _playing() or SaveManager.loading:
		return
	if new_state in [GameStatus.item_states.HELD, GameStatus.item_states.PLACED]:
		TestingFloor.track("item_picked_up" if new_state == GameStatus.item_states.HELD else "item_placed", {
			"item.id": id, "object.id": id, "item.previous_state": _enum_name(GameStatus.item_states, previous)})

func _barked() -> void:
	if _playing():
		TestingFloor.track("dog_barked")

func _dog_interaction(confirmed: bool) -> void:
	if confirmed and _playing():
		TestingFloor.track("interaction_started", {"interaction.type": _enum_name(Chocomel.interaction_types, Context.chocomel.current_interaction_type)})

func _interaction_ended() -> void:
	if _playing():
		TestingFloor.track("interaction_ended")

func _help_requested() -> void:
	if _playing():
		TestingFloor.track("child_help_requested")

func _child_state_changed(value: int) -> void:
	_child_state = _enum_name(Pinda.character_states, value)
	TestingFloor.set_object_state("pinda", "character.state", _enum_name(Pinda.character_states, value))
	if _playing() and value in [Pinda.character_states.STUCK, Pinda.character_states.GETTING_UP, Pinda.character_states.BREAK_DOWN]:
		TestingFloor.track({Pinda.character_states.STUCK: "child_stuck", Pinda.character_states.GETTING_UP: "child_getting_up",
			Pinda.character_states.BREAK_DOWN: "child_upset"}[value])

func _point_reached(key: int) -> void:
	if _playing():
		TestingFloor.track("point_of_interest_reached", {"object.id": _enum_name(Constants.interactable_ids, key)})

func _update_object_state() -> void:
	TestingFloor.set_object_state("pinda", "character.state", _enum_name(Pinda.character_states, Context.pinda.current_character_state))
	TestingFloor.set_object_state("pinda", "mood", snappedf(Context.pinda.mood, 0.1))
	TestingFloor.set_object_state("pinda", "stamina", snappedf(Context.pinda.stamina, 0.1))
	TestingFloor.set_object_state("chocomel", "character.state", _enum_name(Chocomel.character_states, Context.chocomel.current_character_state))
	TestingFloor.set_object_state("gate", "open", _gate_open)

func _context() -> Dictionary:
	return {"game_level.id": LEVEL_ID, "game_level.name": "Winter Forest", "story.phase": _phase,
		"run.elapsed_seconds": snappedf(maxf(0.0, Time.get_ticks_msec() / 1000.0 - _run_started), 0.1) if _run_started > 0 else 0.0}

func _activity() -> Dictionary:
	if not _playing() or not is_instance_valid(Context.chocomel):
		return {}
	var sample := {"player_position": Context.chocomel.global_position}
	var camera := get_viewport().get_camera_3d()
	if camera:
		sample["camera_position"] = camera.global_position
		sample["camera_rotation"] = camera.global_basis.get_rotation_quaternion()
		sample["camera_fov"] = camera.fov
	return sample

func _state() -> Dictionary:
	var values := {"game_level.id": LEVEL_ID, "game_level.name": "Winter Forest", "story.phase": _phase, "game.paused": _paused}
	var found := 0
	var placed := 0
	for key in _item_states:
		var value: int = _item_states[key]
		values["items." + _enum_name(Constants.interactable_ids, key)] = _enum_name(GameStatus.item_states, value)
		if value >= GameStatus.item_states.HELD:
			found += 1
		if value == GameStatus.item_states.PLACED:
			placed += 1
	values["items.found"] = found
	values["items.placed"] = placed
	values["gate.open"] = _gate_open
	if is_instance_valid(Context.pinda) and is_instance_valid(Context.chocomel):
		values["child.mood"] = snappedf(Context.pinda.mood, 0.1)
		values["child.stamina"] = snappedf(Context.pinda.stamina, 0.1)
		values["child.state"] = _child_state
		values["dog.state"] = _enum_name(Chocomel.character_states, Context.chocomel.current_character_state)
		values["leash.length"] = snappedf(Context.pinda.leash_length, 0.1)
		values["child.distance"] = snappedf(Context.pinda.global_position.distance_to(Context.chocomel.global_position), 0.1)
		values["dog.speed"] = snappedf(Context.chocomel.current_velocity.length(), 0.1)
	return values

func begin_save_load() -> void:
	_restoring_save = true
	_save_origin = Context.chocomel.global_position
	TestingFloor.reset_movement()

func end_save_load() -> void:
	_restoring_save = false
	TestingFloor.record_teleport(_save_origin, Context.chocomel.global_position, "save_loaded")
