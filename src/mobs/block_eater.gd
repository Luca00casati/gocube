class_name BlockEater
extends Node3D
## A Block Eater: a squat, slow grazer. The regular one is slim with a cushion
## of moss on its back and drops nothing; now and then it eats the block in
## front of it and becomes that block's form, built from its textures, which
## drops that block. Passive: wanders and grazes, hops
## up 1-block steps, avoids water and drops, and runs off when hit. The node
## origin is at the feet.
##
## Where the world is owned (single player / host) MobManager calls simulate();
## on multiplayer clients the node only shows positions the host sends.

const KIND := "eater"
const BOX := Vector3(0.9, 0.95, 0.9)   # collision box (width, height, depth)
const WALK_SPEED := 1.2
const FLEE_SPEED := 3.4
const GRAVITY := 24.0
const MAX_HEALTH := 8
## Chance that a regular one eats the block in front each time it starts
## grazing (every ~8 s on average): it then takes that block's form.
const EAT_CHANCE := 0.02

var id := 0
## "" = the regular (mossy) one, otherwise the block id it is made of.
var variant := ""
var health := MAX_HEALTH
var world: World
var velocity := Vector3.ZERO
var walking := false
## Client view: where the host says it is.
var target_position := Vector3.ZERO
var target_yaw := 0.0

var _state := "idle"
var _state_time := 0.0
var _heading := 0.0
var _flee_from := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _mover_step := 1.0
var _legs: Array[Node3D] = []
var _body: Node3D
var _walk_phase := 0.0
var _hurt_time := 0.0
## Set when it starts grazing and decides to eat the block in front (regular only).
var wants_to_eat := false

static var _mats := {}
## Set by MobManager: block textures for the block variants.
static var atlas: BlockAtlas


func _ready() -> void:
	_rng.seed = id * 7919 + 13
	_heading = _rng.randf() * TAU
	_build_model()


# --- Model ---------------------------------------------------------------------------

const SHADER := preload("res://src/mobs/block_eater.gdshader")


static func _new_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	return m


static func _mat(name: String, color: Color) -> ShaderMaterial:
	if not _mats.has(name):
		var m := _new_mat()
		m.set_shader_parameter("tint", color)
		_mats[name] = m
	return _mats[name]


## A material made of a block face (tiled once per metre, like the world's blocks).
static func _block_mat(block: String, face: int) -> ShaderMaterial:
	var key := "%s/%d" % [block, face]
	if not _mats.has(key):
		var m := _new_mat()
		var def: Dictionary = Registry.blocks.get(block, {})
		if atlas:
			m.set_shader_parameter("tex", atlas.face_texture(Registry.block_index(block), face))
			m.set_shader_parameter("use_tex", true)
		else:
			m.set_shader_parameter("tint", Color.html(def.get("color", "#888888")))
		m.set_shader_parameter("glow", float(def.get("light", 0)) / 15.0)
		_mats[key] = m
	return _mats[key]


## Follows the time of day like the terrain (0..1 daylight).
static func set_daylight(amount: float) -> void:
	var light := lerpf(DayCycle.NIGHT_CREATURE_LIGHT, 1.0, amount)
	for m in _mats.values():
		m.set_shader_parameter("light", light)


