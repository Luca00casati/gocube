extends Node3D
## Phase-2 test of the native engine on stock Godot: raycast, block edits,
## box-vs-voxel collision and saving/loading edited chunks.
##   godot4 res://prototypes/engine_phase2.tscn -- <screenshot.png>

const SAVE_DIR := "user://_engine_test/chunks"
const BODY := Vector3(0.6, 1.8, 0.6)

var world: GoCubeWorld
var cam: Camera3D


func _ready() -> void:
	ModLoader.load_all()
	_clear_save_dir()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.sky.radiance_size = Sky.RADIANCE_SIZE_32
	add_child(env)
	cam = Camera3D.new()
	add_child(cam)
	_run()


func _make_world() -> GoCubeWorld:
	var atlas := BlockAtlas.new()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/engine/chunk.gdshader")
	mat.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(atlas.atlas))
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.25, 0.46, 0.84, 0.7)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var w := GoCubeWorld.new()
	w.configure_blocks(atlas.block_table)
	w.set_atlas_layout(atlas.cols, atlas.rows, BlockAtlas.CELL, BlockAtlas.FACE_OFFSET)
	w.set_materials(mat, water)
	var ids := {}
	for k in ["stone", "dirt", "grass", "sand", "water", "log", "leaves"]:
		ids[k] = Registry.block_index("core:" + k)
	w.configure_generator(4242, ids)
	w.set_save_directory(ProjectSettings.globalize_path(SAVE_DIR))
	w.view_distance = 96
	w.viewer_position = Vector3(0, 20, 0)
	add_child(w)
	w.start()
	return w


func _wait_loaded(w: GoCubeWorld) -> int:
	var t0 := Time.get_ticks_msec()
	while not w.is_area_meshed(AABB(Vector3(-48, -32, -48), Vector3(96, 64, 96))):
		await get_tree().process_frame
	return Time.get_ticks_msec() - t0


