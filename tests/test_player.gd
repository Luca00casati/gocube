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


## The figure (players and ninjas) animates from how it moves.
func test_figure_animates() -> void:
	var f := Figure.new()
	f.build({"skin": Color.BISQUE, "shirt": Color.BLUE})
	add(f)
	await frames(10)
	check(absf(f.joints.leg_l.rotation.x) < 0.05, "standing: legs straight")
	f.move_speed = 4.3
	var widest := 0.0
	var knee := 0.0
	for i in 60:
		await tree.process_frame
		widest = maxf(widest, absf(f.joints.leg_l.rotation.x - f.joints.leg_r.rotation.x))
		knee = maxf(knee, absf(f.joints.knee_l.rotation.x))
	check(widest > 0.6, "walking: the legs stride (%.2f)" % widest)
	check(knee > 0.2, "and the knees bend (%.2f)" % knee)
	f.move_speed = 0.0
	await frames(60)
	f.swing()
	var raised := 0.0
	var straight_up := false
	for i in 30:
		await tree.process_frame
		raised = maxf(raised, f.joints.arm_r.rotation.x)
		# Never a straight arm held up and forward (it would look like a salute).
		if f.joints.arm_r.rotation.x > 1.0 and f.joints.elbow_r.rotation.x < 0.8:
			straight_up = true
	check(raised > 1.5, "a swing raises the right arm (%.2f)" % raised)
	check(not straight_up, "with the elbow bent whenever the arm is up")
	f.sneaking = true
	await frames(40)
	check(f.joints.torso.rotation.x < -0.3 and f.joints.hips.position.y < Figure.HIP_Y - 0.1, "sneaking: bent forward and lower")
	f.sneaking = false
	f.lying = true
	await frames(90)
	check(f.lie_amount() > 0.95 and absf(f.rotation.x - PI / 2) < 0.1, "asleep: lying down")
	f.flash()
	await frames(1)
	var mi: MeshInstance3D = f.joints.torso.get_child(0)
	check(float(mi.get_instance_shader_parameter("flash")) > 0.5, "hurt: a red flash")


## A left click with nothing in reach still swings the arm.
func test_swing_at_nothing() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, 70, 0.5)  # in the air, looking at the sky
	add(p)
	await frames(2)
	p.set_look(1.2, 0.0)
	var swung := [0]
	p.swung.connect(func(): swung[0] += 1)
	var before: int = p.swings
	p.left_click()
	check_eq(swung[0], 1, "the arm swings")
	check_eq(p.swings, before + 1, "and others see it")


## Swimming to the shore and holding forward + jump climbs out onto the bank
## (level with the water, as around lakes).
func test_climb_out_of_water() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var stone := Registry.block_index("core:stone")
	var water := Registry.block_index("core:water")
	var y := 68
	for x in range(-4, 5):
		for z in range(-8, 5):
			w.engine.set_block(Vector3i(x, y - 1, z), stone)
			var pool := absi(x) <= 2 and z >= -2 and z <= 2
			for dy in 2:
				w.engine.set_block(Vector3i(x, y + dy, z), water if pool else stone)
			for dy in range(2, 5):
				w.engine.set_block(Vector3i(x, y + dy, z), 0)
	w.set_block(Vector3i(0, y + 1, 0), water)  # wake the water up
	await frames(5)
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, y + 0.2, 0.5)
	add(p)
	p.set_ready_to_move()
	await frames(20)
	check(p.in_water, "swimming in the pool")
	_key(KEY_W, true)  # facing -z: the bank at z = -3 is level with the water
	_key(KEY_SPACE, true)
	var out: bool = await wait_until(func(): return p.on_floor and not p.in_water and p.global_position.z < -2.7, 4)
	_key(KEY_W, false)
	_key(KEY_SPACE, false)
	check(out, "climbed out onto the bank (at %s)" % p.global_position)
	check(p.global_position.y >= y + 2 - 0.01, "standing on top of it")



## Deep under water, a wall doesn't launch you up: only at the surface.
func test_no_wall_boost_under_water() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	var stone := Registry.block_index("core:stone")
	var water := Registry.block_index("core:water")
	var y := 62
	for x in range(-3, 4):
		for z in range(-3, 4):
			w.engine.set_block(Vector3i(x, y - 1, z), stone)
			for dy in 8:
				w.engine.set_block(Vector3i(x, y + dy, z), water if absi(x) <= 1 and absi(z) <= 1 else stone)
	w.set_block(Vector3i(0, y + 7, 0), water)
	var p = Player.new()
	p.world = w
	p.position = Vector3(0.5, y, 0.5)
	add(p)
	p.set_ready_to_move()
	await frames(5)
	_key(KEY_W, true)
	_key(KEY_SPACE, true)
	var fastest := 0.0
	for i in 30:
		await tree.physics_frame
		if p.global_position.y < y + 5:
			fastest = maxf(fastest, p.velocity.y)
	_key(KEY_W, false)
	_key(KEY_SPACE, false)
	check(fastest <= Player.SWIM_UP_SPEED + 0.01, "swims up at swimming speed (%.1f)" % fastest)


## Strikes asked for faster than they last (mining) play one after another,
## each one whole (wind up, land, back), and the arm never jumps.
func test_swings_are_smooth_and_whole() -> void:
	var f := Figure.new()
	f.build({"skin": Color.BISQUE, "shirt": Color.BLUE})
	add(f)
	f.process_mode = Node.PROCESS_MODE_DISABLED  # stepped by hand below, at 60 fps
	var step := 1.0 / 60.0
	var t := 0.0
	var next := 0.0
	var last := 0.0
	var biggest := 0.0
	var landed := 0   # strikes that came down to the landing pose
	var low := true
	for i in 240:
		if t >= next:
			next += 0.3
			f.swing()
		f._process(step)
		t += step
		var x: float = f.joints.arm_r.rotation.x
		biggest = maxf(biggest, absf(x - last))
		last = x
		if x > 2.0 and low:
			low = false
		elif x < 0.5 and not low:
			low = true
			landed += 1
	check(biggest < 0.7, "no jumps from one frame to the next (biggest %.2f rad)" % biggest)
	check(landed >= 9, "every strike lands before the next one (%d in 4 s)" % landed)


## First person: a swing stays on screen (the fist never leaves it), starts
## and ends at rest, and moves without jumps from frame to frame.
func test_first_person_swing() -> void:
	var hand := Hand.new()
	add(hand)
	var half := tan(deg_to_rad(75.0) / 2.0)  # the camera's default field of view
	var rest := hand.fist_position()
	var last := rest
	var biggest := 0.0
	var off_screen := []
	var frames_in_swing := int(round(Hand.SWING_TIME * 60.0))  # at 60 fps
	for i in frames_in_swing + 1:
		var t := float(i) / frames_in_swing
		hand.apply_pose(Hand.swing_pose(t))
		var f := hand.fist_position()
		if absf(f.y / -f.z) > half * 0.95 or absf(f.x / -f.z) > half * 16.0 / 9.0 * 0.95:
			off_screen.append(snappedf(t, 0.01))
		biggest = maxf(biggest, f.distance_to(last))
		last = f
	check(off_screen.is_empty(), "the fist stays on screen (left it at t = %s)" % [off_screen])
	check(hand.fist_position().distance_to(rest) < 0.001, "and ends where it started")
	check(biggest < 0.12, "no jumps (biggest step in a frame %.3f m)" % biggest)
	var down: Vector3 = (Hand.swing_pose(Hand.SWING_HIT)[2] as Vector3)
	check(down.x < -0.5, "the item chops forward at the hit")
