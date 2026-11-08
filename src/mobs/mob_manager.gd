class_name MobManager
extends Node3D
## Creatures. Where the world is owned (single player / host) this spawns them
## on grass around players by day, despawns them when nobody is near, runs
## their behaviour and handles hits. On multiplayer clients it only shows what
## the host sends (Session).

signal killed(at: Vector3, attacker: int, drops: Array)  # [[item, count], ...]
signal hurt_at(at: Vector3, variant: String)  # variant: "" or the block id

const MAX_MOBS := 12
const SPAWN_EVERY := 2.0
const SPAWN_MIN := 20.0
const SPAWN_MAX := 48.0
const DESPAWN_DISTANCE := 80.0
const ATTACK_DAMAGE := 3
const REGULAR_CHANCE := 0.75  # the rest are made of a random block

var world: World
## Returns the positions of every player (local and remote).
var player_positions := Callable()
## Returns 0..1 daylight (spawning only by day).
var day_amount := Callable()
var _mobs := {}  # id -> BlockEater
var _next_id := 1
var _spawn_timer := 0.0
var _rng := RandomNumberGenerator.new()


var _variants: Array[String] = []
var _weights: Array[float] = []
var _total_weight := 0.0


func _ready() -> void:
	_rng.randomize()
	for i in Registry.block_ids.size():
		var id: String = Registry.block_ids[i]
		var def = Registry.blocks.get(id)
		if not (def is Dictionary) or id == "core:air" or not def.get("solid", true) or def.has("fluid"):
			continue
		# "eater_weight": how often its Block Eater turns up compared with an
		# ordinary block (1.0); 0 = none.
		var weight := float(def.get("eater_weight", 1.0))
		if weight > 0.0:
			_variants.append(id)
			_weights.append(weight)
			_total_weight += weight


## Every block a Block Eater can be made of.
func variants() -> Array[String]:
	return _variants


func random_variant() -> String:
	if _variants.is_empty() or _rng.randf() < REGULAR_CHANCE:
		return ""
	var r := _rng.randf() * _total_weight
	for i in _variants.size():
		r -= _weights[i]
		if r < 0.0:
			return _variants[i]
	return _variants[-1]


func count() -> int:
	return _mobs.size()


func mobs() -> Array:
	return _mobs.values()


func _process(_delta: float) -> void:
	if day_amount.is_valid() and not _mobs.is_empty():
		BlockEater.set_daylight(day_amount.call())


func _physics_process(delta: float) -> void:
	if world == null or world.remote:
		return
	for mob in _mobs.values():
		mob.simulate(delta)
	_spawn_timer += delta
	if _spawn_timer >= SPAWN_EVERY:
		_spawn_timer = 0.0
		_despawn_far()
		if _mobs.size() < MAX_MOBS and (not day_amount.is_valid() or day_amount.call() > 0.3):
			_try_spawn()


func spawn_at(feet: Vector3, variant := "") -> BlockEater:
	BlockEater.atlas = world.atlas  # built after this node is ready
	var mob := BlockEater.new()
	mob.variant = variant
	mob.id = _next_id
	_next_id += 1
	mob.world = world
	add_child(mob)
	mob.global_position = feet
	mob.target_position = feet
	_mobs[mob.id] = mob
	return mob


func _try_spawn() -> void:
	var players: Array = player_positions.call() if player_positions.is_valid() else []
	if players.is_empty():
		return
	var around: Vector3 = players[_rng.randi() % players.size()]
	var angle := _rng.randf() * TAU
	var dist := _rng.randf_range(SPAWN_MIN, SPAWN_MAX)
	var x := floori(around.x + cos(angle) * dist)
	var z := floori(around.z + sin(angle) * dist)
	var hit := world.raycast(Vector3(x + 0.5, World.TOP_Y, z + 0.5), Vector3.DOWN, 400)
	if not hit.hit or Registry.block_ids[hit.block] != "core:grass":
		return  # only on grass, open to the sky
	var feet := Vector3(x + 0.5, hit.position.y + 1, z + 0.5)
	if world.is_box_free(feet, BlockEater.BOX):
		spawn_at(feet, random_variant())


func _despawn_far() -> void:
	var players: Array = player_positions.call() if player_positions.is_valid() else []
	for id in _mobs.keys():
		var mob: BlockEater = _mobs[id]
		var near := players.any(func(p): return (p as Vector3).distance_to(mob.global_position) < DESPAWN_DISTANCE)
		if not near or mob.global_position.y < -200:
			_remove(id)


func _remove(id: int) -> void:
	if _mobs.has(id):
		_mobs[id].queue_free()
		_mobs.erase(id)


## An attack from a player standing at `from` (attacker: peer id, 0 = local).
func hit(id: int, from: Vector3, attacker: int) -> void:
	var mob: BlockEater = _mobs.get(id)
	if mob == null:
		return
	hurt_at.emit(mob.global_position, mob.variant)
	if mob.hurt(ATTACK_DAMAGE, from):
		var at := mob.global_position + Vector3(0, 0.5, 0)
		killed.emit(at, attacker, mob.drops(_rng))
		_remove(id)


## The creature under a ray (the player's crosshair): {id, distance} or {}.
func pick(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var best := {}
	for mob in _mobs.values():
		var d: float = mob.ray_distance(origin, dir, max_distance)
		if d >= 0.0 and (best.is_empty() or d < best.distance):
			best = {"id": mob.id, "distance": d}
	return best


# --- Multiplayer -------------------------------------------------------------------------

## Host: positions to send to clients: {id: [position, yaw, walking, variant]}.
func states() -> Dictionary:
	var out := {}
	for mob in _mobs.values():
		out[mob.id] = [mob.global_position, mob.rotation.y, mob.walking, mob.variant]
	return out


## Client: show the host's creatures.
func apply_states(states: Dictionary) -> void:
	for id in states:
		var s: Array = states[id]
		var mob: BlockEater = _mobs.get(id)
		if mob == null:
			BlockEater.atlas = world.atlas
			mob = BlockEater.new()
			mob.id = id
			mob.variant = str(s[3]) if Registry.blocks.has(str(s[3])) else ""
			mob.world = world
			add_child(mob)
			mob.global_position = s[0]
			_mobs[id] = mob
		mob.target_position = s[0]
		mob.target_yaw = s[1]
		mob.walking = s[2]
	for id in _mobs.keys():
		if not states.has(id):
			_remove(id)
