extends Node3D
## The game scene: one world, offline, hosted for others, or joined over the network.

const Player := preload("res://src/player/player.gd")
const WorldMenu := preload("res://src/ui/world_menu.gd")
## Height of the terrain band that must be meshed before the loading screen
## hides; horizontally it covers the whole view distance, so nothing pops in
## and the first mesh uploads (which hitch) happen behind the loading screen.
const SPAWN_AREA_HEIGHT := 64.0
## Never keep the loading screen up longer than this.
const LOADING_TIMEOUT_MS := 10000
const AUTOSAVE_SECONDS := 60.0

## Set by the world menu before the scene enters the tree.
var world_name := "default"
var new_seed := -1
var net_mode := "offline"  # "offline", "host" or "client"
var join_address := "127.0.0.1"
var port := Session.DEFAULT_PORT
var player_name := "Player"
## True when launched from the command line: then options after `--` apply.
var use_cmdline := false

## Command-line options after `--`, e.g. `godot4 -- --world=test --view=128`.
## --world / --seed / --host / --join=ADDR / --port / --name override the above.
var _args := {}
var _fps_label: Label
var _loading: Control
var _loading_since := 0
var _world: World
var _player: Node3D  # player.gd
var _cam: Camera3D  # the player's eyes
var _session: Session
var _bench_samples: PackedFloat32Array = []
var _saving := false
var _leaving := false
var _pause_menu: Control
var _underwater: ColorRect


func _ready() -> void:
	# Main keeps running while paused (Esc, saving, networking, streaming); only
	# the camera pauses.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if use_cmdline:
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	world_name = _args.get("world", world_name)
	new_seed = int(_args.get("seed", new_seed))
	if _args.has("host"):
		net_mode = "host"
	if _args.has("join"):
		net_mode = "client"
		join_address = _args.join
	port = int(_args.get("port", port))
	player_name = _args.get("name", player_name)

	_mark("engine start -> main._ready")
	ModLoader.load_all()
	_mark("mods loaded")
	print("Loaded mods: ", ModLoader.mods.map(func(m): return m.id))

	_session = Session.new()
	_session.name = "Session"  # same node path on every peer, for RPCs
	_session.player_name = player_name
	add_child(_session)
	_world = World.new()
	_world.name = "World"
	add_child(_world)
	_session.world = _world
	_add_environment()
	_add_hud()

	if net_mode == "client":
		_start_client()
	else:
		_start_local()


## Offline or hosting: this process owns the world.
func _start_local() -> void:
	if net_mode == "host":
		var err := _session.host(port)
		if err != OK:
			_leave_to_menu.call_deferred("Couldn't host on port %d: %s" % [port, error_string(err)])
			return
	_world.build(world_name, int(_args.get("view", World.DEFAULT_VIEW_DISTANCE)),
			new_seed, not _args.has("bench"))
	print("World '%s' (seed %d) at %s" % [world_name, int(_world.meta.seed),
			ProjectSettings.globalize_path(_world.dir) if _world.is_persistent() else "<not saved>"])
	if net_mode == "host":
		print("Hosting on port %d (%s)" % [port, ", ".join(_lan_addresses())])
	_mark("world built")

	_spawn_player(Vector3(0, 40, 0))
	_restore_player(_world.meta.get("player", {}))

	if _world.is_persistent():
		get_tree().auto_accept_quit = false  # save before closing, see _notification
		var autosave := Timer.new()
		autosave.wait_time = AUTOSAVE_SECONDS
		autosave.autostart = true
		autosave.timeout.connect(save_game)
		add_child(autosave)

	_mark("scene ready")
	if _args.has("profile-startup"):
		_profile_frames()
	if _args.has("bench"):
		_run_bench()


## Joining: connect, get the world's block table from the host, then build.
func _start_client() -> void:
	_set_loading_text("Connecting to %s:%d…" % [join_address, port])
	_session.ended.connect(_on_session_ended)
	_session.welcomed.connect(_on_welcomed, CONNECT_ONE_SHOT)
	var err := _session.join(join_address, port)
	if err != OK:
		_leave_to_menu.call_deferred("Couldn't connect: %s" % error_string(err))


func _on_welcomed(info: Dictionary) -> void:
	_world.build_remote(PackedStringArray(info.block_ids), int(info.view_distance),
			int(info.seed), info.chunks)
	var s: Array = info.spawn  # an eye position next to the host
	_spawn_player(Vector3(s[0], s[1] - Player.EYE_HEIGHT, s[2]))
	_player.edit_handler = _session.request_edit
	_set_loading_text("Loading world…")
	_loading_since = Time.get_ticks_msec()
	print("Joined %s:%d" % [join_address, port])


