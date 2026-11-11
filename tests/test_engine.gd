extends "res://tests/test_suite.gd"
## The native engine (GoCubeWorld) through World.

const BODY := Vector3(0.6, 1.8, 0.6)


func _surface(w: World, x: int, z: int) -> int:
	return w.raycast(Vector3(x + 0.5, 100, z + 0.5), Vector3.DOWN, 300).position.y


func test_generation_is_deterministic() -> void:
	var a := await make_world(777)
	var samples := []
	for i in 40:
		samples.append(a.get_block(Vector3i(i * 3 - 60, (i % 7) * 5 - 20, i * 2 - 40)))
	a.queue_free()
	await frames(2)
	var b := await make_world(777)
	var same := true
	for i in 40:
		same = same and b.get_block(Vector3i(i * 3 - 60, (i % 7) * 5 - 20, i * 2 - 40)) == samples[i]
	check(same, "same seed -> same blocks")
	check(samples.any(func(v): return v != 0) and samples.any(func(v): return v == 0), "samples hit both air and blocks")


func test_raycast_edit_and_unloaded() -> void:
	var w := await make_world()
	var hit := w.raycast(Vector3(0.5, 100, 0.5), Vector3.DOWN, 300)
	check(hit.hit, "raycast down hits the ground")
	check_eq(hit.normal, Vector3i(0, 1, 0), "hit the top face")
	var above: Vector3i = hit.previous
	check(w.set_block(above, Registry.block_index("core:planks")), "set_block on loaded chunk")
	check_eq(w.get_block(above), Registry.block_index("core:planks"), "get_block sees the edit")
	check(not w.set_block(Vector3i(5000, 0, 5000), 1), "set_block on unloaded chunk fails")
	check(not w.raycast(Vector3(0.5, 100, 0.5), Vector3.UP, 50).hit, "nothing above the sky")


func test_box_collision() -> void:
	var w := await make_world()
	var top := _surface(w, 4, 4)
	var pos := Vector3(4.5, top + 15, 4.5)
	var vel := Vector3.ZERO
	var landed := false
	for i in 240:
		vel.y = maxf(vel.y - 28.0 / 60.0, -60.0)
		var r: Dictionary = w.move_box(pos, BODY, vel / 60.0)
		pos = r.position
		if r.on_floor:
			vel.y = 0.0
			landed = true
	check(landed, "falling body lands")
	check_near(pos.y, top + 1, 0.01, "feet rest on the ground")
	# A 1-high platform blocks without step-up and is climbed with step_height 1.
	var f := Vector3i(8, top + 1, 8)
	for x in range(f.x - 1, f.x + 10):
		w.set_block(Vector3i(x, f.y - 1, f.z), Registry.block_index("core:stone"))
		for y in range(0, 4):
			w.set_block(Vector3i(x, f.y + y, f.z), 0)
	for x in range(f.x + 3, f.x + 9):
		w.set_block(Vector3i(x, f.y, f.z), Registry.block_index("core:stone"))
	var p := Vector3(f.x + 0.5, f.y, f.z + 0.5)
	for i in 90:  # 3 blocks of walking: reaches the platform edge at f.x + 3
		p = w.move_box(p, BODY, Vector3(2.0 / 60.0, -0.3, 0), 0.0).position
	check_near(p.x, f.x + 2.7, 0.01, "blocked by the step without step-up")
	for i in 60:
		p = w.move_box(p, BODY, Vector3(2.0 / 60.0, -0.3, 0), 1.0).position
	check(p.x > f.x + 4 and p.y >= f.y + 0.99, "climbed the 1-high step (x=%.2f y=%.2f)" % [p.x, p.y])
	check(not w.is_box_free(Vector3(5000, 0, 5000), BODY), "unloaded space is solid")


func test_chunk_bytes_round_trip() -> void:
	var a := await make_world(11)
	var pos := Vector3i(3, _surface(a, 3, 3) + 1, 3)
	a.set_block(pos, Registry.block_index("core:lamp"))
	var chunk := World.chunk_of(pos)
	var bytes := a.chunk_bytes(chunk)
	check(not bytes.is_empty(), "chunk encodes")
	check(a.edited_chunks().has(chunk), "edited chunk listed for multiplayer")
	a.queue_free()
	await frames(2)
	var b := await make_world(11)
	check(b.get_block(pos) != Registry.block_index("core:lamp"), "fresh world doesn't have the lamp")
	b.set_chunk(chunk, bytes)
	check_eq(b.get_block(pos), Registry.block_index("core:lamp"), "chunk data applied")


