extends "res://tests/test_suite.gd"
## A host and a client game in one process, connected over ENet on localhost
## (each in its own subtree with its own SceneMultiplayer). The client player
## acts the way a person would (aim, then break / place / use), and after every
## action both worlds must agree block for block.
##
## Layout, around the client's feet O on a stone platform the host builds:
##   client at O, host player at O + (4, 0, 0) (frozen, no creatures).

const Play := preload("res://tests/mp_play.gd")

var host: Node   # main.gd
var client: Node
var o: Vector3i  # the client's feet cell
var _containers: Array[Node] = []


func _start(side: String, opts: Dictionary) -> Node:
	var box := Node.new()
	box.name = "MP" + side
	add(box)
	_containers.append(box)
	# RPCs go by node path relative to the multiplayer root: both games are
	# "Main/Session" under their own root.
	tree.set_multiplayer(SceneMultiplayer.new(), box.get_path())
	var game: Node = load("res://src/main.tscn").instantiate()
	game.name = "Main"
	game._args = {"no-mobs": "1", "view": "64", "time": "0.5"}
	for k in opts:
		game.set(k, opts[k])
	box.add_child(game)
	return game


func _connect() -> bool:
	var port := 25000 + randi() % 5000
	host = _start("Host", {"world_name": "_test_mp_host", "net_mode": "host", "port": port,
			"player_name": "Host", "new_seed": 4242})
	if not await wait_until(func(): return host._loading == null and host._player != null, 30):
		check(false, "the host's world loaded")
		return false
	check_eq(host._player.selected_item(), "core:torch", "a new world's player starts with a torch in hand")
	host._player._frozen = true
	client = _start("Client", {"net_mode": "client", "join_address": "127.0.0.1", "port": port,
			"player_name": "Client"})
	if not await wait_until(func(): return client._player != null and client._loading == null, 30):
		check(false, "the client joined and loaded")
		return false
	check_eq(client._player.selected_item(), "core:torch", "a joining player starts with a torch in hand")
	check_eq(client._player.inventory.count_of("core:torch"), 1, "just one")
	Play.take_over(client._player)
	await _build_platform()
	return true


## The play area at the client's feet, client and host standing on it.
func _build_platform() -> void:
	o = Vector3i(client._player.global_position.floor())
	Play.build_area(host._world, o)
	client._player.global_position = Vector3(o) + Vector3(0.5, 0, 0.5)
	host._player.global_position = Vector3(o) + Vector3(4.5, 0, 0.5)
	check(await _match("the platform"), "the client got the host's platform")
	await frames(10)  # the host has seen the client's new position


func _end() -> void:
	# Both leave first: once its multiplayer is handed back, a session still
	# playing would send as the offline peer (id 1: "RPC on yourself").
	for game in [client, host]:
		if is_instance_valid(game) and game._session:
			game._session.leave()
	for box in _containers:
		tree.set_multiplayer(null, box.get_path())


func _peer_id() -> int:
	return host._session._peers.keys()[0] if not host._session._peers.is_empty() else 0


## Waits for `cond` (what an action should lead to), then for both worlds to match.
func _until(cond: Callable, what: String) -> bool:
	if not await wait_until(cond, 5):
		check(false, what + ": didn't happen")
	return await _match(what)


## Whether both worlds have the same blocks all over the play area (waits a
## little for messages under way).
func _match(what: String) -> bool:
	var same := func(): return Play.area_blocks(host._world, o) == Play.area_blocks(client._world, o)
	var ok: bool = await wait_until(same, 5)
	if not ok:
		var h := Play.area_blocks(host._world, o)
		var c := Play.area_blocks(client._world, o)
		var i := range(h.size()).filter(func(k): return h[k] != c[k])
		check(false, "%s: worlds differ in %d cells, e.g. host %s, client %s" % [what, i.size(), h[i[0]], c[i[0]]])
	return ok


func _block(game: Node, rel: Vector3i) -> String:
	return Registry.block_ids[game._world.get_block(o + rel)]


## The host's figure of the client player.
func _wait_avatar() -> Node:
	await wait_until(func(): return not host._session._avatars.is_empty(), 5)
	return host._session._avatars.values()[0] if not host._session._avatars.is_empty() else null


func _aim(rel: Vector3) -> void:
	Play.aim(client._player, Vector3(o) + rel)


