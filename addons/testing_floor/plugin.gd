@tool
extends EditorPlugin
## Adds the TestingFloor autoload and its project settings when the plugin is enabled.

const AUTOLOAD := "TestingFloor"
const SETTINGS := [
	["write_key", TYPE_STRING, "", PROPERTY_HINT_NONE, ""],
	["endpoint", TYPE_STRING, "https://dataentry.testingfloor.com", PROPERTY_HINT_NONE, ""],
	["enabled", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["enable_in_editor", TYPE_BOOL, false, PROPERTY_HINT_NONE, ""],
	["enable_in_editor_while_recording", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["app_version", TYPE_STRING, "", PROPERTY_HINT_NONE, ""],
	["movement_tracking", TYPE_BOOL, false, PROPERTY_HINT_NONE, ""],
	["object_checks_per_second", TYPE_FLOAT, 4.0, PROPERTY_HINT_RANGE, "1,10,0.5"],
	["max_tracked_objects", TYPE_INT, 256, PROPERTY_HINT_RANGE, "0,4096"],
	["qr_heartbeats", TYPE_BOOL, false, PROPERTY_HINT_NONE, ""],
]


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/testing_floor/testing_floor.gd")
	for setting in SETTINGS:
		var name: String = "testing_floor/" + setting[0]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, setting[2])
		ProjectSettings.set_initial_value(name, setting[2])
		ProjectSettings.add_property_info({"name": name, "type": setting[1], "hint": setting[3], "hint_string": setting[4]})
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)
