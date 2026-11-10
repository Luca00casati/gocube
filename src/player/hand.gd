class_name Hand
extends Node3D
## First-person arm and held item, attached to the camera. Drawn in front of
## the world, the item in front of the arm; the sleeve covers the wrist and
## the hand comes out of its cuff (LAYER_*). Swings when you hit,
## place or mine; bobs while walking; lit by the time of day (and dimmer
## underground).

const SHADER := preload("res://src/player/hand.gdshader")
const REST := Vector3(0.36, -0.34, -0.52)   # where the hand rests (camera space)
## The arm turns about the shoulder, off the bottom right of the screen, so
## the sleeve always stays behind the hand.
const SHOULDER := Vector3(0.52, -0.62, 0.02)
## A swing: a small wind-up, a quick arc down towards the crosshair that
## speeds up into the blow, then an easy return. Times are fractions of
## SWING_TIME; poses are [rotation about the shoulder, push (camera space),
## tilt of the held item (it chops forward; the arm stays put)].
const SWING_TIME := 0.3
const SWING_WIND := 0.25
const SWING_HIT := 0.5
const SWING_REST := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
const SWING_UP := [Vector3(0.1, -0.05, 0.0), Vector3(0.0, 0.015, 0.03), Vector3(0.35, 0.0, 0.0)]
const SWING_DOWN := [Vector3(0.12, 0.32, 0.1), Vector3(-0.02, 0.06, -0.06), Vector3(-0.8, 0.0, 0.0)]

var player: Node3D        # player.gd
var atlas: BlockAtlas
var _arm: MeshInstance3D
var _item: MeshInstance3D
var _shown_item := "?"
var _mats: Array[ShaderMaterial] = []       # all, for the light
var _item_mats: Array[ShaderMaterial] = []  # the held item's (replaced when it changes)
var _grip: Node3D           # the hand and item, placed relative to the shoulder
var _tilt: Node3D           # the held item tips on this (the arm doesn't)
var _swing := -1.0          # time into the swing (-1: none)
var _swing_next := false    # another one asked for meanwhile: it follows
var _bob := 0.0
var _bob_amount := 0.0      # 0 standing .. 1 walking (smoothed, so the bob never snaps)
var _light := Color.WHITE
var _light_timer := 0.0


func _ready() -> void:
	position = SHOULDER
	_grip = Node3D.new()
	_grip.position = REST - SHOULDER
	add_child(_grip)
	_arm = MeshInstance3D.new()
	var arm_mesh := BoxMesh.new()
	arm_mesh.size = Vector3(0.135, 0.135, 0.42)  # wider than the hand: a cuff around the wrist
	_arm.mesh = arm_mesh
	_arm.material_override = _mat(null, Color(0.34, 0.46, 0.72), LAYER_ARM)  # sleeve
	_arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arm.position = Vector3(0.0, -0.02, 0.12)
	_arm.rotation = Vector3(0.15, -0.12, 0.0)
	_grip.add_child(_arm)
	var fist := MeshInstance3D.new()
	var fist_mesh := BoxMesh.new()
	fist_mesh.size = Vector3(0.1, 0.1, 0.12)
	fist.mesh = fist_mesh
	fist.material_override = _mat(null, Color(0.86, 0.68, 0.54), LAYER_HAND)  # hand
	fist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fist.position = Vector3(0, 0, -0.22)  # the wrist inside the sleeve
	_arm.add_child(fist)
	_item = MeshInstance3D.new()
	_item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tilt = Node3D.new()
	_grip.add_child(_tilt)
	_tilt.add_child(_item)


## Drawing order: the hand and sleeve share a layer, so real depth decides
## between them (the sleeve covers the wrist, the hand comes out of it); the
## held item is drawn in front of both (see hand.gdshader).
const LAYER_HAND := 0
const LAYER_ARM := 0
const LAYER_ITEM := 2


