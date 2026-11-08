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
## Survival also has health: falls over 3 blocks hurt, so does running out of
## breath underwater; health comes back slowly.
## Pausing is handled by the game scene, which pauses this node.

signal footstep(block_id: String, at: Vector3)
signal block_broken(block_id: String, at: Vector3)
## Survival: what breaking a block gave (drop it in the world). For multiplayer
## clients this fires only once the host has confirmed the break (see main).
signal dropped(item: String, at: Vector3)
## Right click on a block with a "block_entity" (chest, furnace).
signal open_block(position: Vector3i)
## Left click on a creature (main decides: local hit or through the host).
signal attack(mob_id: int)
signal block_placed(block_id: String, at: Vector3)
signal splashed(at: Vector3)
signal hurt(amount: int)
signal died
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
const MAX_HEALTH := 20
const MAX_BREATH := 10.0           # seconds underwater before drowning starts
const SAFE_FALL := 3.0             # blocks you can fall without damage
const DROWN_DAMAGE := 2            # per second without breath
const REGEN_DELAY := 4.0           # seconds without damage before healing
const REGEN_INTERVAL := 2.5        # seconds per health point healed
const STRIDE := 1.7                # metres walked per footstep sound

## Benchmark mode: fly straight ahead without collisions, don't grab the mouse.
@export var autopilot := false
## Multiplayer client: called with (position: Vector3i, block: int) instead of
## editing locally; the host applies the edit and sends it back.
var edit_handler := Callable()
## (origin, dir, max_distance) -> {"id", "distance"} or {}: the creature under the crosshair.
var mob_picker := Callable()
const ATTACK_REACH := 4.0
const ATTACK_COOLDOWN := 0.4
var _attack_cooldown := 0.0

var world: World
var camera: Camera3D
var inventory := Inventory.new()
var creative := false
## Set by the game while a screen (inventory, pause) has the mouse.
var ui_open := false
## 0..1 while holding left click on a block in survival (for the HUD).
var mining_progress := 0.0
var health := MAX_HEALTH
var breath := MAX_BREATH
var dead := false
var _fall_peak := 0.0
var _was_on_floor := true
var _was_in_water := false
var _since_damage := 0.0
var _regen_timer := 0.0
var _drown_timer := 0.0
var _step_distance := 0.0
var velocity := Vector3.ZERO
var flying := false
var in_water := false
var on_floor := false
## Movement stays off until the ground around the player has loaded.
## See set_ready_to_move().
var _frozen := true
var selected := 0  # hotbar slot
## Survival: what a break we asked for will drop, by position, until confirmed.
var pending_drops := {}
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
		elif event.button_index == MOUSE_BUTTON_LEFT and _try_attack():
			pass
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
	if _frozen or dead:
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

	var fell_from := velocity.y
	var r: Dictionary = world.move_box(global_position, BODY, velocity * delta, 0.0)
	var moved: Vector3 = r.position - global_position
	global_position = r.position
	on_floor = r.on_floor
	_after_move(moved, fell_from, sneak, delta)
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


## Falls, footsteps, splashes, breath and healing, after each move.
func _after_move(moved: Vector3, vertical_speed: float, sneak: bool, delta: float) -> void:
	var below := Registry.block_ids[world.get_block(Vector3i((global_position + Vector3(0, -0.1, 0)).floor()))]
	# Falling: remember the highest point since leaving the ground.
	if on_floor or in_water or flying:
		if on_floor and not _was_on_floor and not in_water and not flying:
			var fall := _fall_peak - global_position.y
			if fall > 0.6:
				footstep.emit(below, global_position)
			if fall > SAFE_FALL:
				damage(int(floor(fall - SAFE_FALL)))
		_fall_peak = global_position.y
	else:
		_fall_peak = maxf(_fall_peak, global_position.y)
	_was_on_floor = on_floor

	if in_water and not _was_in_water and vertical_speed < -4.0:
		splashed.emit(global_position)
	_was_in_water = in_water

	var walked := Vector2(moved.x, moved.z).length()
	if on_floor and not in_water and walked > 0.0:
		_step_distance += walked
		if _step_distance >= STRIDE * (0.6 if sneak else 1.0):
			_step_distance = 0.0
			footstep.emit(below, global_position)

	if creative:
		return
	var head_in_water := world.is_fluid(world.get_block(Vector3i(camera.global_position.floor())))
	if head_in_water:
		breath = maxf(0.0, breath - delta)
		if breath <= 0.0:
			_drown_timer += delta
			if _drown_timer >= 1.0:
				_drown_timer = 0.0
				damage(DROWN_DAMAGE)
	else:
		breath = minf(MAX_BREATH, breath + delta * 3.0)
		_drown_timer = 0.0
	_since_damage += delta
	if health < MAX_HEALTH and _since_damage >= REGEN_DELAY:
		_regen_timer += delta
		if _regen_timer >= REGEN_INTERVAL:
			_regen_timer = 0.0
			health += 1


