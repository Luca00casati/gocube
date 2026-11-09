extends "res://tests/test_suite.gd"
## Flowing water on a flat test pad high in the air (away from terrain).


func _ids() -> Dictionary:
	var ids := {"source": Registry.block_index("core:water"), "air": 0, "stone": Registry.block_index("core:stone")}
	for k in range(1, 8):
		ids[k] = Registry.block_index("core:water_%d" % k)
	return ids


func _settle(w: World, seconds: float) -> void:
	await wait_until(func(): return w.fluids.pending_count() == 0, seconds)


func test_spreads_falls_and_drains() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var id := _ids()
	var y := 70
	for x in range(-10, 11):  # a closed channel: floor, walls on both sides
		for z in range(-1, 2):
			w.engine.set_block(Vector3i(x, y - 1, z), id.stone)
			w.engine.set_block(Vector3i(x, y, z), 0 if z == 0 else id.stone)
	w.set_block(Vector3i(0, y, 0), id.source)
	await _settle(w, 15)
	check_eq(w.get_block(Vector3i(1, y, 0)), id[7], "next to the source: level 7")
	check_eq(w.get_block(Vector3i(3, y, 0)), id[5], "3 blocks away: level 5")
	check_eq(w.get_block(Vector3i(7, y, 0)), id[1], "7 blocks away: level 1")
	check_eq(w.get_block(Vector3i(8, y, 0)), 0, "stops after 7 blocks")
	check_eq(w.get_block(Vector3i(-4, y, 0)), id[4], "spreads both ways")
	# Through a hole in the floor it falls (into a 1-block pit).
	for d in [Vector3i(0, -3, 0), Vector3i(1, -2, 0), Vector3i(-1, -2, 0), Vector3i(0, -2, 1), Vector3i(0, -2, -1)]:
		w.engine.set_block(Vector3i(2, y, 0) + d, id.stone)  # a closed 1-block pit
	w.engine.set_block(Vector3i(2, y - 2, 0), 0)
	w.set_block(Vector3i(2, y - 1, 0), 0)
	await _settle(w, 15)
	check(w.is_fluid(w.get_block(Vector3i(2, y - 2, 0))), "pours down through a hole")
	# Remove the source: the flowing water drains.
	var t0 := Time.get_ticks_msec()
	w.set_block(Vector3i(0, y, 0), 0)
	await _settle(w, 20)
	print("        (drained in %.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var left := 0
	for x in range(-10, 11):
		if w.is_fluid(w.get_block(Vector3i(x, y, 0))):
			left += 1
	check_eq(left, 0, "all flowing water drained after the source was removed")


## Flowing water is one connected surface: wherever cells meet, their top
## corners are at the same height (no steps, no gaps), sloping down away
## from the source.
func test_surface_is_connected() -> void:
	var w := await make_world(4242, "", 64, Vector3(4.5, 70, 4.5))
	var id := _ids()
	var y := 70
	for x in range(-5, 15):  # a walled pad, so the water settles
		for z in range(-5, 14):
			var wall := x == -5 or x == 14 or z == -5 or z == 13
			w.engine.set_block(Vector3i(x, y - 1, z), id.stone)
			w.engine.set_block(Vector3i(x, y, z), id.stone if wall else 0)
	w.set_block(Vector3i(4, y, 4), id.source)
	await _settle(w, 15)
	var chunk := World.chunk_of(Vector3i(4, y, 4))
	var tops := {}  # (x, z) of a top corner -> heights seen there
	var ok := await wait_until(func():
		tops.clear()
		# Two chunks: the water crosses the border at x = 0, which must match too.
		for v in w.engine.fluid_vertices(chunk) + w.engine.fluid_vertices(chunk + Vector3i(-1, 0, 0)):
			if v.y > y + 0.05 and v.y < y + 1.0:
				var key := Vector2i(roundi(v.x * 2.0), roundi(v.z * 2.0))
				if not tops.has(key):
					tops[key] = {}
				tops[key][snappedf(v.y, 0.001)] = true
		return tops.size() > 20, 5)
	check(ok, "the water was drawn")
	var split := tops.keys().filter(func(k): return tops[k].size() > 1)
	check(split.is_empty(), "every corner has one height (%d corners with steps, e.g. %s)" % [split.size(), split.slice(0, 3)])
	var near: float = tops.get(Vector2i(8, 8), {0.0: true}).keys()[0]   # a corner of the source cell
	var far: float = tops.get(Vector2i(20, 8), {0.0: true}).keys()[0]   # 6 blocks away
	check(near > far + 0.3, "the surface slopes down from the source (%.2f -> %.2f)" % [near, far])
