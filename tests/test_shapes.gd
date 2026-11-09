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
	# A door stands on the floor, with nothing behind it.
	check(PlantSim.supported(w, "core:wood_door_e_lower", Vector3i(2, Y + 1, 2)), "a door on open floor stands")
	w.set_block(Vector3i(2, Y, 2), 0)
	check(not PlantSim.supported(w, "core:wood_door_e_lower", Vector3i(2, Y + 1, 2)), "not on air")


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


func test_bed_two_blocks() -> void:
	var top_hit := {"previous": Vector3i(0, 1, 0), "normal": Vector3i(0, 1, 0)}
	var p := BlockShapes.placement("core:bed", top_hit, Vector3(1, -0.5, 0), Vector3(0.5, 1, 0.5))
	check_eq(p, [[Vector3i(0, 1, 0), "core:bed_e_foot"], [Vector3i(1, 1, 0), "core:bed_e_head"]],
			"looking east: the foot here, the head one block east")
	p = BlockShapes.placement("core:bed", top_hit, Vector3(0, -0.5, -1), Vector3(0.5, 1, 0.5))
	check_eq(p[0][1], "core:bed", "the north-facing foot is the base block")
	check_eq(BlockShapes.other_part("core:bed_e_foot", Vector3i(0, 1, 0)), Vector3i(1, 1, 0), "foot -> head")
	check_eq(BlockShapes.other_part("core:bed_e_head", Vector3i(1, 1, 0)), Vector3i(0, 1, 0), "head -> foot")
	check_eq(BlockShapes.bed_head("core:bed_e_foot", Vector3i(0, 1, 0)), Vector3i(1, 1, 0), "you sleep on the head")
	check_eq(Registry.blocks["core:bed_s_head"].get("drops"), "core:bed", "the head drops a bed")
	check(Registry.blocks["core:bed_w_head"].get("bed", false), "both halves are beds")
	check_eq(Registry.blocks["core:bed_e_head"].texture_turns, 1, "the top turns with the bed")


func test_snow_layer() -> void:
	var w := await make_world()
	_floor(w, -2, 2, -2, 2)
	_put(w, Vector3i(0, Y + 1, 0), "core:snow")
	# Standing on it: 1/16 above the stone.
	var r: Dictionary = w.move_box(Vector3(0.5, Y + 2, 0.5), Vector3(0.6, 1.8, 0.6), Vector3(0, -1, 0))
	check(r.on_floor, "you stand on snow")
	check_near(r.position.y, Y + 1 + 1.0 / 16.0, 0.01, "a 1/16 layer")
	check(PlantSim.supported(w, "core:snow", Vector3i(0, Y + 1, 0)), "lies on stone")
	w.set_block(Vector3i(0, Y, 0), 0)
	check(not PlantSim.supported(w, "core:snow", Vector3i(0, Y + 1, 0)), "falls off without ground")
	check(Registry.blocks["core:snow"].get("replaceable", false), "placing a block replaces it")
	var hit := {"previous": Vector3i(0, Y + 1, 1), "normal": Vector3i(0, 1, 0)}
	check_eq(BlockShapes.placement("core:snow", hit, Vector3.FORWARD, Vector3())[0][1], "core:snow", "placeable")
	check_eq(load("res://src/player/player.gd").drops_of("core:snow", ""), ["core:snowball"], "breaking it gives a snowball")
	check(Registry.recipes.has("core:snow"), "two snowballs make a layer again")


func test_vanilla_peaks_have_snow() -> void:
	var w := await make_world(777, "", 64, Vector3(318.5, 45, -317.5))
	var snow := 0
	for x in range(310, 326):
		for z in range(-326, -310):
			var hit := w.raycast(Vector3(x + 0.5, 62, z + 0.5), Vector3.DOWN, 80)
			if hit.hit and Registry.block_ids[hit.block] == "core:snow":
				snow += 1
				check(Registry.block_ids[w.get_block(hit.position + Vector3i.DOWN)] != "core:air", "snow lies on something")
	check(snow > 20, "a peak is covered in snow (%d columns)" % snow)


## The outline around what you point at follows the block's shape.
func test_outline_follows_the_shape() -> void:
	var w := await make_world()
	_floor(w, -2, 2, -2, 2)
	_put(w, Vector3i(0, Y + 1, 0), "core:stone_slab")
	_put(w, Vector3i(1, Y + 1, 0), "core:snow")
	_put(w, Vector3i(-1, Y + 1, 0), "core:torch")
	check_eq(w.pick_boxes(Vector3i(0, Y, 0)), [AABB(Vector3.ZERO, Vector3.ONE)], "a cube: the whole block")
	check_eq(w.pick_boxes(Vector3i(0, Y + 1, 0)), [AABB(Vector3.ZERO, Vector3(1, 0.5, 1))], "a slab: its half")
	check_eq(w.pick_boxes(Vector3i(1, Y + 1, 0)), [AABB(Vector3.ZERO, Vector3(1, 1.0 / 16.0, 1))], "snow: 1/16")
	var torch: Array = w.pick_boxes(Vector3i(-1, Y + 1, 0))
	check(torch.size() == 1 and torch[0].size.x < 0.3 and torch[0].size.y < 1.0, "a torch: its stick (%s)" % [torch])
	check(w.pick_boxes(Vector3i(0, Y + 2, 0)).is_empty(), "air: nothing")
	var Player := load("res://src/player/player.gd")
	var mesh: ArrayMesh = Player.outline_mesh(w.pick_boxes(Vector3i(0, Y + 1, 0)))
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check_eq(verts.size(), 24, "12 edges per box")
	var top := -INF
	for v in verts:
		top = maxf(top, v.y)
	check_near(top, 0.502, 0.001, "drawn just above the slab's top")