func damage(amount: int) -> void:
	if creative or dead or amount <= 0:
		return
	health = maxi(0, health - amount)
	_since_damage = 0.0
	_regen_timer = 0.0
	hurt.emit(amount)
	if health == 0:
		dead = true
		velocity = Vector3.ZERO
		died.emit()


func respawn(at: Vector3) -> void:
	health = MAX_HEALTH
	breath = MAX_BREATH
	dead = false
	velocity = Vector3.ZERO
	global_position = at
	_fall_peak = at.y
	_unstuck()


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
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	var hit := _target()
	if not _mob_in_front(hit).is_empty():
		hit = {"hit": false}  # a creature is in the way: no outline, no mining
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
	mining_progress += delta / mine_seconds(Registry.block_ids[hit.block], selected_item())
	if mining_progress >= 1.0:
		mining_progress = 0.0
		_break_target()


## Mining time: hardness x 0.75 s, divided by the held tool's "speed" if it is
## the block's "tool"; three times as long without one if "requires_tool".
static func mine_seconds(block_id: String, tool_item: String = "") -> float:
	var def: Dictionary = Registry.blocks.get(block_id, {})
	var seconds := maxf(MIN_MINE_SECONDS, float(def.get("hardness", 1.0)) * MINE_SECONDS_PER_HARDNESS)
	if def.has("tool"):
		if tool_kind(tool_item) == def.tool:
			return maxf(MIN_MINE_SECONDS, seconds / tool_speed(tool_item))
		if def.get("requires_tool", false):
			return seconds * 3.0
	return seconds


## What breaking a block gives: its "drops" ("" = nothing), else the block
## itself; nothing if it "requires_tool" and the right tool isn't held.
static func drop_of(block_id: String, tool_item: String = "") -> String:
	var def: Dictionary = Registry.blocks.get(block_id, {})
	if def.get("requires_tool", false) and tool_kind(tool_item) != def.get("tool", ""):
		return ""
	return str(def.get("drops", block_id))


static func tool_kind(item: String) -> String:
	return str(Registry.items.get(item, {}).get("tool", ""))


static func tool_speed(item: String) -> float:
	return float(Registry.items.get(item, {}).get("speed", 1.0))


## The creature under the crosshair, if it is nearer than the targeted block.
func _mob_in_front(block_hit: Dictionary) -> Dictionary:
	if not mob_picker.is_valid():
		return {}
	var origin := camera.global_position
	var m: Dictionary = mob_picker.call(origin, -camera.global_basis.z, ATTACK_REACH)
	if m.is_empty():
		return {}
	if block_hit.get("hit", false) and origin.distance_to(Vector3(block_hit.position) + Vector3.ONE * 0.5) < m.distance - 0.5:
		return {}
	return m


func _try_attack() -> bool:
	var m := _mob_in_front(_target())
	if m.is_empty():
		return false
	if _attack_cooldown <= 0.0:
		_attack_cooldown = ATTACK_COOLDOWN
		attack.emit(m.id)
	return true


func _target() -> Dictionary:
	return world.raycast(camera.global_position, -camera.global_basis.z, REACH)


func _break_target() -> void:
	var hit := _target()
	if not hit.hit:
		return
	var broken: String = Registry.block_ids[hit.block]
	var at := Vector3(hit.position) + Vector3.ONE * 0.5
	if not creative:
		pending_drops[hit.position] = drop_of(broken, selected_item())
	_apply_edit(hit.position, Registry.block_index("core:air"))
	block_broken.emit(broken, at)
	if not edit_handler.is_valid():
		confirm_break(hit.position)  # local: the block is gone, drop it now


## The block at `pos` really was broken (multiplayer: the host confirmed it).
func confirm_break(pos: Vector3i) -> void:
	var drop: String = pending_drops.get(pos, "")
	pending_drops.erase(pos)
	if drop != "":
		dropped.emit(drop, Vector3(pos) + Vector3.ONE * 0.5)


func _place() -> void:
	var hit := _target()
	# Right click on a chest/furnace opens it (sneak to place against it instead).
	if hit.hit and not Input.is_action_pressed(&"sneak") \
			and Registry.blocks.get(Registry.block_ids[hit.block], {}).has("block_entity"):
		open_block.emit(hit.position)
		return
	var item := selected_item()
	if not is_placeable(item):
		return
	if not hit.hit or overlaps_block(global_position, hit.previous):
		return  # nothing to place against, or it would be inside you
	_apply_edit(hit.previous, Registry.block_index(item))
	block_placed.emit(item, Vector3(hit.previous) + Vector3.ONE * 0.5)
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
