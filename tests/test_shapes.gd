extends "res://tests/test_suite.gd"
## Block shapes: collision, placement variants, doors, raycasts.

const Y := 70  # open air above the terrain


func _put(w: World, p: Vector3i, id: String) -> void:
	check(w.set_block(p, Registry.block_index(id)), "placed " + id)


func _floor(w: World, x0: int, x1: int, z0: int, z1: int) -> void:
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			w.set_block(Vector3i(x, Y, z), Registry.block_index("core:stone"))


func test_variants_registered() -> void:
	for id in ["core:stone_slab_top", "core:planks_stairs_e", "core:torch_wall_s", "core:ladder_w",
			"core:wood_door_e_upper_open"]:
		check(Registry.blocks.has(id), id + " exists")
	check_eq(Registry.blocks["core:torch_wall_s"].variant_of, "core:torch", "variant knows its base")
	check_eq(load("res://src/player/player.gd").drop_of("core:planks_stairs_e"), "core:planks_stairs", "drops the base")
	check(not load("res://src/player/player.gd").is_placeable("core:torch_wall_n"), "variants aren't items")
	check(load("res://src/player/player.gd").is_placeable("core:torch"), "torches are placeable")


func test_slab_and_stairs_collision() -> void:
	var w := await make_world()
	_floor(w, -2, 2, -2, 2)
	_put(w, Vector3i(0, Y + 1, 0), "core:stone_slab")
	var r: Dictionary = w.move_box(Vector3(0.5, Y + 3, 0.5), Vector3(0.6, 1.8, 0.6), Vector3(0, -5, 0))
	check_near(r.position.y, Y + 1.5, 0.01, "stand on a bottom slab at half height")
	_put(w, Vector3i(1, Y + 1, 0), "core:stone_slab_top")
	r = w.move_box(Vector3(1.5, Y + 1.0, 0.5), Vector3(0.3, 0.4, 0.3), Vector3(0, 0, 0))
	check(w.is_box_free(Vector3(1.5, Y + 1.0, 0.5), Vector3(0.3, 0.45, 0.3)), "room under a top slab")
	_put(w, Vector3i(0, Y + 1, 2), "core:stone_stairs")  # high side to the north (-z)
	r = w.move_box(Vector3(0.5, Y + 3, 2.8), Vector3(0.3, 1.8, 0.3), Vector3(0, -5, 0))
	check_near(r.position.y, Y + 1.5, 0.01, "low step of the stairs")
	r = w.move_box(Vector3(0.5, Y + 3, 2.2), Vector3(0.3, 1.8, 0.3), Vector3(0, -5, 0))
	check_near(r.position.y, Y + 2.0, 0.01, "high step of the stairs")


func test_fence_torch_ladder_collision() -> void:
	var w := await make_world()
	_floor(w, -3, 3, -3, 3)
	_put(w, Vector3i(0, Y + 1, 0), "core:planks_fence")
	var r: Dictionary = w.move_box(Vector3(0.5, Y + 3.5, 0.5), Vector3(0.3, 1.8, 0.3), Vector3(0, -5, 0))
	check_near(r.position.y, Y + 2.5, 0.01, "fences are 1.5 blocks tall")
	_put(w, Vector3i(2, Y + 1, 0), "core:torch")
	check(w.is_box_free(Vector3(2.5, Y + 1, 0.5), Vector3(0.6, 1.8, 0.6)), "walk through torches")
	_put(w, Vector3i(-2, Y + 1, 0), "core:ladder")
	check(w.is_box_free(Vector3(-1.5, Y + 1, 0.5), Vector3(0.6, 1.8, 0.6)), "ladders don't block")


func test_door_open_close() -> void:
	var w := await make_world()
	_floor(w, -3, 3, -3, 3)
	_put(w, Vector3i(0, Y + 1, 0), "core:wood_door")
	_put(w, Vector3i(0, Y + 2, 0), "core:wood_door_n_upper")
	# Closed: a panel along the north edge blocks walking north through it.
	var r: Dictionary = w.move_box(Vector3(0.5, Y + 1, 1.5), Vector3(0.6, 1.8, 0.6), Vector3(0, 0, -2))
	check(r.hit_wall, "a closed door blocks")
	var toggle := BlockShapes.toggle_door("core:wood_door", Vector3i(0, Y + 1, 0))
	check_eq(toggle.size(), 2, "both halves change")
	for t in toggle:
		w.set_block(t[0], Registry.block_index(t[1]))
	check_eq(Registry.block_ids[w.get_block(Vector3i(0, Y + 2, 0))], "core:wood_door_n_upper_open", "upper half opened")
	r = w.move_box(Vector3(0.5, Y + 1, 1.5), Vector3(0.6, 1.8, 0.6), Vector3(0, 0, -2))
	check(not r.hit_wall, "an open door lets you through")


func test_placement_variants() -> void:
	var look_north := Vector3(0, 0, -1)
	var side_hit := {"previous": Vector3i(0, 0, 1), "normal": Vector3i(0, 0, 1)}
	check_eq(BlockShapes.placement("core:torch", side_hit, look_north, Vector3(0.5, 0.5, 1.0))[0][1],
			"core:torch_wall_n", "torch on a wall to the north")
	var top_hit := {"previous": Vector3i(0, 1, 0), "normal": Vector3i(0, 1, 0)}
	check_eq(BlockShapes.placement("core:torch", top_hit, look_north, Vector3(0.5, 1.0, 0.5))[0][1],
			"core:torch", "torch on the floor")
	var under_hit := {"previous": Vector3i(0, -1, 0), "normal": Vector3i(0, -1, 0)}
	check(BlockShapes.placement("core:torch", under_hit, look_north, Vector3(0.5, 0, 0.5)).is_empty(), "no ceiling torches")
	check_eq(BlockShapes.placement("core:stone_slab", side_hit, look_north, Vector3(0.5, 0.8, 1.0))[0][1],
			"core:stone_slab_top", "slab on the upper half of a side: top slab")
	check_eq(BlockShapes.placement("core:stone_stairs", top_hit, Vector3(1, -0.3, 0), Vector3())[0][1],
			"core:stone_stairs_e", "stairs face the way you look")
	var door := BlockShapes.placement("core:wood_door", top_hit, Vector3(0, 0, 1), Vector3())
	check_eq(door.size(), 2, "a door is two blocks")
	check_eq(door[1][1], "core:wood_door_s_upper", "upper half above")


func test_raycast_hits_shape_boxes() -> void:
	var w := await make_world()
	_floor(w, -3, 3, -3, 3)
	_put(w, Vector3i(0, Y + 1, 0), "core:stone_slab")
	# A ray over the slab (through its empty upper half) goes on to the block behind.
	_put(w, Vector3i(0, Y + 1, -2), "core:stone")
	var hit: Dictionary = w.raycast(Vector3(0.5, Y + 1.75, 2.5), Vector3(0, 0, -1), 10)
	check(hit.hit and hit.position == Vector3i(0, Y + 1, -2), "a ray passes above a bottom slab")
	hit = w.raycast(Vector3(0.5, Y + 3, 0.5), Vector3(0, -1, 0), 10)
	check(hit.hit and hit.position == Vector3i(0, Y + 1, 0), "hits the slab from above")
	check_near(hit.distance, 1.5, 0.01, "at its top surface")
	check_eq(hit.normal, Vector3i(0, 1, 0), "facing up")
