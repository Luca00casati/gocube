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
var game_mode := "survival"  # for new worlds
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
var _debug_label: Label   # F3
var _crosshair: Control
var _debug_timer := 0.0
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
var _sleep_shade: ColorRect      # darkens the screen while sleeping
var _notice_label: Label         # short messages ("Respawn point set")
var _notice_time := 0.0
var _slept := 0.0                # seconds everyone has been in bed
const SLEEP_SECONDS := 2.5       # in bed this long (everyone) skips the night
const MORNING := 0.26            # time of day sleeping wakes you at
const NINJA_NEAR := 10.0         # can't sleep with a ninja this close
## A new world's first night is safe: no ninjas until a morning has followed
## a night (or everyone slept through it). meta.first_night: "ahead" -> "now"
## -> "over"; worlds from before this have none, so they count as over.
var _day: DayCycle
var _hud: CanvasLayer
var _hotbar: Hotbar
var _inventory_screen: InventoryScreen
var _settings_screen: SettingsScreen
var _sounds: Sounds
var _hurt_flash: ColorRect
var _death_screen: Control
var _container_screen: ContainerScreen
var _drops_node: ItemDrops
var _mobs: MobManager
var _restored_player := false  # position came from the save (else: put on the ground)


func _ready() -> void:
	# Main keeps running while paused (Esc, saving, networking, streaming); only
	# the camera pauses.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if use_cmdline:
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	game_mode = _args.get("mode", game_mode)
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
	_world.worker_threads = int(_args.get("threads", -1))
	add_child(_world)
	_session.world = _world
	_add_environment()
	_add_hud()
	_sounds = Sounds.new()
	_sounds.name = "Sounds"
	add_child(_sounds)
	_session.remote_edit.connect(_on_remote_edit)
	_session.own_edit_confirmed.connect(func(pos): _player.confirm_break(pos))
	_session.own_edit_refused.connect(func(pos): _player.pending_drops.erase(pos))
	_session.placement_refused.connect(func(item: String):
		if _player == null:
			return
		if _player.inventory.add(item, 1) > 0:  # full meanwhile: on the ground
			spawn_drop(item, 1, _player.global_position + Vector3(0, 0.5, 0))
		show_notice("Couldn't place that there"))
	_drops_node = ItemDrops.new()
	_drops_node.name = "Drops"
	_drops_node.world = _world
	_drops_node.picked_up.connect(func(_i, _n): _sounds.play("core:effects", "pickup", _cam.global_position, -8.0))
	add_child(_drops_node)
	_session.drops = _drops_node
	_session.items_picked.connect(func(item: String, count: int):
		if _player == null:
			return
		_sounds.play("core:effects", "pickup", _cam.global_position, -8.0)
		var left: int = _player.inventory.add(item, count)
		if left > 0:  # it no longer fits: back on the ground
			spawn_drop(item, left, _player.global_position + Vector3(0, 0.5, 0)))
	_mobs = MobManager.new()
	_mobs.name = "Mobs"
	_mobs.world = _world
	_mobs.player_positions = func():
		if _player == null or _loading:
			return []
		return [_player.global_position] + _session.peer_positions()
	_mobs.day_amount = func(): return _day.day_amount()
	_mobs.player_targets = func():
		var out := []
		if _player and not _loading and not _player.creative and not _player.dead:
			out.append({"position": _player.global_position, "peer": 0})
		return out + _session.peer_targets()
	_mobs.struck.connect(func(peer, damage, push):
		if peer == 0:
			_take_hit(damage, push)
		else:
			_session.strike_player(peer, damage, push))
	_mobs.vanished.connect(_smoke_puff)
	_session.struck.connect(_take_hit)
	_mobs.hurt_at.connect(func(at, variant):
		if variant == "":
			_sounds.play("core:effects", "hurt", at, -4.0)
		else:
			_sounds.play_block(variant, "break", at))
	_mobs.ate.connect(func(at, block): _sounds.play_block(block, "break", at))
	_mobs.killed.connect(func(at, _attacker, items):
		for it in items:
			spawn_drop(it[0], it[1], at))
	if _args.has("no-mobs"):
		_mobs.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_mobs)
	_session.mobs = _mobs
	# Offline, pausing stops time too; in multiplayer the world keeps going.
	_day.process_mode = Node.PROCESS_MODE_PAUSABLE if net_mode == "offline" else Node.PROCESS_MODE_ALWAYS
	_session.day_cycle = _day

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
	var problem := _world.build(world_name, int(_args.get("view", Settings.view_distance)),
			new_seed, not _args.has("bench"), game_mode)
	if problem != "":
		_leave_to_menu.call_deferred("Can't open world '%s': %s" % [world_name, problem])
		return
	print("World '%s' (seed %d) at %s" % [world_name, int(_world.meta.seed),
			ProjectSettings.globalize_path(_world.dir) if _world.is_persistent() else "<not saved>"])
	if net_mode == "host":
		print("Hosting on port %d (%s)" % [port, ", ".join(_lan_addresses())])
	# Time runs at real speed (a day is 24 hours) and resumes from the save; a
	# new world starts at the computer's local time. --time overrides it.
	_start_day(float(_args.get("time", _world.meta.get("time", DayCycle.system_time()))),
			float(_args.get("day-length", DayCycle.DEFAULT_DAY_LENGTH)))
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
	_drops_node.remote = true  # the host owns dropped items
	_drops_node.request_spawn = _session.request_drop
	_drops_node.request_pickup = _session.request_pickup
	_session.woken.connect(func():
		if _player:
			_player.wake())
	_session.corrected.connect(func(eye: Vector3):
		if _player:  # the host refused a move: back to where it last accepted us
			_player.global_position += eye - _cam.global_position
			_player.velocity = Vector3.ZERO)
	var err := _session.join(join_address, port)
	if err != OK:
		_leave_to_menu.call_deferred("Couldn't connect: %s" % error_string(err))