func test_ores_generate_deep() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, -50, 0.5))
	var counts := {}
	for x in range(-16, 16):
		for z in range(-16, 16):
			for y in range(-90, -20, 2):
				var name: String = Registry.block_ids[w.get_block(Vector3i(x, y, z))]
				if name.ends_with("_ore"):
					counts[name] = counts.get(name, 0) + 1
	check(counts.get("core:coal_ore", 0) > 0, "coal generates (%s)" % counts)
	check(counts.get("core:iron_ore", 0) > 0, "iron generates (%s)" % counts)


func test_mod_defined_ore_generates() -> void:
	# As if a mod registered an ore made of lamps: lots of small veins.
	Registry.ores["test:lamp_ore"] = {"block": "core:lamp", "min_y": -90, "max_y": 30,
			"veins_per_chunk": 40, "size": [3, 5], "mod": "test", "id": "test:lamp_ore"}
	var w := await make_world(4242, "", 64, Vector3(0.5, -30, 0.5))
	Registry.ores.erase("test:lamp_ore")
	var lamps := 0
	for x in range(-16, 16):
		for z in range(-16, 16):
			for y in range(-60, 0, 2):
				if w.get_block(Vector3i(x, y, z)) == Registry.block_index("core:lamp"):
					lamps += 1
	check(lamps > 20, "a registered ore appears underground (%d found)" % lamps)


func test_trees_come_from_the_registry() -> void:
	check(Registry.trees.has("core:oak"), "core registers its tree as data")
	var w := await make_world()
	var logs := 0
	for x in range(-24, 24):
		for z in range(-24, 24):
			for y in range(-4, 30):
				if w.get_block(Vector3i(x, y, z)) == Registry.block_index("core:log"):
					logs += 1
	check(logs > 0, "trees generate (%d log blocks)" % logs)


func test_leaving_and_coming_back_quickly() -> void:
	var w := await make_world(4242, "_test_reload")  # deleted by the test runner afterwards
	var spot := Vector3i(3, _surface(w, 3, 3) + 1, 3)
	check(w.set_block(spot, Registry.block_index("core:planks")), "edit near the start")
	# Back and forth faster than chunks can load: work queued for the old visits
	# is dropped, and results for an earlier visit don't replace newer ones.
	for i in 6:
		w.set_viewer(Vector3(3000.5 * (1 if i % 2 == 0 else -1), 20, 0.5))
		await frames(2)
		w.set_viewer(Vector3(0.5, 20, 0.5))
		await frames(2)
	var stats: Dictionary = w.engine.get_stats()
	check(int(stats.queued_jobs) <= int(stats.chunks) * 2,
			"no pile of work for areas we left (%d jobs, %d chunks)" % [stats.queued_jobs, stats.chunks])
	var area := AABB(Vector3(-16, -20, -16), Vector3(32, 80, 32))
	check(await wait_until(func(): return w.is_area_meshed(area)), "loaded again")
	check_eq(w.get_block(spot), Registry.block_index("core:planks"), "the edit survived")
	w.queue_free()


## Things that aren't terrain (creatures, players, items, the hand) are lit by
## where they are, like the terrain: dark at night, bright by a held torch or
## a placed lamp.
func test_light_for_creatures_and_items() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	w.sky_light = Color(0.012, 0.014, 0.02)  # night
	var open := Vector3(0.5, 71, 0.5)
	var dark: Color = w.light_for(open)
	check(dark.r < 0.05, "at night, out in the open: dark (%.3f)" % dark.r)
	w.set_hand_lights([Vector4(1.5, 71.5, 0.5, 13.0)])  # someone holding a torch a block away
	var by_torch: Color = w.light_for(open)
	check(by_torch.r > 0.4, "next to a held torch: bright (%.2f)" % by_torch.r)
	check(by_torch.r > by_torch.b, "in its warm colour")
	check(w.light_for(Vector3(20.5, 71, 0.5)).r < 0.05, "far from it: still dark")
	w.set_hand_lights([])
	w.set_block(Vector3i(5, 70, 5), Registry.block_index("core:lamp"))
	var lit := await wait_until(func(): return w.light_for(Vector3(6.5, 70.5, 5.5)).r > 0.5, 5)
	check(lit, "next to a placed lamp: bright")
	check(w.light_for(open, 0.07).r >= 0.07, "never below the floor asked for")


