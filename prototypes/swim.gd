extends Node
func _ready():
	var out: String = OS.get_cmdline_user_args()[0]
	get_node("/root/ModLoader").load_all()
	var game: Node = load("res://src/main.tscn").instantiate(); game.name = "Main"; game.world_name = "_gen"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	while game._loading != null: await get_tree().process_frame
	var p = game._player
	var reg = get_node("/root/Registry")
	var t: VoxelTool = game._world.get_tool(); t.channel = VoxelBuffer.CHANNEL_TYPE
	# find open water at least 3 deep near spawn
	var spot := Vector3i.ZERO
	for x in range(-60, 60, 2):
		for z in range(-60, 60, 2):
			if t.get_voxel(Vector3i(x, -4, z)) == reg.block_index("core:water") and t.get_voxel(Vector3i(x, -6, z)) == reg.block_index("core:water"):
				spot = Vector3i(x, -4, z); break
		if spot != Vector3i.ZERO: break
	p.global_position = Vector3(spot) + Vector3(0.5, 3.0, 0.5)
	await get_tree().create_timer(3.0).timeout
	print("SWIM after dropping in: feet y=%.2f (sea surface y=-3), in_water=%s, vy=%.2f" % [p.global_position.y, p.in_water, p.velocity.y])
	var e := InputEventKey.new(); e.keycode = KEY_SPACE; e.physical_keycode = KEY_SPACE; e.pressed = true; Input.parse_input_event(e)
	var y0: float = p.global_position.y
	await get_tree().create_timer(1.0).timeout
	print("SWIM holding Space 1 s: rose %.2f m" % [p.global_position.y - y0])
	e.pressed = false; Input.parse_input_event(e)
	p.camera.rotation.x = -0.15
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()
