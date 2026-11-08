extends "res://tests/test_suite.gd"
## Player movement with simulated keys.

const Player := preload("res://src/player/player.gd")


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func test_walk_jump_land() -> void:
	var w := await make_world()
	var ground: int = w.raycast(Vector3(0.5, 100, 0.5), Vector3.DOWN, 300).position.y
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, ground + 1.5, 0.5)  # just above the ground (no fall damage)
	add(p)
	p.set_ready_to_move()
	check(await wait_until(func(): return p.on_floor, 10), "lands on the ground")
	# flatten a strip so the measurement doesn't depend on terrain
	var f := Vector3i(p.global_position.floor())
	for z in range(f.z - 8, f.z + 2):
		for x in range(f.x - 1, f.x + 2):
			w.set_block(Vector3i(x, f.y - 1, z), Registry.block_index("core:stone"))
			for y in range(0, 4):
				w.set_block(Vector3i(x, f.y + y, z), 0)
	p.global_position = Vector3(f) + Vector3(0.5, 0, 0.5)
	await frames(10)
	var z0: float = p.global_position.z
	_key(KEY_W, true)
	await tree.create_timer(1.0).timeout
	_key(KEY_W, false)
	await tree.create_timer(0.4).timeout
	check_near(z0 - p.global_position.z, 4.3, 0.35, "walks about 4.3 m in 1 s")
	var y0: float = p.global_position.y
	var peak := y0
	_key(KEY_SPACE, true)
	for i in 40:
		await tree.physics_frame
		peak = maxf(peak, p.global_position.y)
	_key(KEY_SPACE, false)
	check(peak - y0 > 1.0 and peak - y0 < 1.5, "jumps over one block (%.2f)" % (peak - y0))
	check(await wait_until(func(): return p.on_floor, 3), "lands again")
