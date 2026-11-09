extends "res://tests/test_suite.gd"
## Multiplayer across two real Godot processes over the network: starts a
## headless host and a headless client running mp_smoke.tscn, collects the
## client's PASS/FAIL lines, and checks that both ended up with the same blocks
## where the client played (each prints a fingerprint of the area).
## Its world is named _test_…, so the runner deletes it afterwards.

const HOST_READY_SECONDS := 60.0
const RUN_SECONDS := 120.0


## A child Godot process whose output is read as it comes (so its pipe never fills).
class Child:
	var pid := -1
	var _pipes: Array[FileAccess] = []
	var _partial := ["", ""]
	var lines: PackedStringArray = []

	func _init(args: PackedStringArray) -> void:
		var r := OS.execute_with_pipe(OS.get_executable_path(), args, false)
		if r.is_empty():
			return
		pid = r.pid
		_pipes = [r.stdio, r.stderr]

	func started() -> bool:
		return pid > 0

	func running() -> bool:
		return pid > 0 and OS.is_process_running(pid)

	## Reads whatever output arrived; returns whether the process still runs.
	func poll() -> bool:
		var alive := running()
		for i in _pipes.size():
			var data := _pipes[i].get_buffer(1 << 16)
			if data.is_empty():
				continue
			var text: String = _partial[i] + data.get_string_from_utf8()
			var parts := text.split("\n")
			_partial[i] = parts[parts.size() - 1]
			for k in parts.size() - 1:
				lines.append(parts[k].strip_edges(false, true))
		return alive

	func finish() -> void:
		for i in _pipes.size():
			if _partial[i] != "":
				lines.append(_partial[i])
				_partial[i] = ""
		if running():
			OS.kill(pid)
		for f in _pipes:
			f.close()

	func has_line(prefix: String) -> bool:
		return Array(lines).any(func(l): return l.begins_with(prefix))

	func value(prefix: String) -> String:
		for l in lines:
			if l.begins_with(prefix):
				return l.trim_prefix(prefix).strip_edges()
		return ""


func _args(user_args: Array) -> PackedStringArray:
	return PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"res://tests/mp_smoke.tscn", "--"] + user_args)


## Polls the children until `cond` holds or `seconds` pass.
func _wait(children: Array, cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		for c in children:
			c.poll()
		if Time.get_ticks_msec() - t0 > seconds * 1000.0:
			return false
		await tree.process_frame
	for c in children:
		c.poll()
	return true


func test_host_and_client_processes() -> void:
	var port := 25000 + randi() % 5000
	var host := Child.new(_args(["host", "_test_mp_smoke_%d" % OS.get_process_id(), str(port)]))
	check(host.started(), "the host process started")
	if not host.started():
		return
	var client: Child = null
	if not await _wait([host], func(): return host.has_line("HOST ready") or not host.running(), HOST_READY_SECONDS):
		check(false, "the host got ready within %d s" % HOST_READY_SECONDS)
	elif not host.running():
		check(false, "the host stopped before it was ready")
	else:
		client = Child.new(_args(["client", str(port)]))
		check(client.started(), "the client process started")
		if client.started():
			# The host quits once the client has left.
			var done := func(): return not client.running() and not host.running()
			check(await _wait([host, client], done, RUN_SECONDS), "both finished within %d s" % RUN_SECONDS)
	host.finish()
	if client:
		client.finish()
		var results := Array(client.lines).filter(func(l): return l.begins_with("PASS ") or l.begins_with("FAIL "))
		check(not results.is_empty(), "the client reported results")
		for l in results:
			check(l.begins_with("PASS "), "client: " + l.trim_prefix("FAIL").strip_edges())
		var mine := client.value("AREA ")
		var theirs := host.value("HOST AREA ")
		check(mine != "" and mine == theirs,
				"host and client worlds match (client %s, host %s)" % [mine if mine else "none", theirs if theirs else "none"])
		var errors := Array(host.lines + client.lines).filter(func(l): return l.begins_with("ERROR") or l.begins_with("SCRIPT ERROR"))
		check(errors.is_empty(), "no errors in the processes: %s" % "; ".join(errors.slice(0, 3)))
	if not _failures.is_empty():  # show what the processes said
		print("        host output:\n          " + "\n          ".join(host.lines.slice(-15)))
		if client:
			print("        client output:\n          " + "\n          ".join(client.lines.slice(-15)))
