extends RefCounted
## Host: a joined survival player's health, worked out from where the client
## says it is, by the same rules as Player: falls over SAFE_FALL blocks, lava,
## drowning, creatures (armour from the host's copy of its inventory), healing
## after a while without damage, and food. The client only shows it.

const Player := preload("res://src/player/player.gd")

var health := Player.MAX_HEALTH
var breath := Player.MAX_BREATH
var dead := false
var changed := true   # send it to the client
var _fall_peak = null  # feet height since leaving the ground, or null (not falling)
var _since_damage := 0.0
var _regen_timer := 0.0
var _drown_timer := 0.0
var _burn_timer := 0.5


func hurt(amount: int) -> void:
	if dead or amount <= 0:
		return
	health = maxi(0, health - amount)
	_since_damage = 0.0
	_regen_timer = 0.0
	dead = health == 0
	changed = true


func heal(amount: int) -> void:
	if dead or amount <= 0 or health >= Player.MAX_HEALTH:
		return
	health = mini(Player.MAX_HEALTH, health + amount)
	changed = true


func respawn() -> void:
	health = Player.MAX_HEALTH
	breath = Player.MAX_BREATH
	dead = false
	_fall_peak = null
	_since_damage = 0.0
	_drown_timer = 0.0
	changed = true


## A new position the host accepted (feet). `held_up`: flying or in bed
## (no fall). A fall ends on the ground, in water or on a ladder.
func moved(world: World, feet: Vector3, held_up: bool) -> void:
	if dead:
		return
	var in_water := world.is_fluid(world.get_block(Vector3i((feet + Vector3(0, 0.9, 0)).floor())))
	var climbing := _climbable(world, feet) or _climbable(world, feet + Vector3(0, 1.0, 0))
	if held_up or in_water or climbing or _fall_peak == null:
		_fall_peak = feet.y
	elif not world.is_box_free(feet - Vector3(0, 0.05, 0), Player.BODY):  # on the ground
		var fall: float = _fall_peak - feet.y
		if fall > Player.SAFE_FALL:
			hurt(int(floor(fall - Player.SAFE_FALL)))
		_fall_peak = feet.y
	else:
		_fall_peak = maxf(_fall_peak, feet.y)


## Time passing: lava burns, breath runs out under water, health comes back.
## `in_bed`: lying down (the eyes are low, nothing burns or drowns there).
func tick(world: World, feet: Vector3, eye: Vector3, in_bed: bool, delta: float) -> void:
	if dead:
		return
	var body_def: Dictionary = {} if in_bed else Registry.blocks.get(Registry.block_ids[world.get_block(
			Vector3i((feet + Vector3(0, 0.4, 0)).floor()))], {})
	if body_def.has("damage"):
		_burn_timer += delta
		if _burn_timer >= 0.5:
			_burn_timer = 0.0
			hurt(int(body_def.damage))
	else:
		_burn_timer = 0.5  # the first touch hurts at once
	if not in_bed and world.is_fluid(world.get_block(Vector3i(eye.floor()))):
		breath = maxf(0.0, breath - delta)
		if breath <= 0.0:
			_drown_timer += delta
			if _drown_timer >= 1.0:
				_drown_timer = 0.0
				hurt(Player.DROWN_DAMAGE)
	else:
		breath = minf(Player.MAX_BREATH, breath + delta * 3.0)
		_drown_timer = 0.0
	_since_damage += delta
	if health < Player.MAX_HEALTH and _since_damage >= Player.REGEN_DELAY:
		_regen_timer += delta
		if _regen_timer >= Player.REGEN_INTERVAL:
			_regen_timer = 0.0
			health += 1
			changed = true


static func _climbable(world: World, at: Vector3) -> bool:
	var def = Registry.blocks.get(Registry.block_ids[world.get_block(Vector3i(at.floor()))])
	return def is Dictionary and def.get("climbable", false)
