extends "res://tests/test_suite.gd"
## Biomes, legacy worlds, falling blocks, leaf decay, lava.

const Y := 70


func _legacy_world() -> World:
	# A world made before biomes: its meta has no "generator".
	var w := World.new()
	add(w)
	w.meta = {}
	Registry.assign_block_ids()
	w._make_engine(64, 4242, 1)
	w.add_child(w.engine)
	w.engine.start()
	w.set_viewer(Vector3(0.5, 20, 0.5))
	await wait_until(func(): return w.is_area_meshed(AABB(Vector3(-16, -20, -16), Vector3(32, 80, 32))))
	return w


func test_new_worlds_are_vanilla_with_mountains() -> void:
	var w := await make_world(777)
	check_eq(int(w.meta.generator), World.GENERATOR_VERSION, "new worlds use the newest generator")
	var seen := {}
	var highest := -999
	for r in range(0, 3000, 50):
		for a in range(0, 360, 30):
			var x := int(cos(deg_to_rad(a)) * r)
			var z := int(sin(deg_to_rad(a)) * r)
			seen[w.biome_name(x, z)] = true
			highest = maxi(highest, w.engine.generated_height(x, z))
	check_eq(seen.keys(), ["core:vanilla"], "only the vanilla biome")
	check(highest >= 30, "there are mountains (highest ground sampled: %d)" % highest)
	var unused = JSON.parse_string(FileAccess.get_file_as_string("res://mods/core/content/biomes_unused.json"))
	check(unused is Dictionary and unused.biomes.has_all(["plains", "forest", "desert", "snow"]),
			"plains, forest, desert and snow are kept in biomes_unused.json")
	check(not "content/biomes_unused.json" in ModLoader.mods[0].get("content", []), "and not loaded")


func test_legacy_worlds_keep_their_terrain() -> void:
	var w := await _legacy_world()
	check_eq(w.biome_name(0, 0), "", "no biomes")
	var plants := 0
	for x in range(-16, 16):
		for z in range(-16, 16):
			var hit := w.raycast(Vector3(x + 0.5, 100, z + 0.5), Vector3.DOWN, 200)
			if hit.hit and Registry.block_ids[hit.block] in ["core:tall_grass", "core:bluebell", "core:sunpetal"]:
				plants += 1
	check_eq(plants, 0, "no new plants in old worlds")


func test_sand_falls() -> void:
	var w := await make_world()
	var p := Vector3i(0, Y + 5, 0)
	w.set_block(Vector3i(0, Y, 0), Registry.block_index("core:stone"))
	w.set_block(p, Registry.block_index("core:sand"))
	for i in 10:
		w.plants._process(0.016)
	check_eq(w.get_block(p), 0, "sand left its spot")
	check_eq(Registry.block_ids[w.get_block(Vector3i(0, Y + 1, 0))], "core:sand", "and landed on the stone")


func test_leaves_decay_without_their_tree() -> void:
	var w := await make_world()
	var log_pos := Vector3i(0, Y, 0)
	w.set_block(log_pos, Registry.block_index("core:log"))
	var leaves := Registry.block_index("core:leaves")
	for x in range(-1, 2):
		w.set_block(log_pos + Vector3i(x, 1, 0), leaves)
	w.set_block(log_pos + Vector3i(3, 1, 0), Registry.block_index("core:leaves_placed"))
	w.set_block(log_pos + Vector3i(4, 1, 0), Registry.block_index("core:leaves_placed"))
	for i in 5:
		w.plants._process(1.0)
	check_eq(w.get_block(log_pos + Vector3i(1, 1, 0)), leaves, "leaves next to a log stay")
	w.set_block(log_pos, 0)  # chop the tree
	for i in 30:
		w.plants._process(0.5)
	for x in range(-1, 2):
		check_eq(w.get_block(log_pos + Vector3i(x, 1, 0)), 0, "leaves decay once the log is gone")
	check_eq(Registry.block_ids[w.get_block(log_pos + Vector3i(4, 1, 0))], "core:leaves_placed", "placed leaves stay")


func test_lava_meets_water() -> void:
	var w := await make_world()
	for x in range(-2, 3):
		for z in range(-2, 3):
			w.set_block(Vector3i(x, Y, z), Registry.block_index("core:stone"))
	w.set_block(Vector3i(0, Y + 1, 0), Registry.block_index("core:lava"))
	w.set_block(Vector3i(1, Y + 1, 0), Registry.block_index("core:water"))
	for i in 8:
		w.fluids._process(0.3)
	check_eq(Registry.block_ids[w.get_block(Vector3i(0, Y + 1, 0))], "core:stone", "a lava source next to water turns to stone")


## Lake water (above the sea) never stands next to open air, so it never
## hangs as a wall on a slope: lakes get a bank as high as their water.
func test_lakes_are_closed_in() -> void:
	var water := Registry.block_index("core:water")
	var cells := 0
	var open := []
	for seed_value in [4242, 777, 31337]:
		var w := await make_world(seed_value, "", 128, Vector3(0.5, 10, 0.5))
		# Unloaded chunks read as air: wait for everything scanned.
		check(await wait_until(func(): return w.is_area_meshed(AABB(Vector3(-56, -4, -56), Vector3(112, 48, 112)))),
				"the area loaded")
		for x in range(-56, 56):
			for z in range(-56, 56):
				for y in range(-3, 45):  # above the sea (level -4)
					var p := Vector3i(x, y, z)
					if w.get_block(p) != water:
						continue
					cells += 1
					for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i.DOWN]:
						if w.get_block(p + d) == 0:
							open.append(p)
		w.queue_free()
		await frames(2)
	check(cells > 50, "found lakes to check (%d water cells)" % cells)
	check(open.is_empty(), "%d lake water cells next to air, e.g. %s" % [open.size(), open.slice(0, 4)])
