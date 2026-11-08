extends Node
func shot(path: String) -> void:
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
func _ready():
	var outdir: String = OS.get_cmdline_user_args()[0]
	get_node("/root/ModLoader").load_all()
	var game: Node = load("res://src/main.tscn").instantiate(); game.name = "Main"; game.world_name = "_light"; game.new_seed = 4242
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	while game._loading != null: await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout
	var p = game._player
	var reg = get_node("/root/Registry")
	var t: VoxelTool = game._world.get_tool(); t.channel = VoxelBuffer.CHANNEL_TYPE
	var f := Vector3i(p.global_position.floor())
	# hollow cobblestone room in front of the player, doorway facing them
	t.value = reg.block_index("core:cobblestone"); t.do_box(f + Vector3i(-5, -1, -14), f + Vector3i(5, 6, -3))
	t.value = reg.block_index("core:air"); t.do_box(f + Vector3i(-4, 0, -13), f + Vector3i(4, 5, -4))
	t.do_box(f + Vector3i(0, 0, -3), f + Vector3i(0, 1, -3))  # doorway
	t.value = reg.block_index("core:crystal_ore"); t.do_point(f + Vector3i(-3, 0, -12))  # the "lamp"
	p._frozen = true
	await get_tree().create_timer(0.5).timeout
	var emit := {"core:crystal_ore": 14}
	for s in [32, 64]:
		var r := LightPrototype.relight(t, f - Vector3i(s / 2, s / 2, s / 2) + Vector3i(0, 0, -6), Vector3i(s, s, s), emit)
		print("LIGHT %d^3 (%d voxels): read %.0f ms, flood %.0f ms, write %.0f ms, total %.0f ms" % [s, s * s * s, r.read, r.flood, r.write, r.total])
	# inside, looking at the lamp corner
	p.global_position = Vector3(f) + Vector3(3.5, 0.0, -5.0)
	p.rotation.y = 0.0
	p.camera.look_at(Vector3(f) + Vector3(-3, 0.5, -12))
	await shot(outdir + "/inside.png")
	# outside, looking at the doorway
	p.global_position = Vector3(f) + Vector3(0.5, 0.5, 4.0)
	p.camera.rotation = Vector3.ZERO
	p.camera.look_at(Vector3(f) + Vector3(0.5, 1.5, -3))
	await shot(outdir + "/outside.png")
	get_tree().quit()