func _on_session_ended(reason: String) -> void:
	print("Disconnected: ", reason)
	_leave_to_menu(reason)


## `feet`: where the player stands. Physics starts once the spawn area loaded.
func _spawn_player(feet: Vector3) -> void:
	var player := Player.new()
	player.name = "Player"
	player.world = _world
	player.position = feet
	player.autopilot = _args.has("bench")
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(player)
	_world.set_viewer(player.global_position)
	_player = player
	_cam = player.camera
	_session.local_player = player.camera


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _world and _world.is_persistent():
		_save_and_quit()


func _exit_tree() -> void:
	get_tree().auto_accept_quit = true
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and not _loading and not _args.has("bench"):
		set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()


## In multiplayer the world keeps running for everyone; this only freezes our camera.
func set_paused(paused: bool) -> void:
	get_tree().paused = paused
	_pause_menu.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED


func _save_and_quit() -> void:
	_show_saving()
	await save_game()
	get_tree().quit()


## Saves (if this process owns a saved world), then shows the world menu with
## an optional message, e.g. why a connection ended.
func _leave_to_menu(message: String = "") -> void:
	if _leaving:
		return
	_leaving = true
	if _world.is_persistent() and _world.engine:
		_show_saving()
		await save_game()
	_session.leave()
	get_tree().paused = false
	WorldMenu.notice = message
	var tree := get_tree()
	var scene: Node = load("res://src/ui/world_menu.tscn").instantiate()
	tree.root.add_child(scene)
	tree.current_scene = scene
	queue_free()


func _show_saving() -> void:
	for b in _pause_menu.find_children("*", "Button", true, false):
		b.disabled = true
	_pause_menu.visible = true
	(_pause_menu.find_child("Title", true, false) as Label).text = "Saving…"


## Saves the world; if a save (e.g. autosave) is running, waits for it and saves again.
func save_game() -> void:
	if not _world.is_persistent() or _world.engine == null:
		return
	while _saving:
		await get_tree().process_frame
	_saving = true
	var t := Time.get_ticks_msec()
	await _world.save(_player_state())
	_saving = false
	print("World saved in %d ms" % (Time.get_ticks_msec() - t))


## Saved in world.json. "position" is the feet; "rotation" is [pitch, yaw].
func _player_state() -> Dictionary:
	if _player == null:
		return {}
	var p := _player.global_position
	return {"position": [p.x, p.y, p.z], "rotation": [_player.look_pitch(), _player.look_yaw()],
			"flying": _player.flying}


func _restore_player(state: Dictionary) -> void:
	if state.has("position"):
		var p: Array = state.position
		_player.position = Vector3(p[0], p[1], p[2])
	if state.has("rotation"):
		_player.set_look(state.rotation[0], state.rotation[1])
	_player.flying = bool(state.get("flying", false))


func _process(_delta: float) -> void:
	if _loading and _cam and _spawn_area_meshed():
		_loading.queue_free()
		_loading = null
		_player.set_ready_to_move()
		_mark("spawn area meshed, loading screen hidden")
	if _cam and _world.engine:
		_world.set_viewer(_cam.global_position)  # chunks load around the local player
	if _player and _world.engine and not _player.autopilot:
		var eye := Vector3i(_cam.global_position.floor())
		_underwater.visible = _world.is_fluid(_world.get_block(eye))
	var status := "%d FPS" % Engine.get_frames_per_second()
	if _player and not _player.autopilot:
		var block: String = _player.selected_block()
		var def: Dictionary = Registry.blocks.get(block, {})
		status += " · %s · placing %s (1-9 / wheel)" % ["flying (F)" if _player.flying else "walking (F to fly)",
				def.get("name", block.get_slice(":", 1).capitalize())]
	if _session.is_host():
		status += " · hosting on %s port %d · %d player(s)" % [
				" / ".join(_lan_addresses()), port, _session.player_count()]
	elif _session.is_client():
		status += " · connected to %s · %d player(s)" % [join_address, _session.player_count()]
	_fps_label.text = status


static func _lan_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out if not out.is_empty() else PackedStringArray(["127.0.0.1"])


# --- Scene setup -------------------------------------------------------------------

func _add_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = _args.has("shadows") or _args.has("cheap-shadows")
	if _args.has("cheap-shadows"):
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 48.0
	add_child(sun)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Default 256 px radiance map costs ~120 ms on the first frame on weak GPUs;
	# blocks are fully rough, so a tiny one looks identical.
	env.environment.sky.radiance_size = Sky.RADIANCE_SIZE_32
	add_child(env)