func _on_welcomed(info: Dictionary) -> void:
	# Clients generate terrain themselves, so they can use their own view distance.
	_world.build_remote(PackedStringArray(info.block_ids), int(_args.get("view", Settings.view_distance)),
			int(info.seed), info.chunks, str(info.get("mode", "survival")), int(info.get("generator", 1)))
	_start_day(float(info.get("time", DayCycle.START_TIME)), float(info.get("day_length", DayCycle.DEFAULT_DAY_LENGTH)))
	if (info.get("world_spawn", []) as Array).size() == 3:
		_world.meta.spawn = info.world_spawn  # respawn where the host's players do
	var s: Array = info.spawn  # an eye position next to the host
	_spawn_player(Vector3(s[0], s[1] - Player.EYE_HEIGHT, s[2]))
	_player.edit_handler = _session.request_edit
	_player.place_handler = _session.request_place
	_set_loading_text("Loading world…")
	_loading_since = Time.get_ticks_msec()
	print("Joined %s:%d" % [join_address, port])


## Settings that affect the running world.
func _apply_settings() -> void:
	if _world and _world.engine:
		_world.engine.smooth_lighting = Settings.smooth_lighting
		if not _args.has("view"):
			_world.set_view_distance(Settings.view_distance)


func _start_day(time: float, day_length: float) -> void:
	_apply_settings()
	if not Settings.changed.is_connected(_apply_settings):
		Settings.changed.connect(_apply_settings)
	_day.materials = [_world.terrain_material, _world.fluid_material]
	_day.time = fposmod(time, 1.0)
	_day.day_length = maxf(10.0, day_length)
	_day.apply()


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
	player.creative = _world.meta.get("mode", "survival") == "creative"
	add_child(player)
	_world.set_viewer(player.global_position)
	_player = player
	if player.creative:
		player.fill_creative()
	player.footstep.connect(func(block, at): _sounds.play_block(block, "step", at, -6.0))
	player.block_broken.connect(func(block, at): _sounds.play_block(block, "break", at))
	player.block_placed.connect(func(block, at): _sounds.play_block(block, "place", at))
	player.splashed.connect(func(at): _sounds.play("core:effects", "splash", at))
	player.hurt.connect(_on_hurt)
	player.died.connect(_on_died)
	player.dropped.connect(func(item, at): spawn_drop(item, 1, at))
	player.open_block.connect(_open_container)
	player.use_bed.connect(_on_use_bed)
	player.woke.connect(func():
		_slept = 0.0
		if _world.remote:
			_session.set_sleeping(false))
	player.mob_picker = _mobs.pick
	var hand := Hand.new()
	hand.player = player
	hand.atlas = _world.atlas
	player.camera.add_child(hand)
	player.attack.connect(func(_id): hand.swing())
	player.block_placed.connect(func(_b, _at): hand.swing())
	player.block_broken.connect(func(_b, _at): hand.swing())
	player.ate.connect(func(_i): hand.swing())
	player.swung.connect(hand.swing)
	_update_ninjas()
	player.attack.connect(func(id):
		if _world.remote:
			_session.hit_mob(id, player.selected_item())
		else:
			_mobs.hit(id, player.global_position, 0, Player.attack_damage(player.selected_item())))
	if _world.block_entities:
		_world.block_entities.spilled.connect(_on_spilled)
	if _world.plants:
		_world.plants.popped.connect(_on_spilled)
	player.ate.connect(func(_item): _sounds.play("core:effects", "pickup", player.global_position, -4.0))
	_hotbar = Hotbar.new()
	_hotbar.player = player
	_hotbar.atlas = _world.atlas
	_hud.add_child(_hotbar)
	_hud.move_child(_hotbar, 1)
	_cam = player.camera
	_drops_node.set_player(player)
	_session.local_player = player.camera


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _world and _world.is_persistent():
		_save_and_quit()


