extends "res://tests/test_suite.gd"


func test_actions_registered_with_defaults() -> void:
	for action in Settings.ACTIONS:
		check(InputMap.has_action(action), "%s is an input action" % action)
	check_eq(Settings.key_name("move_forward"), OS.get_keycode_string(Settings.keys.move_forward), "key name")


func test_rebinding_changes_the_action() -> void:
	var old: Key = Settings.keys.jump
	Settings.set_key("jump", KEY_J)
	var e := InputEventKey.new()
	e.keycode = KEY_J
	e.pressed = true
	check(e.is_action("jump"), "J now jumps")
	e.keycode = old
	check(not e.is_action("jump"), "the old key no longer does")
	Settings.reset_keys()
	check_eq(Settings.keys.jump, Settings.ACTIONS.jump[1], "reset restores the default")


func test_settings_survive_save_and_load() -> void:
	var before := [Settings.view_distance, Settings.smooth_lighting]
	Settings.view_distance = 192
	Settings.smooth_lighting = true
	Settings.save()
	var cfg := ConfigFile.new()
	check_eq(cfg.load(Settings.PATH), OK, "settings file written")
	check_eq(int(cfg.get_value("settings", "view_distance")), 192, "view distance saved")
	check(bool(cfg.get_value("settings", "smooth_lighting")), "smooth lighting saved")
	Settings.view_distance = before[0]
	Settings.smooth_lighting = before[1]
	Settings.save()


func test_smooth_lighting_meshes() -> void:
	var w := await make_world()
	w.engine.smooth_lighting = true
	check(w.engine.smooth_lighting, "engine option set")
	check(await wait_until(func(): return w.engine.get_stats().queued_jobs == 0 and w.engine.get_stats().pending_uploads == 0, 20),
			"all chunks remeshed with smooth lighting")
	w.engine.smooth_lighting = false


func test_clock_formats() -> void:
	check_eq(DayCycle.format_clock(0.0, false), "12:00 AM", "midnight, 12-hour")
	check_eq(DayCycle.format_clock(0.5, false), "12:00 PM", "noon, 12-hour")
	check_eq(DayCycle.format_clock(7.0 / 24.0 + 19.0 / 1440.0 + 0.0001, false), "7:19 AM", "morning, 12-hour")
	check_eq(DayCycle.format_clock(18.5 / 24.0, false), "6:30 PM", "evening, 12-hour")
	check_eq(DayCycle.format_clock(18.5 / 24.0, true), "18:30", "evening, 24-hour")
	check_eq(DayCycle.format_clock(0.0, true), "00:00", "midnight, 24-hour")


func test_time_runs_in_real_time() -> void:
	var day := DayCycle.new()
	check_eq(day.day_length, 86400.0, "a day lasts 24 hours")
	day.time = 0.5  # noon
	day._process(60.0)  # one real minute
	check_eq(day.clock_text(true), "12:01", "one real minute later the clock shows 12:01")
	day.free()


func test_clock_follows_the_computer() -> void:
	var day := DayCycle.new()
	day.follow_system_clock = true
	day._process(0.016)
	var t := Time.get_time_dict_from_system()
	check_eq(day.clock_text(true), "%02d:%02d" % [t.hour, t.minute], "game clock = computer clock")
	day.free()


func test_volume_buses() -> void:
	var before := Settings.effects_volume
	Settings.effects_volume = 0.5
	Settings.apply()
	var bus := AudioServer.get_bus_index("Effects")
	check(bus >= 0, "Effects bus exists")
	check_near(AudioServer.get_bus_volume_db(bus), linear_to_db(0.5), 0.01, "effects volume applied")
	check(AudioServer.get_bus_index("Ambience") >= 0, "Ambience bus exists")
	Settings.effects_volume = 0.0
	Settings.apply()
	check(AudioServer.is_bus_mute(bus), "0% mutes")
	Settings.effects_volume = before
	Settings.apply()


## At night the haze closes in and goes dark, so you can't see far; by day it
## sits out near the edge of the view.
func test_night_is_dark_and_close() -> void:
	var day := DayCycle.new()
	day.environment = Environment.new()
	day.fog_begin = 60.0
	day.fog_end = 120.0
	add(day)
	day.time = 0.5  # noon
	day.apply()
	check_near(day.environment.fog_depth_end, 120.0, 0.5, "noon: haze far out")
	check(day.haze_color().get_luminance() > 0.5, "noon: a light haze")
	day.time = 0.0  # midnight
	day.apply()
	check(day.environment.fog_depth_end <= DayCycle.NIGHT_FOG_END + 0.5, "midnight: the dark closes in (%.0f)" % day.environment.fog_depth_end)
	check(day.haze_color().get_luminance() < 0.03, "midnight: a nearly black haze")
	check(day.daylight() <= 0.03, "midnight: the sky gives almost no light (%.2f)" % day.daylight())


func test_render_scale_applies_and_saves() -> void:
	var before := Settings.render_scale
	Settings.render_scale = 0.5
	Settings.apply()
	check_eq(Settings.get_tree().root.scaling_3d_scale, 0.5, "the world is drawn at half size")
	Settings.save()
	var cfg := ConfigFile.new()
	cfg.load(Settings.PATH)
	check_eq(float(cfg.get_value("settings", "render_scale")), 0.5, "render scale saved")
	Settings.render_scale = before
	Settings.apply()
	Settings.save()
	check_eq(Settings.get_tree().root.scaling_3d_scale, before, "and back")


func test_shadow_mode_saves() -> void:
	var before: String = Settings.shadow_mode
	for mode in Settings.SHADOW_MODES:
		Settings.shadow_mode = mode
		Settings.save()
		var cfg := ConfigFile.new()
		cfg.load(Settings.PATH)
		check_eq(str(cfg.get_value("settings", "shadow_mode")), mode, "shadow mode %s saved" % mode)
		check(not cfg.has_section_key("settings", "shadows"), "the old on/off key is gone")
	Settings.shadow_mode = before
	Settings.save()
