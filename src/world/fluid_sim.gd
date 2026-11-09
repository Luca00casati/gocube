class_name FluidSim
extends Node
## Flowing fluids. Only cells near a recent change are looked at (every
## TICK seconds), so a still sea costs nothing. Runs where the world is owned
## (single player / host); its edits go through World.set_block, so
## multiplayer clients receive them like any other edit.
##
## Levels: 8 = source, 7..1 = flowing (each block further loses one).
## Rules for a fluid cell:
##   - flowing water must be fed: from above (-> level 7) or by a horizontal
##     neighbour one level higher; otherwise it shrinks and finally drains away
##   - it falls into air below (as level 7) before spreading sideways
##   - otherwise it spreads sideways into air, one level lower

const TICK := 0.25
const MAX_CELLS_PER_TICK := 1024
const SIDES := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const AROUND := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var world: World
var _pending := {}         # Vector3i -> true: cells to look at next tick
var _timer := 0.0
var _level_of := {}        # block index -> level (fluids only)
var _fluid_of := {}        # block index -> fluid name
var _block_for := {}       # fluid name -> {level: block index}
var _step := {}            # fluid name -> levels lost per block ("flow_step": lava 2)
var _stone := 0
var _cobblestone := 0
var _air := 0


func _ready() -> void:
	_air = Registry.block_index("core:air")
	for i in Registry.block_ids.size():
		var def = Registry.blocks.get(Registry.block_ids[i])
		if def is Dictionary and def.has("fluid"):
			var level := clampi(int(def.get("level", 8)), 1, 8)
			_level_of[i] = level
			_fluid_of[i] = def.fluid
			if not _block_for.has(def.fluid):
				_block_for[def.fluid] = {}
			_block_for[def.fluid][level] = i
			_step[def.fluid] = maxi(1, int(def.get("flow_step", 1)))
	_stone = maxi(0, Registry.block_index("core:stone"))
	_cobblestone = maxi(0, Registry.block_index("core:cobblestone"))
	world.block_changed.connect(_on_block_changed)


func _on_block_changed(pos: Vector3i, _block: int) -> void:
	_pending[pos] = true
	for d in AROUND:
		_pending[pos + d] = true


func pending_count() -> int:
	return _pending.size()


func _process(delta: float) -> void:
	_timer += delta
	if _timer < TICK or _pending.is_empty():
		return
	_timer = 0.0
	var cells := _pending.keys()
	_pending.clear()
	if cells.size() > MAX_CELLS_PER_TICK:
		for i in range(MAX_CELLS_PER_TICK, cells.size()):
			_pending[cells[i]] = true  # the rest next tick
		cells.resize(MAX_CELLS_PER_TICK)
	for pos in cells:
		_update(pos)


func _update(pos: Vector3i) -> void:
	var block := world.get_block(pos)
	if not _level_of.has(block):
		return
	var fluid: String = _fluid_of[block]
	var level: int = _level_of[block]
	var step: int = _step.get(fluid, 1)
	# Lava touching water hardens: a lava source into stone, flowing lava into
	# cobblestone.
	if fluid == "lava":
		for d in AROUND:
			if d != Vector3i.DOWN and _fluid_of.get(world.get_block(pos + d)) == "water":
				world.set_block(pos, _stone if level == 8 else _cobblestone)
				return
	if level < 8:
		# Flowing: is something still feeding it?
		var fed := 0
		if _fluid_of.get(world.get_block(pos + Vector3i.UP)) == fluid:
			fed = 7
		for d in SIDES:
			var n := world.get_block(pos + d)
			if _fluid_of.get(n) == fluid:
				fed = maxi(fed, _level_of[n] - step)
		if fed <= 0:
			world.set_block(pos, _air)  # drains away
			return
		if fed != level:
			world.set_block(pos, _block_for[fluid].get(fed, block))
			return  # changing re-schedules this cell and its neighbours
	# Fall first.
	var below := pos + Vector3i.DOWN
	var under := world.get_block(below)
	if under == _air or (_fluid_of.has(under) and _fluid_of[under] != fluid):
		_set_fluid(below, fluid, 7)
		return
	if _fluid_of.get(under) == fluid:
		if _level_of[under] < 7:
			_set_fluid(below, fluid, 7)
		if level < 8:
			return  # falling water lands on water: no sideways spread
	# Then sideways, one level lower.
	var next := level - step
	if next < 1:
		return
	for d in SIDES:
		var p: Vector3i = pos + d
		var n := world.get_block(p)
		if n == _air or (_fluid_of.get(n) == fluid and _level_of[n] < next) \
				or (_fluid_of.has(n) and _fluid_of[n] != fluid):
			_set_fluid(p, fluid, next)


func _set_fluid(pos: Vector3i, fluid: String, level: int) -> void:
	if world.is_fluid(world.get_block(pos)) and _fluid_of.get(world.get_block(pos)) != fluid:
		# Lava flowing into water (or water onto lava) makes cobblestone.
		world.set_block(pos, _cobblestone if _cobblestone else 0)
		return
	var id: int = _block_for[fluid].get(level, -1)
	if id >= 0:
		world.set_block(pos, id)
