extends Control

enum menu_states {MAIN, SETTINGS}

var paused := false
var state := menu_states.MAIN

@export var continue_button : BaseButton
@export var save_button : BaseButton
@export var load_button : BaseButton
@export var main_menu_button : BaseButton
@export var settings_button : BaseButton
@export var quit_button : BaseButton

@export var pause_screen : Control
@export var pause_menu : Control
var settings_menu : Control

func _ready():
	paused = false
	hide()
	init_buttons()

func _process(delta: float) -> void:
	if SaveManager.can_save:
		quit_button.text = "Save & Quit"
	else:
		quit_button.text = "Quit"

func init_buttons():
	continue_button.pressed.connect(_on_continue_button_pressed)
	save_button.pressed.connect(_on_save_button_pressed)
	load_button.pressed.connect(_on_load_button_pressed)
	main_menu_button.pressed.connect(_on_main_menu_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)

func _input(event: InputEvent) -> void:
	if GameStatus.current_game_state in [GameStatus.game_states.MAIN_MENU, GameStatus.game_states.LOADING]:
		return
	if state != menu_states.MAIN:
		return
	if event.is_action('Pause'):
		if not event.is_pressed():
			if paused:
				_on_continue_button_pressed()
			else:
				_on_pause_button_pressed()

func _on_pause_button_pressed():
	pause()

func pause() -> void:
	get_tree().paused = true
	paused = true
	show()
	Context.background_elements_ui.pause.show()
	
	continue_button.call_deferred("grab_focus")
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	state = menu_states.MAIN
	Context.audio_manager.set_lowpass_filter(true)
	Context.audio_manager.ui_sound_manager.connect_ui_sounds_in(self)

func unpause() -> void:
	get_tree().paused = false
	paused = false
	hide()
	Context.background_elements_ui.pause.hide()
	
	if settings_menu:
		settings_menu.exit_settings()
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	# check for pinda being stuck
	if Context.pinda.current_character_state == Pinda.character_states.STUCK and Context.pinda.terrain_detector.current_terrain_state == Constants.terrain_states.SNOW:
		print("PINDA IS STILL IN THE SNOW")
		return # keep the audio lowpass filter on
	
	Context.audio_manager.set_lowpass_filter(false, 0)
	

func _on_continue_button_pressed():
	unpause()
	
func _on_save_button_pressed():
	SaveManager.save_game()
	
func _on_load_button_pressed():
	SaveManager.load_game()

func _on_main_menu_button_pressed():
	unpause()
	
	GameStatus.reset_state()
	(func ():
		get_tree().reload_current_scene()
		Context.menu_ui.main_menu.enter_main_menu()
	).call_deferred()
	
func _on_quit_button_pressed():
	if GameStatus.current_game_state == GameStatus.game_states.GAMEPLAY:
		SaveManager.save_game()
		var save_sound = Context.audio_manager.ui_sound_manager.save_sound
		save_sound.play()
		await get_tree().create_timer(save_sound.stream.get_length() + .01).timeout
		
	TestingFloor.quit_game()
	
func _on_settings_button_pressed():
	if state == menu_states.SETTINGS:
		settings_menu.exit_settings()
	else:
		state = menu_states.SETTINGS
		settings_menu = preload("res://source/user_interface/menus/settings_menu.tscn").instantiate()
		pause_screen.add_child(settings_menu)
		settings_menu.owner = self
		settings_menu.parent_menu = self
		Context.audio_manager.ui_sound_manager.connect_ui_sounds_in(settings_menu)
