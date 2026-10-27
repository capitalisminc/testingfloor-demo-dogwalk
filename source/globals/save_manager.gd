extends Node

var can_save : bool = true:
	get():
		if not GameStatus.current_game_state == GameStatus.game_states.GAMEPLAY:
			return false
		if Context.sequence_gate:
			if Context.sequence_gate.active_sequence:
				return false
		if Context.pinda.current_character_state == Context.pinda.character_states.INTERACTION:
			return false
		return true

var TransitionScreen = preload("res://source/user_interface/transition_screen.tscn")
var transition_screen = null

var loading := false
var loading_target : Node3D

const save_interval := 5.
var save_timer : float = save_interval

func _ready() -> void:
	SignalBus.trigger_auto_save.connect(auto_save)

func _physics_process(delta: float) -> void:
	if loading:
		nudge_pinda(delta)

func _process(delta: float) -> void:
	if can_save:
		save_timer -= delta
	if save_timer < 0.:
		save_timer = save_interval
		auto_save()

func auto_save():
	if not Settings.auto_save:
		return
	save_game()

# Note: This can be called from anywhere inside the tree. This function is
# path independent.
# Go through everything in the persist category and ask them to return a
# dict of relevant variables.
func save_game(key = "0"):
	if not can_save:
		return
	var save_file = FileAccess.open("user://savegame_"+key+".save", FileAccess.WRITE)
	var save_nodes = get_tree().get_nodes_in_group("Persist")
	for node in save_nodes:
		# Check the node has a save function.
		if !node.has_method("save_state"):
			print("persistent node '%s' is missing a save_state() function, skipped" % node.name)
			continue

		# Call the node's save function.
		var node_data = node.call("save_state")

		# JSON provides a static method to serialized JSON string.
		var json_string = JSON.stringify(node_data, "", false, true)

		# Store the save dictionary as a new line in the save file.
		save_file.store_line(json_string)

# Note: This can be called from anywhere inside the tree. This function
# is path independent.
func load_game_fade(key = "0"):
	InputController.bypass_controls = true
	transition_screen = TransitionScreen.instantiate()
	get_tree().current_scene.add_child(transition_screen)
	
	transition_screen.connect("screen_covered", load_game_fade_back)
	transition_screen.wait_time = 2.

func nudge_pinda(delta):
	Context.pinda.current_point_of_interest = loading_target
	Context.pinda.velocity = (loading_target.global_position - Context.pinda.global_position) / .5
	Context.pinda.move_and_slide()
	
func load_game_fade_back(key = "0"):
	load_game(key)
	
	loading = true
	loading_target = Node3D.new()
	loading_target.global_position = Context.chocomel.global_position + Vector3.FORWARD * 1.5 + Vector3.RIGHT * 2.
	self.add_child(loading_target)
	
	var timer = Timer.new()
	timer.connect("timeout", fade_back)
	timer.wait_time = 2.
	timer.one_shot = true
	add_child(timer)
	timer.start()

func fade_back():
	loading = false
	Context.pinda.reset_point_of_interest()
	Context.pinda.force_next_character_state(
		Context.pinda.character_states.CATCHING_UP,
		Context.pinda.animation_states.REGULAR
	)
	loading_target.queue_free()
	
	## make sure pinda notices item that's already in proximity
	Context.pinda.find_child("InterestDetector").reset_intersection()
	
	transition_screen.resume()
	InputController.bypass_controls = false
	GameStatus.current_game_state = GameStatus.game_states.GAMEPLAY

func load_game(key = "0"):
	# TODO: fade to white and use a timer to let the state reset properly (while stats are locked) before resuming gemaplay
	if not FileAccess.file_exists("user://savegame_"+key+".save"):
		push_error("Save game with key '"+key+"' not found")
		return # Error! We don't have a save to load.

	# Load the file line by line and process that dictionary to restore
	# the object it represents.
	DogwalkTelemetry.begin_save_load()
	var save_file = FileAccess.open("user://savegame_"+key+".save", FileAccess.READ)
	while save_file.get_position() < save_file.get_length():
		var json_string = save_file.get_line()

		# Creates the helper class to interact with JSON.
		var json = JSON.new()

		# Check if there is any error while parsing the JSON string, skip in case of failure.
		var parse_result = json.parse(json_string)
		if not parse_result == OK:
			print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
			continue

		# Get the data from the JSON object.
		var node_data = json.data
		var node = get_node(node_data["node"])
		if "pos_x" in node_data.keys():
			node.position.x = node_data["pos_x"]
			node.position.y = node_data["pos_y"]
			node.position.z = node_data["pos_z"]
		
		if node.has_method('load_state'):
			node.load_state(node_data)
		else:
			# Now we set the remaining variables.
			for i in node_data.keys():
				if i == "filename" or i == "parent" or i == "position":
					continue
				node.set(i, node_data[i])
	
	GameStatus.init_load()
	DogwalkTelemetry.end_save_load()

func save_exists(key = "0"):
	return FileAccess.file_exists("user://savegame_"+key+".save")