func _add_hud() -> void:
	var hud := CanvasLayer.new()
	_fps_label = Label.new()
	_fps_label.position = Vector2(8, 8)
	hud.add_child(_fps_label)
	var crosshair := Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for r in [Rect2(-8, -1, 16, 2), Rect2(-1, -8, 2, 16)]:
		var bar := ColorRect.new()
		bar.color = Color(1, 1, 1, 0.75)
		bar.position = r.position
		bar.size = r.size
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crosshair.add_child(bar)
	hud.add_child(crosshair)
	_underwater = ColorRect.new()  # tint while the camera is inside a fluid
	_underwater.color = Color(0.1, 0.3, 0.55, 0.45)
	_underwater.set_anchors_preset(Control.PRESET_FULL_RECT)
	_underwater.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_underwater.visible = false
	hud.add_child(_underwater)
	hud.move_child(_underwater, 0)  # under the HUD text
	_loading = _make_loading_screen()
	_loading_since = Time.get_ticks_msec()
	hud.add_child(_loading)
	_pause_menu = _make_pause_menu()
	hud.add_child(_pause_menu)
	add_child(hud)


func _spawn_area_meshed() -> bool:
	if Time.get_ticks_msec() - _loading_since > LOADING_TIMEOUT_MS:
		push_warning("Spawn area not meshed after %d ms; showing world anyway" % LOADING_TIMEOUT_MS)
		return true
	# Stay two mesh blocks inside the view distance: blocks at the edge may
	# never load when the camera isn't aligned to the block grid.
	# A chunk inside the view distance: the corners of a square that size would
	# poke outside the circular view range and never load.
	var r := float(_world.view_distance) * 0.7 - World.CHUNK_SIZE
	var size := Vector3(2 * r, SPAWN_AREA_HEIGHT, 2 * r)
	return _world.is_area_meshed(AABB(_cam.global_position - size / 2, size))


func _make_pause_menu() -> Control:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	bg.visible = false
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	var title := Label.new()
	title.name = "Title"
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var entries: Array = [["Resume", func(): set_paused(false)]]
	if net_mode == "client":
		entries += [["Disconnect", _leave_to_menu.bind("")], ["Quit game", get_tree().quit]]
	else:
		entries += [["Save & quit to menu", _leave_to_menu.bind("")], ["Save & quit game", _save_and_quit]]
	for entry in entries:
		var b := Button.new()
		b.text = entry[0]
		b.pressed.connect(entry[1])
		box.add_child(b)
	return bg


func _make_loading_screen() -> Control:
	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.13, 0.17)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var label := Label.new()
	label.name = "Label"
	label.text = "Generating world…"
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.grow_vertical = Control.GROW_DIRECTION_BOTH
	bg.add_child(label)
	return bg


func _set_loading_text(text: String) -> void:
	if _loading:
		(_loading.get_node("Label") as Label).text = text


# --- Benchmark / profiling -----------------------------------------------------------

## Flies forward for 20 s, logging FPS each second and frame-time stats at the end.
func _run_bench() -> void:
	var start := Time.get_ticks_msec()
	var worst := 0.0
	var hitches := 0
	var frames := 0
	var last := start
	while Time.get_ticks_msec() - start < 20000:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		worst = maxf(worst, now - last)
		if now - last > 33 and now - start > 2000:  # ignore startup
			hitches += 1
		last = now
		frames += 1
		if frames % 30 == 0:
			_bench_samples.append(Engine.get_frames_per_second())
	var avg := frames / ((Time.get_ticks_msec() - start) / 1000.0)
	print("BENCH avg_fps=%.1f worst_frame_ms=%.0f hitches_over_33ms=%d fps_samples=%s" % [avg, worst, hitches, Array(_bench_samples).map(func(f): return int(f))])
	get_tree().quit()


var _last_mark := 0


## Startup profiling (`-- --profile-startup`): prints time spent in each step.
func _mark(label: String) -> void:
	if not _args.has("profile-startup"):
		return
	var now := Time.get_ticks_msec()
	print("STARTUP %6d ms  +%5d  %s" % [now, now - _last_mark, label])
	_last_mark = now


func _profile_frames() -> void:
	var last := Time.get_ticks_msec()
	var slow: Array[String] = []
	for i in 180:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		if now - last > 20:
			slow.append("f%d@%dms:%dms" % [i, now, now - last])
		last = now
	print("STARTUP slow frames (>20ms) in first 180: ", slow)
	print("STARTUP first 180 frames done at %d ms" % last)
