class_name Crafting
extends RefCounted
## Recipes from the Registry as "ingredients -> output", crafted straight from
## the inventory (no crafting grid). Supported recipe types:
##   "shaped":    {"pattern": ["P", "P"], "key": {"P": "core:planks"}, "output": {...}}
##              (only the ingredient counts matter here, not the layout)
##   "shapeless": {"ingredients": {"core:log": 1}, "output": {"item": "core:planks", "count": 4}}
## Other types (e.g. "smelting") need a station and are not hand-craftable yet.


## [{id, ingredients: {item: count}, output: String, count: int}], sorted by output.
static func hand_recipes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in Registry.recipes:
		var r: Dictionary = Registry.recipes[id]
		var ingredients := {}
		match r.get("type", ""):
			"shaped":
				for row in r.get("pattern", []):
					for ch in str(row):
						if ch != " ":
							var item: String = r.get("key", {}).get(ch, "")
							ingredients[item] = ingredients.get(item, 0) + 1
			"shapeless":
				for item in r.get("ingredients", {}):
					ingredients[item] = int(r.ingredients[item])
			_:
				continue
		var output: Dictionary = r.get("output", {})
		if ingredients.is_empty() or ingredients.has("") or not output.has("item"):
			continue
		out.append({"id": id, "ingredients": ingredients, "output": output.item,
				"count": int(output.get("count", 1))})
	out.sort_custom(func(a, b): return a.output < b.output)
	return out


## Smelting: what an input item turns into, {"item": id, "count": n} or {}.
static func smelting_output(input: String) -> Dictionary:
	for id in Registry.recipes:
		var r: Dictionary = Registry.recipes[id]
		if r.get("type") == "smelting" and r.get("input") == input:
			return {"item": r.output.item, "count": int(r.output.get("count", 1))}
	return {}


## Seconds an item burns in a furnace ("fuel" on its item or block definition).
static func fuel_seconds(id: String) -> float:
	var def = Registry.items.get(id, Registry.blocks.get(id, {}))
	return float(def.get("fuel", 0.0)) if def is Dictionary else 0.0


static func can_craft(recipe: Dictionary, inventory: Inventory) -> bool:
	for item in recipe.ingredients:
		if inventory.count_of(item) < recipe.ingredients[item]:
			return false
	return true


## Takes the ingredients and adds the output. False if not enough ingredients
## or no room for the output (then nothing changes).
static func craft(recipe: Dictionary, inventory: Inventory) -> bool:
	if not can_craft(recipe, inventory):
		return false
	var backup := inventory.serialize()
	for item in recipe.ingredients:
		inventory.remove(item, recipe.ingredients[item])
	if inventory.add(recipe.output, recipe.count) > 0:
		inventory.deserialize(backup)  # no room: undo
		return false
	return true
