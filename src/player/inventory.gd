class_name Inventory
extends RefCounted
## Item slots: 0..8 are the hotbar. A slot is {} (empty) or {"id": String, "count": int}.
## Blocks are items too (placing one uses it up). Pure logic: no UI, no world.

signal changed

const SIZE := 36
const HOTBAR := 9
const DEFAULT_MAX_STACK := 64

var slots: Array[Dictionary] = []


func _init() -> void:
	slots.resize(SIZE)
	for i in SIZE:
		slots[i] = {}


static func max_stack(id: String) -> int:
	var def = Registry.items.get(id, Registry.blocks.get(id))
	return int(def.get("max_stack", DEFAULT_MAX_STACK)) if def is Dictionary else DEFAULT_MAX_STACK


## Adds items, filling existing stacks first, then empty slots (hotbar first).
## Returns how many didn't fit.
func add(id: String, count: int) -> int:
	if count <= 0 or id == "":
		return 0
	var limit := max_stack(id)
	for i in SIZE:
		if count > 0 and slots[i].get("id") == id and slots[i].count < limit:
			var n := mini(count, limit - slots[i].count)
			slots[i].count += n
			count -= n
	for i in SIZE:
		if count > 0 and slots[i].is_empty():
			var n := mini(count, limit)
			slots[i] = {"id": id, "count": n}
			count -= n
	changed.emit()
	return count


func count_of(id: String) -> int:
	var total := 0
	for s in slots:
		if s.get("id") == id:
			total += s.count
	return total


## Removes `count` of an item from wherever it is. False (and nothing removed)
## if there aren't enough.
func remove(id: String, count: int) -> bool:
	if count_of(id) < count:
		return false
	for i in range(SIZE - 1, -1, -1):  # take from the back first, keep the hotbar
		if count > 0 and slots[i].get("id") == id:
			var n := mini(count, slots[i].count)
			slots[i].count -= n
			count -= n
			if slots[i].count == 0:
				slots[i] = {}
	changed.emit()
	return true


## Uses up one item from a slot; returns its id ("" if the slot was empty).
func take_one(slot: int) -> String:
	if slots[slot].is_empty():
		return ""
	var id: String = slots[slot].id
	slots[slot].count -= 1
	if slots[slot].count <= 0:
		slots[slot] = {}
	changed.emit()
	return id


## Mouse-style move: put `held` into a slot, returning what is now held.
## Same item stacks up to the limit; otherwise the two swap.
func put(slot: int, held: Dictionary) -> Dictionary:
	var here: Dictionary = slots[slot]
	if not held.is_empty() and here.get("id") == held.id:
		var n := mini(held.count, max_stack(held.id) - here.count)
		here.count += n
		var rest := held.duplicate()
		rest.count -= n
		changed.emit()
		return {} if rest.count <= 0 else rest
	slots[slot] = held.duplicate()
	changed.emit()
	return here


func serialize() -> Array:
	return slots.map(func(s): return [s.id, s.count] if not s.is_empty() else null)


func deserialize(data: Array) -> void:
	for i in mini(data.size(), SIZE):
		var s = data[i]
		# Items whose mod is gone are dropped; everything else comes back.
		var known: bool = s is Array and s.size() == 2 and (Registry.items.has(s[0]) or Registry.blocks.has(s[0]))
		slots[i] = {"id": str(s[0]), "count": int(s[1])} if known else {}
	changed.emit()