func _mat(tex: Texture2D, tint: Color, layer: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("layer", layer)
	m.set_shader_parameter("use_tex", tex != null)
	if tex:
		m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("tint", tint)
	_mats.append(m)
	return m


## A swing (hitting, placing, using, mining). One asked for during another
## plays right after it, whole.
func swing() -> void:
	if _swing < 0.0:
		_swing = 0.0
	else:
		_swing_next = true


## Places the arm and item for a swing pose (plus the walking bob).
func apply_pose(pose: Array, bob := Vector3.ZERO) -> void:
	position = SHOULDER + bob + pose[1]
	rotation = pose[0]
	_tilt.rotation = pose[2]


## Where the fist is, in camera space (for tests).
func fist_position() -> Vector3:
	var fist: Node3D = _arm.get_child(0)
	return transform * (_grip.transform * (_arm.transform * fist.position))


## The swing's [rotation, push, tilt] at `t` (0..1 of SWING_TIME).
static func swing_pose(t: float) -> Array:
	var ease := func(x: float) -> float:
		x = clampf(x, 0.0, 1.0)
		return x * x * (3.0 - 2.0 * x)
	var a: Array
	var b: Array
	var u: float
	if t < SWING_WIND:
		a = SWING_REST
		b = SWING_UP
		u = ease.call(t / SWING_WIND)
	elif t < SWING_HIT:
		a = SWING_UP
		b = SWING_DOWN
		u = pow((t - SWING_WIND) / (SWING_HIT - SWING_WIND), 2.0)  # speeds up into the blow
	else:
		a = SWING_DOWN
		b = SWING_REST
		u = ease.call((t - SWING_HIT) / (1.0 - SWING_HIT))
	return [(a[0] as Vector3).lerp(b[0], u), (a[1] as Vector3).lerp(b[1], u), (a[2] as Vector3).lerp(b[2], u)]


func _process(delta: float) -> void:
	if player == null:
		return
	visible = not player.dead and not player.autopilot and not player.sleeping and player.view == player.View.FIRST
	var item: String = player.selected_item()
	if item != _shown_item:
		_shown_item = item
		_show_item(item)
		_light_timer = 0.0
	# Keep swinging while mining, one whole swing after another.
	if player.mining_progress > 0.0 and _swing < 0.0:
		_swing = 0.0
	var pose := SWING_REST
	if _swing >= 0.0:
		_swing += delta
		if _swing >= SWING_TIME:
			_swing = 0.0 if _swing_next else -1.0
			_swing_next = false
		if _swing >= 0.0:
			pose = swing_pose(_swing / SWING_TIME)
	# Walking bob, faded in and out (never snapping when you stop).
	var moving: bool = player.on_floor and Vector2(player.velocity.x, player.velocity.z).length() > 0.5
	_bob_amount = lerpf(_bob_amount, 1.0 if moving else 0.0, 1.0 - exp(-8.0 * delta))
	_bob += delta * 9.0 * _bob_amount
	var bob := Vector3(cos(_bob * 0.5) * 0.012, -absf(sin(_bob * 0.5)) * 0.02, 0) * _bob_amount
	apply_pose(pose, bob)
	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.05
		_update_light()


func _show_item(item: String) -> void:
	_item.visible = item != ""
	_arm.visible = true
	if item == "":
		return
	var mesh := ItemDrop.model_mesh(item, atlas)
	_item.mesh = mesh
	for m in _item_mats:
		_mats.erase(m)
	_item_mats.clear()
	var is_block := Registry.blocks.has(item) and mesh.get_surface_count() > 1  # boxes, not a flat icon
	for i in mesh.get_surface_count():
		var src := mesh.surface_get_material(i) as ShaderMaterial
		var m := _mat(src.get_shader_parameter("tex"), Color.WHITE, LAYER_ITEM)
		_item_mats.append(m)
		_item.set_surface_override_material(i, m)
	if is_block:
		_item.scale = Vector3.ONE * 1.1
		_item.position = Vector3(-0.04, 0.04, -0.2)
		_item.rotation = Vector3(0.1, 0.75, 0.0)
	else:
		_item.scale = Vector3.ONE * 0.85
		_item.position = Vector3(-0.02, 0.1, -0.2)
		_item.rotation = Vector3(0.0, -1.35, 0.35)  # held edge-on, tip up
	_update_light()


## The light where the eyes are, like everything else (World.light_for): dark
## at night and in caves, bright by a torch (your own one too).
func _update_light() -> void:
	var c: Color = player.world.light_for(player.camera.global_position, DayCycle.NIGHT_CREATURE_LIGHT)
	_light = c
	for m in _mats:
		m.set_shader_parameter("light", Vector3(c.r, c.g, c.b))
