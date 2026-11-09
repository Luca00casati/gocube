extends Node
## Multiplayer smoke test: a host and a client process (see mp_smoke.sh).
## The client exits 0 if edits made before and after joining reach it, its
## requests are applied (or refused and answered) by the host, and a short
## round of play (placing, breaking, a door, a bed) works. Both print a
## fingerprint of the play area at the end; mp_smoke.sh checks they match.

const Play := preload("res://tests/mp_play.gd")
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
	await Play.walk(player, to)


## Where the scripted play happens: next to the world spawn (the host player
## stands at the spawn, outside the area).
static func _play_area(w: World) -> Vector3i:
	var sp: Array = w.meta.spawn
	return Vector3i(Vector3(sp[0], sp[1], sp[2]).floor()) + Vector3i(9, 0, 0)


## The client plays a little, as a person would. Returns what worked.
func _play(game: Node) -> Dictionary:
	var p: Node3D = game._player
	var w: World = game._world
	var o := _play_area(w)
	var at := func(rel: Vector3i) -> String: return Registry.block_ids[w.get_block(o + rel)]
	var r := {}
	Play.take_over(p)
	await get_tree().create_timer(2.5).timeout  # the edit flood above used up our requests
	await _walk(p, Vector3(o) + Vector3(0.5, 0, 0.5))
	Play.give(p, "core:planks", 1)
	Play.aim(p, Vector3(o) + Vector3(-1.5, 0, 0.5))
	p._place()
	r["play: place a block"] = await _wait_for(func(): return at.call(Vector3i(-2, 0, 0)) == "core:planks", 5)
	Play.aim(p, Vector3(o) + Vector3(-1.5, 0.5, 0.5))
	p._break_target()
	r["play: break it, get it back"] = await _wait_for(func(): return at.call(Vector3i(-2, 0, 0)) == "core:air" \
			and p.inventory.count_of("core:planks") == 1, 5)
	Play.give(p, "core:wood_door", 1)
	Play.aim(p, Vector3(o) + Vector3(0.5, 0, -1.5))
	p._place()
	r["play: place a door"] = await _wait_for(func(): return at.call(Vector3i(0, 1, -2)).ends_with("_upper"), 5)
	Play.aim(p, Vector3(o) + Vector3(0.5, 0.5, -1.5))
	p._place()
	r["play: open it"] = await _wait_for(func(): return at.call(Vector3i(0, 0, -2)).ends_with("_open"), 5)
	Play.give(p, "core:bed", 1)
	Play.aim(p, Vector3(o) + Vector3(-1.3, 0, -1.7))
	p._place()
	r["play: place a bed"] = await _wait_for(func(): return at.call(Vector3i(-2, 0, -2)).begins_with("core:bed") \
			and at.call(Vector3i(-2, 0, -3)).ends_with("_head"), 5)
	Play.aim(p, Vector3(o) + Vector3(-1.5, 0.3, -2.5))  # the head
	p._place()
	r["play: sleep there (respawn point)"] = p.bed == o + Vector3i(-2, 0, -3)
	await _walk(p, Vector3(o) + Vector3(-0.5, 0, -0.5))
	Play.aim(p, Vector3(o) + Vector3(-1.5, 0.3, -1.5))  # the foot
	p._break_target()
	r["play: break the bed, one comes back"] = await _wait_for(func(): return at.call(Vector3i(-2, 0, -3)) == "core:air" \
			and p.inventory.count_of("core:bed") == 1, 5)
	await _wait_for(func(): return game._session._own_edits.is_empty(), 5)
	print("AREA ", Play.area_hash(w, o))
	return r


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var role: String = args[0] if args.size() > 0 else ""
	if role == "host":
		var world_name: String = args[1] if args.size() > 1 else "_mp_smoke"
		var game := await _start({"world_name": world_name, "net_mode": "host", "port": PORT, "player_name": "Host"})
		await _wait_for(func(): return game._loading == null, 30)
		game._world.set_block(LAMP_BEFORE, Registry.block_index("core:lamp"))
		game._world.set_block(CHEST, Registry.block_index("core:chest"))
		game._world.block_entities.click(CHEST, 0, {"id": "core:coal", "count": 4})
		var g: Dictionary = game._world.raycast(Vector3(8.5, World.TOP_Y, 8.5), Vector3.DOWN, 400)
		game._mobs.spawn_at(Vector3(8.5, g.position.y + 1, 8.5))
		game._player.inventory.slots[game._player.selected] = {"id": "core:torch", "count": 1}
		Play.build_area(game._world, _play_area(game._world))
		print("HOST ready")
		await _wait_for(func(): return not game._session._peers.is_empty(), 60)
		await get_tree().create_timer(1.5).timeout
		game._world.set_block(ORE_AFTER, Registry.block_index("core:gold_ore"))
		await _wait_for(func(): return game._session._peers.is_empty(), 60)
		print("HOST AREA ", Play.area_hash(game._world, _play_area(game._world)))
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
		# An edit the host refuses (out of reach) is answered, not left pending.
		var refused := [false]
		var far := Vector3i(game._player.global_position.floor()) + Vector3i(40, 0, 0)
		game._session.own_edit_refused.connect(func(p): refused[0] = refused[0] or p == far)
		game._session.request_edit(far, Registry.block_index("core:planks"))
		results["refused edit answered"] = await _wait_for(func(): return refused[0] \
				and not game._session._own_edits.has(far), 5)
		# A refused placement gives the item back; a bed is placed whole or not at all.
		var back := []
		game._session.placement_refused.connect(func(item): back.append(item))
		var had_beds: int = game._player.inventory.count_of("core:bed")
		game._player._frozen = true
		game._player.creative = false
		game._session.request_place([[far, Registry.block_index("core:planks")]], "core:planks")
		var foot := Vector3i(game._player.global_position.floor()) + Vector3i(2, 0, 2)
		var head := foot + Vector3i(0, 0, -1)
		var reach_far := head + Vector3i(0, 0, -30)  # the head half out of reach
		game._session.request_place([[foot, Registry.block_index("core:bed")],
				[reach_far, Registry.block_index("core:bed_n_head")]], "core:bed")
		results["refused placements give items back"] = await _wait_for(func(): return back == ["core:planks", "core:bed"], 5) \
				and game._player.inventory.count_of("core:bed") == had_beds + 1
		results["half a bed is never placed"] = w.get_block(foot) != Registry.block_index("core:bed")
		game._session.request_place([[foot, Registry.block_index("core:bed")],
				[head, Registry.block_index("core:bed_n_head")]], "core:bed")
		results["a whole bed is placed"] = await _wait_for(func(): return w.get_block(foot) == Registry.block_index("core:bed") \
				and w.get_block(head) == Registry.block_index("core:bed_n_head"), 5)
		# Flooding: the host applies only a burst of edits, refusing the rest.
		var base := Vector3i(game._player.global_position.floor()) + Vector3i(-2, 3, -2)
		var refusals := [0]
		game._session.own_edit_refused.connect(func(_p): refusals[0] += 1)
		for i in 100:
			game._session.request_edit(base + Vector3i(i % 4, i / 16, (i / 4) % 4), Registry.block_index("core:planks"))
		results["edit flood limited"] = await _wait_for(func(): return game._session._own_edits.is_empty(), 5) \
				and refusals[0] >= 50
		results.merge(await _play(game))
	var failed := results.keys().filter(func(k): return not results[k])
	for k in results:
		print("%s  %s" % ["PASS" if results[k] else "FAIL", k])
	get_tree().quit(1 if not failed.is_empty() else 0)
