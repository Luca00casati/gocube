extends Node
## Multiplayer smoke test: a host and a client process (see mp_smoke.sh).
## The client exits 0 if edits made before and after joining reach it and its
## own edit request is applied by the host.

const PORT := 24711
const LAMP_BEFORE := Vector3i(5, 20, 5)
const ORE_AFTER := Vector3i(6, 20, 5)
const CHEST := Vector3i(5, 22, 5)


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


## Moves the (frozen) player in steps at walking speed.
func _walk(player: Node3D, to: Vector3) -> void:
	while player.global_position.distance_to(to) > 0.01:
		player.global_position = player.global_position.move_toward(to, 4.0 * get_physics_process_delta_time())
		await get_tree().physics_frame


func _ready() -> void:
	var role: String = OS.get_cmdline_user_args()[-1]
	if role == "host":
		var game := await _start({"world_name": "_mp_smoke", "net_mode": "host", "port": PORT, "player_name": "Host"})
		await _wait_for(func(): return game._loading == null, 30)
		game._world.set_block(LAMP_BEFORE, Registry.block_index("core:lamp"))
		game._world.set_block(CHEST, Registry.block_index("core:chest"))
		game._world.block_entities.click(CHEST, 0, {"id": "core:coal", "count": 4})
		var g: Dictionary = game._world.raycast(Vector3(8.5, World.TOP_Y, 8.5), Vector3.DOWN, 400)
		game._mobs.spawn_at(Vector3(8.5, g.position.y + 1, 8.5))
		game._player.inventory.slots[game._player.selected] = {"id": "core:torch", "count": 1}
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
		results["sees the host's torch light"] = await _wait_for(
				func(): return game._session.held_lights().any(func(l): return l.w == 13.0), 5)
		results["sees the host's creatures"] = await _wait_for(func(): return game._mobs.count() >= 1, 5)
		# Breaking: the drop appears only once the host has confirmed it.
		var drops: Node = game._drops_node
		game._player.pending_drops[target] = ["core:planks"]
		game._player._apply_edit(target, 0)
		var early := drops.get_child_count()
		results["drop after host confirms"] = early == 0 and await _wait_for(
				func(): return drops.count() == 1 and w.get_block(target) == 0, 5)
		# Drops are the host's: we see its drop and picking it up goes through it.
		var had: int = game._player.inventory.count_of("core:planks")
		results["picked up shared drop"] = await _wait_for(func(): return drops.count() == 0 \
				and game._player.inventory.count_of("core:planks") == had + 1, 5)
		game._session.request_drop("core:coal", 2, game._player.global_position + Vector3(6, 1, 0))
		results["host shares a dropped item"] = await _wait_for(func():
				return drops._by_id.values().any(func(d): return d.item == "core:coal" and d.count == 2), 5)
		# A chest through the host (stand next to it first: the host checks reach).
		# The host checks movement: a teleport is put back, walking is fine.
		var before: Vector3 = game._player.global_position
		var put_back := [false]
		game._session.corrected.connect(func(_eye): put_back[0] = true)
		game._player.global_position = before + Vector3(200, 0, 0)
		results["teleport put back by host"] = await _wait_for(func(): return put_back[0] \
				and game._player.global_position.distance_to(before) < 2.0, 5)
		await _walk(game._player, Vector3(CHEST) + Vector3(0.5, 0, 2.5))
		await get_tree().create_timer(0.3).timeout
		var seen := {}
		var held := [null]
		game._session.container_updated.connect(func(_p, data): seen.merge(data, true))
		game._session.container_held.connect(func(_p, h): held[0] = h)
		game._session.open_container(CHEST)
		var opened: bool = await _wait_for(func(): return seen.get("type") == "chest", 5)
		results["chest contents from host"] = opened and seen.slots[0] == {"id": "core:coal", "count": 4}
		game._session.container_click(CHEST, 1, {"id": "core:stick", "count": 2})
		results["chest click via host"] = await _wait_for(func(): return held[0] == {} \
				and seen.slots[1] == {"id": "core:stick", "count": 2}, 5)
	var failed := results.keys().filter(func(k): return not results[k])
	for k in results:
		print("%s  %s" % ["PASS" if results[k] else "FAIL", k])
	get_tree().quit(1 if not failed.is_empty() else 0)
