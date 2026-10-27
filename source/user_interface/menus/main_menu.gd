extends Control

enum menu_states {MAIN, SETTINGS}

var state := menu_states.MAIN:
	get():
		return state
	set(value):
		if state == value:
			return
		settings_dummy.visible = value == menu_states.MAIN
		state = value

@export var continue_button : BaseButton
@export var new_game_button : BaseButton
@export var settings_button : BaseButton
@export var quit_button : BaseButton

var title_prop : Node3D

@export var main_screen : Control
@export var main_menu : Control
var settings_menu : Control

@export var transition_timer : Timer
var title_transforms : Transform3D
var letter_bones

var settings_dummy : Node

var block_ui_input := false

var Intro = preload("res://source/sequences/intro.gd")
var intro : Intro

func _ready():
	call_deferred("init_camera")
	init_buttons()
	
	settings_dummy = find_child("SettingsDummy")
	
	intro = Intro.new()
	self.add_child(intro)
	intro.owner = self
	
	title_prop = get_tree().current_scene.find_child("PR-logo")
	
	transition_timer.timeout.connect(start_gameplay)
	title_transforms = title_prop.global_transform
	
	enter_main_menu()

func _process(delta: float) -> void:
	transition_game()

func _input(event: InputEvent) -> void:
	if block_ui_input:
		for action in ["ui_left", "ui_right", "ui_up", "ui_down", "ui_accept", "ui_select", "ui_cancel"]:
			if event.is_action(action):
				get_viewport().set_input_as_handled()
				return

func init_camera():
	var reference_camera = Context.level.find_child("MenuCamera")
	var camera_start_transform : Transform3D = reference_camera.global_transform
	
	# Init Camera
	Context.camera.current_camera_state = Context.camera.camera_states.DIRECTED
	Context.camera.global_transform = camera_start_transform
	Context.camera.camera3D.fov = reference_camera.fov

func init_buttons():
	continue_button.pressed.connect(_on_continue_button_pressed)
	new_game_button.pressed.connect(_on_new_game_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	state = menu_states.MAIN

func start_gameplay():
	block_ui_input = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Context.camera.current_camera_state = Context.camera.camera_states.FOLLOW
	if settings_menu:
		settings_menu.exit_settings()
		Context.background_elements_ui.settings.modulate = Color(1,1,1,1)
	hide()
	title_prop.queue_free()

func transition_game():
	if transition_timer.is_stopped():
		return
	var progress := 1. - (transition_timer.time_left / transition_timer.wait_time)
	
	title_prop.scale = title_transforms.basis.get_scale() * (1. - pow(progress, 2.))
	title_prop.position += Vector3.UP * progress * 1.
	self.modulate = Color(1,1,1, 1 - progress)
	Context.background_elements_ui.settings.modulate = Color(1,1,1, 1 - progress)
	

func enter_main_menu():
	show()
	block_ui_input = false
	self.modulate = Color(1,1,1,1)
	
	var hide_continue = !SaveManager.save_exists()
	continue_button.disabled = hide_continue
	continue_button.focus_mode = Control.FOCUS_NONE if hide_continue else Control.FOCUS_ALL
	
	init_focus()
	
	GameStatus.current_game_state = GameStatus.game_states.MAIN_MENU
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	InputController.reset_movement_input()
	
	GameStatus.init_state.call_deferred()
	GameStatus.reset_state.call_deferred()
	

func init_focus():
	if continue_button.disabled:
		new_game_button.call_deferred("grab_focus")
	else:
		continue_button.call_deferred("grab_focus")

func fade_to_new_game():
	block_ui_input = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	Context.camera.current_camera_state = Context.camera.camera_states.FOLLOW
	intro.start()
	transition_timer.start()

func fade_to_continue():
	SaveManager.load_game_fade()
	SaveManager.transition_screen.screen_covered.connect(continue_game)

func continue_game():
	intro.stop()
	start_gameplay()

func fade_to_main_menu():
	enter_main_menu()

func _on_continue_button_pressed():
	fade_to_continue()
	GameStatus.current_game_state = GameStatus.game_states.LOADING
	
func _on_new_game_button_pressed():
	fade_to_new_game()
	
func _on_quit_button_pressed():
	TestingFloor.quit_game()
	
func _on_settings_button_pressed():
	toggle_settings()

func toggle_settings() -> void:
	if state == menu_states.SETTINGS:
		settings_menu.exit_settings()
	else:
		state = menu_states.SETTINGS
		settings_menu = preload("res://source/user_interface/menus/settings_menu.tscn").instantiate()
		main_screen.add_child(settings_menu)
	
		Context.audio_manager.ui_sound_manager.call_deferred("connect_ui_sounds_in", settings_menu)
		
		settings_menu.owner = self
		settings_dummy.hide()
		settings_menu.parent_menu = self


func _on_credits_button_pressed() -> void:
	Context.sequence_credits = preload("res://source/sequences/credits/credits.tscn").instantiate()
	Context.menu_ui.find_child("CreditsDummy").add_child(Context.sequence_credits)
