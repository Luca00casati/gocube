extends SceneTree
## Runs one installed mod's entry script in a Godot process of its own, so
## nothing it does can crash or stall the game (ModLoader._run_entry_isolated
## starts it and kills it if it takes too long).
##
##   godot --headless --path <game> -s res://src/core/mod_runner.gd -- <input file>
##
## The input (var_to_bytes) has the mod id, its script, what is registered so
## far (blocks and items, for get_block / get_item) and where to write the
## result: {"calls": [[kind, id, def], ...], "gave_up", "stopped", "problem",
## "errors"}. The game registers the calls itself.

var _id := ""
var _snapshot := {}
var _result := {"calls": [], "errors": [], "gave_up": false, "stopped": "", "problem": ""}
var _engine_errors := []


## Errors the engine reports while the script runs (say, a string too big to
## make): the mod is refused with the first one.
class ErrorLog extends Logger:
	var errors: Array

	func _init(into: Array) -> void:
		errors = into

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_WARNING:
			errors.append(rationale if rationale != "" else code)

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var input = bytes_to_var(FileAccess.get_file_as_bytes(args[0])) if not args.is_empty() else null
	if not input is Dictionary:
		quit(1)
		return
	_id = input.id
	_snapshot = input.snapshot
	ModSandbox.time_limit_ms = input.time_limit_ms
	ModSandbox.memory_limit = input.memory_limit
	_run(input.script)
	var f := FileAccess.open(input.out, FileAccess.WRITE)
	f.store_buffer(var_to_bytes(_result))
	f.close()
	quit()


func _run(path: String) -> void:
	var source := FileAccess.get_file_as_string(path)
	var problem := ModSandbox.check(source)  # (checked by the game too)
	if problem != "":
		_result.problem = problem
		return
	var script := GDScript.new()
	script.source_code = ModSandbox.instrument(source)
	if script.reload() != OK or not script.can_instantiate():
		_result.problem = "its entry script doesn't compile"
		return
	var inst = script.new()
	var api := GoCubeModApi.new()
	api._set_handler(_api)
	var log := ErrorLog.new(_engine_errors)
	OS.add_logger(log)
	_result.gave_up = inst.has_method("init_mod") and inst.init_mod(api) == false
	OS.remove_logger(log)
	api._set_handler(Callable())
	_result.stopped = ModSandbox.stopped_by(script)
	if not _engine_errors.is_empty() and _result.stopped == "":
		_result.problem = "error while loading: %s" % _engine_errors[0]


## As ModLoader._api_call, but recording: ids get the mod's prefix, and blocks
## and items registered are seen by get_block / get_item afterwards.
func _api(kind: String, id: String, def: Dictionary) -> Variant:
	var full := id if ":" in id else "%s:%s" % [_id, id]
	match kind:
		"get_block":
			return _snapshot.blocks.get(full, {}).duplicate(true)
		"get_item":
			return _snapshot.items.get(full, {}).duplicate(true)
	if not ModSandbox.is_plain(def):
		_result.errors.append("%s '%s' holds something that isn't plain data; not registered" % [kind, full])
		return ""
	_result.calls.append([kind, full, def.duplicate(true)])
	if kind in ["block", "item"]:
		var entry := def.duplicate(true)
		entry.id = full
		entry.mod = _id
		_snapshot[kind + "s"][full] = entry
	return full
