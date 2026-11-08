extends CharacterBody3D
## The local player: walks with gravity and collisions, or flies (F to toggle).
##
## Walk: WASD, Space jump, Ctrl sprint, Shift sneak.  Fly: WASD, Space up, Shift down
## (descending onto the ground lands), Ctrl faster.  Mouse to look, left click breaks, right click places the selected
## block (1-9 to pick).  Pausing is handled by the game scene, which pauses this node.
##
## The node origin is at the feet; `camera` sits at eye height.

const EYE_HEIGHT := 1.62
const HEIGHT := 1.8
const RADIUS := 0.3
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

@export var mouse_sensitivity := 0.003
@export var view_distance := 128
## Benchmark mode: fly straight ahead without physics, don't grab the mouse.
@export var autopilot := false
## Multiplayer host: 1, so the terrain knows this viewer is local (no sending).
var network_peer_id := -1
## Multiplayer client: called with (position: Vector3i, block: int) instead of
## editing locally; the host applies the edit and sends it back.
var edit_handler := Callable()

var world: World
var camera: Camera3D
var flying := false
## Physics stays off until the ground around the player has loaded, so nobody
## falls through chunks that don't have collisions yet. See set_ready_to_move().
var _frozen := true
var _placeable: PackedStringArray = []
var _selected := 0
var _outline: MeshInstance3D


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	shape.shape = capsule
	shape.position.y = HEIGHT / 2
	add_child(shape)

	camera = Camera3D.new()
	camera.position.y = EYE_HEIGHT
	camera.far = 600.0
	add_child(camera)

	var viewer := VoxelViewer.new()  # tells the terrain where to load chunks
	viewer.view_distance = view_distance
	camera.add_child(viewer)
	if network_peer_id >= 0:
		viewer.set_network_peer_id(network_peer_id)

	_outline = _make_outline()
	_outline.visible = false
	add_child(_outline)
	_outline.top_level = true

	for id in Registry.block_ids:
		var def = Registry.blocks.get(id)
		if def != null and def.get("solid", true):
			_placeable.append(id)
	if autopilot:
		flying = true
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Called by the game once the spawn area is loaded: moves the player out of any
## solid blocks and turns physics on.
func set_ready_to_move() -> void:
	_unstuck()
	_frozen = false


## Eye position and view direction; this is what other players see.
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
	if _frozen or (not flying and not _ground_loaded()):
		velocity = Vector3.ZERO
		return

	var input := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))).limit_length(1.0)
	var wish := basis * Vector3(input.x, 0, input.y)  # yaw only: looking down doesn't slow you
	var sprint := Input.is_key_pressed(KEY_CTRL)
	var sneak := Input.is_key_pressed(KEY_SHIFT)

	if flying:
		var speed := FLY_SPRINT_SPEED if sprint else FLY_SPEED
		var vertical := float(Input.is_key_pressed(KEY_SPACE)) - float(sneak)
		var target := Vector3(wish.x * speed, vertical * speed, wish.z * speed)
		velocity = velocity.lerp(target, 1.0 - exp(-10.0 * delta))
	else:
		var speed := SNEAK_SPEED if sneak else (SPRINT_SPEED if sprint else WALK_SPEED)
		var accel := ACCEL_GROUND if is_on_floor() else ACCEL_AIR
		var horizontal := Vector2(velocity.x, velocity.z).lerp(
				Vector2(wish.x, wish.z) * speed, 1.0 - exp(-accel * delta))
		velocity.x = horizontal.x
		velocity.z = horizontal.y
		velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL_SPEED)
		if is_on_floor() and Input.is_key_pressed(KEY_SPACE):
			velocity.y = JUMP_VELOCITY
	move_and_slide()
	if flying and is_on_floor() and sneak:
		flying = false  # flying down onto the ground ends flight


## True when the chunks around the player have meshes (and so collisions).
func _ground_loaded() -> bool:
	return world.terrain.is_area_meshed(AABB(global_position - Vector3(2, 3, 2), Vector3(4, 6, 4)))


## Moves up until feet and head are in non-solid blocks (spawned inside a hill,
## or a block appeared where we stand).
func _unstuck() -> void:
	var tool := world.get_tool()
	tool.channel = VoxelBuffer.CHANNEL_TYPE
	var cell := Vector3i(global_position.floor())
	for dy in 128:
		var feet := cell + Vector3i(0, dy, 0)
		if not _is_solid(tool, feet) and not _is_solid(tool, feet + Vector3i.UP):
			if dy > 0:
				global_position.y = feet.y + 0.01
			return


static func _is_solid(tool: VoxelTool, cell: Vector3i) -> bool:
	var id := tool.get_voxel(cell)
	if id <= 0 or id >= Registry.block_ids.size():
		return false
	var def = Registry.blocks.get(Registry.block_ids[id])
	return def == null or def.get("solid", true)  # missing-mod blocks count as solid


# --- Building ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if autopilot or world == null:
		return
	var hit := _target()
	_outline.visible = hit != null
	if hit:
		_outline.global_position = Vector3(hit.position) + Vector3.ONE * 0.5


func _target() -> VoxelRaycastResult:
	return world.get_tool().raycast(camera.global_position, -camera.global_basis.z, REACH)


func _edit(breaking: bool) -> void:
	var hit := _target()
	if hit == null:
		return
	var pos: Vector3i = hit.position if breaking else hit.previous_position
	if not breaking and overlaps_block(global_position, pos):
		return  # don't build inside yourself
	var block := Registry.block_index("core:air") if breaking else Registry.block_index(_placeable[_selected])
	if edit_handler.is_valid():
		edit_handler.call(pos, block)
		return
	var tool := world.get_tool()
	tool.channel = VoxelBuffer.CHANNEL_TYPE
	tool.set_voxel(pos, block)


## Whether a player standing with feet at `feet` overlaps block `cell`.
static func overlaps_block(feet: Vector3, cell: Vector3i) -> bool:
	var body := AABB(feet - Vector3(RADIUS, 0, RADIUS), Vector3(RADIUS * 2, HEIGHT, RADIUS * 2))
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
