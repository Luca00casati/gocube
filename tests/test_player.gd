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


## F5: first person, then from behind, then from in front; a wall pulls the
## camera in; aiming still goes from the eyes.
func test_third_person_views() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, 70, 0.5)  # in the air: nothing near the cameras
	add(p)
	await frames(2)
	var hand := Hand.new()
	hand.player = p
	hand.atlas = w.atlas
	p.camera.add_child(hand)
	await frames(2)
	check(p.camera.current and not p.view_camera.current, "starts in first person")
	check(hand.visible and not p._body.visible, "the hand, not the body")
	var eye: Vector3 = p.camera.global_position
	var forward: Vector3 = -p.camera.global_basis.z
	_key(KEY_F5, true)
	_key(KEY_F5, false)
	await frames(2)
	check_eq(p.view, Player.View.BACK, "F5: from behind")
	check(p.view_camera.current, "the third-person camera shows")
	check(p._body.visible and not hand.visible, "our body, not the hand")
	check(p.view_camera.global_position.distance_to(eye - forward * Player.VIEW_DISTANCE) < 0.01, "4 blocks behind the eyes")
	check(p.view_camera.global_basis.z.dot(-forward) > 0.99, "looking the same way we do")
	check(p.camera.global_position.is_equal_approx(eye), "aiming still from the eyes")
	# A wall right behind us: the camera stays on our side of it.
	var behind := Vector3i((eye - forward * 2.0).floor())
	w.set_block(behind, Registry.block_index("core:stone"))
	await frames(2)
	check(p.view_camera.global_position.distance_to(eye) < 1.8, "pulled in by a wall behind")
	w.set_block(behind, 0)
	p.set_view(Player.View.FRONT)
	await frames(2)
	check(p.view_camera.global_position.distance_to(eye + forward * Player.VIEW_DISTANCE) < 0.01, "in front of us")
	check(p.view_camera.global_basis.z.dot(forward) > 0.99, "looking back at us")
	p.set_view(Player.View.FIRST)
	await frames(2)
	check(p.camera.current and not p._body.visible and hand.visible, "back to first person")
