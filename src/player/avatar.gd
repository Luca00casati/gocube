extends Node3D
## A player's figure: another player as seen by us (with a name tag), or our
## own body in the third-person views (no tag; it follows our player).
## The node's origin is the player's eye (camera) position. Looks (skin, hair,
## clothes) come from the player's id, so everyone sees the same person.
##
## Animation comes from movement: for other players the speed is worked out
## from the positions the host sends; flags and a swing counter come with them.

const EYE_HEIGHT := 1.62
const FLAG_SNEAK := 1
const FLAG_SLEEP := 2
const FLAG_FLY := 4

var target_position := Vector3.ZERO
var target_yaw := 0.0
var pitch := 0.0          # looking up (+) or down (-): tilts the head
var light := 0            # level of the light they hold (a torch), 0 for none
var item := ""            # what they hold in the right hand
var flags := 0            # FLAG_*
var swings := 0           # goes up by one with every swing (hit, place, mine...)
## False for our own body: its parent (the player) moves and turns it and
## sets `velocity` / `on_floor` itself.
var follow := true
var velocity := Vector3.ZERO
var on_floor := true
var atlas: BlockAtlas     # for the held item's model
var world: World          # to light the figure by where it stands

var figure: Figure
var _held: MeshInstance3D
var _shown_item := "-"
var _seen_swings := 0
var _last := Vector3.INF


## Skin, hair and clothes for player `peer_id` (stable for an id).
static func looks(peer_id: int) -> Dictionary:
	var h := absi(hash(peer_id))
	var skins := [Color(0.96, 0.80, 0.66), Color(0.87, 0.67, 0.5), Color(0.72, 0.52, 0.36), Color(0.5, 0.34, 0.24)]
	var hairs := [Color(0.25, 0.16, 0.1), Color(0.1, 0.08, 0.07), Color(0.75, 0.55, 0.25), Color(0.55, 0.24, 0.12)]
	var shirt := Color.from_hsv(fmod(peer_id * 0.618034, 1.0), 0.6, 0.85)
	return {
		"skin": skins[h % skins.size()],
		"hair": hairs[(h / 7) % hairs.size()],
		"shirt": shirt,
		"sleeve": shirt.darkened(0.12),
		"trousers": Color.from_hsv(0.6 + 0.08 * ((h / 13) % 3), 0.35, 0.3 + 0.1 * ((h / 29) % 2)),
		"shoes": Color(0.2, 0.15, 0.12),
	}


func setup(player_name: String, peer_id: int, block_atlas: BlockAtlas = null) -> void:
	atlas = block_atlas
	var look := looks(peer_id)
	figure = Figure.new()
	figure.build(look)
	figure.position.y = -EYE_HEIGHT
	add_child(figure)
	_dress(look)
	_held = MeshInstance3D.new()
	_held.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	figure.hand.add_child(_held)
	if player_name == "":
		return
	var tag := Label3D.new()
	tag.text = player_name
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.fixed_size = true
	tag.pixel_size = 0.0015
	tag.outline_size = 6
	tag.position.y = 0.55
	tag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tag)


## Face and hair on the head (it faces -Z; its box spans y 0..0.44).
func _dress(look: Dictionary) -> void:
	var head: Node3D = figure.joints.head
	var hair := BlockEater._mat("figure_hair_" + str(look.hair), look.hair)
	var white := BlockEater._mat("figure_eye_white", Color(0.95, 0.95, 0.95))
	var dark := BlockEater._mat("figure_eye", Color(0.12, 0.1, 0.12))
	var mouth := BlockEater._mat("figure_mouth", Color(0.55, 0.28, 0.25))
	figure.add_box(head, Vector3(0.46, 0.12, 0.46), Vector3(0, 0.41, 0), hair)          # top
	figure.add_box(head, Vector3(0.46, 0.3, 0.06), Vector3(0, 0.29, 0.205), hair)       # back
	for side in [-1, 1]:
		figure.add_box(head, Vector3(0.05, 0.18, 0.4), Vector3(0.205 * side, 0.33, 0.02), hair)  # sides
		figure.add_box(head, Vector3(0.1, 0.06, 0.02), Vector3(0.1 * side, 0.21, -0.225), white)
		figure.add_box(head, Vector3(0.05, 0.06, 0.02), Vector3(0.085 * side, 0.21, -0.23), dark)
		figure.add_box(head, Vector3(0.11, 0.03, 0.02), Vector3(0.1 * side, 0.27, -0.225), hair)  # brows
	figure.add_box(head, Vector3(0.14, 0.03, 0.02), Vector3(0, 0.09, -0.225), mouth)
	figure.add_box(figure.joints.torso, Vector3(0.52, 0.06, 0.29), Vector3(0, 0.03, 0),
			BlockEater._mat("figure_belt", Color(0.22, 0.16, 0.1)))


func _process(delta: float) -> void:
	var t := FrameProfiler.begin()
	_process_step(delta)
	FrameProfiler.add(&"figures", t)


func _process_step(delta: float) -> void:
	if follow:
		# Smooth between the 20 Hz network updates; the speed comes from how
		# far the figure moves.
		var t := 1.0 - exp(-15.0 * delta)
		position = position.lerp(target_position, t)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
		if _last != Vector3.INF and delta > 0.0:
			velocity = velocity.lerp((position - _last) / delta, 1.0 - exp(-10.0 * delta))
		_last = position
		on_floor = flags & FLAG_FLY == 0 and absf(velocity.y) < 1.5
	figure.move_speed = Vector2(velocity.x, velocity.z).length()
	figure.vertical_speed = velocity.y
	figure.on_floor = on_floor
	figure.sneaking = flags & FLAG_SNEAK != 0
	figure.lying = flags & FLAG_SLEEP != 0
	figure.pitch = pitch
	# Asleep the eye is on the pillow: the head goes there, the body along the bed.
	var lie := figure.lie_amount()
	figure.position = Vector3(0, -EYE_HEIGHT, 0).lerp(Vector3(0, -0.3, -1.35), lie)
	if world:  # (origin: the eyes; light at the chest)
		var at := global_position + Vector3(0, -0.6, 0)
		figure.set_light(world.light_for(at, DayCycle.NIGHT_CREATURE_LIGHT))
		ItemDrop.light_model(_held, world, at)
	if swings != _seen_swings:
		_seen_swings = swings
		figure.swing()
	if item != _shown_item:
		_show_item(item)


func _show_item(id: String) -> void:
	_shown_item = id
	_held.visible = id != "" and atlas != null
	if not _held.visible:
		return
	_held.mesh = ItemDrop.model_mesh(id, atlas)
	var is_block := Registry.blocks.has(id) and _held.mesh.get_surface_count() > 1
	if is_block:  # a small cube (0.25 m) in the fist
		_held.scale = Vector3.ONE * 0.9
		_held.position = Vector3(0, -0.08, -0.06)
		_held.rotation = Vector3(0, 0.6, 0)
	else:  # a flat item (tool, torch, stick) held by its lower corner, tip forward and up
		_held.scale = Vector3.ONE * 0.85
		_held.position = Vector3(0, 0.1, -0.12)
		_held.rotation = Vector3(0, PI / 2, 0)


## Hurt: a red flash.
func flash() -> void:
	figure.flash()
