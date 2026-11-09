class_name Ninja
extends Node3D
## A ninja: comes out at night, runs at the nearest survival player, jumps
## over obstacles and strikes when close. Vanishes in a puff of smoke when the
## sun reaches it (daytime under open sky). The node origin is at the feet.
##
## Same interface as BlockEater, so MobManager can run either.

const KIND := "ninja"
const BOX := Vector3(0.6, 1.8, 0.6)
const RUN_SPEED := 3.6
const WANDER_SPEED := 1.4
const GRAVITY := 24.0
const JUMP := 8.0
const MAX_HEALTH := 12
const SIGHT := 24.0
const REACH := 1.5
const DAMAGE := 3
const ATTACK_EVERY := 1.0

var id := 0
var variant := ""            # unused (BlockEater's forms)
var health := MAX_HEALTH
var world: World
var velocity := Vector3.ZERO
var walking := false
var attacking := 0.0         # >0 while the strike animation plays
var target_position := Vector3.ZERO
var target_yaw := 0.0

var _heading := 0.0
var _cooldown := 0.0
var _wander_time := 0.0
var _rng := RandomNumberGenerator.new()
## Goes up with every hit it takes (clients flash it when it changes).
var hurts := 0
var _figure: Figure
var _tails: Node3D           # the headband's tails
var _last := Vector3.INF
var _speed := 0.0
var _vspeed := 0.0
var _was_attacking := false
var _time := 0.0
var _on_floor := false


func _ready() -> void:
	_rng.seed = id * 104729 + 7
	_heading = _rng.randf() * TAU
	_build_model()


# --- Model ---------------------------------------------------------------------------

## A jointed figure in dark cloth with a hood, a red sash and a headband whose
## tails flutter behind it. It runs leaning forward with its arms swept back,
## and strikes with a fast overhead chop.
func _build_model() -> void:
	var cloth := Color(0.11, 0.12, 0.16)
	_figure = Figure.new()
	_figure.style = "ninja"
	_figure.build({"skin": cloth, "shirt": cloth, "hands": Color(0.07, 0.07, 0.1),
			"trousers": cloth, "shoes": Color(0.06, 0.06, 0.08)})
	add_child(_figure)
	var skin := BlockEater._mat("ninja_skin", Color(0.80, 0.62, 0.48))
	var eyes := BlockEater._mat("ninja_eyes", Color(0.05, 0.05, 0.06))
	var sash := BlockEater._mat("ninja_sash", Color(0.66, 0.10, 0.12))
	var steel := BlockEater._mat("ninja_steel", Color(0.62, 0.65, 0.7))
	var head: Node3D = _figure.joints.head
	_figure.add_box(head, Vector3(0.36, 0.1, 0.02), Vector3(0, 0.25, -0.222), skin)       # eye slit
	for side in [-1, 1]:
		_figure.add_box(head, Vector3(0.06, 0.05, 0.02), Vector3(0.08 * side, 0.25, -0.232), eyes)
	_figure.add_box(head, Vector3(0.46, 0.06, 0.46), Vector3(0, 0.35, 0), sash)          # headband
	_tails = Node3D.new()                                                              # its tails
	_tails.position = Vector3(0.08, 0.35, 0.23)
	head.add_child(_tails)
	_figure.add_box(_tails, Vector3(0.05, 0.05, 0.3), Vector3(0.03, 0, 0.15), sash)
	_figure.add_box(_tails, Vector3(0.05, 0.05, 0.24), Vector3(-0.04, -0.03, 0.12), sash, Vector3(0, -0.25, 0))
	var torso: Node3D = _figure.joints.torso
	_figure.add_box(torso, Vector3(0.52, 0.1, 0.29), Vector3(0, 0.06, 0), sash)          # sash
	_figure.add_box(torso, Vector3(0.1, 0.26, 0.04), Vector3(0.15, -0.08, -0.15), sash)   # sash ends
	_figure.add_box(torso, Vector3(0.06, 0.62, 0.06), Vector3(-0.12, 0.34, 0.17), steel, Vector3(0, 0, 0.7))  # sword on the back