func _exit_tree() -> void:
	get_tree().auto_accept_quit = true
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_debug_label.visible = not _debug_label.visible
		_fps_label.visible = not _debug_label.visible
		get_viewport().set_input_as_handled()
		return
	if _player and not _loading and not get_tree().paused and _inventory_screen == null \
			and _death_screen == null and _container_screen == null and event.is_action_pressed(&"inventory"):
		_open_inventory()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_cancel") and not _loading and not _args.has("bench") \
			and _settings_screen == null and _death_screen == null and _container_screen == null:
		set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()


func _open_inventory() -> void:
	_inventory_screen = InventoryScreen.new()
	_inventory_screen.player = _player
	_inventory_screen.atlas = _world.atlas
	_inventory_screen.closed.connect(_close_inventory)
	_hud.add_child(_inventory_screen)
	_player.ui_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_remote_edit(pos: Vector3i, old_block: int, new_block: int) -> void:
	var at := Vector3(pos) + Vector3.ONE * 0.5
	if new_block == Registry.block_index("core:air"):
		_sounds.play_block(Registry.block_ids[old_block], "break", at)
	else:
		_sounds.play_block(Registry.block_ids[new_block], "place", at)


## Items on the ground that anyone can pick up (shared in multiplayer, see
## ItemDrops). Merges with the same item lying close by.
func spawn_drop(item: String, count: int, at: Vector3) -> void:
	_drops_node.spawn(item, count, at)


## Host / single player: a chest or furnace was broken, or a block popped off.
func _on_spilled(pos: Vector3i, items: Array) -> void:
	var at := Vector3(pos) + Vector3.ONE * 0.5
	for it in items:
		spawn_drop(it[0], it[1], at)


func _open_container(pos: Vector3i) -> void:
	if _container_screen or _inventory_screen:
		return
	var backend
	if _world.remote:
		backend = ContainerScreen.Remote.new(_session, pos)
	elif _world.block_entities.has_entity(pos):
		backend = ContainerScreen.Local.new(_world.block_entities, pos)
	else:
		return
	_container_screen = ContainerScreen.new()
	_container_screen.player = _player
	_container_screen.atlas = _world.atlas
	_container_screen.backend = backend
	_container_screen.closed.connect(func():
		_container_screen.queue_free()
		_container_screen = null
		_player.ui_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED)
	_hud.add_child(_container_screen)
	_player.ui_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## A creature hit the local player: damage (armour counts) and a shove.
func _take_hit(damage: int, push: Vector3) -> void:
	if _player == null or _player.dead:
		return
	_player.damage(damage, "mob")
	_player.velocity += push


## A little cloud of smoke (a ninja vanishing in the sun).
func _smoke_puff(at: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 24
	p.lifetime = 0.9
	p.explosiveness = 0.95
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 2.5
	p.gravity = Vector3(0, 0.8, 0)
	p.scale_amount_min = 0.2
	p.scale_amount_max = 0.45
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.82, 0.82, 0.86)
	mesh.material = mat
	p.mesh = mesh
	add_child(p)
	p.global_position = at
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)
	_sounds.play("core:effects", "splash", at, -12.0)


