extends "res://tests/test_suite.gd"

const Player := preload("res://src/player/player.gd")


func _player(w: World, at: Vector3) -> Node3D:
	var p = Player.new()
	p.world = w
	p.position = at
	add(p)
	p.set_ready_to_move()
	return p


func test_fall_damage_and_safe_falls() -> void:
	var w := await make_world()
	var ground: int = w.raycast(Vector3(0.5, 100, 0.5), Vector3.DOWN, 300).position.y
	var p = _player(w, Vector3(0.5, ground + 1 + 2.5, 0.5))  # a 2.5-block drop
	check(await wait_until(func(): return p.on_floor, 5), "landed")
	check_eq(p.health, Player.MAX_HEALTH, "a short fall doesn't hurt")
	p.global_position = Vector3(0.5, ground + 1 + 8.2, 0.5)  # an 8-block drop: 5 damage
	p._fall_peak = p.global_position.y
	p.on_floor = false
	p._was_on_floor = false
	check(await wait_until(func(): return p.on_floor, 5), "landed again")
	check_eq(p.health, Player.MAX_HEALTH - 5, "8 blocks: 8 - 3 = 5 damage")


func test_creative_takes_no_damage() -> void:
	var w := await make_world()
	var p = _player(w, Vector3(0.5, 40, 0.5))
	p.creative = true
	p.damage(10)
	check_eq(p.health, Player.MAX_HEALTH, "creative ignores damage")


func test_death_respawn_and_healing() -> void:
	var w := await make_world()
	var p = _player(w, Vector3(0.5, 40, 0.5))
	var died := [false]
	p.died.connect(func(): died[0] = true)
	p.damage(25)
	check(p.dead and died[0], "dies at 0 health")
	p.respawn(Vector3(0.5, 40, 0.5))
	check(not p.dead and p.health == Player.MAX_HEALTH, "respawns with full health")
	p.damage(3)
	p._since_damage = Player.REGEN_DELAY
	p._regen_timer = Player.REGEN_INTERVAL - 0.01
	p._after_move(Vector3.ZERO, 0.0, false, 0.02)
	check_eq(p.health, Player.MAX_HEALTH - 2, "heals one point after the delay")


func test_drowning() -> void:
	var w := await make_world(4242, "", 64, Vector3(0.5, 70, 0.5))
	for y in range(66, 72):  # a water column to stand in, high above the terrain
		w.engine.set_block(Vector3i(0, y, 0), Registry.block_index("core:water"))
	var p = _player(w, Vector3(0.5, 67, 0.5))
	p._frozen = true
	p.breath = 0.0
	for i in 70:  # ~1.2 s at 60 fps
		p._after_move(Vector3.ZERO, 0.0, false, 1.0 / 60.0)
	check(p.health < Player.MAX_HEALTH, "out of breath underwater hurts (%d)" % p.health)
