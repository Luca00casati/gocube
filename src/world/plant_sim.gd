class_name PlantSim
extends Node
## Growing crops and blocks that need support. Runs where the world is owned
## (single player / host); its edits go through World.set_block, so they reach
## multiplayer clients like any other edit.
##
## Falling: blocks with "falls" (sand, gravel) drop while there's air or a
## fluid under them.
## Leaf decay: leaves ("leaves": true) more than LEAF_REACH steps (through
## leaves) from any tree log disappear after a short random delay, now and then
## dropping a sapling ("sapling" of the leaves) or a stick; placed leaves are a "_placed" variant that never decays.
## Growth: a block with "grows_into" turns into that block after about
## "grow_seconds" (randomised); a sapling ("grows_tree": a tree id, or
## {tree id: weight}) grows into that tree, trying again later when there's no
## room. Tracked crops and saplings are saved with the world.
## Support: plants ("plant_on": [blocks]) need one of those below; blocks with
## "needs_support" need a solid block below (floor torch, door) or behind them
## on their facing side (wall torch, ladder); an upper door half needs its
## lower half. Unsupported blocks pop off and drop their item (`popped`).

signal popped(pos: Vector3i, items: Array)  # [[id, count]]

const TICK := 1.0
const AROUND := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const FACING_DIR := {"n": Vector3i(0, 0, -1), "e": Vector3i(1, 0, 0), "s": Vector3i(0, 0, 1), "w": Vector3i(-1, 0, 0)}

var world: World
var _growing := {}   # Vector3i -> seconds left
var _timer := 0.0
var _check := {}     # positions whose support to check this frame
var _leaf_check := {}  # leaves to test for a nearby log
var _decaying := {}    # leaves -> seconds until they fall
var _logs := {}        # block index -> true, for every tree's log
const LEAF_REACH := 4
const SAPLING_CHANCE := 0.05


func _ready() -> void:
	world.block_changed.connect(_on_block_changed)
	for t in Registry.trees.values():
		var i := Registry.block_index(str(t.get("log", "")))
		if i > 0:
			_logs[i] = true


func _on_block_changed(pos: Vector3i, block: int) -> void:
	var def: Dictionary = Registry.blocks.get(Registry.block_ids[block], {})
	if def.has("grows_into") or def.has("grows_tree"):
		_growing[pos] = float(def.get("grow_seconds", 60.0)) * randf_range(0.6, 1.4)
	else:
		_growing.erase(pos)
	_check[pos] = true
	for d in AROUND:
		_check[pos + d] = true
		if _is_leaves(world.get_block(pos + d)):
			_leaf_check[pos + d] = true


func growing_count() -> int:
	return _growing.size()


func _process(delta: float) -> void:
	var t := FrameProfiler.begin()
	_process_step(delta)
	FrameProfiler.add(&"plants", t)


