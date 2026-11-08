extends Node
func shot(path: String) -> void:
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
func _ready():
	var outdir: String = OS.get_cmdline_user_args()[0]
	get_node("/root/ModLoader").load_all()
	var reg = get_node("/root/Registry")
	# 1) generator speed, standalone
	reg.assign_block_ids()
	var g = load("res://src/world/graph_terrain_generator.gd").new(); g.setup(4242)
	for band in [["all y -64..64", range(-4, 4)], ["surface y -32..16", range(-2, 1)], ["deep y -64..-32", range(-4, -2)]]:
		var t := Time.get_ticks_usec(); var n := 0
		for bx in range(-8, 8):
			for by in band[1]:
				for bz in range(-8, 8):
					var b := VoxelBuffer.new(); b.create(16, 16, 16); g.generate_block(b, Vector3i(bx, by, bz) * 16, 0); n += 1
		print("GEN %s: %.3f ms/block" % [band[0], (Time.get_ticks_usec() - t) / 1000.0 / n])
	# 2) in game
	var game: Node = load("res://src/main.tscn").instantiate(); game.name = "Main"; game.world_name = "_gen"; game.new_seed = 4242
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	while game._loading != null: await get_tree().process_frame
	var p = game._player; p._frozen = true
	var t2: VoxelTool = game._world.get_tool(); t2.channel = VoxelBuffer.CHANNEL_TYPE
	var counts := {}
	for x in range(-64, 64, 4):
		for z in range(-64, 64, 4):
			for y in range(-40, 30):
				var id: String = reg.block_ids[t2.get_voxel(Vector3i(x, y, z))]
				counts[id] = counts.get(id, 0) + 1
	print("GEN block mix around spawn: ", counts)
	# aerial
	p.global_position = Vector3(-30, 40, 40); p.rotation.y = 0.0
	p.camera.look_at(Vector3(10, -4, -20))
	await shot(outdir + "/gen_aerial.png")
	# find a cave: air with solid above and below, well under the surface
	var cave := Vector3i.ZERO
	var found := false
	for x in range(-60, 60, 3):
		if found: break
		for z in range(-60, 60, 3):
			if found: break
			for y in range(-30, -6):
				var c := Vector3i(x, y, z)
				if t2.get_voxel(c) == reg.block_index("core:air") and t2.get_voxel(c + Vector3i(0, 1, 0)) == 0 and t2.get_voxel(c + Vector3i(0, 12, 0)) != 0 and t2.get_voxel(c + Vector3i(4, 0, 0)) == 0:
					cave = c; found = true; break
	print("GEN cave found: ", found, " at ", cave)
	if found:
		p.global_position = Vector3(cave) + Vector3(0.5, 0, 0.5); p.rotation.y = 0.0
		p.camera.look_at(Vector3(cave) + Vector3(6, 0.5, 0.5))
		await shot(outdir + "/gen_cave.png")
	get_tree().quit()