func _walk(to: Vector3) -> void:
	check(await Play.walk(client._player, to), "walked to %s" % (to - Vector3(o)))


func _give(item: String, count: int) -> void:
	Play.give(client._player, item, count)


func test_two_players() -> void:
	if not await _connect():
		_end()
		return
	var p: Node3D = client._player
	var hs: Session = host._session

	# Breaking: the host applies it and the drop ends up in the client's inventory.
	host._world.set_block(o + Vector3i(-2, 0, 0), Registry.block_index("core:planks"))
	await _match("a block the host put down")
	_aim(Vector3(-1.5, 0.5, 0.5))
	p._break_target()
	await _until(func(): return _block(host, Vector3i(-2, 0, 0)) == "core:air", "breaking")
	check_eq(_block(host, Vector3i(-2, 0, 0)), "core:air", "broken on the host")
	check(await wait_until(func(): return p.inventory.count_of("core:planks") == 1, 5), "the drop reached the client")
	check(await wait_until(func(): return host._drops_node.count() == 0 and client._drops_node.count() == 0, 5),
			"no drop left on either side")

	# Placing: the item is used up and the block is there for both.
	_aim(Vector3(-1.5, 0, 0.5))  # top of the floor
	p._place()
	await _until(func(): return _block(host, Vector3i(-2, 0, 0)) == "core:planks", "placing")
	check_eq(_block(host, Vector3i(-2, 0, 0)), "core:planks", "placed on the host")
	check_eq(p.inventory.count_of("core:planks"), 0, "the item was used")

	# A placement the host refuses (the host player stands there): the item comes back.
	_give("core:stone", 1)
	_aim(Vector3(4.5, 0, 0.5))
	p._place()
	check_eq(p.inventory.count_of("core:stone"), 0, "used up while the host decides")
	check(await wait_until(func(): return p.inventory.count_of("core:stone") == 1, 5), "refused: the stone came back")
	await _match("a refused placement")
	check_eq(_block(client, Vector3i(4, 0, 0)), "core:air", "nothing placed in the host player")

	# A bed: two blocks, placed whole; using it sets the respawn point on the host too.
	_give("core:bed", 1)
	_aim(Vector3(-1.3, 0, -1.7))  # looking mostly north
	p._place()
	await _until(func(): return _block(host, Vector3i(-2, 0, -2)).begins_with("core:bed"), "placing a bed")
	var foot := Vector3i(-2, 0, -2)
	check(_block(host, foot).begins_with("core:bed"), "the bed's foot is there")
	var head: Vector3i = BlockShapes.bed_head(_block(host, foot), o + foot) - o
	check(_block(host, head).ends_with("_head"), "and its head")
	check_eq(p.inventory.count_of("core:bed"), 0, "one bed used")
	_aim(Vector3(head) + Vector3(0.5, 0.5, 0.5))
	p._place()  # use it
	check(await wait_until(func(): return hs._peers[_peer_id()].get("bed") == o + head, 5), "the host knows our bed")
	check_eq(p.bed, o + head, "our respawn point")

	# Death and respawn at the bed: the host accepts where we come back.
	var corrections := [0]
	client._session.corrected.connect(func(_eye): corrections[0] += 1)
	await _walk(Vector3(o) + Vector3(0.5, 0, 2.5))  # round the planks at (-2, 0, 0)
	await _walk(Vector3(o) + Vector3(-5.5, 0, 2.5))
	p.damage(1000)
	check(p.dead and client._death_screen != null, "died")
	client._respawn()
	check(await wait_until(func(): return client._loading == null, 10), "respawned")
	p._frozen = true
	check(p.global_position.distance_to(Vector3(o + head) + Vector3(0.5, 0.5625, 0.5)) < 1.5, "at the bed")
	await wait_until(func(): return (hs._peers[_peer_id()].position as Vector3).distance_to(p.camera.global_position) < 0.5, 3)
	check_eq(corrections[0], 0, "the host didn't put us back")

	# Breaking the bed: both halves go, one bed comes back.
	await _walk(Vector3(o) + Vector3(0.5, 0, 0.5))
	_aim(Vector3(foot) + Vector3(0.5, 0.3, 0.5))
	p._break_target()
	await _until(func(): return _block(host, foot) == "core:air", "breaking the bed")
	check_eq(_block(host, foot), "core:air", "foot gone")
	check_eq(_block(host, head), "core:air", "head gone")
	await _walk(Vector3(o) + Vector3(-0.5, 0, -0.5))  # next to it, to pick it up
	check(await wait_until(func(): return p.inventory.count_of("core:bed") == 1, 5), "one bed back")
	await frames(30)
	check_eq(p.inventory.count_of("core:bed"), 1, "only one")

	# A door: placed as two blocks, opened by the client, closed by the host.
	_give("core:wood_door", 1)
	await _walk(Vector3(o) + Vector3(0.5, 0, 0.5))
	_aim(Vector3(0.5, 0, -1.5))
	p._place()
	await _until(func(): return _block(host, Vector3i(0, 1, -2)) != "core:air", "placing a door")
	check(_block(host, Vector3i(0, 0, -2)).begins_with("core:wood_door"), "lower half")
	check(_block(host, Vector3i(0, 1, -2)).ends_with("_upper"), "upper half")
	_aim(Vector3(0.5, 0.5, -1.5))
	p._place()  # open it
	await _until(func(): return _block(host, Vector3i(0, 0, -2)).ends_with("_open"), "opening the door")
	check(_block(host, Vector3i(0, 0, -2)).ends_with("_open"), "open on the host")
	for t in BlockShapes.toggle_door(_block(host, Vector3i(0, 0, -2)), o + Vector3i(0, 0, -2)):
		host._world.set_block(t[0], Registry.block_index(t[1]))
	await _until(func(): return not _block(client, Vector3i(0, 0, -2)).ends_with("_open"), "the host closing the door")
	check(not _block(client, Vector3i(0, 1, -2)).ends_with("_open"), "closed for the client")

	# The outline around what the client points at follows the block's shape
	# and changes when the host changes the block.
	host._world.set_block(o + Vector3i(-2, 0, 1), Registry.block_index("core:stone_slab"))
	await _until(func(): return _block(client, Vector3i(-2, 0, 1)) == "core:stone_slab", "a slab from the host")
	_aim(Vector3(-1.5, 0.25, 1.5))
	await frames(2)
	var aabb: AABB = p._outline.mesh.get_aabb()
	check_near(aabb.size.y, 0.504, 0.01, "the outline is half a block high")
	host._world.set_block(o + Vector3i(-2, 0, 1), Registry.block_index("core:stone"))
	await _until(func(): return _block(client, Vector3i(-2, 0, 1)) == "core:stone", "a full block from the host")
	await frames(2)
	check_near(p._outline.mesh.get_aabb().size.y, 1.004, 0.01, "then a whole block high")

	# How the host sees the client: what it holds, sneaking, its swings.
	_give("core:torch", 1)
	p.sneaking = true
	var avatar = await _wait_avatar()
	check(await wait_until(func(): return avatar.item == "core:torch" and avatar.flags & 1 != 0, 5),
			"the host sees the torch and the sneaking")
	check(avatar.light > 0, "and its light (from the host's own item data)")
	var swings_before: int = avatar.swings
	p.swings += 1
	check(await wait_until(func(): return avatar.swings == swings_before + 1, 5), "and the swing")
	p.sneaking = false
	p.inventory.slots[0] = {}

	# Tilling grass: the farmland goes through the host, and a seed it turns up
	# is dropped only once the host has made the farmland.
	_give("core:wood_hoe", 1)
	var tilled := 0
	seed(11)
	for i in 30:
		host._world.set_block(o + Vector3i(1, -1, -1), Registry.block_index("core:grass"))
		await _until(func(): return _block(client, Vector3i(1, -1, -1)) == "core:grass", "grass to till")
		_aim(Vector3(1.5, 0, -0.5))
		p._place()
		if await _until(func(): return _block(host, Vector3i(1, -1, -1)) == "core:farmland", "tilling"):
			tilled += 1
	check_eq(tilled, 30, "every till went through the host")
	check(await wait_until(func(): return p.inventory.count_of("core:seeds") > 0, 5), "and seeds turned up (%d)" % p.inventory.count_of("core:seeds"))
	check(p.pending_drops.is_empty(), "nothing left waiting for the host")
	p.inventory.slots[0] = {}
	for i in Inventory.SIZE:
		if p.inventory.slots[i].get("id", "") == "core:seeds":
			p.inventory.slots[i] = {}
	host._world.set_block(o + Vector3i(1, -1, -1), Registry.block_index("core:stone"))
	await _until(func(): return _block(client, Vector3i(1, -1, -1)) == "core:stone", "the floor back")

	# Throwing an item: the host owns it, both see it, walking over picks it up.
	client.spawn_drop("core:stick", 1, Vector3(o) + Vector3(-5.5, 0.5, 2.5))
	check(await wait_until(func(): return host._drops_node.count() == 1 and client._drops_node.count() == 1, 5),
			"the drop is on both sides")
	await _walk(Vector3(o) + Vector3(0.5, 0, 2.5))  # round the planks and stone at x -2
	await _walk(Vector3(o) + Vector3(-4.5, 0, 2.5))
	check(await wait_until(func(): return p.inventory.count_of("core:stick") == 1, 5), "picked up")
	check(await wait_until(func(): return host._drops_node.count() == 0 and client._drops_node.count() == 0, 5),
			"gone for both")

	# Walls: a move through blocks is put back (fast enough, but not through a
	# wall); walking around the wall to the same spot is fine.
	await _walk(Vector3(o) + Vector3(0.5, 0, 2.5))
	await _walk(Vector3(o) + Vector3(0.5, 0, 0.5))
	for y in 3:
		for z in range(-1, 2):
			host._world.set_block(o + Vector3i(2, y, z), Registry.block_index("core:stone"))
	await _match("a wall")
	await wait_until(func(): return false, 1.0)  # the host's movement budget is full again
	var was: int = corrections[0]
	var start := p.global_position
	p.global_position = Vector3(o) + Vector3(3.5, 0, 0.5)  # through it in one update
	check(await wait_until(func(): return corrections[0] > was, 5), "through the wall: put back")
	check(await wait_until(func(): return p.global_position.distance_to(start) < 0.1, 5),
			"back on our side of the wall")
	was = corrections[0]
	for to in [Vector3(0.5, 0, 2.5), Vector3(3.5, 0, 2.5), Vector3(3.5, 0, 0.5)]:
		await _walk(Vector3(o) + to)  # around its end
	check(await wait_until(func():
			return (hs._peers[_peer_id()].position as Vector3).distance_to(p.camera.global_position) < 0.1, 3),
			"around it: the host followed")
	check_eq(corrections[0], was, "and didn't put us back")
	for y in 3:
		for z in range(-1, 2):
			host._world.set_block(o + Vector3i(2, y, z), 0)
	await _match("the wall gone")
	corrections[0] = 0

	# Death without a bed: back at the world spawn, the same one the host has.
	await _walk(Vector3(o) + Vector3(0.5, 0, 0.5))
	p.bed = null
	p.damage(1000)
	client._respawn()
	check(await wait_until(func(): return client._loading == null, 15), "respawned at the world spawn")
	var sp: Array = host._world.meta.spawn
	check(Vector2(p.global_position.x - sp[0], p.global_position.z - sp[2]).length() < 1.0, "at the host's spawn")
	check(await wait_until(func():
			return (hs._peers[_peer_id()].position as Vector3).distance_to(p.camera.global_position) < 1.0, 3),
			"the host accepted it")
	check_eq(corrections[0], 0, "never put back")
	check(not p.dead and p.health == p.MAX_HEALTH, "alive and well")
	_end()


