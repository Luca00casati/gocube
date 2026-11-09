extends SceneTree
## Runs every tests/test_*.gd file's test_* methods; exits with 1 on failure.
##   godot4 --headless -s res://tests/run_tests.gd [-- name_filter]
## A test fails if a check fails, if its file doesn't compile, or if any error
## (script, engine or shader; not warnings) is logged while it runs, other
## than ones the test expects (expect_error).
## Test data (worlds and folders in user:// whose names start with "_test") is
## deleted before and after every test, so nothing is left behind and no test
## sees another's leftovers.


class ErrorCounter extends Logger:
	var _mutex := Mutex.new()
	var _messages: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		_messages.append("%s (%s:%d %s)" % [rationale if rationale != "" else code, file.get_file(), line, function])
		_mutex.unlock()

	func take() -> PackedStringArray:
		_mutex.lock()
		var m := _messages
		_messages = []
		_mutex.unlock()
		return m


var _errors := ErrorCounter.new()


func _initialize() -> void:
	OS.add_logger(_errors)
	_run.call_deferred()


## Permanently deletes test worlds (user://worlds/_test*) and other test
## folders (user://_test*).
static func _remove_test_data() -> void:
	for parent in ["user://worlds", "user://"]:
		if not DirAccess.dir_exists_absolute(parent):
			continue
		for d in DirAccess.get_directories_at(parent):
			if d.begins_with("_test"):
				_remove_dir(parent.path_join(d))


static func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _run() -> void:
	var filter := ""
	if not OS.get_cmdline_user_args().is_empty():
		filter = OS.get_cmdline_user_args()[0]
	root.get_node("ModLoader").load_all()
	var setup_errors := _errors.take()
	var files := Array(DirAccess.get_files_at("res://tests")).filter(
			func(f): return f.begins_with("test_") and f.ends_with(".gd") and f != "test_suite.gd")
	files.sort()
	var passed := 0
	var failed := 0
	if not setup_errors.is_empty():
		failed += 1
		print("FAIL  loading mods")
		for e in setup_errors:
			print("        - ", e)
	_remove_test_data()
	var t_all := Time.get_ticks_msec()
	for file in files:
		if filter != "" and not filter in file:
			continue
		var script: GDScript = load("res://tests/" + file)
		if script == null or not script.can_instantiate():
			failed += 1
			print("FAIL  %s: does not compile" % file)
			for e in _errors.take():
				print("        - ", e)
			continue
		_errors.take()
		for method in script.get_script_method_list():
			var name: String = method.name
			if not name.begins_with("test_"):
				continue
			var suite = script.new()
			suite.tree = self
			var t0 := Time.get_ticks_msec()
			await suite.call(name)
			var failures: PackedStringArray = suite._finish()
			await process_frame
			await process_frame  # freed worlds have saved their last chunks by now
			_remove_test_data()
			var expected: PackedStringArray = suite.expected_errors
			for e in _errors.take():
				if not Array(expected).any(func(x): return x in e):
					failures.append("error logged: " + e)
			var label := "%s :: %s (%d ms)" % [file.get_basename(), name, Time.get_ticks_msec() - t0]
			if failures.is_empty():
				passed += 1
				print("PASS  ", label)
			else:
				failed += 1
				print("FAIL  ", label)
				for f in failures:
					print("        - ", f)
	print("\n%d passed, %d failed (%.1f s)" % [passed, failed, (Time.get_ticks_msec() - t_all) / 1000.0])
	quit(1 if failed > 0 else 0)
