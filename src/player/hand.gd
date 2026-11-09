class_name Hand
extends Node3D
## First-person arm and held item, attached to the camera. Drawn in front of
## the world, the item in front of the hand in front of the arm (LAYER_*). Swings when you hit,
## place or mine; bobs while walking; lit by the time of day (and dimmer
## underground).

const SHADER := preload("res://src/player/hand.gdshader")
const REST := Vector3(0.36, -0.34, -0.52)
const SWING_TIME := 0.25

var player: Node3D        # player.gd
var atlas: BlockAtlas
var _arm: MeshInstance3D
var _item: MeshInstance3D
var _shown_item := "?"
var _mats: Array[ShaderMaterial] = []       # all, for the light
var _item_mats: Array[ShaderMaterial] = []  # the held item's (replaced when it changes)
var _swing := 0.0
var _bob := 0.0
var _light := 1.0
var _light_timer := 0.0


func _ready() -> void:
	position = REST
	_arm = MeshInstance3D.new()
	var arm_mesh := BoxMesh.new()
	arm_mesh.size = Vector3(0.11, 0.11, 0.42)
	_arm.mesh = arm_mesh
	_arm.material_override = _mat(null, Color(0.34, 0.46, 0.72), LAYER_ARM)  # sleeve
	_arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arm.position = Vector3(0.0, -0.02, 0.12)
	_arm.rotation = Vector3(0.15, -0.12, 0.0)
	add_child(_arm)
	var fist := MeshInstance3D.new()
	var fist_mesh := BoxMesh.new()
	fist_mesh.size = Vector3(0.12, 0.12, 0.12)
	fist.mesh = fist_mesh
	fist.material_override = _mat(null, Color(0.86, 0.68, 0.54), LAYER_HAND)  # hand
	fist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fist.position = Vector3(0, 0, -0.24)
	_arm.add_child(fist)
	_item = MeshInstance3D.new()
	_item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_item)


## Drawing order, front last: the held item in front of the hand, the hand in
## front of the arm (see hand.gdshader).
const LAYER_ARM := 0
const LAYER_HAND := 1
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


## A quick swing (hitting, placing, using).
func swing() -> void:
	if _swing <= 0.0:
		_swing = SWING_TIME


func _process(delta: float) -> void:
	if player == null:
		return
	visible = not player.dead and not player.autopilot and not player.sleeping
	var item: String = player.selected_item()
	if item != _shown_item:
		_shown_item = item
		_show_item(item)
		_light_timer = 0.0
	# Keep swinging while mining.
	if player.mining_progress > 0.0 and _swing <= 0.0:
		_swing = SWING_TIME
	var t := 0.0
	if _swing > 0.0:
		_swing = maxf(0.0, _swing - delta)
		t = sin((1.0 - _swing / SWING_TIME) * PI)
	var moving: bool = player.on_floor and Vector2(player.velocity.x, player.velocity.z).length() > 0.5
	_bob += delta * (9.0 if moving else 0.0)
	var bob := Vector3(cos(_bob * 0.5) * 0.012, -absf(sin(_bob * 0.5)) * 0.02, 0) if moving else Vector3.ZERO
	position = REST + bob + Vector3(-0.08 * t, 0.06 * t, -0.12 * t)
	rotation = Vector3(-0.9 * t, 0.25 * t, 0.0)
	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.25
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


## Daylight, dimmed when something is overhead (caves, indoors).
func _update_light() -> void:
	var day: float = player.get_meta("daylight", 1.0)
	var eye: Vector3 = player.camera.global_position
	var covered: bool = player.world.raycast(eye, Vector3.UP, 64.0).hit
	_light = maxf(0.25, day * (0.55 if covered else 1.0))
	if player.get_meta("hand_light", 0.0) > 0.0:
		_light = 1.0  # holding a torch
	for m in _mats:
		m.set_shader_parameter("light", _light)
