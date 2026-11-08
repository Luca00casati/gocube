extends Node
func shot(path: String) -> void:
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
func _ready():
	var outdir: String = OS.get_cmdline_user_args()[0]
	get_node("/root/ModLoader").load_all()
	var game: Node = load("res://src/main.tscn").instantiate(); game.name = "Main"; game.world_name = "_sky"; game.new_seed = 4242
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	while game._loading != null: await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout
	var p = game._player; p._frozen = true
	var w: World = game._world
	var reg = get_node("/root/Registry")
	var gen = w.terrain.generator
	# 1) a tree near spawn, from a little above and to the side
	var trees: Array = gen.trees_near(Rect2i(-40, -40, 80, 80))
	var tr: Dictionary = trees[0]
	for t in trees:
		if Vector2(t.x, t.z).length() < Vector2(tr.x, tr.z).length(): tr = t
	print("SKY tree at ", tr)
	p.global_position = Vector3(tr.x + 7, tr.ground + 3, tr.z + 9); p.rotation.y = 0.0
	p.camera.look_at(Vector3(tr.x, tr.ground + 1, tr.z))
	await shot(outdir + "/sky_tree.png")
	# 2) house: walls + roof placed via the same path as player edits
	var t: VoxelTool = w.get_tool(); t.channel = VoxelBuffer.CHANNEL_TYPE
	var f := Vector3i(tr.x + 12, gen.height_at(tr.x + 12, tr.z) + 1, tr.z)
	var cob: int = reg.block_index("core:planks")
	t.value = reg.block_index("core:stone"); t.do_box(f + Vector3i(-1, -4, -1), f + Vector3i(7, -1, 7))
	t.value = reg.block_index("core:grass"); t.do_box(f + Vector3i(-1, -1, -1), f + Vector3i(7, -1, 7))
	t.value = 0; t.do_box(f + Vector3i(-1, 0, -1), f + Vector3i(7, 8, 7))
	var placed := []
	for x in range(0, 7):
		for z in range(0, 7):
			for y in range(0, 5):
				var edge := x == 0 or x == 6 or z == 0 or z == 6
				var roof := y == 4
				var door := z == 6 and x == 3 and y < 2
				var window := x == 0 and z == 3 and y == 2
				if (edge or roof) and not door and not window:
					var pos := f + Vector3i(x, y, z)
					t.set_voxel(pos, cob); w.notify_edit(pos, cob); placed.append(pos)
	var inside := f + Vector3i(3, 0, 3)
	print("SKY column top inside house: %d (roof at y=%d) -> shadowed=%s" % [w.sky.get_top(Vector2i(inside.x, inside.z)), f.y + 4, inside.y < w.sky.get_top(Vector2i(inside.x, inside.z)) - 1])
	p.global_position = Vector3(f) + Vector3(5.5, 0, 5.2); p.rotation.y = 0.0
	p.camera.look_at(Vector3(f) + Vector3(1, 1.5, 1))
	await shot(outdir + "/sky_inside.png")
	p.global_position = Vector3(f) + Vector3(3.5, 1, 14); p.camera.look_at(Vector3(f) + Vector3(3.5, 2, 3))
	await shot(outdir + "/sky_outside.png")
	# 3) remove the roof -> column light returns
	for pos in placed:
		if pos.y == f.y + 4:
			t.set_voxel(pos, 0); w.notify_edit(pos, 0)
	print("SKY after removing roof, top inside: %d -> shadowed=%s" % [w.sky.get_top(Vector2i(inside.x, inside.z)), inside.y < w.sky.get_top(Vector2i(inside.x, inside.z)) - 1])
	p.global_position = Vector3(f) + Vector3(5.5, 0, 5.2); p.camera.look_at(Vector3(f) + Vector3(1, 1.5, 1))
	await shot(outdir + "/sky_noroof.png")
	print("SKY overrides saved: ", w.sky.serialize().size())
	get_tree().quit()
