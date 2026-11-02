extends Node
## Loads the ignored TestingFloor.local.json that tools/configure.py writes into
## the SDK's project settings. It is listed before the TestingFloor autoload, so
## the settings are in place when the SDK starts. This keeps the write key out of
## project.godot in this public example; a game can set testing_floor/write_key
## directly instead.

const PATH := "res://addons/testing_floor/TestingFloor.local.json"


func _ready() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not settings is Dictionary:
		return
	for key in ["write_key", "app_version", "enable_in_editor"]:
		if settings.has(key):
			ProjectSettings.set_setting("testing_floor/" + key, settings[key])