## The F3 screen: where you are, what you look at, and how the world is doing.
## Light-giving blocks in hand (torches) light the world around players:
## ours and those of other players in multiplayer (nearest first).
const MAX_HAND_LIGHTS := 8


func _update_hand_light() -> void:
	if _world == null:
		return
	var level := 0.0
	if _player and not _player.dead and not _player.autopilot:
		level = float(Registry.blocks.get(_player.selected_item(), {}).get("light", 0))
	var lights: Array = []
	if level > 0.0:
		var c := _cam.global_position
		lights.append(Vector4(c.x, c.y, c.z, level))
	if _session:
		_session.held_light = int(level)
		var others: Array = _session.held_lights()
		if others.size() > MAX_HAND_LIGHTS - lights.size():
			var c := _cam.global_position
			others.sort_custom(func(a, b): return Vector3(a.x, a.y, a.z).distance_squared_to(c) \
					< Vector3(b.x, b.y, b.z).distance_squared_to(c))
		lights.append_array(others.slice(0, MAX_HAND_LIGHTS - lights.size()))
	var packed := PackedVector4Array(lights)
	packed.resize(MAX_HAND_LIGHTS)
	for m in [_world.terrain_material, _world.fluid_material]:
		if m:
			m.set_shader_parameter("hand_light_count", lights.size())
			if not lights.is_empty():
				m.set_shader_parameter("hand_lights", packed)
	if _player:
		_player.set_meta("hand_light", level)


func _debug_text() -> String:
	if _player == null or _world.engine == null:
		return ""
	var p: Vector3 = _player.global_position
	var b := Vector3i(p.floor())
	var c: Vector3i = _world.chunk_of(p)
	var yaw := fposmod(rad_to_deg(_player.rotation.y), 360.0)
	var facing: String = ["north (-Z)", "west (-X)", "south (+Z)", "east (+X)"][int(round(yaw / 90.0)) % 4]
	var lines := [
		"GoCube · %d FPS · %s" % [Engine.get_frames_per_second(), _day.clock_text(Settings.clock_24h)],
		"",
		"XYZ: %.2f / %.2f / %.2f" % [p.x, p.y, p.z],
		"Block: %d %d %d" % [b.x, b.y, b.z],
		"Chunk: %d %d %d  (in chunk: %d %d %d)" % [c.x, c.y, c.z, posmod(b.x, 32), posmod(b.y, 32), posmod(b.z, 32)],
		"Facing: %s  (%.0f°)" % [facing, yaw],
	]
	var biome := _world.biome_name(b.x, b.z)
	lines.append("Biome: %s" % (biome.get_slice(":", 1).capitalize() if biome != "" else "(original world)"))
	var hit: Dictionary = _player._target()
	if hit.hit:
		lines.append("Looking at: %s at %d %d %d" % [Registry.block_ids[hit.block], hit.position.x, hit.position.y, hit.position.z])
	lines.append("")
	var st: Dictionary = _world.engine.get_stats()
	lines.append("Chunks: %d loaded, %d meshed, %d queued" % [st.get("chunks", 0), st.get("meshed", 0), st.get("queued_jobs", 0)])
	lines.append("Generate %.1f ms · light %.1f ms · mesh %.1f ms (per chunk)" % [st.get("generate_ms_avg", 0.0),
			st.get("light_ms_avg", 0.0), st.get("mesh_ms_avg", 0.0)])
	lines.append("Creatures: %d · drops: %d · view %d blocks" % [_mobs.count(), _drops_node.count(), _world.view_distance])
	lines.append("Memory: %.0f MB · %s" % [OS.get_static_memory_usage() / 1048576.0,
			"multiplayer (%d players)" % _session.player_count() if net_mode != "offline" else "single player"])
	return "\n".join(lines)


func _on_hurt(_amount: int) -> void:
	_sounds.play("core:effects", "hurt", _cam.global_position)
	_hurt_flash.color.a = 0.35
	create_tween().tween_property(_hurt_flash, "color:a", 0.0, 0.4)