func _part(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


func _build_model() -> void:
	var dark := _mat("dark", Color(0.10, 0.08, 0.07))
	var horn := _mat("horn", Color(0.82, 0.78, 0.66))
	var hide: ShaderMaterial
	var belly: ShaderMaterial
	var moss: ShaderMaterial
	var moss_light: ShaderMaterial
	var w := 0.86  # body width
	if variant == "":
		hide = _mat("hide", Color(0.45, 0.36, 0.28))
		belly = _mat("belly", Color(0.58, 0.49, 0.38))
		moss = _mat("moss", Color(0.30, 0.48, 0.22))
		moss_light = _mat("moss_light", Color(0.42, 0.60, 0.28))
		w = 0.68  # the regular one is slim
	else:
		hide = _block_mat(variant, 0)    # sides
		moss = _block_mat(variant, 2)    # the back is the block's top
		moss_light = moss
		belly = _block_mat(variant, 3)   # the bottom

	_body = Node3D.new()
	add_child(_body)
	# A rounded back built from stacked, narrowing slabs.
	_part(_body, Vector3(w, 0.42, 1.18), Vector3(0, 0.55, 0), hide)
	_part(_body, Vector3(w - 0.08, 0.1, 1.0), Vector3(0, 0.32, 0), belly)
	_part(_body, Vector3(w + 0.04, 0.14, 1.12), Vector3(0, 0.82, 0), moss)
	_part(_body, Vector3(w - 0.2, 0.1, 0.86), Vector3(0, 0.93, 0.02), moss_light)
	_part(_body, Vector3(0.34, 0.07, 0.4), Vector3(0.08, 1.0, -0.06), moss)
	# Head at the front (-Z is forward), low and blunt.
	var head := Node3D.new()
	head.position = Vector3(0, 0.56, -0.68)
	_body.add_child(head)
	_part(head, Vector3(0.48, 0.4, 0.36), Vector3.ZERO, hide)
	_part(head, Vector3(0.32, 0.2, 0.16), Vector3(0, -0.08, -0.24), belly)          # snout
	_part(head, Vector3(0.06, 0.06, 0.02), Vector3(-0.07, -0.06, -0.325), dark)     # nostrils
	_part(head, Vector3(0.06, 0.06, 0.02), Vector3(0.07, -0.06, -0.325), dark)
	_part(head, Vector3(0.07, 0.08, 0.02), Vector3(-0.15, 0.06, -0.185), dark)      # eyes
	_part(head, Vector3(0.07, 0.08, 0.02), Vector3(0.15, 0.06, -0.185), dark)
	_part(head, Vector3(0.08, 0.12, 0.08), Vector3(-0.17, 0.24, 0.02), horn)        # horn nubs
	_part(head, Vector3(0.08, 0.12, 0.08), Vector3(0.17, 0.24, 0.02), horn)
	_part(head, Vector3(0.36, 0.06, 0.2), Vector3(0, 0.23, 0.06), moss)             # tuft
	# Four stubby legs, pivoting at the hip.
	var lx := w / 2.0 - 0.14
	for corner in [Vector2(-lx, -0.38), Vector2(lx, -0.38), Vector2(-lx, 0.38), Vector2(lx, 0.38)]:
		var hip := Node3D.new()
		hip.position = Vector3(corner.x, 0.36, corner.y)
		_body.add_child(hip)
		_part(hip, Vector3(0.2, 0.36, 0.2), Vector3(0, -0.18, 0), hide)
		_legs.append(hip)


## Become another form (after eating a block): rebuilds the model.
func set_variant(block: String) -> void:
	if block == variant:
		return
	variant = block
	if _body:
		_body.queue_free()
		_body = null
		_legs.clear()
		_build_model()
		_hurt_time = 0.3  # a little squash as it changes


## The block in front of its feet that it would eat.
func eat_target() -> Vector3i:
	var fwd := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
	return Vector3i((global_position + fwd * 0.9 + Vector3(0, -0.5, 0)).floor())


## Display name, e.g. "Block Eater" or "Stone Block Eater".
func display_name() -> String:
	return "Block Eater" if variant == "" else "%s Block Eater" % variant.get_slice(":", 1).capitalize()


## What it drops when defeated: [[item, count], ...].
func drops(rng: RandomNumberGenerator) -> Array:
	return [] if variant == "" else [[variant, 1]]


func _process(delta: float) -> void:
	if world and world.remote:
		# Client: follow the host smoothly.
		var t := 1.0 - exp(-12.0 * delta)
		position = position.lerp(target_position, t)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
	# Animation: legs swing while walking, a little bob; a squash when hurt.
	_walk_phase += delta * (9.0 if walking else 0.0)
	var swing := sin(_walk_phase) * (0.6 if walking else 0.0)
	for i in _legs.size():
		_legs[i].rotation.x = swing * (1.0 if i % 3 == 0 else -1.0)
	_body.position.y = absf(sin(_walk_phase)) * 0.04 if walking else 0.0
	_hurt_time = maxf(0.0, _hurt_time - delta)
	var squash := 1.0 - 0.15 * sin(_hurt_time / 0.3 * PI) if _hurt_time > 0.0 else 1.0
	_body.scale = Vector3(1.0 / squash, squash, 1.0 / squash)


# --- Behaviour (where the world is owned) ----------------------------------------------

func simulate(delta: float) -> void:
	_state_time -= delta
	if _state_time <= 0.0:
		_pick_state()
	var speed := 0.0
	match _state:
		"wander":
			speed = WALK_SPEED
		"flee":
			speed = FLEE_SPEED
			var away := global_position - _flee_from
			if away.length() > 0.1:
				_heading = atan2(-away.x, -away.z)
	var dir := Vector3(-sin(_heading), 0, -cos(_heading))
	if speed > 0.0 and _danger_ahead(dir):
		_heading += PI * (0.5 + _rng.randf())  # water or a drop ahead: turn away
		dir = Vector3(-sin(_heading), 0, -cos(_heading))
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	velocity.y = maxf(velocity.y - GRAVITY * delta, -40.0)
	var r: Dictionary = world.move_box(global_position, BOX, velocity * delta, _mover_step)
	if r.hit_wall and _state == "wander":
		_heading += PI * 0.5 + _rng.randf() * PI  # blocked: try another way
	if r.on_floor:
		velocity.y = 0.0
	global_position = r.position
	walking = speed > 0.0
	rotation.y = lerp_angle(rotation.y, _heading, 1.0 - exp(-8.0 * delta))


func _pick_state() -> void:
	if _state == "flee" or _rng.randf() < 0.45:
		_state = "idle"  # graze a while
		_state_time = _rng.randf_range(2.0, 5.0)
		wants_to_eat = variant == "" and _rng.randf() < EAT_CHANCE
	else:
		_state = "wander"
		_state_time = _rng.randf_range(2.5, 6.0)
		_heading += _rng.randf_range(-1.6, 1.6)


## Water at the next step, or a fall of more than 3 blocks.
func _danger_ahead(dir: Vector3) -> bool:
	var ahead := Vector3i((global_position + dir * 0.9).floor())
	for dy in range(1, -4, -1):
		var b := world.get_block(ahead + Vector3i(0, dy, 0))
		if world.is_fluid(b):
			return true
		if b != 0:
			return false
	return true


## Returns true if this hit killed it.
func hurt(amount: int, from: Vector3) -> bool:
	health -= amount
	_hurt_time = 0.3
	_flee_from = from
	_state = "flee"
	_state_time = 3.0
	var push := (global_position - from)
	push.y = 0.0
	velocity = push.normalized() * 4.0 + Vector3(0, 5.0, 0)  # knocked back
	return health <= 0


## Hit-test for the player's attack: distance along the ray, or -1.
func ray_distance(origin: Vector3, dir: Vector3, max_distance: float) -> float:
	var box := AABB(global_position - Vector3(BOX.x / 2, 0, BOX.z / 2), BOX)
	var hit = box.intersects_ray(origin, dir)
	if hit == null:
		return -1.0
	var d: float = (hit as Vector3).distance_to(origin)
	return d if d <= max_distance else -1.0
