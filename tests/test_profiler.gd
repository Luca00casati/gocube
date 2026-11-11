extends "res://tests/test_suite.gd"
## The F4 profiler: off, nothing is timed; on, each frame's time is split by
## system (the engine's step, scripts, rendering) and summed up for the screen.


func test_f4_shows_where_frames_go() -> void:
	var game: Node = load("res://src/main.tscn").instantiate()
	game.world_name = "_test_profiler"
	game.new_seed = 4242
	game._args = {"view": "64"}
	add(game)
	check(await wait_until(func(): return game._loading == null and game._player != null, 30), "the world loaded")
	var overlay: Control = game._profiler
	check(not overlay.visible and not FrameProfiler.on, "off at first")
	await frames(5)
	check(FrameProfiler.take().is_empty(), "off: nothing is timed")

	var f4 := InputEventKey.new()
	f4.keycode = KEY_F4
	f4.pressed = true
	game._unhandled_input(f4)
	check(overlay.visible and FrameProfiler.on, "F4 shows it")
	check(await wait_until(func(): return overlay._history.size() >= 30 and not overlay._averages.is_empty(), 10),
			"it records frames")
	var last: Dictionary = overlay._history[-1]
	for k in ["frame", "world", "uploads", "game", "player", "mobs", "network", "rest", "render_cpu", "render_gpu"]:
		check(last.has(k), "a frame has %s" % k)
	check(overlay._averages.frame > 0.0, "frames take time")
	check(overlay._history.any(func(r): return r.player > 0.0), "the player's time is counted")
	check(overlay._history.any(func(r): return r.world > 0.0), "and the engine's (%s)" % [overlay._history[-1].world])
	check(overlay._history.any(func(r): return r.game > 0.0), "and the game's")
	check(overlay._biggest(last) != "", "it names the biggest system in a frame")
	check(overlay._footer.size() == 2 and "workers" in overlay._workers, "and the counters")

	game._unhandled_input(f4)
	check(not overlay.visible and not FrameProfiler.on, "F4 again hides it and stops timing")
