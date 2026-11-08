extends Node3D
## The local player: walks with gravity, or flies (F to toggle), colliding with
## blocks through the engine's box-vs-voxel mover (no physics engine).
##
## Walk: WASD, Space jump, Ctrl sprint, Shift sneak.  Fly: WASD, Space up, Shift down
## (descending onto the ground lands), Ctrl faster.  In water: Space swims up.
## Mouse to look, left click breaks, right click places the selected block
## (1-9 / wheel to pick). Pausing is handled by the game scene, which pauses this node.
##
## The node origin is at the feet; `camera` sits at eye height.

const EYE_HEIGHT := 1.62
const HEIGHT := 1.8
const RADIUS := 0.3
const BODY := Vector3(RADIUS * 2, HEIGHT, RADIUS * 2)
const WALK_SPEED := 4.3
const SPRINT_SPEED := 5.6
const SNEAK_SPEED := 1.3
const FLY_SPEED := 11.0
const FLY_SPRINT_SPEED := 22.0
const JUMP_VELOCITY := 8.4    # with GRAVITY: ~1.26 blocks high, enough to climb one block
const GRAVITY := 28.0
const MAX_FALL_SPEED := 60.0
const ACCEL_GROUND := 14.0
const ACCEL_AIR := 3.0
const REACH := 6.0
const BENCH_SPEED := 20.0
const SWIM_SPEED_FACTOR := 0.6
const SWIM_UP_SPEED := 3.5
const SINK_SPEED := 2.0

@export var mouse_sensitivity := 0.003
## Benchmark mode: fly straight ahead without collisions, don't grab the mouse.
@export var autopilot := false
## Multiplayer client: called with (position: Vector3i, block: int) instead of
## editing locally; the host applies the edit and sends it back.
var edit_handler := Callable()

var world: World
var camera: Camera3D
var velocity := Vector3.ZERO
var flying := false
var in_water := false
var on_floor := false
## Movement stays off until the ground around the player has loaded.
## See set_ready_to_move().
var _frozen := true
var _placeable: PackedStringArray = []
var _selected := 0
var _outline: MeshInstance3D


func _ready() -> void:
	camera = Camera3D.new()
	camera.position.y = EYE_HEIGHT
	camera.far = 600.0
	add_child(camera)

	_outline = _make_outline()
	_outline.visible = false
	add_child(_outline)
	_outline.top_level = true

	for id in Registry.block_ids:
		var def = Registry.blocks.get(id)
		if def != null and def.get("solid", true) and not def.has("fluid"):
			_placeable.append(id)
	if autopilot:
		flying = true
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Called by the game once the spawn area is loaded: moves the player out of any
## solid blocks and turns movement on.
func set_ready_to_move() -> void:
	_unstuck()
	_frozen = false


## View direction; other players see this.
func look_yaw() -> float:
	return rotation.y


func look_pitch() -> float:
	return camera.rotation.x


func set_look(pitch: float, yaw: float) -> void:
	rotation.y = yaw
	if camera:
		camera.rotation.x = pitch
	else:
		ready.connect(func(): camera.rotation.x = pitch, CONNECT_ONE_SHOT)


func selected_block() -> String:
	return _placeable[_selected] if not _placeable.is_empty() else ""


# --- Input ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if autopilot:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * mouse_sensitivity, -1.55, 1.55)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_selected = mini(event.keycode - KEY_1, _placeable.size() - 1)
		elif event.keycode == KEY_F:
			flying = not flying
			velocity.y = 0.0
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_edit(true)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_edit(false)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_selected = (_selected + 1) % _placeable.size()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_selected = (_selected - 1 + _placeable.size()) % _placeable.size()


