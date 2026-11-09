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
var _hurt_time := 0.0
var _rng := RandomNumberGenerator.new()
var _parts := {}             # name -> Node3D (for animation)
var _walk_phase := 0.0
var _on_floor := false


func _ready() -> void:
	_rng.seed = id * 104729 + 7
	_heading = _rng.randf() * TAU
	_build_model()


# --- Model ---------------------------------------------------------------------------

func _build_model() -> void:
	var cloth := BlockEater._mat("ninja_cloth", Color(0.11, 0.12, 0.16))
	var cloth_dark := BlockEater._mat("ninja_dark", Color(0.07, 0.07, 0.10))
	var skin := BlockEater._mat("ninja_skin", Color(0.80, 0.62, 0.48))
	var eyes := BlockEater._mat("ninja_eyes", Color(0.05, 0.05, 0.06))
	var sash := BlockEater._mat("ninja_sash", Color(0.66, 0.10, 0.12))
	var body := Node3D.new()
	add_child(body)
	_parts.body = body
	_box(body, Vector3(0.5, 0.62, 0.28), Vector3(0, 1.08, 0), cloth)             # torso
	_box(body, Vector3(0.52, 0.1, 0.3), Vector3(0, 0.82, 0), sash)               # sash
	_box(body, Vector3(0.12, 0.3, 0.04), Vector3(0.14, 0.66, 0.16), sash)         # sash ends
	var head := Node3D.new()
	head.position = Vector3(0, 1.62, 0)
	body.add_child(head)
	_parts.head = head
	_box(head, Vector3(0.42, 0.42, 0.42), Vector3.ZERO, cloth)                    # hood
	_box(head, Vector3(0.36, 0.1, 0.02), Vector3(0, 0.03, -0.215), skin)          # eye slit
	_box(head, Vector3(0.06, 0.05, 0.02), Vector3(-0.08, 0.03, -0.225), eyes)
	_box(head, Vector3(0.06, 0.05, 0.02), Vector3(0.08, 0.03, -0.225), eyes)
	_box(head, Vector3(0.44, 0.06, 0.44), Vector3(0, 0.12, 0), sash)             # headband
	_box(head, Vector3(0.06, 0.06, 0.26), Vector3(0.1, 0.12, 0.33), sash)         # its tails
	for side in [-1, 1]:
		var arm := Node3D.new()
		arm.position = Vector3(0.33 * side, 1.36, 0)
		body.add_child(arm)
		_box(arm, Vector3(0.16, 0.6, 0.16), Vector3(0, -0.28, 0), cloth)
		_box(arm, Vector3(0.14, 0.1, 0.14), Vector3(0, -0.6, 0), cloth_dark)     # glove
		_parts["arm%d" % side] = arm
		var leg := Node3D.new()
		leg.position = Vector3(0.13 * side, 0.78, 0)
		body.add_child(leg)
		_box(leg, Vector3(0.2, 0.78, 0.2), Vector3(0, -0.39, 0), cloth)
		_box(leg, Vector3(0.21, 0.12, 0.26), Vector3(0, -0.74, -0.03), cloth_dark) # tabi
		_parts["leg%d" % side] = leg


func _box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)


func _process(delta: float) -> void:
	if world and world.remote:
		var t := 1.0 - exp(-12.0 * delta)
		position = position.lerp(target_position, t)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
	_walk_phase += delta * (11.0 if walking else 0.0)
	var swing := sin(_walk_phase) * (0.8 if walking else 0.0)
	_parts["leg-1"].rotation.x = swing
	_parts["leg1"].rotation.x = -swing
	_parts["arm-1"].rotation.x = -swing * 0.8
	_parts["arm1"].rotation.x = swing * 0.8
	attacking = maxf(0.0, attacking - delta)
	if attacking > 0.0:  # a quick overhead strike with the right hand
		_parts["arm1"].rotation.x = -2.6 * sin(attacking / 0.35 * PI)
	_parts.body.rotation.x = 0.18 if walking else 0.0  # leans into the run
	_hurt_time = maxf(0.0, _hurt_time - delta)
	_parts.body.position.x = sin(_hurt_time * 60.0) * 0.04 if _hurt_time > 0.0 else 0.0


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


## In daylight under open sky (nothing above its head).
func in_sunlight(day_amount: float) -> bool:
	if day_amount < 0.35:
		return false
	var hit: Dictionary = world.raycast(global_position + Vector3(0, BOX.y + 0.1, 0), Vector3.UP, 96.0)
	return not hit.hit


func hurt(amount: int, from: Vector3) -> bool:
	health -= amount
	_hurt_time = 0.25
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