func _process_step(delta: float) -> void:
	if not _check.is_empty():
		var cells := _check.keys()
		_check.clear()
		for pos in cells:
			var id: String = Registry.block_ids[world.get_block(pos)]
			if Registry.blocks.get(id, {}).get("falls", false):
				var below: int = world.get_block(pos + Vector3i.DOWN)
				if below == 0 or world.is_fluid(below):
					var block := world.get_block(pos)
					world.set_block(pos, 0)
					world.set_block(pos + Vector3i.DOWN, block)  # checked again next frame
				continue
			if id != "core:air" and not supported(world, id, pos):
				var drop := str(Registry.blocks[id].get("drops", BlockShapes.base_of(id)))
				world.set_block(pos, 0)  # -> block_changed -> neighbours checked next frame
				if drop != "" and not (Registry.blocks[id].get("shape") == "door" and Registry.blocks[id].state.half == "upper"):
					popped.emit(pos, [[drop, 1]])
	for pos in _leaf_check.keys():
		if _is_leaves(world.get_block(pos)) and not _near_log(pos) and not _decaying.has(pos):
			_decaying[pos] = randf_range(0.3, 3.0)
	_leaf_check.clear()
	for pos in _decaying.keys():
		_decaying[pos] -= delta
		if _decaying[pos] <= 0.0:
			_decaying.erase(pos)
			var leaf := world.get_block(pos)
			if _is_leaves(leaf):
				var sapling := str(Registry.blocks[Registry.block_ids[leaf]].get("sapling", ""))
				world.set_block(pos, 0)  # its neighbours get checked in turn
				if sapling != "" and randf() < SAPLING_CHANCE:
					popped.emit(pos, [[sapling, 1]])
				elif randf() < 0.06:
					popped.emit(pos, [["core:stick", 1]])
	_timer += delta
	if _timer < TICK:
		return
	for pos in _growing.keys():
		_growing[pos] -= _timer
		if _growing[pos] <= 0.0:
			_growing.erase(pos)
			var def: Dictionary = Registry.blocks.get(Registry.block_ids[world.get_block(pos)], {})
			if def.has("grows_into"):
				world.set_block(pos, Registry.block_index(def.grows_into))  # tracks the next stage
			elif def.has("grows_tree") and not world.grow_tree(pos, pick_tree(def.grows_tree)):
				_growing[pos] = float(def.get("grow_seconds", 60.0)) * 0.5  # no room yet: later
	_timer = 0.0


## A tree id from "grows_tree": the id itself, or picked by weight.
static func pick_tree(grows) -> String:
	if grows is Dictionary:
		var total := 0.0
		for w in grows.values():
			total += float(w)
		var roll := randf() * total
		for id in grows:
			roll -= float(grows[id])
			if roll <= 0.0:
				return str(id)
		return str(grows.keys()[-1])
	return str(grows)


func _is_leaves(block: int) -> bool:
	return block > 0 and Registry.blocks.get(Registry.block_ids[block], {}).get("leaves", false)


## Whether a log is within LEAF_REACH steps, going through leaves.
func _near_log(start: Vector3i) -> bool:
	var seen := {start: 0}
	var queue := [start]
	while not queue.is_empty():
		var p: Vector3i = queue.pop_front()
		var dist: int = seen[p]
		for d in AROUND:
			var n: Vector3i = p + d
			if seen.has(n):
				continue
			var b := world.get_block(n)
			if _logs.has(b):
				return true
			if dist + 1 < LEAF_REACH and _is_leaves(b):
				seen[n] = dist + 1
				queue.append(n)
	return false


## Whether block `id` placed at `pos` has what it needs (see the class notes).
static func supported(w: World, id: String, pos: Vector3i) -> bool:
	var def: Dictionary = Registry.blocks.get(id, {})
	var below: String = Registry.block_ids[w.get_block(pos + Vector3i.DOWN)]
	if def.has("plant_on"):
		return below in def.plant_on
	if not def.get("needs_support", false):
		return true
	var st: Dictionary = def.get("state", {})
	if def.get("shape") == "door":  # stands on the floor whichever way it faces
		if st.get("half") == "upper":
			return BlockShapes.base_of(below) == BlockShapes.base_of(id)
		return _solid(w, pos + Vector3i.DOWN)
	var facing := str(st.get("facing", "floor"))
	var support: Vector3i = pos + (FACING_DIR[facing] if FACING_DIR.has(facing) else Vector3i.DOWN)
	return _solid(w, support)


static func _solid(w: World, pos: Vector3i) -> bool:
	var def: Dictionary = Registry.blocks.get(Registry.block_ids[w.get_block(pos)], {})
	return not def.is_empty() and def.get("solid", true) and not def.has("fluid") \
			and def.get("id", "") != "core:air" and def.get("shape", "cube") in ["cube", "slab", "stairs"]


func serialize() -> Array:
	return _growing.keys().map(func(p): return [p.x, p.y, p.z, _growing[p]])


func deserialize(data: Array) -> void:
	for e in data:
		if e is Array and e.size() == 4:
			_growing[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = float(e[3])
