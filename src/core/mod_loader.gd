extends Node
## Discovers and loads mods.
##
## A mod is a folder containing mod.json:
##   {
##     "id": "mymod",                       # required, [a-z0-9_]
##     "name": "My Mod", "version": "1.0.0",
##     "dependencies": ["othermod"],        # "core" is implicit
##     "content": ["content/blocks.json"],  # data-only content (optional)
##     "entry": "main.gd",                  # code entry point (optional)
##     "api_version": 1                     # modding API it was written for (default 1)
##   }
##
## Sources, in order:
##   res://mods/<id>/          built-in mods (incl. the base game, "core")
##   user://mods/*.zip         a zipped mod folder (mod.json at the top of the zip,
##                             or inside one folder); unpacked to user://mods/.unzipped/
##   user://mods/*.pck         resource packs; must contain mods/<id>/..., so they
##                             mount into res://mods/<id>/
##   user://mods/<id>/         unpacked mod folders (handy while developing)
##
## Mods listed in Settings.disabled_mods are found but not loaded (the Mods
## part of the settings screen; takes effect the next time the game starts).
##
## WARNING: mod scripts run unsandboxed with full access to the game and system.

signal mods_loaded

const BUILTIN_DIR := "res://mods"
const USER_DIR := "user://mods"
const UNZIP_DIR := "user://mods/.unzipped"
const CORE_ID := "core"
## Version of the modding API (registry, content files, mod.json). Raise it when
## something changes in a way that breaks existing mods.
const API_VERSION := 1

## Manifests of successfully loaded mods, in load order. Each has a "path" key.
var mods: Array[Dictionary] = []
## Every mod found with a valid mod.json (loaded or not, core excluded), sorted
## by id: for the settings screen.
var available: Array[Dictionary] = []
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
	_scan_zips(USER_DIR, found)

	available.clear()
	for id in found:
		if id != CORE_ID:
			available.append(found[id])
	available.sort_custom(func(a, b): return a.id < b.id)
	for id in Settings.disabled_mods:
		if found.has(id) and id != CORE_ID:
			print("Mod %s is turned off" % id)
			found.erase(id)

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
		if file.get_extension() == "pck":
			var path := ProjectSettings.globalize_path(dir.path_join(file))
			# replace_files=false: a pack can add files but not clobber existing ones.
			if not ProjectSettings.load_resource_pack(path, false):
				push_error("Failed to mount mod pack: " + path)


