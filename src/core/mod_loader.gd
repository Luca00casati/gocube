extends Node
## Discovers and loads mods.
##
## A mod is a folder containing mod.json:
##   {
##     "id": "mymod",                       # required, [a-z0-9_]
##     "name": "My Mod", "version": "1.0.0",
##     "dependencies": ["othermod"],        # "core" is implicit
##     "content": ["content/blocks.json"],  # data-only content (optional)
##     "entry": "main.gd"                   # code entry point (optional)
##   }
##
## Sources, in order:
##   res://mods/<id>/          built-in mods (incl. the base game, "core")
##   user://mods/*.pck|*.zip   resource packs; must contain mods/<id>/..., so they
##                             mount into res://mods/<id>/
##   user://mods/<id>/         unpacked mod folders (handy while developing)
##
## WARNING: mod scripts run unsandboxed with full access to the game and system.

signal mods_loaded

const BUILTIN_DIR := "res://mods"
const USER_DIR := "user://mods"
const CORE_ID := "core"

## Manifests of successfully loaded mods, in load order. Each has a "path" key.
var mods: Array[Dictionary] = []
## Instances of mod entry scripts, keyed by mod id.
var instances: Dictionary = {}

var _id_regex := RegEx.create_from_string("^[a-z0-9_]+$")
var _loading: Dictionary = {}  # manifest of the mod currently being loaded


## Loads every mod once per game session; later calls do nothing.
func load_all() -> void:
	if Registry.is_frozen():
		return
	DirAccess.make_dir_recursive_absolute(USER_DIR)
	_mount_packs(USER_DIR)

	var found := {}
	_scan(BUILTIN_DIR, found)
	_scan(USER_DIR, found)

	for id in _resolve_order(found):
		_load_mod(found[id])

	Registry._freeze()
	mods_loaded.emit()


## Folder a loaded mod lives in (res://mods/<id> or user://mods/<id>), or "" if unknown.
func get_mod_path(mod_id: String) -> String:
	for m in mods:
		if m.id == mod_id:
			return m.path
	return _loading.get("path", "") if _loading.get("id") == mod_id else ""


func _mount_packs(dir: String) -> void:
	for file in DirAccess.get_files_at(dir):
		if file.get_extension() in ["pck", "zip"]:
			var path := ProjectSettings.globalize_path(dir.path_join(file))
			# replace_files=false: a pack can add files but not clobber existing ones.
			if not ProjectSettings.load_resource_pack(path, false):
				push_error("Failed to mount mod pack: " + path)


func _scan(dir: String, found: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		var root := dir.path_join(sub)
		var manifest_path := root.path_join("mod.json")
		if not FileAccess.file_exists(manifest_path):
			continue
		var m = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if not m is Dictionary or not _id_regex.search(str(m.get("id", ""))):
			push_error("Invalid mod.json: " + manifest_path)
			continue
		if found.has(m.id):
			push_warning("Duplicate mod id '%s' at %s, ignoring" % [m.id, root])
			continue
		m.path = root
		found[m.id] = m


## Topological sort on dependencies; core always loads first.
func _resolve_order(found: Dictionary) -> Array:
	var order: Array = []
	var state := {}  # id -> 1 visiting, 2 done, -1 failed
	var ids := found.keys()
	ids.sort()
	ids.erase(CORE_ID)
	ids.push_front(CORE_ID)
	for id in ids:
		_visit(id, found, state, order)
	return order


func _visit(id: String, found: Dictionary, state: Dictionary, order: Array) -> bool:
	match state.get(id, 0):
		2: return true
		1:
			push_error("Dependency cycle involving mod '%s'" % id)
			return false
		-1: return false
	if not found.has(id):
		push_error("Missing mod '%s'" % id)
		state[id] = -1
		return false
	state[id] = 1
	var deps: Array = found[id].get("dependencies", [])
	if id != CORE_ID and CORE_ID not in deps:
		deps = [CORE_ID] + deps
	for dep in deps:
		if not _visit(dep, found, state, order):
			push_error("Skipping mod '%s': dependency '%s' unavailable" % [id, dep])
			state[id] = -1
			return false
	state[id] = 2
	order.append(id)
	return true


func _load_mod(m: Dictionary) -> void:
	_loading = m
	Registry._begin_mod(m.id)

	for rel in m.get("content", []):
		_load_content_file(m.path.path_join(rel))

	if m.has("entry"):
		var script = load(m.path.path_join(m.entry))
		if script is Script:
			var inst = script.new()
			if inst is Node:
				inst.name = m.id
				add_child(inst)
			if inst.has_method("init_mod"):
				inst.init_mod(Registry)
			instances[m.id] = inst
		else:
			push_error("Mod '%s': could not load entry script %s" % [m.id, m.entry])

	Registry._end_mod()
	_loading = {}
	mods.append(m)
	print("Loaded mod %s %s" % [m.id, m.get("version", "")])


## Content file format: { "blocks": {id: def}, "items": {id: def}, "recipes": {id: def} }
func _load_content_file(path: String) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("Invalid content file: " + path)
		return
	for id in data.get("blocks", {}):
		Registry.register_block(id, data.blocks[id])
	for id in data.get("items", {}):
		Registry.register_item(id, data.items[id])
	for id in data.get("recipes", {}):
		Registry.register_recipe(id, data.recipes[id])
