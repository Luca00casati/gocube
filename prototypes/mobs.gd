extends Node
func _ready():
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_node("/root/ModLoader").load_all()
	var game: Node = load("res://src/main.tscn").instantiate(); game.name = "Main"; game.world_name = "_gen"
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	while game._loading != null: await get_tree().process_frame
	var p = game._player; p._frozen = true
	p.global_position = Vector3(0, 30, 0); p.camera.look_at(Vector3(0, 0, -20))
	var t: VoxelTool = game._world.get_tool()
	var mobs := []
	var rng := RandomNumberGenerator.new(); rng.seed = 1
	for target in [0, 50, 100, 200, 400, 800]:
		while mobs.size() < target:
			var x := rng.randi_range(-40, 40); var z := rng.randi_range(-40, 40)
			var hit := t.raycast(Vector3(x + 0.5, 40, z + 0.5), Vector3.DOWN, 80)
			if hit == null: continue
			var m: Node3D
			if OS.get_cmdline_user_args().has("voxel"):
				m = VoxelWanderer.new(); m.terrain = game._world.terrain
			else:
				m = Wanderer.new()
			m.position = Vector3(hit.position) + Vector3(0.5, 1.05, 0.5)
			game._world.add_child(m); mobs.append(m)
		await get_tree().create_timer(1.5).timeout  # settle
		var frames := 0; var phys := 0.0; var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 5000:
			await get_tree().process_frame
			frames += 1; phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var fps := frames / ((Time.get_ticks_msec() - start) / 1000.0)
		var fell := mobs.filter(func(m): return m.global_position.y < -40).size()
		print("MOBS %3d: %.1f FPS (%.1f ms/frame), physics %.2f ms/frame, fell out of world: %d" % [target, fps, 1000.0 / fps, phys / frames, fell])
	get_tree().quit()