func _run() -> void:
	world = _make_world()
	print("P2 loaded in %d ms" % await _wait_loaded(world))
	var planks := Registry.block_index("core:planks")

	# 1) Raycast straight down onto the terrain.
	var hit: Dictionary = world.raycast(Vector3(8.5, 80, 8.5), Vector3.DOWN, 200)
	print("P2 raycast down at (8,8): hit=%s block=%s at %s normal=%s" % [hit.hit,
			Registry.block_ids[hit.block] if hit.hit else "-", hit.get("position"), hit.get("normal")])
	var ground: int = hit.position.y

	# 2) Edit: a plank tower; measure how long until it is remeshed.
	var base := Vector3i(8, ground + 1, 8)
	var t0 := Time.get_ticks_usec()
	for y in 6:
		world.set_block(base + Vector3i(0, y, 0), planks)
	var frames := 0
	while world.get_stats().pending_remesh > 0 or world.get_stats().pending_uploads > 0:
		await get_tree().process_frame
		frames += 1
	await get_tree().process_frame
	print("P2 6 edits remeshed and visible after %.1f ms (%d frames); get_block=%s" % [
			(Time.get_ticks_usec() - t0) / 1000.0, frames + 1, Registry.block_ids[world.get_block(base + Vector3i(0, 5, 0))]])

	# 3) Drop a body from the sky beside the tower: it should land on the ground.
	var col := Vector3i(12, 0, 8)
	var top: int = world.raycast(Vector3(col.x + 0.5, 80, col.z + 0.5), Vector3.DOWN, 200).position.y
	var pos := Vector3(col.x + 0.5, top + 20, col.z + 0.5)
	var vel := Vector3.ZERO
	var on_floor := false
	for i in 240:  # 4 s at 60 Hz
		vel.y = maxf(vel.y - 28.0 / 60.0, -60.0)
		var r: Dictionary = world.move_box(pos, BODY, vel / 60.0, 0.0)
		pos = r.position
		on_floor = r.on_floor
		if on_floor:
			vel.y = 0.0
	print("P2 falling body: feet y=%.3f, ground top=%d -> landed=%s" % [pos.y, top + 1, on_floor and absf(pos.y - (top + 1)) < 0.01])

	# 4) Walls: flatten a test strip, then a 2-high wall blocks and a 1-high step is climbed (step 1.0).
	var f := Vector3i(20, ground + 1, 20)
	_box(Vector3i(f.x - 1, f.y - 1, f.z - 1), Vector3i(f.x + 12, f.y - 1, f.z + 1), Registry.block_index("core:stone"))
	_box(Vector3i(f.x - 1, f.y, f.z - 1), Vector3i(f.x + 12, f.y + 4, f.z + 1), 0)
	_box(Vector3i(f.x + 4, f.y, f.z - 1), Vector3i(f.x + 4, f.y + 1, f.z + 1), Registry.block_index("core:cobblestone"))
	_box(Vector3i(f.x + 9, f.y, f.z - 1), Vector3i(f.x + 9, f.y, f.z + 1), Registry.block_index("core:cobblestone"))
	for step_h in [0.0, 1.0]:
		var p := Vector3(f.x + 0.5, f.y, f.z + 0.5)
		for i in 300:
			p = world.move_box(p, BODY, Vector3(2.0 / 60.0, -0.3, 0), step_h).position
		print("P2 walking +x with step_height %.0f: stopped at x=%.2f (2-high wall face at %d, 1-high step at %d, end of strip %d)" % [
				step_h, p.x, f.x + 4, f.x + 9, f.x + 12])
	# Past the 2-high wall: walk into the 1-high step and stop on top of it.
	var p2 := Vector3(f.x + 7.5, f.y, f.z + 0.5)
	var top_y := p2.y
	for i in 60:  # 1 s: about 2 blocks, ends standing on the step
		p2 = world.move_box(p2, BODY, Vector3(2.0 / 60.0, -0.3, 0), 1.0).position
		top_y = maxf(top_y, p2.y)
	print("P2 walking into the 1-high step (x=%d) with step 1.0: x=%.2f, feet y=%.2f (floor %d) -> climbed=%s" % [
			f.x + 9, p2.x, top_y, f.y, top_y >= f.y + 0.99 and p2.x > f.x + 9])

	# 5) Speed.
	var t := Time.get_ticks_usec()
	for i in 1000:
		world.move_box(Vector3(10.5 + (i % 20), ground + 3, 10.5), BODY, Vector3(0.03, -0.3, 0.02), 1.0)
	print("P2 1000 move_box calls: %.2f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	for i in 1000:
		world.raycast(Vector3(0.5, ground + 2, 0.5), Vector3(cos(i * 0.1), -0.3, sin(i * 0.1)), 6.0)
	print("P2 1000 raycasts (6 blocks): %.2f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	print("P2 unloaded area is solid: %s" % (not world.is_box_free(Vector3(5000, 0, 5000), BODY)))

	# Screenshot of the tower and test strip.
	cam.position = Vector3(16, ground + 8, 22)
	cam.look_at(Vector3(14, ground + 2, 14))
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		get_viewport().get_texture().get_image().save_png(args[0])

	# 6) Save, throw the world away, load it again from disk.
	print("P2 saved %d edited chunks; files: %s" % [world.save_modified(), DirAccess.get_files_at(SAVE_DIR)])
	world.queue_free()
	await get_tree().process_frame
	world = _make_world()
	await _wait_loaded(world)
	var still := true
	for y in 6:
		still = still and world.get_block(base + Vector3i(0, y, 0)) == planks
	print("P2 after reload from disk: tower intact=%s, wall intact=%s" % [still,
			world.get_block(Vector3i(f.x + 4, f.y + 1, f.z)) == Registry.block_index("core:cobblestone")])
	_clear_save_dir()
	get_tree().quit()


func _box(a: Vector3i, b: Vector3i, id: int) -> void:
	for x in range(a.x, b.x + 1):
		for y in range(a.y, b.y + 1):
			for z in range(a.z, b.z + 1):
				world.set_block(Vector3i(x, y, z), id)


func _clear_save_dir() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	for file in DirAccess.get_files_at(SAVE_DIR):
		DirAccess.remove_absolute(SAVE_DIR.path_join(file))
