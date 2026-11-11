extends Node
## Discovers and loads mods.
##
## A mod is a folder containing mod.json:
##   {
##     "id": "mymod",                       # required, [a-z0-9_]
##     "name": "My Mod", "version": "1.0.0",
##     "dependencies": ["othermod"],        # "core" is implicit
##     "content": ["content/blocks.json"],  # data-only content (optional)
##     "entry": "main.gd",                  # code entry point (optional): init_mod(registry)
##                                          # may return false to give up (the mod is undone);
##                                          # sandboxed, see mod_sandbox.gd
##     "api_version": 1                     # modding API it was written for (default 1)
##   }
##
## Sources, in order:
##   res://mods/<id>/          built-in mods (incl. the base game, "core")
##   user://mods/*.zip         a zipped mod folder (mod.json at the top of the zip,
##                             or inside one folder); unpacked to user://mods/.unzipped/
##   user://mods/<id>/         unpacked mod folders (handy while developing)
##
## Every content file is read and checked before anything of a mod is
## registered; a mod whose entry script can't load (or whose init_mod returns
## false) is undone: its registrations are rolled back and mods depending on
## it are skipped.
##
## Mods listed in Settings.disabled_mods are found but not loaded (the Mods
## part of the settings screen; takes effect the next time the game starts).
##
## Joining a server with other mods: the player downloads the ones they lack
## into SERVER_DIR/<id>_<fingerprint>/ (Session) and the game restarts with
## `--server-mods=<list>` (see restart_with_server_mods), which loads exactly
## the server's mods (from the player's own copies or that cache) and nothing
## else, for that game only.
##
## Mods are sandboxed: an entry script is checked by ModSandbox before it is
## compiled and only gets a GoCubeModApi (register_* and get_block/get_item);
## mod files (textures, sounds) are read as plain PNG/WAV data, never through
## Godot's resource loader, which could run scripts hidden in a resource.

signal mods_loaded

const BUILTIN_DIR := "res://mods"
const USER_DIR := "user://mods"
const UNZIP_DIR := "user://mods/.unzipped"
## Mods downloaded from servers, by "<id>_<fingerprint>" (never loaded otherwise).
const SERVER_DIR := "user://mods/.server"
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
## Playing with a server's mods (launched with --server-mods): its mod list
## ("id@version#fingerprint" each); empty otherwise.
var server_mods: Array = []
## Why mods didn't load this time: mod id (or folder / zip name) -> reason.
var problems := {}

var _id_regex := RegEx.create_from_string("^[a-z0-9_]+$")
var _loading: Dictionary = {}  # manifest of the mod currently being loaded


## Loads every mod once per game session; later calls do nothing.
func load_all() -> void:
	if Registry.is_frozen():
		return
	DirAccess.make_dir_recursive_absolute(USER_DIR)
	for file in DirAccess.get_files_at(USER_DIR):
		if file.get_extension() == "pck":
			push_warning("Mod packs (.pck) aren't loaded, they could run any code: zip the mod folder instead (%s)" % file)

	var found := {}
	_scan(BUILTIN_DIR, found)
	_scan(USER_DIR, found)
	_scan_zips(USER_DIR, found)
	var wanted = server_mods_option()
	if wanted is Array:
		server_mods = wanted
		found = _server_set(wanted, found)

	available.clear()
	for id in found:
		if id != CORE_ID:
			available.append(found[id])
	available.sort_custom(func(a, b): return a.id < b.id)
	for id in Settings.disabled_mods:
		if found.has(id) and id != CORE_ID and server_mods.is_empty():
			print("Mod %s is turned off" % id)
			found.erase(id)

	var failed := {}
	for id in _resolve_order(found):
		var deps: Array = found[id].get("dependencies", [])
		var broken_dep = deps.filter(func(d): return failed.has(d))
		if not broken_dep.is_empty():
			_fail(id, "Skipping mod '%s': dependency '%s' failed to load" % [id, broken_dep[0]])
			failed[id] = true
		elif not _load_mod(found[id]):
			failed[id] = true

	Registry._freeze()
	mods_loaded.emit()


## Folder a loaded mod lives in (res://mods/<id> or user://mods/<id>), or "" if unknown.
func get_mod_path(mod_id: String) -> String:
	for m in mods:
		if m.id == mod_id:
			return m.path
	return _loading.get("path", "") if _loading.get("id") == mod_id else ""


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
			_fail(zip.get_file(), "Mod zip %s: %s; skipping it" % [zip, problem])
			continue
		_add_found(out, found)