func _scan(dir: String, found: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_add_found(dir.path_join(sub), found)


## Each zip in `dir` is unpacked (again only when the zip changed) into
## UNZIP_DIR/<zip name>/ and added like a folder.
func _scan_zips(dir: String, found: Dictionary) -> void:
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() != "zip":
			continue
		var zip := dir.path_join(file)
		var out := UNZIP_DIR.path_join(file.get_basename())
		var problem := unzip_mod(zip, out)
		if problem != "":
			push_error("Mod zip %s: %s; skipping it" % [zip, problem])
			continue
		_add_found(out, found)


## Unpacks a mod zip into `out` (replacing what was there) unless `out` already
## holds this version of it. The zip has mod.json at its top or in its single
## top folder. Returns "" or what went wrong.
func unzip_mod(zip_path: String, out: String) -> String:
	var stamp := str(FileAccess.get_modified_time(zip_path)) + ":" + str(FileAccess.get_size(zip_path))
	var stamp_file := out.path_join(".from_zip")
	if FileAccess.file_exists(stamp_file) and FileAccess.get_file_as_string(stamp_file) == stamp:
		return ""
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "can't open it as a zip"
	var files := reader.get_files()
	var prefix := ""
	if not "mod.json" in files:
		var tops := {}
		for f in files:
			tops[f.get_slice("/", 0)] = true
		if tops.size() != 1 or not (tops.keys()[0] + "/mod.json") in files:
			reader.close()
			return "no mod.json at its top or in its one top folder"
		prefix = tops.keys()[0] + "/"
	_remove_dir(out)
	DirAccess.make_dir_recursive_absolute(out)
	for f in files:
		if not f.begins_with(prefix) or f.ends_with("/"):
			continue
		var rel: String = f.substr(prefix.length())
		if rel.is_absolute_path() or rel.begins_with("/") or ".." in rel.split("/") or ":" in rel or "\\" in rel:
			reader.close()
			_remove_dir(out)
			return "'%s' points outside the mod" % f
		var target := out.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var w := FileAccess.open(target, FileAccess.WRITE)
		if w == null:
			reader.close()
			return "can't write " + target
		w.store_buffer(reader.read_file(f))
		w.close()
	reader.close()
	var s := FileAccess.open(stamp_file, FileAccess.WRITE)
	s.store_string(stamp)
	s.close()
	return ""


static func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true  # the .from_zip stamp
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _add_found(root: String, found: Dictionary) -> void:
	var manifest_path := root.path_join("mod.json")
	if not FileAccess.file_exists(manifest_path):
		return
	var json := JSON.new()
	var m = json.data if json.parse(FileAccess.get_file_as_string(manifest_path)) == OK else null
	var problem := manifest_problem(m, root)
	if problem != "":
		push_error("Invalid mod.json (%s), skipping it: %s" % [problem, manifest_path])
		return
	if int(m.get("api_version", 1)) > API_VERSION:
		push_error("Mod '%s' needs a newer game (mod API %d, this game has %d); skipping it"
				% [m.id, int(m.api_version), API_VERSION])
		return
	if found.has(m.id):
		push_warning("Duplicate mod id '%s' at %s, ignoring" % [m.id, root])
		return
	m.path = root
	found[m.id] = m


## What is wrong with a mod.json (already parsed) for a mod in `root`, or "".
## Checked before anything of the mod loads, so a broken mod is skipped as a
## whole instead of failing halfway through.
func manifest_problem(m, root: String) -> String:
	if not m is Dictionary:
		return "not a JSON object"
	if not m.get("id") is String or not _id_regex.search(m.id):
		return "\"id\" must be a string of a-z, 0-9 and _"
	for key in ["name", "version"]:
		if m.has(key) and not m[key] is String:
			return "\"%s\" must be a string" % key
	if m.has("api_version") and not (m.api_version is float or m.api_version is int):
		return "\"api_version\" must be a number"
	if not m.get("dependencies", []) is Array:
		return "\"dependencies\" must be a list"
	for dep in m.get("dependencies", []):
		if not dep is String or not _id_regex.search(dep):
			return "dependency %s isn't a mod id" % [dep]
	if not m.get("content", []) is Array:
		return "\"content\" must be a list"
	for rel in m.get("content", []):
		var why := _file_problem(rel, root, ".json")
		if why != "":
			return "content " + why
	if m.has("entry"):
		var why := _file_problem(m.entry, root, ".gd")
		if why != "":
			return "entry " + why
	return ""


## A path inside the mod folder to an existing file with this extension.
func _file_problem(rel, root: String, extension: String) -> String:
	if not rel is String or rel == "":
		return "path must be a string"
	if rel.is_absolute_path() or rel.begins_with("/") or ".." in rel.split("/") or "://" in rel:
		return "'%s' must be a path inside the mod folder" % rel
	if not rel.ends_with(extension):
		return "'%s' must be a %s file" % [rel, extension]
	if not FileAccess.file_exists(root.path_join(rel)):
		return "'%s' doesn't exist" % rel
	return ""


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
		push_error("Missing mod '%s'%s" % [id, " (it's turned off)" if id in Settings.disabled_mods else ""])
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


## Content file format: { "blocks": {id: def}, "items": {id: def}, "recipes": {id: def},
##                        "ores": {id: def}, "trees": {id: def}, "biomes": {id: def}, "sound_sets": {id: def} }
func _load_content_file(path: String) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("Invalid content file: " + path)
		return
	for section in data:  # every section is {id: definition object}
		if not data[section] is Dictionary or data[section].values().any(func(d): return not d is Dictionary):
			push_error("Invalid content file %s: \"%s\" must map ids to objects; skipping the file" % [path, section])
			return
	for id in data.get("blocks", {}):
		Registry.register_block(id, data.blocks[id])
	for id in data.get("items", {}):
		Registry.register_item(id, data.items[id])
	for id in data.get("recipes", {}):
		Registry.register_recipe(id, data.recipes[id])
	for id in data.get("ores", {}):
		Registry.register_ore(id, data.ores[id])
	for id in data.get("trees", {}):
		Registry.register_tree(id, data.trees[id])
	for id in data.get("biomes", {}):
		Registry.register_biome(id, data.biomes[id])
	for id in data.get("sound_sets", {}):
		Registry.register_sound_set(id, data.sound_sets[id])
