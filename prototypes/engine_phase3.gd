extends Node3D
## Phase-3 test of the native engine on stock Godot: sky light and block light.
##   godot4 res://prototypes/engine_phase3.tscn -- <output dir>

var world: GoCubeWorld
var cam: Camera3D
var out_dir := ""


func _ready() -> void:
	ModLoader.load_all()
	var args := OS.get_cmdline_user_args()
	out_dir = args[0] if not args.is_empty() else ""
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.sky.radiance_size = Sky.RADIANCE_SIZE_32
	add_child(env)
	cam = Camera3D.new()
	cam.far = 500
	add_child(cam)

	var atlas := BlockAtlas.new()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/engine/chunk.gdshader")
	mat.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(atlas.atlas))
	var water := ShaderMaterial.new()
	water.shader = load("res://src/engine/chunk_fluid.gdshader")
	world = GoCubeWorld.new()
	world.configure_blocks(atlas.block_table)
	world.set_atlas_layout(atlas.cols, atlas.rows, BlockAtlas.CELL, BlockAtlas.FACE_OFFSET)
	world.set_materials(mat, water)
	var ids := {}
	for k in ["stone", "dirt", "grass", "sand", "water", "log", "leaves"]:
		ids[k] = Registry.block_index("core:" + k)
	world.configure_generator(4242, ids)
	world.view_distance = 128
	world.viewer_position = Vector3(0, 20, 0)
	add_child(world)
	world.start()
	_run()


func _settle() -> float:
	var t0 := Time.get_ticks_usec()
	await get_tree().process_frame
	while world.get_stats().pending_remesh > 0 or world.get_stats().pending_uploads > 0 or world.get_stats().queued_jobs > 0:
		await get_tree().process_frame
	return (Time.get_ticks_usec() - t0) / 1000.0


func _shot(name: String) -> void:
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	if out_dir != "":
		get_viewport().get_texture().get_image().save_png(out_dir.path_join(name))


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	while not world.is_area_meshed(AABB(Vector3(-64, -32, -64), Vector3(128, 64, 128))):
		await get_tree().process_frame
	print("P3 spawn area lit+meshed in %d ms" % (Time.get_ticks_msec() - t0))
	await _settle()
	var s: Dictionary = world.get_stats()
	print("P3 per 32^3 chunk: generate %.2f ms, light+mesh %.2f ms (light %.2f ms)" % [s.generate_ms_avg, s.mesh_ms_avg, s.light_ms_avg])

	# Room with a doorway and a lamp, on a flattened pad.
	var ground: int = world.raycast(Vector3(40.5, 90, 40.5), Vector3.DOWN, 200).position.y
	var f := Vector3i(36, ground + 1, 36)
	var planks := Registry.block_index("core:planks")
	_box(f + Vector3i(-2, -3, -2), f + Vector3i(10, -1, 10), Registry.block_index("core:stone"))
	_box(f + Vector3i(-2, 0, -2), f + Vector3i(10, 10, 10), 0)
	for x in range(0, 9):
		for z in range(0, 9):
			for y in range(0, 6):
				var wall := x == 0 or x == 8 or z == 0 or z == 8
				var door := z == 8 and x == 4 and y < 3
				if (wall or y == 5) and not door:
					world.set_block(f + Vector3i(x, y, z), planks)
	world.set_block(f + Vector3i(2, 0, 2), Registry.block_index("core:lamp"))
	var ms := await _settle()
	print("P3 room built (%d blocks) and relit in %.0f ms" % [9 * 9 + 4 * 8 * 5, ms])

	cam.position = Vector3(f) + Vector3(6.5, 1.6, 6.5)
	cam.look_at(Vector3(f) + Vector3(2.5, 0.5, 2.5))
	await _shot("p3_room_inside.png")
	cam.position = Vector3(f) + Vector3(4.5, 3, 16)
	cam.look_at(Vector3(f) + Vector3(4.5, 1.5, 8))
	await _shot("p3_room_outside.png")

	# Relight timing: a roof over open ground (changes column sky exposure).
	var t := Time.get_ticks_usec()
	world.set_block(f + Vector3i(-1, 3, 4), planks)
	ms = await _settle()
	print("P3 single block placed above open ground: relit and visible in %.1f ms" % ms)

	# A cave: air below the surface with rock above, looking along it.
	var cave := Vector3i.ZERO
	# Search outward from spawn so the cave isn't at the edge of the loaded area.
	var spots: Array[Vector2i] = []
	for x in range(-48, 49, 3):
		for z in range(-48, 49, 3):
			spots.append(Vector2i(x, z))
	spots.sort_custom(func(a, b): return a.length_squared() < b.length_squared())
	for spot in spots:
		var x := spot.x
		var z := spot.y
		if true:
			if cave != Vector3i.ZERO:
				break
			var top: Dictionary = world.raycast(Vector3(x + 0.5, 90, z + 0.5), Vector3.DOWN, 200)
			if not top.hit:
				continue
			for y in range(top.position.y - 8, -50, -1):
				var c := Vector3i(x, y, z)
				if world.get_block(c) == 0 and world.get_block(c + Vector3i(0, -1, 0)) != 0 \
						and world.get_block(c + Vector3i(4, 0, 0)) == 0:
					cave = c
					break
	print("P3 cave at ", cave)
	if cave != Vector3i.ZERO:
		cam.position = Vector3(cave) + Vector3(0.5, 1.0, 0.5)
		cam.look_at(Vector3(cave) + Vector3(5, 0.8, 0.5))
		await _shot("p3_cave.png")
	cam.position = Vector3(-20, 45, 60)
	cam.look_at(Vector3(20, 0, 0))
	await _shot("p3_landscape.png")
	get_tree().quit()


func _box(a: Vector3i, b: Vector3i, id: int) -> void:
	for x in range(a.x, b.x + 1):
		for y in range(a.y, b.y + 1):
			for z in range(a.z, b.z + 1):
				world.set_block(Vector3i(x, y, z), id)
