extends Node3D
## The local player: walks with gravity, or flies (F to toggle), colliding with
## blocks through the engine's box-vs-voxel mover (no physics engine).
##
## Walk: WASD, Space jump, Ctrl sprint, Shift sneak.  Fly: WASD, Space up, Shift down
## (descending onto the ground lands), Ctrl faster.  In water: Space swims up.
## Mouse to look, 1-9 / wheel pick a hotbar slot, right click places its block.
## Survival: hold left click to mine (time from the block's "hardness"); the
## drop goes into the inventory, and placing uses items up.
## Creative: left click breaks instantly, nothing is used up.
## Pausing is handled by the game scene, which pauses this node.
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
const MINE_SECONDS_PER_HARDNESS := 0.75
const MIN_MINE_SECONDS := 0.1

## Benchmark mode: fly straight ahead without collisions, don't grab the mouse.
@export var autopilot := false
## Multiplayer client: called with (position: Vector3i, block: int) instead of
## editing locally; the host applies the edit and sends it back.
var edit_handler := Callable()

var world: World
var camera: Camera3D
var inventory := Inventory.new()
var creative := false
## Set by the game while a screen (inventory, pause) has the mouse.
var ui_open := false
## 0..1 while holding left click on a block in survival (for the HUD).
var mining_progress := 0.0
var velocity := Vector3.ZERO
var flying := false
var in_water := false
var on_floor := false
## Movement stays off until the ground around the player has loaded.
## See set_ready_to_move().
var _frozen := true
var selected := 0  # hotbar slot
var _outline: MeshInstance3D
var _mining_target := Vector3i(1 << 30, 0, 0)


func _ready() -> void:
	camera = Camera3D.new()
	camera.position.y = EYE_HEIGHT
	camera.far = 600.0
	add_child(camera)

	_outline = _make_outline()
	_outline.visible = false
	add_child(_outline)
	_outline.top_level = true

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


## The item in the selected hotbar slot ("" if empty).
func selected_item() -> String:
	return inventory.slots[selected].get("id", "")


static func is_placeable(id: String) -> bool:
	var def = Registry.blocks.get(id)
	return def != null and def.get("solid", true) and not def.has("fluid") and id != "core:air"


## Creative: one of every placeable block (counts are never used up).
func fill_creative() -> void:
	var ids := Array(Registry.block_ids).filter(func(id): return is_placeable(id))
	for i in mini(ids.size(), Inventory.SIZE):
		inventory.slots[i] = {"id": ids[i], "count": 1}
	inventory.changed.emit()


# --- Input ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if autopilot or ui_open:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * Settings.mouse_sensitivity
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * Settings.mouse_sensitivity, -1.55, 1.55)
	elif event.is_action_pressed(&"toggle_fly"):
		flying = not flying
		velocity.y = 0.0
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			selected = event.keycode - KEY_1
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT and creative:
			_break_target()  # survival mines over time in _process
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_place()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			selected = (selected + 1) % Inventory.HOTBAR
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			selected = (selected - 1 + Inventory.HOTBAR) % Inventory.HOTBAR


# --- Movement --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if autopilot:
		global_position += -camera.global_basis.z * BENCH_SPEED * delta
		return
	if _frozen:
		velocity = Vector3.ZERO
		return

	var input := Vector2(
		Input.get_action_strength(&"move_right") - Input.get_action_strength(&"move_left"),
		Input.get_action_strength(&"move_back") - Input.get_action_strength(&"move_forward")).limit_length(1.0)
	if ui_open:
		input = Vector2.ZERO
	var wish := basis * Vector3(input.x, 0, input.y)  # yaw only: looking down doesn't slow you
	var sprint := Input.is_action_pressed(&"sprint") and not ui_open
	var sneak := Input.is_action_pressed(&"sneak") and not ui_open
	var jump := Input.is_action_pressed(&"jump") and not ui_open
	in_water = world.is_fluid(world.get_block(Vector3i((global_position + Vector3(0, 0.9, 0)).floor())))

	if flying:
		var speed := FLY_SPRINT_SPEED if sprint else FLY_SPEED
		var vertical := float(jump) - float(sneak)
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
			if jump:
				velocity.y = minf(velocity.y + 20.0 * delta, SWIM_UP_SPEED)
		else:
			velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL_SPEED)
			if on_floor and jump:
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

func _process(delta: float) -> void:
	if autopilot or world == null:
		return
	var hit := _target()
	_outline.visible = hit.hit
	if hit.hit:
		_outline.global_position = Vector3(hit.position) + Vector3.ONE * 0.5
	_update_mining(hit, delta)


## Survival mining: hold left click on the same block until it breaks.
func _update_mining(hit: Dictionary, delta: float) -> void:
	var holding := not creative and not ui_open and not _frozen \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding or not hit.hit:
		mining_progress = 0.0
		_mining_target = Vector3i(1 << 30, 0, 0)
		return
	if hit.position != _mining_target:
		_mining_target = hit.position
		mining_progress = 0.0
	mining_progress += delta / mine_seconds(Registry.block_ids[hit.block])
	if mining_progress >= 1.0:
		mining_progress = 0.0
		_break_target()


static func mine_seconds(block_id: String) -> float:
	var def: Dictionary = Registry.blocks.get(block_id, {})
	return maxf(MIN_MINE_SECONDS, float(def.get("hardness", 1.0)) * MINE_SECONDS_PER_HARDNESS)


## What breaking a block gives: its "drops" ("" = nothing), else the block itself.
static func drop_of(block_id: String) -> String:
	var def: Dictionary = Registry.blocks.get(block_id, {})
	return str(def.get("drops", block_id))


func _target() -> Dictionary:
	return world.raycast(camera.global_position, -camera.global_basis.z, REACH)


func _break_target() -> void:
	var hit := _target()
	if not hit.hit:
		return
	var broken: String = Registry.block_ids[hit.block]
	_apply_edit(hit.position, Registry.block_index("core:air"))
	if not creative:
		var drop := drop_of(broken)
		if drop != "":
			inventory.add(drop, 1)  # a full inventory loses it (no dropped items yet)


func _place() -> void:
	var item := selected_item()
	if not is_placeable(item):
		return
	var hit := _target()
	if not hit.hit or overlaps_block(global_position, hit.previous):
		return  # nothing to place against, or it would be inside you
	_apply_edit(hit.previous, Registry.block_index(item))
	if not creative:
		inventory.take_one(selected)


## Changes a block here, or asks the host in multiplayer (which applies it and
## sends it back). Inventory changes happen right away either way.
func _apply_edit(pos: Vector3i, block: int) -> void:
	if edit_handler.is_valid():
		edit_handler.call(pos, block)
	else:
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
