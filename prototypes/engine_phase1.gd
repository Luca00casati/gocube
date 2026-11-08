extends Node3D
## Phase-1 test of the native engine on stock Godot (no voxel module):
## streams the world around a camera that flies forward, measures load time,
## frame times and engine stats, and saves a screenshot.
##   godot4 res://prototypes/engine_phase1.tscn -- <screenshot.png>

const FLY_SPEED := 20.0
const RUN_SECONDS := 20.0

var world: GoCubeWorld
var cam: Camera3D
var _flying := false


func _ready() -> void:
	ModLoader.load_all()
	var atlas := BlockAtlas.new()

	var terrain_mat := ShaderMaterial.new()
	terrain_mat.shader = load("res://src/engine/chunk.gdshader")
	terrain_mat.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(atlas.atlas))
	var water_mat := StandardMaterial3D.new()
	water_mat.albedo_color = Color(0.25, 0.46, 0.84, 0.7)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	world = GoCubeWorld.new()
	world.configure_blocks(atlas.block_table)
	world.set_atlas_layout(atlas.cols, atlas.rows, BlockAtlas.CELL, BlockAtlas.FACE_OFFSET)
	world.set_materials(terrain_mat, water_mat)
	var ids := {}
	for k in ["stone", "dirt", "grass", "sand", "water", "log", "leaves"]:
		ids[k] = Registry.block_index("core:" + k)
	world.configure_generator(4242, ids)
	world.view_distance = 128
	add_child(world)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.sky.radiance_size = Sky.RADIANCE_SIZE_32
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	add_child(sun)

	cam = Camera3D.new()
	cam.position = Vector3(0, 40, 0)
	cam.rotation_degrees = Vector3(-15, 0, 0)
	cam.far = 600
	add_child(cam)
	world.viewer_position = cam.position
	world.start()
	_run()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var spawn := AABB(Vector3(-64, -32, -64), Vector3(128, 64, 128))
	while not world.is_area_meshed(spawn):
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > 30000:
			print("ENGINE spawn area not meshed after 30 s: ", world.get_stats())
			break
	print("ENGINE spawn area (128x64x128) meshed in %d ms; stats %s" % [Time.get_ticks_msec() - t0, world.get_stats()])

	_flying = true
	var frames := 0
	var worst := 0.0
	var hitches := 0
	var start := Time.get_ticks_msec()
	var last := start
	while Time.get_ticks_msec() - start < RUN_SECONDS * 1000:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		worst = maxf(worst, now - last)
		if now - last > 33:
			hitches += 1
		last = now
		frames += 1
	var secs := (Time.get_ticks_msec() - start) / 1000.0
	print("ENGINE fly %.0f s: avg %.1f FPS, worst frame %d ms, frames over 33 ms: %d" % [secs, frames / secs, worst, hitches])
	print("ENGINE final stats: ", world.get_stats())
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(args[0])
	get_tree().quit()


func _process(delta: float) -> void:
	if _flying:
		cam.position += Vector3(0, 0, -FLY_SPEED * delta)
		world.viewer_position = cam.position