func _on_died() -> void:
	_death_screen = ColorRect.new()
	_death_screen.color = Color(0.35, 0.0, 0.0, 0.55)
	_death_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_screen.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title := Label.new()
	title.text = "You died"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var button := Button.new()
	button.text = "Respawn"
	button.pressed.connect(_respawn)
	box.add_child(button)
	_hud.add_child(_death_screen)
	_player.ui_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _respawn() -> void:
	var s: Array = _world.meta.get("spawn", [0.5, 40.0, 0.5])
	var at := Vector3(s[0], s[1], s[2])
	if _player.bed != null:
		if Registry.blocks.get(Registry.block_ids[_world.get_block(_player.bed)], {}).get("bed", false):
			at = Vector3(_player.bed) + Vector3(0.5, 0.5625, 0.5)
		else:
			_player.bed = null
			show_notice("Your bed was missing, so you're back at the world spawn")
	# Far from where we died the ground may not be loaded yet: wait for it
	# behind the loading screen (as when opening a world).
	var wait := not _world.is_area_meshed(AABB(at - Vector3(8, 8, 8), Vector3(16, 16, 16)))
	_player.respawn(at, wait)
	if wait and _loading == null:
		_loading = _make_loading_screen()
		_loading_since = Time.get_ticks_msec()
		_hud.add_child(_loading)
		_set_loading_text("Respawning…")
	_death_screen.queue_free()
	_death_screen = null
	_player.ui_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _open_settings() -> void:
	_settings_screen = SettingsScreen.new()
	_settings_screen.process_mode = Node.PROCESS_MODE_ALWAYS  # works while paused
	_settings_screen.closed.connect(func():
		_settings_screen.queue_free()
		_settings_screen = null)
	_hud.add_child(_settings_screen)


func _close_inventory() -> void:
	_inventory_screen.queue_free()
	_inventory_screen = null
	_player.ui_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## In multiplayer the world keeps running for everyone; this only freezes our camera.
func set_paused(paused: bool) -> void:
	get_tree().paused = paused
	_pause_menu.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED


func _save_and_quit() -> void:
	_show_saving()
	await save_game()
	await _quit()


## Quits cleanly: stop sounds and give the audio thread time to let go of them
## (it drops stopped sounds on its next mix; a couple of frames isn't always
## enough with a real audio device, which leaves them "still in use" at exit).
func _quit() -> void:
	_sounds.stop_all()
	await get_tree().create_timer(0.25, true, false, true).timeout
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
	_world.meta.time = _day.time
	await _world.save(_player_state())
	_saving = false
	print("World saved in %d ms" % (Time.get_ticks_msec() - t))


## Saved in world.json. "position" is the feet; "rotation" is [pitch, yaw].
func _player_state() -> Dictionary:
	if _player == null:
		return {}
	var p := _player.global_position
	var state := {"position": [p.x, p.y, p.z], "rotation": [_player.look_pitch(), _player.look_yaw()],
			"flying": _player.flying, "selected": _player.selected}
	if not _player.creative:
		state.inventory = _player.inventory.serialize()
		state.health = _player.health
	if _player.bed != null:
		state.bed = [_player.bed.x, _player.bed.y, _player.bed.z]
	return state


## Puts the player on dry ground: the nearest column (searching outward up to
## SPAWN_SEARCH blocks) whose top block is a biome's surface (grass, sand,
## snow), not under water: so not on the bare stone of a pit or cave mouth.
## If there's none, the nearest dry column will do.
const SPAWN_SEARCH := 64


func _place_on_ground(player: Node3D) -> void:
	var surfaces := {}
	for b in Registry.biomes.values():
		surfaces[Registry.block_index(str(b.get("surface", "")))] = true
	var origin := Vector3i(player.global_position.floor())
	var fallback = null
	for radius in range(0, SPAWN_SEARCH + 1, 2):
		for dz in range(-radius, radius + 1, 2):
			for dx in range(-radius, radius + 1, 2):
				if maxi(absi(dx), absi(dz)) != radius:
					continue  # only the ring at this radius
				var x := origin.x + dx
				var z := origin.z + dz
				var hit := _world.raycast(Vector3(x + 0.5, World.TOP_Y, z + 0.5), Vector3.DOWN, 400)
				if not hit.hit or _world.is_fluid(_world.get_block(hit.previous)):
					continue
				var feet := Vector3(x + 0.5, hit.position.y + 1, z + 0.5)
				if surfaces.has(hit.block):
					player.global_position = feet
					return
				if fallback == null:
					fallback = feet
	if fallback != null:
		player.global_position = fallback


