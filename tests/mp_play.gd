extends RefCounted
## Driving a player the way a person would, for the multiplayer tests
## (test_multiplayer.gd in one process; mp_smoke.gd in two, started by
## test_mp_processes.gd): aim at a point, walk at walking speed, and compare
## the area a test played in.

const Player := preload("res://src/player/player.gd")

## Half sizes of the play area around its centre O: x -6..6, y -1..3, z -3..3.
const AREA_X := 6
const AREA_Z := 3


## Turns the player to look at a world point.
static func aim(p: Node3D, at: Vector3) -> void:
	var dir: Vector3 = (at - p.camera.global_position).normalized()
	p.set_look(asin(dir.y), atan2(-dir.x, -dir.z))


## Moves a frozen player there in a straight line at walking speed, as the
## host expects (the way must be clear: the host puts players back who walk
## through blocks). False if it didn't get there (put back all the way).
static func walk(p: Node3D, to: Vector3) -> bool:
	var tree := p.get_tree()
	var give_up := Time.get_ticks_msec() + int(p.global_position.distance_to(to) / 4.0 * 3000.0) + 2000
	while p.global_position.distance_to(to) > 0.001:
		if Time.get_ticks_msec() > give_up:
			return false
		p.global_position = p.global_position.move_toward(to, 4.0 * p.get_physics_process_delta_time())
		await tree.physics_frame
	for i in 5:
		await tree.process_frame
	return true


## Holds the left button on what the player aims at until a block breaks
## (survival mining takes the block's time; the host checks it). False if
## nothing broke within `seconds`.
static func mine(p: Node3D, seconds := 10.0) -> bool:
	var broke := [false]
	var on_break := func(_block, _at): broke[0] = true
	p.block_broken.connect(on_break)
	p.mine_held = true
	var give_up := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not broke[0] and Time.get_ticks_msec() < give_up:
		await p.get_tree().process_frame
	p.mine_held = false
	p.block_broken.disconnect(on_break)
	return broke[0]


## A frozen survival player, for scripted play (its inventory stays: in
## multiplayer the host has a copy of it).
static func take_over(p: Node3D) -> void:
	p._frozen = true
	p.creative = false
	p.selected = 0


## Takes the hotbar slot holding `item` in hand (as a person would with the
## number keys). False if no hotbar slot has it.
static func hold(p: Node3D, item: String) -> bool:
	for i in Inventory.HOTBAR:
		if p.inventory.slots[i].get("id", "") == item:
			p.selected = i
			return true
	return false


## Host: a stone floor under the area around `o`, with air above it.
static func build_area(w: World, o: Vector3i) -> void:
	var stone := Registry.block_index("core:stone")
	for x in range(-AREA_X, AREA_X + 1):
		for z in range(-AREA_Z, AREA_Z + 1):
			w.set_block(o + Vector3i(x, -1, z), stone)
			for y in 4:
				w.set_block(o + Vector3i(x, y, z), 0)


## Every block id in the area, in order (to compare two worlds).
static func area_blocks(w: World, o: Vector3i) -> PackedStringArray:
	var out := PackedStringArray()
	for x in range(-AREA_X, AREA_X + 1):
		for z in range(-AREA_Z, AREA_Z + 1):
			for y in range(-1, 4):
				out.append(Registry.block_ids[w.get_block(o + Vector3i(x, y, z))])
	return out


## A short fingerprint of the area, printed by both smoke test processes.
static func area_hash(w: World, o: Vector3i) -> String:
	return ",".join(area_blocks(w, o)).sha256_text().left(16)
