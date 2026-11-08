extends "res://tests/test_suite.gd"

const Player := preload("res://src/player/player.gd")


func _pos(w: World) -> Vector3i:
	return Vector3i(4, w.raycast(Vector3(4.5, 100, 4.5), Vector3.DOWN, 300).position.y + 1, 4)


func test_chest_stores_and_spills() -> void:
	var w := await make_world()
	var pos := _pos(w)
	w.set_block(pos, Registry.block_index("core:chest"))
	check(w.block_entities.has_entity(pos), "placing a chest creates its storage")
	check_eq(w.block_entities.get_entity(pos).slots.size(), BlockEntities.CHEST_SLOTS, "27 slots")
	var held := w.block_entities.click(pos, 3, {"id": "core:coal", "count": 5})
	check(held.is_empty(), "put 5 coal in")
	held = w.block_entities.click(pos, 3, {"id": "core:coal", "count": 2})
	check_eq(w.block_entities.get_entity(pos).slots[3].count, 7, "same item stacks")
	var spilled := []
	w.block_entities.spilled.connect(func(_p, items): spilled.append_array(items))
	w.set_block(pos, 0)
	check(not w.block_entities.has_entity(pos), "breaking removes the storage")
	check_eq(spilled, [["core:coal", 7]], "contents spill out")


func test_furnace_smelts_with_fuel() -> void:
	var w := await make_world()
	var pos := _pos(w)
	w.set_block(pos, Registry.block_index("core:furnace"))
	var be := w.block_entities
	be.click(pos, BlockEntities.FURNACE_INPUT, {"id": "core:iron_ore", "count": 2})
	check_eq(be.click(pos, BlockEntities.FURNACE_FUEL, {"id": "core:dirt", "count": 1}), {"id": "core:dirt", "count": 1},
			"dirt isn't fuel")
	be.click(pos, BlockEntities.FURNACE_FUEL, {"id": "core:coal", "count": 1})
	var e := be.get_entity(pos)
	for i in 24:  # 6 s in 0.25 s steps
		be._tick_furnace(pos, e, 0.25)
	check_eq(e.slots[BlockEntities.FURNACE_OUTPUT], {"id": "core:iron_ingot", "count": 1}, "one ingot after 5+ s")
	check_eq(e.slots[BlockEntities.FURNACE_INPUT].count, 1, "one ore used")
	check(e.burn > 0.0, "coal still burning")
	check_eq(be.click(pos, BlockEntities.FURNACE_OUTPUT, {"id": "core:stone", "count": 1}), {"id": "core:stone", "count": 1},
			"nothing can be put into the output")


func test_containers_saved_with_the_world() -> void:
	var w := await make_world()
	var pos := _pos(w)
	w.set_block(pos, Registry.block_index("core:chest"))
	w.block_entities.click(pos, 0, {"id": "core:gold_ingot", "count": 3})
	var data := w.block_entities.serialize()
	var other := BlockEntities.new()
	other.deserialize(JSON.parse_string(JSON.stringify(data)))  # as if through world.json
	check_eq(other.get_entity(pos).slots[0], {"id": "core:gold_ingot", "count": 3}, "contents come back")
	other.free()


func test_dropped_item_is_picked_up() -> void:
	var w := await make_world()
	var ground: int = w.raycast(Vector3(0.5, 100, 0.5), Vector3.DOWN, 300).position.y
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, ground + 1, 0.5)
	add(p)
	p.set_ready_to_move()
	p._frozen = true
	var drop := ItemDrop.new()
	drop.setup("core:coal", 3, null)
	drop.world = w
	drop.player = p
	add(drop)
	drop.global_position = Vector3(2.0, ground + 1.5, 0.5)
	check(await wait_until(func(): return p.inventory.count_of("core:coal") == 3, 5), "picked up 3 coal")
	check(not is_instance_valid(drop) or drop.is_queued_for_deletion(), "the drop is gone")