## A modified client sending nonsense to every request the host takes: nothing
## changes, nothing is made, nothing breaks, and the client can still play.
func test_malformed_requests() -> void:
	if not await _connect():
		_end()
		return
	var hs: Session = host._session
	var cs: Session = client._session
	var chest := o + Vector3i(-4, 0, -2)
	host._world.set_block(chest, Registry.block_index("core:chest"))
	host._world.block_entities.click(chest, 0, {"id": "core:coal", "count": 4})
	await _match("a chest")
	await _walk(Vector3(o) + Vector3(-3.5, 0, -0.5))
	cs.open_container(chest)  # opened properly, so only what follows is wrong
	await wait_until(func(): return client._player != null and chest in hs._viewers \
			and _peer_id() in hs._viewers[chest], 5)
	var area := Play.area_blocks(host._world, o)
	var chest_before: Dictionary = host._world.block_entities.entities[chest].duplicate(true)
	var at: Vector3 = client._player.camera.global_position
	var nan := Vector3(NAN, 0, 0)
	var inf := Vector3(INF, INF, INF)
	var stone := Registry.block_index("core:stone")
	var cell := o + Vector3i(1, 0, 1)

	cs._client_state.rpc_id(1, nan, 0.0, 0.0, "", 0, 0)
	cs._client_state.rpc_id(1, inf, NAN, INF, "core:no_such_item", -1, -5)
	cs._client_state.rpc_id(1, at + Vector3(500, 0, 0), 0.0, 0.0, "", 0xFFFF, 0)
	for block in [-1, 1 << 30, Registry.block_ids.size(), Registry.block_index("core:water")]:
		cs._request_edit.rpc_id(1, cell, block)
	cs._request_edit.rpc_id(1, cell + Vector3i(0, 1000000, 0), stone)
	cs._request_edit.rpc_id(1, Vector3i(1 << 30, 0, 0), stone)
	for cells in [[], [[cell]], [[cell, stone, 1]], [["x", stone]], [[cell, "core:stone"]], [[cell, stone], [cell, stone]],
			[[cell, 0]], range(50).map(func(i): return [cell + Vector3i(0, i, 0), stone]), [[cell, -3]], [null]]:
		cs._request_place.rpc_id(1, 77, cells)
	for stack in [["core:coal", 0], ["core:coal", -5], ["core:coal", 1 << 30], ["core:no_such_item", 1], ["", 1]]:
		cs._request_drop.rpc_id(1, stack[0], stack[1], at)
	cs._request_drop.rpc_id(1, "core:coal", 1, nan)
	cs._request_drop.rpc_id(1, "core:coal", 1, at + Vector3(300, 0, 0))
	for id in [-1, 0, 1 << 40]:
		cs._request_pickup.rpc_id(1, id)
		cs._hit_mob.rpc_id(1, id, "core:no_such_item")
	for slot in [-1, 999, 1 << 40]:
		cs._container_click.rpc_id(1, chest, slot, {"id": "core:coal", "count": 1})
	for held in [{"id": "core:coal", "count": 1 << 30}, {"id": "core:coal", "count": "1"}, {"id": 5, "count": 1},
			{"id": "core:coal", "count": 1, "extra": true}, {"count": 64}, {"id": "core:no_such_item", "count": 1}]:
		cs._container_click.rpc_id(1, chest, 1, held)
	cs._container_click.rpc_id(1, o + Vector3i(5, 0, 2), 0, {})  # not a container
	cs._open_container.rpc_id(1, o + Vector3i(200, 0, 0))
	cs._set_bed.rpc_id(1, cell)  # not a bed
	cs._set_bed.rpc_id(1, Vector3i(1 << 30, 0, 0))
	cs._request_chunk.rpc_id(1, Vector3i(1 << 20, 1 << 20, 1 << 20))
	cs._hello.rpc_id(1, -1, ["nonsense"], "x".repeat(10000))  # a second hello
	await frames(30)

	var rates: Dictionary = hs._peers[_peer_id()].get("rates", {})
	for kind in ["edit", "drop", "pickup", "hit", "container", "other", "chunk"]:
		check(rates.has(kind), "the host got and checked the %s requests" % kind)
	check_eq(Play.area_blocks(host._world, o), area, "no block changed on the host")
	check_eq(host._drops_node.count(), 0, "no item was made")
	check_eq(host._world.block_entities.entities[chest], chest_before, "the chest is as it was")
	check_eq(hs._peers.size(), 1, "the client is still connected")
	check(hs._peers[_peer_id()].get("bed") == null, "no bed was set")
	check((hs._peers[_peer_id()].position as Vector3).is_finite(), "its position stayed a real one")
	check(hs._peers[_peer_id()].position.distance_to(client._player.camera.global_position) < 0.5,
			"where it really is")
	check(hs._peers[_peer_id()].name == "Client", "its name didn't change")

	# And the client still plays normally (once the flood's rate limits refill).
	await wait_until(func(): return false, 3.0)
	_give("core:planks", 1)
	_aim(Vector3(-2.5, 0, -0.5))  # top of the floor, west of us
	client._player._place()
	await _until(func(): return _block(host, Vector3i(-3, 0, -1)) == "core:planks", "a normal placement afterwards")
	check_eq(_block(host, Vector3i(-3, 0, -1)), "core:planks", "placed")
	_end()
