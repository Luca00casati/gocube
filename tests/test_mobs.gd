extends "res://tests/test_suite.gd"


func _manager(w: World) -> MobManager:
	var m := MobManager.new()
	m.world = w
	m.process_mode = Node.PROCESS_MODE_DISABLED  # step it by hand
	add(m)
	return m


func _ground(w: World, x: int, z: int) -> int:
	return w.raycast(Vector3(x + 0.5, 100, z + 0.5), Vector3.DOWN, 300).position.y


func test_mob_walks_on_the_ground() -> void:
	var w := await make_world()
	var m := _manager(w)
	var g := _ground(w, 0, 0)
	var mob := m.spawn_at(Vector3(0.5, g + 3, 0.5))  # dropped from a little height
	for i in 600:  # 10 s
		mob.simulate(1.0 / 60.0)
	check(w.is_box_free(mob.global_position, BlockEater.BOX), "never inside blocks")
	var under := w.get_block(Vector3i((mob.global_position + Vector3(0, -0.05, 0)).floor()))
	check(under != 0, "standing on something")
	check(not w.is_fluid(under), "not in water")


func test_hits_make_it_flee_and_kill_it() -> void:
	var w := await make_world()
	var m := _manager(w)
	var g := _ground(w, 0, 0)
	var mob := m.spawn_at(Vector3(0.5, g + 1, 0.5))
	var drops := []
	m.killed.connect(func(_at, attacker, items): drops.append([attacker, items]))
	m.hit(mob.id, mob.global_position + Vector3(2, 0, 0), 0)
	check_eq(mob._state, "flee", "runs off when hit")
	check_eq(m.count(), 1, "one hit doesn't kill")
	m.hit(mob.id, Vector3.ZERO, 0)
	m.hit(mob.id, Vector3.ZERO, 7)
	check_eq(m.count(), 0, "three hits kill")
	check_eq(drops.size(), 1, "killed once")
	check_eq(drops[0][0], 7, "the last attacker gets the drop")
	check_eq(drops[0][1][0][0], "core:hide", "drops hide")


func test_pick_under_crosshair() -> void:
	var w := await make_world()
	var m := _manager(w)
	var mob := m.spawn_at(Vector3(10.5, 50, 0.5))
	var p := m.pick(Vector3(7, 50.5, 0.5), Vector3.RIGHT, 4.0)
	check_eq(p.get("id"), mob.id, "ray hits the creature")
	check(m.pick(Vector3(7, 50.5, 0.5), Vector3.LEFT, 4.0).is_empty(), "looking away misses")
	check(m.pick(Vector3(0, 50.5, 0.5), Vector3.RIGHT, 4.0).is_empty(), "too far")


func test_client_mirrors_host_states() -> void:
	var w := await make_world()
	var host := _manager(w)
	host.spawn_at(Vector3(3.5, 60, 3.5))
	host.spawn_at(Vector3(5.5, 60, 3.5))
	var client := _manager(w)
	client.apply_states(host.states())
	check_eq(client.count(), 2, "client shows both")
	host.hit(1, Vector3.ZERO, 0)
	host.hit(1, Vector3.ZERO, 0)
	host.hit(1, Vector3.ZERO, 0)
	client.apply_states(host.states())
	check_eq(client.count(), 1, "removed when the host's is gone")


func test_block_variants() -> void:
	var w := await make_world()
	var m := _manager(w)
	var v := m.variants()
	check("core:stone" in v and "core:lamp" in v and "core:planks" in v, "solid blocks have a Block Eater")
	check(not ("core:air" in v or "core:water" in v or "core:water_3" in v), "air and water don't")
	check("core:chest" in v and "core:furnace" in v, "chests and furnaces have one too")
	var counts := {}
	for i in 20000:
		var k := m.random_variant()
		counts[k] = counts.get(k, 0) + 1
	check(counts.get("core:crystal_ore", 0) * 8 < counts.get("core:dirt", 0), "crystal ore ones are rare")
	check(counts.get("core:coal_ore", 0) < counts.get("core:dirt", 0), "coal ore ones are less common than dirt")
	check(counts.get("core:chest", 0) * 3 < counts.get("core:dirt", 0), "chest ones are rare")
	var regular := 0
	for i in 400:
		if m.random_variant() == "":
			regular += 1
	check(regular > 250 and regular < 350, "the regular one is the most common (%d / 400)" % regular)
	var mob := m.spawn_at(Vector3(0.5, 60, 0.5), "core:gold_ore")
	check_eq(mob.display_name(), "Gold Ore Block Eater", "named after its block")
	var drops := []
	m.killed.connect(func(_at, _a, items): drops.append_array(items))
	for i in 3:
		m.hit(mob.id, Vector3.ZERO, 0)
	check_eq(drops, [["core:gold_ore", 1]], "drops its block")
	var client := _manager(w)
	m.spawn_at(Vector3(3.5, 60, 0.5), "core:log")
	client.apply_states(m.states())
	check_eq(client.mobs()[0].variant, "core:log", "variant reaches clients")
