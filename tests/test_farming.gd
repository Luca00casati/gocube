extends "res://tests/test_suite.gd"
## Tool tiers, armour, farming, plants and support.

const Player := preload("res://src/player/player.gd")
const Y := 70


func test_tool_tiers() -> void:
	check_eq(Player.drop_of("core:iron_ore", "core:wood_pickaxe"), "", "iron ore needs a stone pickaxe")
	check_eq(Player.drop_of("core:iron_ore", "core:stone_pickaxe"), "core:iron_ore", "stone pickaxe gets iron ore")
	check_eq(Player.drop_of("core:gold_ore", "core:stone_pickaxe"), "", "gold needs iron")
	check_eq(Player.drop_of("core:crystal_ore", "core:iron_pickaxe"), "core:crystal_ore", "iron pickaxe gets crystal")
	check(Player.mine_seconds("core:stone", "core:iron_pickaxe") < Player.mine_seconds("core:stone", "core:stone_pickaxe"),
			"iron mines faster than stone")
	check(Player.attack_damage("core:iron_sword") > Player.attack_damage(""), "swords hit harder than hands")


func test_armour() -> void:
	var inv := Inventory.new()
	check_eq(inv.put_armor("head", {"id": "core:iron_boots", "count": 1}), {"id": "core:iron_boots", "count": 1},
			"boots don't go on your head")
	for piece in [["head", "helmet"], ["chest", "chestplate"], ["legs", "leggings"], ["feet", "boots"]]:
		check(inv.put_armor(piece[0], {"id": "core:iron_" + piece[1], "count": 1}).is_empty(), "wear " + piece[1])
	check_eq(inv.armor_points(), 15, "full iron armour")
	var data: Array = JSON.parse_string(JSON.stringify(inv.serialize()))
	var back := Inventory.new()
	back.deserialize(data)
	check_eq(back.armor_points(), 15, "armour is saved")


func test_armour_reduces_mob_damage() -> void:
	var w := await make_world()
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, 80, 0.5)
	add(p)
	for piece in [["head", "helmet"], ["chest", "chestplate"], ["legs", "leggings"], ["feet", "boots"]]:
		p.inventory.put_armor(piece[0], {"id": "core:iron_" + piece[1], "count": 1})
	p.damage(10, "mob")
	check_eq(p.health, 16, "15 armour points take 60% off")
	p.damage(3)
	check_eq(p.health, 13, "falls ignore armour")


func test_crops_grow_and_pop() -> void:
	var w := await make_world()
	var base := Vector3i(0, Y, 0)
	w.set_block(base, Registry.block_index("core:farmland"))
	w.set_block(base + Vector3i.UP, Registry.block_index("core:wheat_0"))
	check_eq(w.plants.growing_count(), 1, "a planted crop is tracked")
	for i in 8:  # fast-forward every stage
		for pos in w.plants._growing:
			w.plants._growing[pos] = 0.0
		w.plants._process(1.0)
	check_eq(Registry.block_ids[w.get_block(base + Vector3i.UP)], "core:wheat_7", "grown to ripe wheat")
	check_eq(w.plants.growing_count(), 0, "ripe wheat stops growing")
	var popped := []
	w.plants.popped.connect(func(_p, items): popped.append_array(items))
	w.set_block(base, Registry.block_index("core:dirt"))
	w.plants._process(0.0)
	check_eq(w.get_block(base + Vector3i.UP), 0, "wheat needs farmland under it")
	check_eq(popped, [["core:wheat", 1]], "and drops when it pops off")


func test_torch_falls_with_its_wall() -> void:
	var w := await make_world()
	var wall := Vector3i(0, Y, 0)
	w.set_block(wall, Registry.block_index("core:stone"))
	w.set_block(wall + Vector3i(0, 0, 1), Registry.block_index("core:torch_wall_n"))
	check(PlantSim.supported(w, "core:torch_wall_n", wall + Vector3i(0, 0, 1)), "held by the wall")
	check(not PlantSim.supported(w, "core:torch_wall_s", wall + Vector3i(0, 0, 1)), "nothing on the other side")
	w.set_block(wall, 0)
	w.plants._process(0.0)
	check_eq(w.get_block(wall + Vector3i(0, 0, 1)), 0, "the torch falls off")


func test_tall_grass_drops() -> void:
	var seeds := 0
	for i in 400:
		seeds += Player.drops_of("core:tall_grass").count("core:seeds")
	check(seeds > 30 and seeds < 100, "tall grass sometimes gives seeds (%d / 400)" % seeds)
	var ripe := Player.drops_of("core:wheat_7")
	check(ripe.has("core:wheat") and ripe.count("core:seeds") >= 1, "ripe wheat gives wheat and seeds")
