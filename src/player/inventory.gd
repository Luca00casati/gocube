class_name Inventory
extends RefCounted
## Item slots: 0..8 are the hotbar. A slot is {} (empty) or {"id": String, "count": int}.
## Blocks are items too (placing one uses it up). Pure logic: no UI, no world.

signal changed

const SIZE := 36
const HOTBAR := 9
const DEFAULT_MAX_STACK := 64

var slots: Array[Dictionary] = []
## What the mouse holds in an open inventory or container screen ({} or a stack).
var cursor: Dictionary = {}
## Multiplayer client in survival: called with each action ([kind, ...]) done
## through the methods below, so the host can do the same to its copy (see
## Session.inventory_action). Unset: nobody else needs to know.
var on_action: Callable


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


## Whether at least one more of this item fits somewhere.
func can_fit(id: String) -> bool:
	var limit := max_stack(id)
	for s in slots:
		if s.is_empty() or (s.id == id and s.count < limit):
			return true
	return false


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


## Worn armour: slot ("head", "chest", "legs", "feet") -> {"id": item} or {}.
const ARMOR_SLOTS := ["head", "chest", "legs", "feet"]
var armor := {"head": {}, "chest": {}, "legs": {}, "feet": {}}


func armor_points() -> int:
	var total := 0
	for slot in ARMOR_SLOTS:
		if not armor[slot].is_empty():
			total += int(Registry.items.get(armor[slot].id, {}).get("armor", {}).get("points", 0))
	return total


## Click on an armour slot holding `held`: wear it if it fits there, else give
## the held item back. Returns what is held afterwards.
func put_armor(slot: String, held: Dictionary) -> Dictionary:
	if not held.is_empty() and Registry.items.get(held.id, {}).get("armor", {}).get("slot", "") != slot:
		return held
	var was: Dictionary = armor[slot]
	armor[slot] = {"id": held.id, "count": 1} if not held.is_empty() else {}
	changed.emit()
	return was


# --- Actions (the same on a client and on the host's copy) -------------------

## Click on a slot in a screen: put down or pick up (see put).
func click(slot: int) -> void:
	if slot < 0 or slot >= SIZE:
		return
	cursor = put(slot, cursor)
	_did(["click", slot])


## Click on an armour slot in a screen (see put_armor).
func click_armor(slot: String) -> void:
	if slot not in ARMOR_SLOTS:
		return
	cursor = put_armor(slot, cursor)
	_did(["armor", slot])


## Crafts a hand recipe (Crafting.hand_recipes) by its id. False if it couldn't.
func craft(recipe_id: String) -> bool:
	var ok := false
	for r in Crafting.hand_recipes():
		if r.id == recipe_id:
			ok = Crafting.craft(r, self)
	_did(["craft", recipe_id])
	return ok


## A screen closed: what the mouse held goes back in. Returns what didn't fit
## ({} or a stack), which the caller drops.
func close_cursor() -> Dictionary:
	var held := cursor
	cursor = {}
	var left := add(held.id, held.count) if not held.is_empty() else 0
	_did(["close"])
	return {} if left == 0 else {"id": held.id, "count": left}


## Eats one of the food in a slot. False if it isn't food.
func eat(slot: int) -> bool:
	if slot < 0 or slot >= SIZE or not Registry.items.get(slots[slot].get("id", ""), {}).has("food"):
		return false
	take_one(slot)
	_did(["eat", slot])
	return true


func _did(action: Array) -> void:
	if on_action.is_valid():
		on_action.call(action)


## Does an action from a client's inventory (host side, on its copy; the
## client did the same through the methods above). Returns what didn't fit
## back after a "close" (to drop), else {}.
func apply_action(action: Array) -> Dictionary:
	if action.is_empty() or not action[0] is String:
		return {}
	match [action[0], action.size()]:
		["click", 2]:
			if action[1] is int:
				click(action[1])
		["armor", 2]:
			if action[1] is String:
				click_armor(action[1])
		["craft", 2]:
			if action[1] is String:
				craft(action[1])
		["close", 1]:
			return close_cursor()
		["eat", 2]:
			if action[1] is int:
				eat(action[1])
	return {}


## Everything a client is shown of its inventory: slots, armour, cursor.
func snapshot() -> Array:
	return [serialize(), cursor.duplicate()]


func apply_snapshot(data: Array) -> void:
	if data.size() != 2 or not data[0] is Array or not data[1] is Dictionary:
		return
	deserialize(data[0])
	var c: Dictionary = data[1]
	cursor = {"id": str(c.id), "count": int(c.count)} if c.has("id") and c.has("count") else {}
	changed.emit()


func serialize() -> Array:
	var out: Array = slots.map(func(s): return [s.id, s.count] if not s.is_empty() else null)
	out.append({"armor": ARMOR_SLOTS.map(func(k): return armor[k].get("id", ""))})
	return out


func deserialize(data: Array) -> void:
	if not data.is_empty() and data[-1] is Dictionary:
		var worn: Array = data[-1].get("armor", [])
		for i in mini(worn.size(), ARMOR_SLOTS.size()):
			armor[ARMOR_SLOTS[i]] = {"id": str(worn[i]), "count": 1} if Registry.items.has(str(worn[i])) else {}
		data = data.slice(0, data.size() - 1)
	for i in mini(data.size(), SIZE):
		var s = data[i]
		# Items whose mod is gone are dropped; everything else comes back.
		var known: bool = s is Array and s.size() == 2 and (Registry.items.has(s[0]) or Registry.blocks.has(s[0]))
		slots[i] = {"id": str(s[0]), "count": int(s[1])} if known else {}
	changed.emit()