# --- Movement --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if autopilot:
		global_position += -camera.global_basis.z * BENCH_SPEED * delta
		return
	if _frozen:
		velocity = Vector3.ZERO
		return

	var input := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))).limit_length(1.0)
	var wish := basis * Vector3(input.x, 0, input.y)  # yaw only: looking down doesn't slow you
	var sprint := Input.is_key_pressed(KEY_CTRL)
	var sneak := Input.is_key_pressed(KEY_SHIFT)
	in_water = world.is_fluid(world.get_block(Vector3i((global_position + Vector3(0, 0.9, 0)).floor())))

	if flying:
		var speed := FLY_SPRINT_SPEED if sprint else FLY_SPEED
		var vertical := float(Input.is_key_pressed(KEY_SPACE)) - float(sneak)
		var target := Vector3(wish.x * speed, vertical * speed, wish.z * speed)
		velocity = velocity.lerp(target, 1.0 - exp(-10.0 * delta))
	else:
		var speed := SNEAK_SPEED if sneak else (SPRINT_SPEED if sprint else WALK_SPEED)
		var accel := ACCEL_GROUND if on_floor else ACCEL_AIR
		if in_water:
			speed *= SWIM_SPEED_FACTOR
			accel = ACCEL_GROUND
		var horizontal := Vector2(velocity.x, velocity.z).lerp(
				Vector2(wish.x, wish.z) * speed, 1.0 - exp(-accel * delta))
		velocity.x = horizontal.x
		velocity.z = horizontal.y
		if in_water:
			# buoyant: sink slowly, Space swims up
			velocity.y = maxf(velocity.y - GRAVITY * 0.3 * delta, -SINK_SPEED)
			if Input.is_key_pressed(KEY_SPACE):
				velocity.y = minf(velocity.y + 20.0 * delta, SWIM_UP_SPEED)
		else:
			velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL_SPEED)
			if on_floor and Input.is_key_pressed(KEY_SPACE):
				velocity.y = JUMP_VELOCITY

	var r: Dictionary = world.move_box(global_position, BODY, velocity * delta, 0.0)
	var moved: Vector3 = r.position - global_position
	global_position = r.position
	on_floor = r.on_floor
	# Lose the velocity that ran into something.
	if r.on_floor or r.hit_ceiling:
		velocity.y = 0.0
	if r.hit_wall:
		if absf(moved.x) < absf(velocity.x * delta) - 1e-4:
			velocity.x = 0.0
		if absf(moved.z) < absf(velocity.z * delta) - 1e-4:
			velocity.z = 0.0
	if flying and on_floor and sneak:
		flying = false  # flying down onto the ground ends flight


## Moves up until the body fits (spawned inside a hill, or a block appeared
## where we stand).
func _unstuck() -> void:
	for dy in 256:
		var p := global_position + Vector3(0, dy, 0)
		if world.is_box_free(p, BODY):
			global_position = p
			return


# --- Building ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if autopilot or world == null:
		return
	var hit := _target()
	_outline.visible = hit.hit
	if hit.hit:
		_outline.global_position = Vector3(hit.position) + Vector3.ONE * 0.5


func _target() -> Dictionary:
	return world.raycast(camera.global_position, -camera.global_basis.z, REACH)


func _edit(breaking: bool) -> void:
	var hit := _target()
	if not hit.hit:
		return
	var pos: Vector3i = hit.position if breaking else hit.previous
	if not breaking and overlaps_block(global_position, pos):
		return  # don't build inside yourself
	var block := Registry.block_index("core:air") if breaking else Registry.block_index(_placeable[_selected])
	if edit_handler.is_valid():
		edit_handler.call(pos, block)
		return
	world.set_block(pos, block)


## Whether a player standing with feet at `feet` overlaps block `cell`.
static func overlaps_block(feet: Vector3, cell: Vector3i) -> bool:
	var body := AABB(feet - Vector3(RADIUS, 0, RADIUS), BODY)
	return body.intersects(AABB(Vector3(cell), Vector3.ONE))


static func _make_outline() -> MeshInstance3D:
	var s := 0.502  # just outside the block faces, so lines don't z-fight
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(Vector3(s if i & 1 else -s, s if i & 2 else -s, s if i & 4 else -s))
	var verts := PackedVector3Array()
	for i in 8:
		for bit in [1, 2, 4]:
			if not (i & bit):
				verts.append(corners[i])
				verts.append(corners[i | bit])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0, 0, 0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
