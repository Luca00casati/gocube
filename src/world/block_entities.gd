class_name BlockEntities
extends Node
## Data attached to some blocks: chests (27 slots) and furnaces (input, fuel,
## output). Lives where the world is owned (single player / host); multiplayer
## clients use them through the host (Session). Saved in world.json.
##
## A block gets one when it is placed if its definition has "block_entity":
## "chest" or "furnace"; breaking it emits `spilled` with the contents.

signal changed(pos: Vector3i)
signal spilled(pos: Vector3i, items: Array)  # [[id, count], ...]

const CHEST_SLOTS := 27
const FURNACE_INPUT := 0
const FURNACE_FUEL := 1
const FURNACE_OUTPUT := 2
const SMELT_SECONDS := 5.0
const TICK := 0.25

var world: World
## Vector3i -> {"type", "slots": Array[Dictionary], "burn", "burn_total", "progress"}
var entities := {}
var _timer := 0.0


func _ready() -> void:
	world.block_changed.connect(_on_block_changed)


func has_entity(pos: Vector3i) -> bool:
	return entities.has(pos)


func get_entity(pos: Vector3i) -> Dictionary:
	return entities.get(pos, {})


func _on_block_changed(pos: Vector3i, block: int) -> void:
	var kind: String = Registry.blocks.get(Registry.block_ids[block], {}).get("block_entity", "")
	if entities.has(pos) and entities[pos].type != kind:
		var items := []
		for s in entities[pos].slots:
			if not s.is_empty():
				items.append([s.id, s.count])
		entities.erase(pos)
		spilled.emit(pos, items)
	if kind != "" and not entities.has(pos):
		entities[pos] = _new_entity(kind)
		changed.emit(pos)


static func _new_entity(kind: String) -> Dictionary:
	var size := CHEST_SLOTS if kind == "chest" else 3
	var slots: Array[Dictionary] = []
	for i in size:
		slots.append({})
	return {"type": kind, "slots": slots, "burn": 0.0, "burn_total": 0.0, "progress": 0.0}


## Mouse-style click on a slot while holding `held`; returns what is now held.
## Furnace output can only be taken; fuel only accepts fuel.
func click(pos: Vector3i, slot: int, held: Dictionary) -> Dictionary:
	var e: Dictionary = entities.get(pos, {})
	if e.is_empty() or slot < 0 or slot >= e.slots.size():
		return held
	if e.type == "furnace":
		if slot == FURNACE_OUTPUT and not held.is_empty():
			return held
		if slot == FURNACE_FUEL and not held.is_empty() and Crafting.fuel_seconds(held.id) <= 0.0:
			return held
	var here: Dictionary = e.slots[slot]
	var result: Dictionary
	if not held.is_empty() and here.get("id") == held.id:
		var n := mini(held.count, Inventory.max_stack(held.id) - here.count)
		here.count += n
		result = held.duplicate()
		result.count -= n
		if result.count <= 0:
			result = {}
	else:
		e.slots[slot] = held.duplicate()
		result = here
	changed.emit(pos)
	return result


func _process(delta: float) -> void:
	var t := FrameProfiler.begin()
	_process_step(delta)
	FrameProfiler.add(&"furnaces", t)


func _process_step(delta: float) -> void:
	_timer += delta
	if _timer < TICK:
		return
	for pos in entities:
		if entities[pos].type == "furnace":
			_tick_furnace(pos, entities[pos], _timer)
	_timer = 0.0


func _tick_furnace(pos: Vector3i, e: Dictionary, dt: float) -> void:
	var input: Dictionary = e.slots[FURNACE_INPUT]
	var fuel: Dictionary = e.slots[FURNACE_FUEL]
	var out: Dictionary = e.slots[FURNACE_OUTPUT]
	var result := Crafting.smelting_output(input.get("id", ""))
	var room: bool = not result.is_empty() and (out.is_empty() or (out.id == result.item
			and out.count + result.count <= Inventory.max_stack(result.item)))
	var before := [e.burn, e.progress]
	if e.burn <= 0.0 and room and not fuel.is_empty():
		e.burn_total = Crafting.fuel_seconds(fuel.id)
		e.burn = e.burn_total
		fuel.count -= 1
		if fuel.count <= 0:
			e.slots[FURNACE_FUEL] = {}
	if e.burn > 0.0:
		e.burn = maxf(0.0, e.burn - dt)
		if room:
			e.progress += dt
			if e.progress >= SMELT_SECONDS:
				e.progress = 0.0
				input.count -= 1
				if input.count <= 0:
					e.slots[FURNACE_INPUT] = {}
				if out.is_empty():
					e.slots[FURNACE_OUTPUT] = {"id": result.item, "count": result.count}
				else:
					out.count += result.count
		else:
			e.progress = 0.0
	elif e.progress > 0.0:
		e.progress = maxf(0.0, e.progress - dt * 2.0)  # cools down without fuel
	if [e.burn, e.progress] != before:
		changed.emit(pos)


## For the furnace UI: 0..1 fractions.
static func furnace_status(e: Dictionary) -> Dictionary:
	return {"burn": e.burn / e.burn_total if e.get("burn_total", 0.0) > 0.0 else 0.0,
			"progress": e.get("progress", 0.0) / SMELT_SECONDS}


func serialize() -> Dictionary:
	var out := {}
	for pos in entities:
		var e: Dictionary = entities[pos]
		out["%d,%d,%d" % [pos.x, pos.y, pos.z]] = {"type": e.type,
				"slots": e.slots.map(func(s): return [s.id, s.count] if not s.is_empty() else null),
				"burn": e.burn, "burn_total": e.burn_total, "progress": e.progress}
	return out


func deserialize(data: Dictionary) -> void:
	for key in data:
		var xyz := str(key).split(",")
		var d: Dictionary = data[key]
		var e := _new_entity(str(d.get("type", "chest")))
		var saved: Array = d.get("slots", [])
		for i in mini(saved.size(), e.slots.size()):
			var s = saved[i]
			if s is Array and (Registry.items.has(s[0]) or Registry.blocks.has(s[0])):
				e.slots[i] = {"id": str(s[0]), "count": int(s[1])}
		e.burn = float(d.get("burn", 0.0))
		e.burn_total = float(d.get("burn_total", 0.0))
		e.progress = float(d.get("progress", 0.0))
		entities[Vector3i(int(xyz[0]), int(xyz[1]), int(xyz[2]))] = e