func _restore_player(state: Dictionary) -> void:
	_restored_player = state.has("position")
	if state.has("position"):
		var p: Array = state.position
		_player.position = Vector3(p[0], p[1], p[2])
	if state.has("rotation"):
		_player.set_look(state.rotation[0], state.rotation[1])
	_player.flying = bool(state.get("flying", false))
	_player.selected = clampi(int(state.get("selected", 0)), 0, Inventory.HOTBAR - 1)
	if not _player.creative and state.has("inventory"):
		_player.inventory.deserialize(state.inventory)
	if state.has("health"):
		_player.health = clampi(int(state.health), 1, _player.MAX_HEALTH)
	if state.get("bed") is Array and state.bed.size() == 3:
		_player.bed = Vector3i(int(state.bed[0]), int(state.bed[1]), int(state.bed[2]))


## A short message at the top of the screen.
func show_notice(text: String) -> void:
	_notice_label.text = text
	_notice_time = 3.5


## Right click on a bed: it becomes the respawn point; at night, sleep in it.
func _on_use_bed(pos: Vector3i) -> void:
	if _player.bed != pos:
		_player.bed = pos
		if _world.remote:
			_session.set_bed(pos)
		show_notice("Respawn point set")
	if _day.day_amount() > 0.3:
		show_notice("You can only sleep at night (respawn point set)")
		return
	if not _player.creative and _mobs.mobs().any(func(m):
			return m.KIND == "ninja" and m.global_position.distance_to(_player.global_position) < NINJA_NEAR):
		show_notice("You can't sleep now: a ninja is nearby")
		return
	_player.lie_down(pos)
	_slept = 0.0
	if _world.remote:
		_session.set_sleeping(true)
	if _session.is_host() and not _session.peers_sleeping():
		show_notice("Sleeping… the night passes when everyone is in bed")


## Single player / host: everyone in bed for a moment skips to the morning.
func _update_sleep(delta: float) -> void:
	if _notice_time > 0.0:
		_notice_time -= delta
		_notice_label.modulate.a = clampf(_notice_time, 0.0, 1.0)
	var sleeping: bool = _player != null and _player.sleeping
	_slept = _slept + delta if sleeping else 0.0
	_sleep_shade.color.a = clampf(_slept / SLEEP_SECONDS, 0.0, 1.0) * 0.85
	if not sleeping or _world.remote or _slept < SLEEP_SECONDS or not _session.peers_sleeping():
		return
	_day.time = MORNING
	_session.night_skipped()
	_player.wake()
	if _world.meta.get("first_night", "over") != "over":
		_world.meta.first_night = "over"  # slept through it
		_update_ninjas()


## Whether ninjas may come out: survival, after the world's first night.
func _update_ninjas() -> void:
	_mobs.ninjas_enabled = _player != null and not _player.creative \
			and _world.meta.get("first_night", "over") == "over"


## Single player / host: notes when the first night starts and ends.
func _update_first_night() -> void:
	var stage: String = _world.meta.get("first_night", "over")
	if stage == "over" or _world.remote:
		return
	var day := _day.day_amount()
	if stage == "ahead" and day < MobManager.NINJA_NIGHT:
		_world.meta.first_night = "now"
	elif stage == "now" and day > 0.3:
		_world.meta.first_night = "over"  # morning: from now on nights have ninjas
		_update_ninjas()