## Limits for a mod zip (a small zip can unpack to gigabytes, a "zip bomb").
const ZIP_MAX_FILES := 2000
const ZIP_MAX_FILE := 64 << 20
const ZIP_MAX_TOTAL := 256 << 20
const ZIP_MAX_RATIO := 1000  # unpacked / packed, for files over 1 MB


## Unpacks a mod zip into `out` (replacing what was there) unless `out` already
## holds this version of it. The zip has mod.json at its top or in its single
## top folder. Its table of contents is read and checked first (number of
## files, sizes, how much they unpack to: Godot makes room for that much when
## it reads a file), then it is unpacked into a folder beside `out` that takes
## its place only once everything is there. Returns "" or what went wrong.
func unzip_mod(zip_path: String, out: String) -> String:
	var stamp := str(FileAccess.get_modified_time(zip_path)) + ":" + str(FileAccess.get_size(zip_path))
	var stamp_file := out.path_join(".from_zip")
	if FileAccess.file_exists(stamp_file) and FileAccess.get_file_as_string(stamp_file) == stamp:
		return ""
	var listing = zip_listing(zip_path)
	if listing is String:
		return listing
	var total := 0
	for name in listing:
		var packed: int = listing[name][0]
		var size: int = listing[name][1]
		total += size
		if size > ZIP_MAX_FILE:
			return "'%s' unpacks to more than %d MB" % [name, ZIP_MAX_FILE >> 20]
		if size > (1 << 20) and size > maxi(packed, 1) * ZIP_MAX_RATIO:
			return "'%s' is packed suspiciously tight (a zip bomb?)" % name
	if listing.size() > ZIP_MAX_FILES:
		return "it has more than %d files" % ZIP_MAX_FILES
	if total > ZIP_MAX_TOTAL:
		return "it unpacks to more than %d MB" % (ZIP_MAX_TOTAL >> 20)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "can't open it as a zip"
	var files := reader.get_files()
	var names := PackedStringArray(listing.keys())
	names.sort()
	var sorted_files := files.duplicate()
	sorted_files.sort()
	if sorted_files != names:
		reader.close()
		return "its table of contents doesn't match its files"
	var prefix := ""
	if not "mod.json" in files:
		var tops := {}
		for f in files:
			tops[f.get_slice("/", 0)] = true
		if tops.size() != 1 or not (tops.keys()[0] + "/mod.json") in files:
			reader.close()
			return "no mod.json at its top or in its one top folder"
		prefix = tops.keys()[0] + "/"
	for f in files:
		var rel: String = f.substr(prefix.length())
		if f.begins_with(prefix) and not f.ends_with("/") and (rel.is_absolute_path() or rel.begins_with("/")
				or ".." in rel.split("/") or ":" in rel or "\\" in rel):
			reader.close()
			return "'%s' points outside the mod" % f
	var tmp := out.get_base_dir().path_join(".%s.unpacking" % out.get_file())  # (hidden: never taken for a mod)
	_remove_dir(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	for f in files:
		if not f.begins_with(prefix) or f.ends_with("/"):
			continue
		var target := tmp.path_join(f.substr(prefix.length()))
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var data := reader.read_file(f)
		var w := FileAccess.open(target, FileAccess.WRITE)
		if w == null or data.size() != int(listing[f][1]):
			reader.close()
			_remove_dir(tmp)
			return "can't unpack '%s'" % f
		w.store_buffer(data)
		w.close()
	reader.close()
	var s := FileAccess.open(tmp.path_join(".from_zip"), FileAccess.WRITE)
	s.store_string(stamp)
	s.close()
	_remove_dir(out)
	if DirAccess.rename_absolute(tmp, out) != OK:
		_remove_dir(tmp)
		return "can't move it into " + out
	return ""


## {file name: [packed size, unpacked size]} from a zip's table of contents
## (its central directory), or a String saying what's wrong with it.
static func zip_listing(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "can't open it"
	var size := f.get_length()
	if size < 22:
		return "it isn't a zip"
	var tail_len := mini(size, 22 + 65535)  # the end record, after a comment of up to 64 KB
	f.seek(size - tail_len)
	var tail := f.get_buffer(tail_len)
	var end := -1
	for i in range(tail_len - 22, -1, -1):
		if tail[i] == 0x50 and tail[i + 1] == 0x4b and tail[i + 2] == 0x05 and tail[i + 3] == 0x06:
			end = i
			break
	if end == -1:
		return "it isn't a zip"
	var count := tail.decode_u16(end + 10)
	var dir_size := tail.decode_u32(end + 12)
	var dir_at := tail.decode_u32(end + 16)
	if count == 0xFFFF or dir_at == 0xFFFFFFFF or dir_size == 0xFFFFFFFF:
		return "it's a ZIP64 archive (not supported)"
	if dir_at + dir_size > size or count > ZIP_MAX_FILES:
		return "its table of contents is broken" if count <= ZIP_MAX_FILES else "it has more than %d files" % ZIP_MAX_FILES
	f.seek(dir_at)
	var dir := f.get_buffer(dir_size)
	var out := {}
	var at := 0
	for n in count:
		if at + 46 > dir.size() or dir.decode_u32(at) != 0x02014b50:
			return "its table of contents is broken"
		var packed := dir.decode_u32(at + 20)
		var unpacked := dir.decode_u32(at + 24)
		var name_len := dir.decode_u16(at + 28)
		var next := at + 46 + name_len + dir.decode_u16(at + 30) + dir.decode_u16(at + 32)
		if next > dir.size():
			return "its table of contents is broken"
		if packed == 0xFFFFFFFF or unpacked == 0xFFFFFFFF:
			return "it's a ZIP64 archive (not supported)"
		var name := dir.slice(at + 46, at + 46 + name_len).get_string_from_utf8()
		if out.has(name):
			return "it has '%s' twice" % name
		out[name] = [packed, unpacked]
		at = next
	return out


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
		_fail(root.get_file(), "Invalid mod.json (%s), skipping it: %s" % [problem, manifest_path])
		return
	if int(m.get("api_version", 1)) > API_VERSION:
		_fail(m.id, "Mod '%s' needs a newer game (mod API %d, this game has %d); skipping it"
				% [m.id, int(m.api_version), API_VERSION])
		return
	if found.has(m.id):
		push_warning("Duplicate mod id '%s' at %s, ignoring" % [m.id, root])
		return
	var content := []
	for rel in m.get("content", []):
		var path := root.path_join(rel)
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		var why := content_problem(data)
		if why != "":
			_fail(m.id, "Mod '%s': content file %s %s; skipping the mod" % [m.id, rel, why])
			return
		content.append(data)
	m.path = root
	m._content = content  # parsed, checked content files
	found[m.id] = m


## What is wrong with a parsed content file, or "".
static func content_problem(data) -> String:
	if not data is Dictionary:
		return "isn't a JSON object"
	for section in data:  # every section is {id: definition object}
		if not data[section] is Dictionary or data[section].values().any(func(d): return not d is Dictionary):
			return "has \"%s\" not mapping ids to objects" % section
	return ""


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
		_fail(id, "Missing mod '%s'%s" % [id, " (it's turned off)" if id in Settings.disabled_mods else ""])
		state[id] = -1
		return false
	state[id] = 1
	var deps: Array = found[id].get("dependencies", [])
	if id != CORE_ID and CORE_ID not in deps:
		deps = [CORE_ID] + deps
	for dep in deps:
		if not _visit(dep, found, state, order):
			_fail(id, "Skipping mod '%s': dependency '%s' unavailable" % [id, dep])
			state[id] = -1
			return false
	state[id] = 2
	order.append(id)
	return true


## Loads one mod. Returns false (with everything it registered undone) if
## its entry script fails.
func _load_mod(m: Dictionary) -> bool:
	_loading = m
	var before := Registry._snapshot()
	Registry._begin_mod(m.id)
	for data in m.get("_content", []):
		_register_content(data)
	var ok := true
	if m.has("entry"):
		var problem := _run_entry(m) if is_builtin(m.path) else _run_entry_isolated(m)
		if problem != "":
			_fail(m.id, problem)
			ok = false
	Registry._end_mod()
	_loading = {}
	m.erase("_content")
	if not ok:
		Registry._restore(before)
		return false
	m.hash = fingerprint(m.path)
	mods.append(m)
	print("Loaded mod %s %s" % [m.id, m.get("version", "")])
	return true


## Runs a built-in mod's entry script here (it ships with the game). Returns
## "" or why the mod failed.
func _run_entry(m: Dictionary) -> String:
	var script := compile_entry(m.path.path_join(m.entry), m.id)
	if script == null:
		return "Mod '%s': could not load entry script %s; undoing the mod" % [m.id, m.entry]
	var inst = script.new()
	var api := GoCubeModApi.new()
	api._set_handler(_api_call)
	var gave_up: bool = inst.has_method("init_mod") and inst.init_mod(api) == false
	api._set_handler(Callable())  # the API only works while the mod loads
	var stopped := ModSandbox.stopped_by(script)
	if stopped != "":
		return ModSandbox.stop_message(m.id, stopped)
	if gave_up:
		return "Mod '%s': init_mod gave up; undoing the mod" % m.id
	instances[m.id] = inst
	return ""


## Results of installed mods' entry scripts, by mod files + what was
## registered before them (see mod_runner.gd).
const RESULTS_DIR := "user://mods/.results"
const RUN_DIR := "user://mods/.run"
## Most memory the process running a mod may have (Linux, with prlimit).
const RUNNER_ADDRESS_SPACE := 2 << 30
## Time for the process to start, on top of the mod's own time limit.
const RUNNER_START_GRACE_MS := 5000


## Runs an installed mod's entry script in a Godot process of its own
## (mod_runner.gd), which sends back what the mod registered; that is then
## registered here. Whatever the script does (fill all memory, crash), the
## game keeps running. Returns "" or why the mod failed.
func _run_entry_isolated(m: Dictionary) -> String:
	var path: String = m.path.path_join(m.entry)
	if not FileAccess.file_exists(path):
		return "Mod '%s': could not load entry script %s; undoing the mod" % [m.id, m.entry]
	var problem := ModSandbox.check(FileAccess.get_file_as_string(path))
	if problem != "":
		return "Mod '%s': %s %s; mods may only use the mod API (see mod_sandbox.gd)" % [m.id, m.entry, problem]
	var snapshot := {"blocks": Registry.blocks, "items": Registry.items}
	var key := _hash_text("v1|%s|%s|%s|%d|%d" % [fingerprint(m.path), var_to_str(snapshot), m.entry,
			ModSandbox.time_limit_ms, ModSandbox.memory_limit])
	var cached := RESULTS_DIR.path_join(key + ".bin")
	var result = null
	if FileAccess.file_exists(cached):
		result = bytes_to_var(FileAccess.get_file_as_bytes(cached))  # (never objects)
	if not result is Dictionary:
		result = _run_runner(m, path, snapshot)
		if result.get("problem", "") == "" and result.get("stopped", "") == "":
			DirAccess.make_dir_recursive_absolute(RESULTS_DIR)
			var f := FileAccess.open(cached, FileAccess.WRITE)
			if f:
				f.store_buffer(var_to_bytes(result))
	for e in result.get("errors", []):
		push_error("Mod '%s': %s" % [m.id, e])
	if result.get("problem", "") != "":
		return "Mod '%s': %s; undoing the mod" % [m.id, result.problem]
	if result.get("stopped", "") != "":
		return ModSandbox.stop_message(m.id, result.stopped)
	for call in result.get("calls", []):
		if call is Array and call.size() == 3 and call[0] is String and call[1] is String and call[2] is Dictionary:
			_api_call(call[0], call[1], call[2])
	if result.get("gave_up", false):
		return "Mod '%s': init_mod gave up; undoing the mod" % m.id
	return ""


func _run_runner(m: Dictionary, path: String, snapshot: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(RUN_DIR)
	var input := RUN_DIR.path_join("%s_%d.in" % [m.id, OS.get_process_id()])
	var output := input.get_basename() + ".out"
	DirAccess.remove_absolute(output)
	var f := FileAccess.open(input, FileAccess.WRITE)
	f.store_buffer(var_to_bytes({"id": m.id, "script": path, "snapshot": snapshot, "out": output,
			"time_limit_ms": ModSandbox.time_limit_ms, "memory_limit": ModSandbox.memory_limit}))
	f.close()
	var exe := OS.get_executable_path()
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://src/core/mod_runner.gd", "--", ProjectSettings.globalize_path(input)])
	if OS.get_name() == "Linux" and FileAccess.file_exists("/usr/bin/prlimit"):
		args = PackedStringArray(["--as=%d" % RUNNER_ADDRESS_SPACE, "--", exe]) + args
		exe = "/usr/bin/prlimit"
	var started := Time.get_ticks_msec()
	var pid := OS.create_process(exe, args)
	if pid == -1:
		return {"problem": "couldn't start a process to run it"}
	var waited := false
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() - started > ModSandbox.time_limit_ms + RUNNER_START_GRACE_MS:
			OS.kill(pid)
			waited = true
			break
		OS.delay_msec(5)
	DirAccess.remove_absolute(input)
	var result = bytes_to_var(FileAccess.get_file_as_bytes(output)) if FileAccess.file_exists(output) else null
	DirAccess.remove_absolute(output)
	if waited:
		return {"stopped": "time"}
	if not result is Dictionary:
		return {"problem": "its script crashed while loading (asked for too much memory?)"}
	return result


static func _hash_text(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode().left(24)


## Reads a mod's entry script, checks it with ModSandbox and compiles it from
## that same text (not through load(), which could pick up something other
## than the checked source). Returns null, with the reason logged, if refused.
func compile_entry(path: String, mod_id: String) -> GDScript:
	if not FileAccess.file_exists(path):
		return null
	var source := FileAccess.get_file_as_string(path)
	var problem := ModSandbox.check(source)
	if problem != "":
		_fail(mod_id, "Mod '%s': %s %s; mods may only use the mod API (see mod_sandbox.gd)" % [mod_id, path.get_file(), problem])
		return null
	var script := GDScript.new()
	script.source_code = ModSandbox.instrument(source)
	if script.reload() != OK or not script.can_instantiate():
		return null
	return script


## What a mod's GoCubeModApi calls. Definitions must be plain data (what JSON
## has, plus numbers and vectors): no objects or callables reach the game.
func _api_call(kind: String, id: String, def: Dictionary) -> Variant:
	match kind:
		"get_block":
			return Registry.blocks.get(Registry._qualify(id), {}).duplicate(true)
		"get_item":
			return Registry.items.get(Registry._qualify(id), {}).duplicate(true)
	if not ModSandbox.is_plain(def):
		push_error("Mod '%s': %s '%s' holds something that isn't plain data; not registered" % [_loading.get("id"), kind, id])
		return ""
	match kind:
		"block": return Registry.register_block(id, def)
		"item": return Registry.register_item(id, def)
		"recipe": return Registry.register_recipe(id, def)
		"ore": return Registry.register_ore(id, def)
		"tree": return Registry.register_tree(id, def)
		"biome": return Registry.register_biome(id, def)
		"sound_set": return Registry.register_sound_set(id, def)
	return ""


## The file `rel` of mod `mod_id` (or of another mod, as "othermod:path"), or
## "" when the path would leave the mod's folder or the mod isn't known.
func asset_path(mod_id: String, rel: String) -> String:
	if ":" in rel:
		mod_id = rel.get_slice(":", 0)
		rel = rel.substr(rel.find(":") + 1)
	var root := get_mod_path(mod_id)
	if root == "" or rel == "" or rel.is_absolute_path() or rel.begins_with("/") or "\\" in rel \
			or ":" in rel or ".." in rel.split("/"):
		return ""
	return root.path_join(rel)


## Files of built-in mods (res://) go through Godot's import system; files of
## installed mods are only ever read as raw data.
static func is_builtin(path: String) -> bool:
	return path.begins_with("res://")


## Logs why a mod didn't load and keeps the first reason for the Mods screen.
func _fail(key: String, message: String) -> void:
	push_error(message)
	if not problems.has(key):
		problems[key] = message


## Where a found mod comes from: "built-in", "zip" or "folder".
static func origin(m: Dictionary) -> String:
	var path: String = m.get("path", "")
	if path.begins_with("res://"):
		return "built-in"
	if path.begins_with(UNZIP_DIR):
		return "zip"
	return "folder"


## Total size in bytes of the files under a folder (hidden ones too).
static func folder_size(root: String) -> int:
	var total := 0
	var d := DirAccess.open(root)
	if d == null:
		return 0
	d.include_hidden = true
	for f in d.get_files():
		total += FileAccess.get_size(root.path_join(f))
	for sub in d.get_directories():
		total += folder_size(root.path_join(sub))
	return total


## Mods downloaded from servers: [{entry folder name, path, size}].
static func server_cache() -> Array:
	var out := []
	if DirAccess.dir_exists_absolute(SERVER_DIR):
		for sub in DirAccess.get_directories_at(SERVER_DIR):
			var path := SERVER_DIR.path_join(sub)
			out.append({"name": sub, "path": path, "size": folder_size(path)})
	return out


## Deletes the downloaded server mods (not while playing with them).
func clear_server_cache() -> bool:
	if not server_mods.is_empty():
		return false
	_remove_dir(SERVER_DIR)
	_fingerprints.clear()
	return true


# --- A server's mods ------------------------------------------------------------

## "id@version#fingerprint" of a loaded mod (what players compare when joining).
static func entry_of(m: Dictionary) -> String:
	return "%s@%s#%s" % [m.id, m.get("version", ""), m.get("hash", "")]


static func entry_id(entry: String) -> String:
	return entry.get_slice("@", 0)


static func entry_hash(entry: String) -> String:
	return entry.get_slice("#", entry.get_slice_count("#") - 1)


## Where a mod downloaded from a server is kept.
static func cache_dir(entry: String) -> String:
	return SERVER_DIR.path_join("%s_%s" % [entry_id(entry), entry_hash(entry)])


## The list given with --server-mods (base64 of a JSON list), or null.
static func server_mods_option():
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--server-mods="):
			var list = JSON.parse_string(Marshalls.base64_to_utf8(a.trim_prefix("--server-mods=")))
			if list is Array and list.all(func(e): return e is String):
				return list
			push_error("Bad --server-mods option; loading the usual mods")
	return null


static func encode_list(entries: Array) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify(entries))


var _fingerprints := {}  # folder -> fingerprint, for local_copy


## A folder here holding exactly the mod `entry` (same id and files): one the
## player installed (or a built-in one) or one downloaded before; "" if none.
func local_copy(entry: String) -> String:
	var id := entry_id(entry)
	var roots: Array[String] = [BUILTIN_DIR.path_join(id), USER_DIR.path_join(id), cache_dir(entry)]
	for dir in [UNZIP_DIR, SERVER_DIR]:
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for sub in DirAccess.get_directories_at(dir):
			roots.append(dir.path_join(sub))
	for root in roots:
		var manifest := root.path_join("mod.json")
		if not FileAccess.file_exists(manifest):
			continue
		var m = JSON.parse_string(FileAccess.get_file_as_string(manifest))
		if not m is Dictionary or m.get("id") != id:
			continue
		if not _fingerprints.has(root):
			_fingerprints[root] = fingerprint(root)
		if _fingerprints[root] == entry_hash(entry):
			return root
	return ""


## The mods to load for a server's list: each from a local copy with the same
## files; the player's other mods are left out.
func _server_set(wanted: Array, scanned: Dictionary) -> Dictionary:
	var out := {}
	for entry in wanted:
		var root := local_copy(entry)
		if root == "":
			push_error("The server's mod %s isn't here" % entry)
		elif scanned.has(entry_id(entry)) and scanned[entry_id(entry)].path == root:
			out[entry_id(entry)] = scanned[entry_id(entry)]
		else:
			_add_found(root, out)
	if not out.has(CORE_ID) and scanned.has(CORE_ID):
		out[CORE_ID] = scanned[CORE_ID]  # (the server would refuse a different core anyway)
	print("Playing with the server's mods: ", out.keys())
	return out


## Restarts the game with these launch options after `--` (the same project
## folder and engine options).
func restart(user_args: Array) -> void:
	var args := OS.get_cmdline_args()
	if not "--path" in args:
		args = PackedStringArray(["--path", ProjectSettings.globalize_path("res://")]) + args
	args.append("--")
	args.append_array(PackedStringArray(user_args))
	OS.set_restart_on_exit(true, args)
	(Engine.get_main_loop() as SceneTree).quit()


## Launch options without the ones that pick what to play (for a restart).
static func plain_user_args() -> Array:
	return Array(OS.get_cmdline_user_args()).filter(func(a: String):
		return a.trim_prefix("--").get_slice("=", 0) not in ["join", "port", "name", "server-mods",
				"world", "host", "seed", "mode", "bench", "notice"])


## A short hash of every file in a mod folder (names and contents), so players
## can tell whether two copies of a mod with the same version really match.
static func fingerprint(root: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in _files_under(root, ""):
		ctx.update(rel.to_utf8_buffer())
		ctx.update(PackedByteArray([0]))
		ctx.update(FileAccess.get_file_as_bytes(root.path_join(rel)))
	return ctx.finish().hex_encode().left(12)


## Relative paths of the files under root (not hidden ones), sorted.
static func _files_under(root: String, rel: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := root.path_join(rel) if rel != "" else root
	var files := DirAccess.get_files_at(dir)
	for f in files:
		out.append(rel.path_join(f) if rel != "" else f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_files_under(root, rel.path_join(d) if rel != "" else d))
	out.sort()
	return out


## Content file format: { "blocks": {id: def}, "items": {id: def}, "recipes": {id: def},
##                        "ores": {id: def}, "trees": {id: def}, "biomes": {id: def}, "sound_sets": {id: def} }
## (already checked with content_problem)
func _register_content(data: Dictionary) -> void:
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