func _process(delta: float) -> void:
	if world and world.remote:
		var t := 1.0 - exp(-12.0 * delta)
		position = position.lerp(target_position, t)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
	# Speed from how far it actually moved (the same on the host and on clients).
	if _last != Vector3.INF and delta > 0.0:
		_speed = lerpf(_speed, Vector2(position.x - _last.x, position.z - _last.z).length() / delta, 1.0 - exp(-10.0 * delta))
		_vspeed = lerpf(_vspeed, (position.y - _last.y) / delta, 1.0 - exp(-10.0 * delta))
	_last = position
	_figure.move_speed = _speed
	_figure.on_floor = absf(_vspeed) < 1.5
	attacking = maxf(0.0, attacking - delta)
	if attacking > 0.0 and not _was_attacking:
		_figure.swing()
	_was_attacking = attacking > 0.0
	_time += delta
	var run := minf(_speed / RUN_SPEED, 1.0)  # the tails hang still when it stands
	_tails.rotation = Vector3(0.5 * run + sin(_time * (6.0 + 3.0 * _speed)) * 0.25 * run,
			sin(_time * 4.3) * 0.2 * run, 0)


# --- Behaviour (where the world is owned) ----------------------------------------------

## targets: [{"position": Vector3, "peer": int}] of survival players.
## Returns {"peer", "damage", "push"} when it strikes someone, else {}.
func simulate(delta: float, targets: Array = []) -> Dictionary:
	_cooldown = maxf(0.0, _cooldown - delta)
	var strike := {}
	var target = null
	var best := SIGHT
	for t in targets:
		var d: float = (t.position as Vector3).distance_to(global_position)
		if d < best:
			best = d
			target = t
	var speed := 0.0
	if target != null:
		var to: Vector3 = target.position - global_position
		_heading = atan2(-to.x, -to.z)
		var flat := Vector2(to.x, to.z).length()
		if flat > REACH * 0.8:
			speed = RUN_SPEED
		if flat < REACH and absf(to.y) < 1.6 and _cooldown <= 0.0:
			_cooldown = ATTACK_EVERY
			attacking = 0.35
			var push := Vector3(to.x, 0, to.z).normalized() * 6.0 + Vector3(0, 4.0, 0)
			strike = {"peer": target.peer, "damage": DAMAGE, "push": push}
	else:
		_wander_time -= delta
		if _wander_time <= 0.0:
			_wander_time = _rng.randf_range(2.0, 5.0)
			_heading += _rng.randf_range(-2.0, 2.0)
			speed = 0.0
		speed = WANDER_SPEED if fmod(_wander_time, 2.0) > 0.8 else 0.0
	var dir := Vector3(-sin(_heading), 0, -cos(_heading))
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	velocity.y = maxf(velocity.y - GRAVITY * delta, -40.0)
	var r: Dictionary = world.move_box(global_position, BOX, velocity * delta, 1.0)
	if r.hit_wall and r.on_floor and speed > 0.0:
		velocity.y = JUMP  # over whatever is in the way
	elif r.on_floor:
		velocity.y = 0.0
	_on_floor = r.on_floor
	global_position = r.position
	walking = speed > 0.0
	rotation.y = lerp_angle(rotation.y, _heading, 1.0 - exp(-12.0 * delta))
	return strike


## Client: the host says it has been hit `count` times in all.
func set_hurts(count: int) -> void:
	if count != hurts:
		hurts = count
		_figure.flash()


## In daylight under open sky (nothing above its head).
func in_sunlight(day_amount: float) -> bool:
	if day_amount < 0.35:
		return false
	var hit: Dictionary = world.raycast(global_position + Vector3(0, BOX.y + 0.1, 0), Vector3.UP, 96.0)
	return not hit.hit


func hurt(amount: int, from: Vector3) -> bool:
	health -= amount
	hurts += 1
	_figure.flash()
	var push := global_position - from
	push.y = 0.0
	velocity = push.normalized() * 5.0 + Vector3(0, 4.5, 0)
	return health <= 0


func drops(_rng_in: RandomNumberGenerator) -> Array:
	return []


func ray_distance(origin: Vector3, dir: Vector3, max_distance: float) -> float:
	var box := AABB(global_position - Vector3(BOX.x / 2, 0, BOX.z / 2), BOX)
	var hit = box.intersects_ray(origin, dir)
	if hit == null:
		return -1.0
	var d: float = (hit as Vector3).distance_to(origin)
	return d if d <= max_distance else -1.0