## Block shadows: a tower on a platform shades whole block faces on the side
## away from the sun, as long as the tower's shadow; the shadow turns with the
## sun, and none are marked with block shadows off.
func test_block_shadows() -> void:
	const Y := 70  # in the air, above the terrain
	var w := await make_world(4242, "", 64, Vector3(0.5, Y, 0.5))
	var stone := Registry.block_index("core:stone")
	for x in range(-10, 11):
		for z in range(-3, 4):
			w.set_block(Vector3i(x, Y, z), stone)
	for y in range(Y + 1, Y + 9):  # 8 blocks tall
		w.set_block(Vector3i(0, y, 0), stone)
	var shaded := func() -> Array:
		var out := []
		for cx in [-1, 0]:
			out.append_array(Array(w.engine.shaded_faces(Vector3i(cx, Y / World.CHUNK_SIZE, 0))))
		return out
	var top := func(x: int) -> Vector3:  # the platform's top face at (x, 0)
		return Vector3(x + 0.5, Y + 1, 0.5)

	w.engine.sun_angle = deg_to_rad(60.0)  # morning: the sun in the east (+x)
	w.engine.block_shadows = true
	check(await wait_until(func(): return shaded.call().has(top.call(-2))), "the tower shades the ground west of it")
	var s: Array = shaded.call()
	check(s.has(top.call(-4)), "as far as its shadow reaches (8 / tan 60° = 4.6 blocks)")
	check(not s.has(top.call(-7)), "and no further")
	check(not s.has(top.call(2)), "the sunny side is lit")

	w.engine.sun_angle = deg_to_rad(120.0)  # afternoon: the sun in the west
	check(await wait_until(func(): return shaded.call().has(top.call(3)) and not shaded.call().has(top.call(-2))),
			"the shadow turns with the sun, leaving the morning side")

	w.engine.block_shadows = false
	check(await wait_until(func(): return shaded.call().is_empty()), "off: nothing is marked")


## A held torch lights whole blocks like a placed one: one level less per
## block, and not through walls (only around them).
func test_held_light_is_blocky_and_stopped_by_walls() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var torch := [Vector4(1.5, 71.5, 0.5, 13.0)]
	check(w.set_hand_lights(torch), "the light is spread")
	check(not w.set_hand_lights([Vector4(1.9, 71.2, 0.7, 13.0)]), "not again while it stays in the same block")
	check_eq(w.hand_light_at(Vector3(1.5, 71.5, 0.5)), 13, "its own block: the full level")
	check_eq(w.hand_light_at(Vector3(0.1, 71.9, 0.9)), 12, "the next block: one less, all over it")
	check_eq(w.hand_light_at(Vector3(4.5, 71.5, 0.5)), 10, "three blocks away: three less")
	var stone := Registry.block_index("core:stone")
	for y in range(66, 77):
		for z in range(-6, 7):
			w.set_block(Vector3i(3, y, z), stone)  # a wall between
	check(w.set_hand_lights(torch), "a changed world spreads it again")
	check(w.hand_light_at(Vector3(4.5, 71.5, 0.5)) < 5, "behind the wall: only what gets around it (%d)" % w.hand_light_at(Vector3(4.5, 71.5, 0.5)))
	check(w.hand_light_texture != null and w.hand_light_texture.get_depth() == World.HAND_LIGHT_SIZE, "and the shaders get it")
	# The cube follows the viewer, not the first torch: a torch near us lights
	# even when the first one in the list is far away.
	w.set_hand_lights([Vector4(200.5, 71.5, 0.5, 13.0), Vector4(-2.5, 71.5, 0.5, 13.0)], Vector3(0.5, 71.5, 0.5))
	check_eq(w.hand_light_at(Vector3(-2.5, 71.5, 0.5)), 13, "the torch near the viewer lights")
	check_eq(w.hand_light_at(Vector3(200.5, 71.5, 0.5)), 0, "the far one is outside the cube")
	w.set_hand_lights([])
	check(not w.set_hand_lights([]), "no torches, nothing moved: nothing to do")
