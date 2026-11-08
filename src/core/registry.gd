extends Node
## Central content registry. The base game ("core" mod) and third-party mods
## register blocks, items and recipes through exactly this API.
##
## IDs are namespaced as "modid:name". Unqualified names passed by a mod are
## automatically prefixed with that mod's id.

signal content_registered(kind: StringName, id: String)

var blocks: Dictionary = {}   # id -> definition
var items: Dictionary = {}
var recipes: Dictionary = {}

## Numeric voxel ids. block_ids[n] is the string id of voxel n; "core:air" is
## always 0. Assigned at freeze, then re-assigned per world from its saved table
## (see assign_block_ids) so saved voxels keep their meaning when mods change.
var block_ids: PackedStringArray = []
var _block_index: Dictionary = {}

var _frozen := false
var _current_mod := ""


func register_block(id: String, def: Dictionary = {}) -> String:
	return _register(blocks, &"block", id, def)


func register_item(id: String, def: Dictionary = {}) -> String:
	return _register(items, &"item", id, def)


func register_recipe(id: String, def: Dictionary) -> String:
	return _register(recipes, &"recipe", id, def)


func block_index(id: String) -> int:
	return _block_index.get(id, -1)


func is_frozen() -> bool:
	return _frozen


# --- Called by ModLoader -------------------------------------------------------

func _begin_mod(mod_id: String) -> void:
	_current_mod = mod_id


func _end_mod() -> void:
	_current_mod = ""


## Locks the registry and assigns default numeric block ids.
func _freeze() -> void:
	_frozen = true
	assign_block_ids()


## Assigns numeric voxel ids. Without a saved table (new world), ids are sorted so
## the mapping only depends on which blocks exist, not on load order. With a
## world's saved table, every saved id keeps its number and new blocks are
## appended. Saved ids whose mod is gone keep their slot (rendered as "missing")
## so their voxels survive until the mod comes back.
func assign_block_ids(saved: PackedStringArray = PackedStringArray()) -> void:
	var ids := PackedStringArray(["core:air"])
	if not saved.is_empty():
		assert(saved[0] == "core:air", "Saved block table must start with core:air")
		ids = saved.duplicate()
	var added := blocks.keys().filter(func(id): return id not in ids)
	added.sort()
	ids.append_array(PackedStringArray(added))
	block_ids = ids
	_block_index.clear()
	for i in block_ids.size():
		_block_index[block_ids[i]] = i
		if not blocks.has(block_ids[i]):
			push_warning("Block '%s' is in this world but no loaded mod provides it" % block_ids[i])


# --- Internals -----------------------------------------------------------------

func _qualify(id: String) -> String:
	if ":" in id:
		return id
	assert(_current_mod != "", "Unqualified id '%s' registered outside a mod" % id)
	return "%s:%s" % [_current_mod, id]


func _register(table: Dictionary, kind: StringName, id: String, def: Dictionary) -> String:
	if _frozen:
		push_error("Registry is frozen; cannot register %s '%s'" % [kind, id])
		return ""
	var full := _qualify(id)
	if table.has(full):
		push_warning("%s '%s' (from %s) overridden by mod '%s'"
				% [kind, full, table[full].mod, _current_mod])
	var entry := def.duplicate(true)
	entry.id = full
	entry.mod = _current_mod
	table[full] = entry
	content_registered.emit(kind, full)
	return full
