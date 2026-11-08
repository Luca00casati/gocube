extends "res://tests/test_suite.gd"


func test_add_stacks_and_overflow() -> void:
	var inv := Inventory.new()
	check_eq(inv.add("core:dirt", 100), 0, "100 dirt fit")
	check_eq(inv.slots[0], {"id": "core:dirt", "count": 64}, "first stack is full")
	check_eq(inv.slots[1], {"id": "core:dirt", "count": 36}, "rest in the next slot")
	inv.add("core:dirt", 10)
	check_eq(inv.slots[1].count, 46, "tops up the existing stack first")
	check_eq(inv.add("core:stone", 64 * 40), 64 * 40 - 64 * 34, "overflow returned when full")


func test_remove_take_and_put() -> void:
	var inv := Inventory.new()
	inv.add("core:planks", 5)
	check(not inv.remove("core:planks", 6), "can't remove more than there is")
	check(inv.remove("core:planks", 2), "remove 2")
	check_eq(inv.count_of("core:planks"), 3, "3 left")
	check_eq(inv.take_one(0), "core:planks", "take one from the hotbar slot")
	check_eq(inv.count_of("core:planks"), 2, "2 left")
	var held := inv.put(5, {"id": "core:planks", "count": 3})
	check(held.is_empty(), "put into an empty slot")
	held = inv.put(0, {"id": "core:stone", "count": 1})
	check_eq(held, {"id": "core:planks", "count": 2}, "different items swap")


func test_serialize_round_trip_drops_unknown_items() -> void:
	var inv := Inventory.new()
	inv.add("core:lamp", 3)
	var data := inv.serialize()
	data[4] = ["gone:thing", 2]
	var back := Inventory.new()
	back.deserialize(data)
	check_eq(back.count_of("core:lamp"), 3, "known items come back")
	check(back.slots[4].is_empty(), "items from removed mods are dropped")


func test_crafting() -> void:
	var recipes := Crafting.hand_recipes()
	var by_id := {}
	for r in recipes:
		by_id[r.id] = r
	check(by_id.has("core:log_to_planks"), "shapeless recipe listed")
	check(by_id.has("core:planks_to_sticks"), "shaped recipe listed")
	check(not by_id.has("core:stone_from_cobblestone"), "smelting isn't hand-craftable")
	check_eq(by_id["core:planks_to_sticks"].ingredients, {"core:planks": 2}, "shaped pattern counted")
	var inv := Inventory.new()
	inv.add("core:log", 1)
	check(not Crafting.can_craft(by_id["core:planks_to_sticks"], inv), "no planks yet")
	check(Crafting.craft(by_id["core:log_to_planks"], inv), "log -> planks")
	check_eq(inv.count_of("core:planks"), 4, "4 planks")
	check_eq(inv.count_of("core:log"), 0, "log used up")
	check(Crafting.craft(by_id["core:planks_to_sticks"], inv), "planks -> sticks")
	check_eq(inv.count_of("core:stick"), 4, "4 sticks")
	check_eq(inv.count_of("core:planks"), 2, "2 planks left")


func test_mining_rules() -> void:
	var Player := load("res://src/player/player.gd")
	check_eq(Player.drop_of("core:stone"), "core:cobblestone", "stone drops cobblestone")
	check_eq(Player.drop_of("core:grass"), "core:dirt", "grass drops dirt")
	check_eq(Player.drop_of("core:log"), "core:log", "blocks without 'drops' drop themselves")
	check_near(Player.mine_seconds("core:stone"), 1.125, 0.001, "stone: hardness 1.5 x 0.75 s")
	check(Player.mine_seconds("core:leaves") >= 0.1, "minimum mining time")
	check(Player.is_placeable("core:planks") and not Player.is_placeable("core:water")
			and not Player.is_placeable("core:stick"), "only solid blocks are placeable")