func _process(_delta: float) -> void:
	_update_sleep(_delta)
	if _world.engine and _player:
		_update_first_night()
	if _loading and _cam and _spawn_area_meshed():
		_loading.queue_free()
		_loading = null
		if not _restored_player and not _world.remote:
			_place_on_ground(_player)  # new world: start on the ground, not mid-air
			_restored_player = true  # (not again after respawning)
		_player.set_ready_to_move()
		if not _world.meta.has("spawn") and not _world.remote:
			var s := _player.global_position
			_world.meta.spawn = [s.x, s.y, s.z]  # where new players appear and the dead respawn
		_mark("spawn area meshed, loading screen hidden")
	if _cam and _world.engine:
		_world.set_viewer(_cam.global_position)  # chunks load around the local player
	if _player and _world.engine and not _player.autopilot:
		var eye := Vector3i(_cam.global_position.floor())
		var eye_block := _world.get_block(eye)
		_underwater.visible = _world.is_fluid(eye_block)
		if _underwater.visible:  # blue in water, orange in lava
			var lava: bool = Registry.blocks.get(Registry.block_ids[eye_block], {}).get("fluid") == "lava"
			_underwater.color = Color(0.9, 0.35, 0.05, 0.75) if lava else Color(0.1, 0.3, 0.55, 0.45)
		_sounds.set_underwater(_underwater.visible)
	if _sounds:
		_sounds.update_ambience(_day.day_amount())
	if _day:
		ItemDrop.set_daylight(_day.day_amount())
		if _player:
			_player.set_meta("daylight", _day.daylight())
	_update_hand_light()
	if _player and _session:  # how others see us
		_session.local_pose = {"pitch": _player.look_pitch(), "item": _player.selected_item(),
				"flags": _player.pose_flags(), "swings": _player.swings}
	if _player:  # from in front of us, the crosshair would point nowhere useful
		_crosshair.visible = _player.view != Player.View.FRONT
	var status := "%d FPS · %s" % [Engine.get_frames_per_second(), _day.clock_text(Settings.clock_24h)]
	if _player and not _player.autopilot:
		status += " · %s · %s · E inventory" % ["creative" if _player.creative else "survival",
				"flying (F)" if _player.flying else "walking (F to fly)"]
	if _session.is_host():
		status += " · hosting on %s port %d · %d player(s)" % [
				" / ".join(_lan_addresses()), port, _session.player_count()]
	elif _session.is_client():
		status += " · connected to %s · %d player(s)" % [join_address, _session.player_count()]
	_fps_label.text = status
	if _debug_label.visible:
		_debug_timer -= _delta
		if _debug_timer <= 0.0:
			_debug_timer = 0.2
			_debug_label.text = _debug_text()


static func _lan_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out if not out.is_empty() else PackedStringArray(["127.0.0.1"])


# --- Scene setup -------------------------------------------------------------------

func _add_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = _args.has("shadows") or _args.has("cheap-shadows")
	if _args.has("cheap-shadows"):
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 48.0
	add_child(sun)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	var sky := ShaderMaterial.new()
	sky.shader = preload("res://src/world/sky.gdshader")
	env.environment.sky.sky_material = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Default 256 px radiance map costs ~120 ms on the first frame on weak GPUs;
	# blocks are fully rough, so a tiny one looks identical.
	env.environment.sky.radiance_size = Sky.RADIANCE_SIZE_32
	add_child(env)

	_day = DayCycle.new()
	_day.name = "DayCycle"
	_day.sky_material = env.environment.sky.sky_material
	_day.environment = env.environment
	_day.sun = sun
	add_child(_day)


func _add_hud() -> void:
	var hud := CanvasLayer.new()
	_hud = hud
	_debug_label = Label.new()
	_debug_label.position = Vector2(8, 8)
	_debug_label.visible = false
	_debug_label.add_theme_constant_override("outline_size", 4)
	_debug_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_debug_label.add_theme_font_size_override("font_size", 14)
	hud.add_child(_debug_label)
	_fps_label = Label.new()
	_fps_label.position = Vector2(8, 8)
	hud.add_child(_fps_label)
	var crosshair := Control.new()
	_crosshair = crosshair
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
	_sleep_shade = ColorRect.new()
	_sleep_shade.color = Color(0.0, 0.0, 0.03, 0.0)
	_sleep_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sleep_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_sleep_shade)
	_notice_label = Label.new()
	_notice_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_notice_label.position.y = 60
	_notice_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.add_theme_constant_override("outline_size", 5)
	_notice_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_notice_label.add_theme_font_size_override("font_size", 18)
	hud.add_child(_notice_label)
	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(0.8, 0.0, 0.0, 0.0)
	_hurt_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_hurt_flash)
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
		entries += [["Disconnect", _leave_to_menu.bind("")], ["Quit game", _quit]]
	else:
		entries += [["Save & quit to menu", _leave_to_menu.bind("")], ["Save & quit game", _save_and_quit]]
	entries.insert(1, ["Settings…", _open_settings])
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
