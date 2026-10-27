extends Node

@onready var root: Window = get_tree().root

func _ready() -> void:
	_capture.call_deferred()

func _capture() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("Map capture needs the normal renderer. Run with --audio-driver Dummy, not --headless.")
		get_tree().quit(1)
		return
	for frame in range(30):
		await get_tree().process_frame
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(640, 360))
	var context := root.get_node("Context")
	var points: Array[Vector3] = []
	for node in context.interactable_nodes.values():
		if is_instance_valid(node) and node is Node3D:
			points.append(node.global_position)
	if points.is_empty():
		push_error("No landmarks found for map bounds.")
		get_tree().quit(1)
		return
	var low := points[0]
	var high := low
	for point in points:
		low = low.min(point)
		high = high.max(point)
	var center := (low + high) / 2.0
	var span := maxf(high.x - low.x, high.z - low.z) + 40.0
	var viewport := SubViewport.new()
	viewport.size = Vector2i(2048, 2048)
	viewport.world_3d = root.world_3d
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = span
	camera.near = 0.1
	camera.far = 800.0
	camera.position = Vector3(center.x, high.y + 200.0, center.z)
	camera.look_at(Vector3(center.x, low.y, center.z), Vector3(0, 0, 1))
	camera.current = true
	for frame in range(90):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.flip_x()
	var output := ProjectSettings.globalize_path("res://Artifacts/maps")
	DirAccess.make_dir_recursive_absolute(output)
	image.save_png(output.path_join("dogwalk_world.png"))
	var manifest := {"organizationId": "example-studio", "gameId": "37", "appVersion": "dogwalk-tf-0.1.0", "maps": [{
		"levelId": "dogwalk_world", "image": "dogwalk_world.png", "variantKey": "overhead", "defaultVariant": true,
		"horizontalAxis": "x", "verticalAxis": "z", "worldUnitsPerMeter": 1,
		"bounds": {"centerX": center.x, "centerZ": center.z, "sizeX": span, "sizeZ": span}}]}
	var file := FileAccess.open(output.path_join("testingfloor-maps.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "  ") + "\n")
	file.close()
	print("Captured map: ", JSON.stringify(manifest))
	get_tree().quit()
