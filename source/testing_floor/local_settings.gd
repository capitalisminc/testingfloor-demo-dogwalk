extends Node
## Sets the SDK's project settings for this example before it starts. It is
## listed before the TestingFloor autoload, so the settings are in place when the
## SDK reads them.
##
## It loads the ignored TestingFloor.local.json that tools/configure.py writes,
## which keeps the write key out of project.godot in this public example; a game
## can set testing_floor/write_key directly instead. A map capture
## (--tf-capture-map) collects nothing.

const PATH := "res://addons/testing_floor/TestingFloor.local.json"


func _ready() -> void:
	if "--tf-capture-map" in OS.get_cmdline_user_args():
		ProjectSettings.set_setting("testing_floor/enabled", false)
		return
	if not FileAccess.file_exists(PATH):
		return
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not settings is Dictionary:
		return
	for key in ["write_key", "app_version", "enable_in_editor"]:
		if settings.has(key):
			ProjectSettings.set_setting("testing_floor/" + key, settings[key])
