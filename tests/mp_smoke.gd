extends Node
## Multiplayer smoke test: a host and a client process (see mp_smoke.sh).
## The client exits 0 if edits made before and after joining reach it and its
## own edit request is applied by the host.

const PORT := 24711
const LAMP_BEFORE := Vector3i(5, 20, 5)
const ORE_AFTER := Vector3i(6, 20, 5)


func _wait_for(cond: Callable, s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > s * 1000:
			return false
	return true


func _start(opts: Dictionary) -> Node:
	ModLoader.load_all()
	var game: Node = load("res://src/main.tscn").instantiate()
	game.name = "Main"
	for k in opts:
		game.set(k, opts[k])
	get_tree().root.add_child.call_deferred(game)
	await get_tree().create_timer(0.2).timeout
	return game


func _ready() -> void:
	var role: String = OS.get_cmdline_user_args()[-1]
	if role == "host":
		var game := await _start({"world_name": "_mp_smoke", "net_mode": "host", "port": PORT, "player_name": "Host"})
		await _wait_for(func(): return game._loading == null, 30)
		game._world.set_block(LAMP_BEFORE, Registry.block_index("core:lamp"))
		print("HOST ready")
		await _wait_for(func(): return not game._session._peers.is_empty(), 60)
		await get_tree().create_timer(1.5).timeout
		game._world.set_block(ORE_AFTER, Registry.block_index("core:gold_ore"))
		await _wait_for(func(): return game._session._peers.is_empty(), 60)
		get_tree().quit()
		return
	var game := await _start({"net_mode": "client", "join_address": "127.0.0.1", "port": PORT, "player_name": "Client"})
	var ok := await _wait_for(func(): return game._player != null and game._loading == null, 30)
	var w: World = game._world if ok else null
	var results := {
		"joined": ok,
		"edit before join": ok and w.get_block(LAMP_BEFORE) == Registry.block_index("core:lamp"),
		"edit after join": ok and await _wait_for(func(): return w.get_block(ORE_AFTER) == Registry.block_index("core:gold_ore"), 10),
	}
	if ok:
		var target := Vector3i(game._player.global_position.floor()) + Vector3i(2, 1, 0)
		game._player._frozen = true
		game._session.request_edit(target, Registry.block_index("core:planks"))
		results["client edit via host"] = await _wait_for(func(): return w.get_block(target) == Registry.block_index("core:planks"), 5)
	var failed := results.keys().filter(func(k): return not results[k])
	for k in results:
		print("%s  %s" % ["PASS" if results[k] else "FAIL", k])
	get_tree().quit(1 if not failed.is_empty() else 0)
