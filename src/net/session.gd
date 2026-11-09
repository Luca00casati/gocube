class_name Session
extends Node
## Multiplayer session over Godot's high-level multiplayer (ENet).
##
## The host is an authoritative server that also plays. World generation is
## deterministic, so clients generate terrain themselves from the seed and only
## edits travel over the network:
##   - handshake: protocol + exact mod list check, then seed, block table and
##     every edited chunk (run-length encoded)
##   - block edits: clients ask, the host validates and applies, then sends
##     (position, block) to everyone; a client that hasn't loaded that chunk
##     asks the host for the whole chunk instead
##   - player positions (clients -> host -> everyone) and avatars
##
## Mods are NOT sent over the network: both sides must have the same mods
## installed (mod scripts run unsandboxed, so never auto-download them).

signal welcomed(info: Dictionary)  # client: host accepted us, build the world
signal ended(reason: String)       # client: connection failed / rejected / lost
## Another player changed a block (for sounds): old and new block index.
signal remote_edit(position: Vector3i, old_block: int, new_block: int)
## Client: the host applied a block change we asked for (drop what we broke).
signal own_edit_confirmed(position: Vector3i)
## Client: the host refused a block change we asked for (nothing was broken).
signal own_edit_refused(position: Vector3i)
## Client: the host gave us a dropped item we asked for (put it in the inventory).
signal items_picked(item: String, count: int)
## Client: a container's contents / what we hold after clicking it.
signal container_updated(position: Vector3i, data: Dictionary)
signal container_held(position: Vector3i, held: Dictionary)
## Client: a creature hit us (damage, knockback).
signal struck(damage: int, push: Vector3)
## Client: everyone slept and the host skipped the night: get up.
signal woken
## Client: the host refused our movement and put us back at `eye` (an eye position).
signal corrected(eye: Vector3)

const Avatar := preload("res://src/player/avatar.gd")
const Player := preload("res://src/player/player.gd")

const PROTOCOL := 4
const DEFAULT_PORT := 24680
const MAX_PLAYERS := 8
const STATE_INTERVAL := 0.05       # seconds between position updates (20 Hz)
const EDIT_REACH := 16.0           # max distance from a player to a block they edit
const CONNECT_TIMEOUT_MS := 8000
const TIME_SYNC_SECONDS := 5.0     # host corrects clients' clocks this often

enum Mode { OFFLINE, HOST, CLIENT }

var mode := Mode.OFFLINE
var world: World
## The local player's eyes (camera); its position is what others see.
var local_player: Node3D
var drops: ItemDrops               # dropped items (set by main)
var _drop_timer := 0.0
var held_light := 0         # light level of what the local player holds (a torch: 13); set by main
var player_name := "Player"
## Time of day; the host's is authoritative.
var day_cycle: DayCycle
## Creatures: the host simulates them and sends their positions.
var mobs: MobManager
const MOB_INTERVAL := 0.1
const DROP_INTERVAL := 0.1        # seconds between dropped-item updates to clients
const MOB_REACH := 6.0
var _mob_timer := 0.0

## Host only: peer id -> {name, position: Vector3, yaw: float}
var _peers := {}
## Avatars of other players, by peer id.
var _avatars := {}
var _player_count := 1
var _send_timer := 0.0
var _time_sync_timer := 0.0
var _connect_started := 0
var _welcomed := false
var _ended := false
var _own_edits := {}  # client: position we asked the host to change -> when (no echo sound)
const EDIT_PENDING_SECONDS := 5.0  # a request the host never answered is forgotten after this
var _viewers := {}    # host: container position -> [peer ids looking at it]
const CONTAINER_REACH := 8.0
## Host-side movement check (clients report their own positions): the fastest
## a player can go, in blocks per second, as (horizontal, up, down). Survival
## covers sprinting plus a creature's knockback; creative covers sprint-flying.
const MOVE_SPEED_SURVIVAL := Vector3(14.0, 13.0, 62.0)
const MOVE_SPEED_CREATIVE := Vector3(28.0, 28.0, 62.0)
const MOVE_BURST := 0.75          # seconds of movement that may arrive at once (lag)
const MOVE_SLACK := 1.0           # extra blocks always allowed
const RESPAWN_RADIUS := 2.0       # a jump to the world spawn (respawning) is fine
const CORRECT_EVERY := 0.5        # seconds between corrections sent to one client
## Host: how many requests of each kind a client may send per second, and in
## one burst (lag can bunch them up). Requests over the limit are ignored.
const RATES := {
	"edit": [20.0, 40.0],       # breaking and placing (creative mines fast; doors and beds are two)
	"hit": [8.0, 12.0],
	"chunk": [30.0, 120.0],
	"drop": [10.0, 30.0],
	"pickup": [20.0, 60.0],
	"container": [20.0, 40.0],
	"other": [4.0, 10.0],       # bed, sleeping
}
const NAME_LENGTH := 16
const MAX_MODS := 256             # longest mod list accepted in a hello


# --- Setup / teardown ----------------------------------------------------------

func host(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	mode = Mode.HOST
	return OK


func join(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	mode = Mode.CLIENT
	_connect_started = Time.get_ticks_msec()
	return OK


func _exit_tree() -> void:
	leave()


func leave() -> void:
	for sig in [[multiplayer.peer_disconnected, _on_peer_disconnected],
			[multiplayer.connected_to_server, _on_connected],
			[multiplayer.connection_failed, _on_connection_failed],
			[multiplayer.server_disconnected, _on_server_disconnected]]:
		if sig[0].is_connected(sig[1]):
			sig[0].disconnect(sig[1])
	if mode != Mode.OFFLINE and multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func is_client() -> bool:
	return mode == Mode.CLIENT


func player_count() -> int:
	return _peers.size() + 1 if is_host() else _player_count


## "id@version#fingerprint" of every loaded mod: two players can only play
## together with exactly the same mods (the fingerprint covers their files).
static func mod_list() -> Array:
	var mods := ModLoader.mods.map(func(m): return "%s@%s#%s" % [m.id, m.get("version", ""), m.get("hash", "")])
	mods.sort()
	return mods


func _end(reason: String) -> void:
	if _ended:
		return
	_ended = true
	ended.emit(reason)


# --- Client side ---------------------------------------------------------------

func _on_connected() -> void:
	_hello.rpc_id(1, PROTOCOL, mod_list(), player_name)


func _on_connection_failed() -> void:
	_end("Couldn't connect to the server.")


func _on_server_disconnected() -> void:
	_end("The server closed the connection.")


@rpc("authority", "call_remote", "reliable")
func _welcome(info: Dictionary) -> void:
	_welcomed = true
	welcomed.emit(info)


@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_end(reason)


## Clients ask the host to change a block; the host validates and applies it.
func request_edit(pos: Vector3i, block: int) -> void:
	_own_edits[pos] = _now()
	_request_edit.rpc_id(1, pos, block)


@rpc("authority", "call_remote", "unreliable_ordered")
func _players_state(states: Dictionary) -> void:
	_player_count = states.size()
	_update_avatars(states)


# --- Host side -----------------------------------------------------------------

static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _move_speeds() -> Vector3:
	return MOVE_SPEED_CREATIVE if world.meta.get("mode", "survival") == "creative" else MOVE_SPEED_SURVIVAL


func _move_cap() -> Vector3:
	return _move_speeds() * MOVE_BURST + Vector3.ONE * MOVE_SLACK


## Host: whether a client may have moved from its last accepted position to
## `pos`. Each player has a movement budget per direction that refills at the
## top speed (up to MOVE_BURST seconds' worth, so late packets arriving
## together pass) and is spent by moving. Respawning jumps to the world spawn.
func _move_allowed(p: Dictionary, pos: Vector3) -> bool:
	var now := _now()
	var budget: Vector3 = p.get("budget", Vector3.ZERO) + _move_speeds() * (now - float(p.get("time", now)))
	budget = budget.min(_move_cap())
	p.time = now
	var d: Vector3 = pos - (p.position as Vector3)
	var cost := Vector3(Vector2(d.x, d.z).length(), maxf(d.y, 0.0), maxf(-d.y, 0.0))
	if cost.x <= budget.x and cost.y <= budget.y and cost.z <= budget.z:
		p.budget = budget - cost
		return true
	var sp: Array = world.meta.get("spawn", [])
	var bed = p.get("bed")
	if (sp.size() == 3 and Vector2(pos.x - sp[0], pos.z - sp[2]).length() <= RESPAWN_RADIUS) \
			or (bed != null and Vector2(pos.x - bed.x - 0.5, pos.z - bed.z - 0.5).length() <= RESPAWN_RADIUS):
		p.budget = _move_cap()
		return true
	p.budget = budget
	return false


@rpc("authority", "call_remote", "reliable")
func _correct(eye: Vector3) -> void:
	corrected.emit(eye)


@rpc("any_peer", "call_remote", "reliable")
func _hello(protocol: int, mods: Array, requested_name: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if _peers.has(id):
		return  # only once (a second hello would reset its position)
	var reason := ""
	if mods.size() > MAX_MODS or mods.any(func(m): return not m is String or m.length() > 200):
		reason = "Bad hello."
		mods = []
	elif protocol != PROTOCOL:
		reason = "Game version mismatch (server protocol %d, yours %d)." % [PROTOCOL, protocol]
	elif mods != mod_list():
		var mine := mod_list()
		reason = "Your mods don't match the server's (after # is a fingerprint of the mod's files).\n" \
				+ "Only on the server, or different there: %s\nOnly yours, or different: %s" % [
				", ".join(mine.filter(func(x): return x not in mods)), ", ".join(mods.filter(func(x): return x not in mine))]
	if reason != "":
		print("Rejected peer %d: %s" % [id, reason])
		_rejected.rpc_id(id, reason)
		# Give the message time to arrive before dropping the connection.
		get_tree().create_timer(1.0).timeout.connect(_kick.bind(id))
		return

	var pname := clean_name(requested_name)
	if pname == "":
		pname = "Player %d" % id
	var spawn := local_player.global_position + Vector3(2, 0, 2)

	# Reliable messages on one channel arrive in order, so the client has the
	# world before any later block edit reaches it.
	_welcome.rpc_id(id, {
		"block_ids": Array(Registry.block_ids),
		"view_distance": world.view_distance,
		"spawn": [spawn.x, spawn.y, spawn.z],
		"world_spawn": world.meta.get("spawn", []),  # where the dead respawn
		"seed": int(world.meta.seed),
		"generator": int(world.meta.get("generator", 1)),
		"mode": world.meta.get("mode", "survival"),
		"chunks": world.edited_chunks(),  # {Vector3i: PackedByteArray}
		"time": day_cycle.time if day_cycle else DayCycle.START_TIME,
		"day_length": day_cycle.day_length if day_cycle else DayCycle.DEFAULT_DAY_LENGTH,
	})
	if not world.block_changed.is_connected(_on_block_changed):
		world.block_changed.connect(_on_block_changed)

	_peers[id] = {"name": pname, "position": spawn, "yaw": 0.0,
			"time": _now(), "budget": _move_cap()}
	print("%s joined (peer %d)" % [pname, id])


## A player name as shown to others: printable characters only, trimmed and
## at most NAME_LENGTH long.
static func clean_name(requested: String) -> String:
	var out := ""
	for c in requested.left(NAME_LENGTH * 4):
		var u := c.unicode_at(0)
		if u >= 32 and u != 127 and not (u >= 0x80 and u < 0xA0) and not (u >= 0x200B and u <= 0x200F) \
				and not (u >= 0x202A and u <= 0x202E) and not (u >= 0x2066 and u <= 0x2069):
			out += c
	return out.strip_edges().left(NAME_LENGTH).strip_edges()


## Host: whether peer `id` may make another request of this kind now (see RATES).
func _allow(id: int, kind: String) -> bool:
	var p = _peers.get(id)
	if p == null:
		return false
	var rate: Array = RATES[kind]
	if not p.has("rates"):
		p.rates = {}
	var now := _now()
	var b: Array = p.rates.get(kind, [rate[1], now])  # [tokens, last update]
	var tokens := minf(rate[1], b[0] + (now - b[1]) * rate[0])
	if tokens < 1.0:
		p.rates[kind] = [tokens, now]
		if now - float(p.get("flood_logged", -INF)) > 5.0:
			p.flood_logged = now
			print("Peer %d sends too many %s requests; ignoring some" % [id, kind])
		return false
	p.rates[kind] = [tokens - 1.0, now]
	return true


func _kick(id: int) -> void:
	if is_host() and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if not _peers.has(id):
		return
	print("%s left" % _peers[id].name)
	_peers.erase(id)
	for pos in _viewers:
		_viewers[pos].erase(id)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _client_state(pos: Vector3, yaw: float, light: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id) or not pos.is_finite() or not is_finite(yaw):
		return
	var p: Dictionary = _peers[id]
	if not _move_allowed(p, pos):
		if _now() - float(p.get("corrected", -INF)) >= CORRECT_EVERY:
			p.corrected = _now()
			_correct.rpc_id(id, p.position)
		return
	p.position = pos
	p.yaw = wrapf(yaw, -PI, PI)
	p.light = clampi(light, 0, 15)


@rpc("any_peer", "call_remote", "reliable")
func _request_edit(pos: Vector3i, block: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id):
		return
	if not _edit_allowed(id, pos, block):
		_edit_refused.rpc_id(id, pos)  # so it doesn't wait for an answer
		return
	var old := world.get_block(pos)
	world.editor = id  # spilled container contents go to this player
	var ok := world.set_block(pos, block)  # -> block_changed -> sent to everyone
	world.editor = 0
	if ok:
		remote_edit.emit(pos, old, block)
	else:
		_edit_refused.rpc_id(id, pos)  # its chunk isn't loaded here


## Host: whether peer `id` may set the block at pos (within its request rate,
## a known placeable block, within reach, nobody inside it).
func _edit_allowed(id: int, pos: Vector3i, block: int) -> bool:
	if not _allow(id, "edit") or block < 0 or block >= Registry.block_ids.size():
		return false
	var def = Registry.blocks.get(Registry.block_ids[block])
	if block != Registry.block_index("core:air") and (def == null or not def.get("solid", true)):
		return false  # unknown/missing or non-placeable block
	var player_pos: Vector3 = _peers[id].position
	if player_pos.distance_to(Vector3(pos) + Vector3.ONE * 0.5) > EDIT_REACH:
		return false
	if block != Registry.block_index("core:air"):
		for state in _host_states().values():  # nobody may get built into a block
			if Player.overlaps_block(state[0] - Vector3(0, Player.EYE_HEIGHT, 0), pos):
				return false
	return true


## Client: the host didn't make a change we asked for.
@rpc("authority", "call_remote", "reliable")
func _edit_refused(pos: Vector3i) -> void:
	if _own_edits.erase(pos):
		own_edit_refused.emit(pos)


func _on_block_changed(pos: Vector3i, block: int) -> void:
	if is_host() and not _peers.is_empty():
		_block.rpc(pos, block)


## Client: a block changed on the host.
@rpc("authority", "call_remote", "reliable")
func _block(pos: Vector3i, block: int) -> void:
	if world == null:
		return
	var old := world.get_block(pos)
	if not world.apply_remote_block(pos, block):
		_request_chunk.rpc_id(1, World.chunk_of(pos))  # not loaded here: get the whole chunk
	elif _own_edits.erase(pos):
		own_edit_confirmed.emit(pos)
	else:
		remote_edit.emit(pos, old, block)


## Client: the host's time of day (snap only if we drifted noticeably).
@rpc("authority", "call_remote", "unreliable_ordered")
func _time(host_time: float) -> void:
	if day_cycle:
		var drift := absf(wrapf(host_time - day_cycle.time, -0.5, 0.5)) * day_cycle.day_length
		if drift > 0.5:  # seconds
			day_cycle.time = host_time


# --- Containers and drops (the host owns chests/furnaces) -------------------------

## Host: where every joined player is (for creature spawning).
func peer_positions() -> Array:
	return _peers.values().map(func(p): return p.position)


## Host: joined players ninjas may chase (the world's mode decides for all).
func peer_targets() -> Array:
	return _peers.keys().map(func(id): return {"position": _peers[id].position, "peer": id})


## Host: a creature hit a joined player.
func strike_player(peer: int, damage: int, push: Vector3) -> void:
	if _peers.has(peer):
		_struck.rpc_id(peer, damage, push)


@rpc("authority", "call_remote", "reliable")
func _struck(damage: int, push: Vector3) -> void:
	struck.emit(damage, push)


@rpc("authority", "call_remote", "unreliable_ordered")
func _mobs_state(states: Dictionary) -> void:
	if mobs:
		mobs.apply_states(states)


## `item`: what the attacker holds (the host looks up its damage).
func hit_mob(id: int, item: String) -> void:
	_hit_mob.rpc_id(1, id, item)


@rpc("any_peer", "call_remote", "reliable")
func _hit_mob(id: int, item: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if not is_host() or mobs == null or not _allow(peer, "hit"):
		return
	var from: Vector3 = _peers[peer].position
	for mob in mobs.mobs():
		if mob.id == id and mob.global_position.distance_to(from) <= MOB_REACH:
			mobs.hit(id, from, peer, load("res://src/player/player.gd").attack_damage(item))
			return


# Beds and sleeping: the host skips the night once every player is in bed.

## Client: we set our respawn point at the bed at `pos`.
func set_bed(pos: Vector3i) -> void:
	_set_bed.rpc_id(1, pos)


@rpc("any_peer", "call_remote", "reliable")
func _set_bed(pos: Vector3i) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _allow(id, "other") or not _can_reach(id, pos):
		return
	if Registry.blocks.get(Registry.block_ids[world.get_block(pos)], {}).get("bed", false):
		_peers[id].bed = pos  # respawning there is a jump the host allows


## Client: we lay down in a bed or got up.
func set_sleeping(on: bool) -> void:
	_set_sleeping.rpc_id(1, on)


@rpc("any_peer", "call_remote", "reliable")
func _set_sleeping(on: bool) -> void:
	var id := multiplayer.get_remote_sender_id()
	if is_host() and _allow(id, "other"):
		_peers[id].sleeping = on


## Host / single player: whether every joined player is in bed (true alone).
func peers_sleeping() -> bool:
	return _peers.values().all(func(p): return p.get("sleeping", false))


## Host: the night was skipped: send the new time and get everyone up.
func night_skipped() -> void:
	if not is_host() or _peers.is_empty():
		return
	for p in _peers.values():
		p.sleeping = false
	if day_cycle:
		_time.rpc(day_cycle.time)
	_wake_up.rpc()


@rpc("authority", "call_remote", "reliable")
func _wake_up() -> void:
	woken.emit()


# Dropped items: the host owns them all (ItemDrops) and sends their state to
# everyone; clients ask to drop and to pick up.

## Client: ask the host to drop items at a position (what we broke or threw).
func request_drop(item: String, count: int, at: Vector3) -> void:
	_request_drop.rpc_id(1, item, count, at)


@rpc("any_peer", "call_remote", "reliable")
func _request_drop(item: String, count: int, at: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or drops == null or not _allow(id, "drop") or not at.is_finite() \
			or not valid_stack({"id": item, "count": count}) \
			or at.distance_to(_peers[id].position) > EDIT_REACH + 2.0:
		return
	drops.spawn(item, count, at)


## Client: ask the host for a dropped item we reached.
func request_pickup(drop_id: int) -> void:
	_request_pickup.rpc_id(1, drop_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(drop_id: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or drops == null or not _allow(id, "pickup"):
		return
	var got: Array = drops.take(drop_id, _peers[id].position)
	if not got.is_empty():
		_picked.rpc_id(id, got[0], got[1])


@rpc("authority", "call_remote", "reliable")
func _picked(item: String, count: int) -> void:
	items_picked.emit(item, count)


@rpc("authority", "call_remote", "unreliable_ordered")
func _drops_state(states: Dictionary) -> void:
	if drops:
		drops.apply_states(states)


func open_container(pos: Vector3i) -> void:
	_open_container.rpc_id(1, pos)


func container_click(pos: Vector3i, slot: int, held: Dictionary) -> void:
	_container_click.rpc_id(1, pos, slot, held)


func close_container(pos: Vector3i) -> void:
	_close_container.rpc_id(1, pos)


func _container_data(pos: Vector3i) -> Dictionary:
	var e := world.block_entities.get_entity(pos)
	return {} if e.is_empty() else {"type": e.type, "slots": e.slots.duplicate(true),
			"burn": e.burn, "burn_total": e.burn_total, "progress": e.progress}


## An empty hand, or a stack of a known item within its stack size.
static func valid_stack(stack: Dictionary) -> bool:
	if stack.is_empty():
		return true
	if stack.size() != 2 or not stack.get("id") is String or not (stack.get("count") is int):
		return false
	var item: String = stack.id
	return (Registry.items.has(item) or (Registry.blocks.has(item) and not Registry.blocks[item].has("variant_of"))) \
			and stack.count >= 1 and stack.count <= Inventory.max_stack(item)


func _can_reach(id: int, pos: Vector3i) -> bool:
	return _peers.has(id) and (_peers[id].position as Vector3).distance_to(Vector3(pos) + Vector3.ONE * 0.5) <= CONTAINER_REACH


@rpc("any_peer", "call_remote", "reliable")
func _open_container(pos: Vector3i) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _allow(id, "container") or not world.block_entities.has_entity(pos) \
			or not _can_reach(id, pos):
		return
	if not _viewers.has(pos):
		_viewers[pos] = []
	if id not in _viewers[pos]:
		_viewers[pos].append(id)
	if not world.block_entities.changed.is_connected(_on_container_changed):
		world.block_entities.changed.connect(_on_container_changed)
	_container.rpc_id(id, pos, _container_data(pos))


@rpc("any_peer", "call_remote", "reliable")
func _container_click(pos: Vector3i, slot: int, held: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	# Only a player who opened this container (and is still near it) may click
	# it, with a real item stack.
	if not is_host() or not _allow(id, "container") or id not in _viewers.get(pos, []) \
			or not world.block_entities.has_entity(pos) or not _can_reach(id, pos) or not valid_stack(held):
		_held.rpc_id(id, pos, held)  # refused: give it back
		return
	_held.rpc_id(id, pos, world.block_entities.click(pos, slot, held))


@rpc("any_peer", "call_remote", "reliable")
func _close_container(pos: Vector3i) -> void:
	if _viewers.has(pos):
		_viewers[pos].erase(multiplayer.get_remote_sender_id())


func _on_container_changed(pos: Vector3i) -> void:
	for id in _viewers.get(pos, []):
		if _peers.has(id):
			_container.rpc_id(id, pos, _container_data(pos))


@rpc("authority", "call_remote", "reliable")
func _container(pos: Vector3i, data: Dictionary) -> void:
	container_updated.emit(pos, data)


@rpc("authority", "call_remote", "reliable")
func _held(pos: Vector3i, held: Dictionary) -> void:
	container_held.emit(pos, held)


@rpc("any_peer", "call_remote", "reliable")
func _request_chunk(chunk_pos: Vector3i) -> void:
	var id := multiplayer.get_remote_sender_id()
	if is_host() and _allow(id, "chunk"):
		var bytes := world.chunk_bytes(chunk_pos)
		if not bytes.is_empty():
			_chunk.rpc_id(id, chunk_pos, bytes)


@rpc("authority", "call_remote", "reliable")
func _chunk(chunk_pos: Vector3i, bytes: PackedByteArray) -> void:
	if world:
		world.set_chunk(chunk_pos, bytes)


func _host_states() -> Dictionary:
	var states := {}
	if local_player:
		states[1] = [local_player.global_position, local_player.global_rotation.y, player_name, held_light]
	for id in _peers:
		states[id] = [_peers[id].position, _peers[id].yaw, _peers[id].name, _peers[id].get("light", 0)]
	return states


# --- Both sides ----------------------------------------------------------------

func _process(delta: float) -> void:
	if is_client() and not _own_edits.is_empty():
		var now := _now()
		for pos in _own_edits.keys():
			if now - float(_own_edits[pos]) > EDIT_PENDING_SECONDS:
				_own_edits.erase(pos)  # never answered (lost with a reconnect, say)
				own_edit_refused.emit(pos)
	if is_client() and not _welcomed and not _ended \
			and Time.get_ticks_msec() - _connect_started > CONNECT_TIMEOUT_MS:
		_end("Connection timed out.")
		return
	if is_host() and day_cycle and not _peers.is_empty():
		_time_sync_timer += delta
		if _time_sync_timer >= TIME_SYNC_SECONDS:
			_time_sync_timer = 0.0
			_time.rpc(day_cycle.time)
	if is_host() and drops and not _peers.is_empty():
		_drop_timer += delta
		if _drop_timer >= DROP_INTERVAL:
			_drop_timer = 0.0
			_drops_state.rpc(drops.states())
	if is_host() and mobs and not _peers.is_empty():
		_mob_timer += delta
		if _mob_timer >= MOB_INTERVAL:
			_mob_timer = 0.0
			_mobs_state.rpc(mobs.states())
	_send_timer += delta
	if _send_timer < STATE_INTERVAL or local_player == null:
		return
	_send_timer = 0.0
	if is_host():
		var states := _host_states()
		_update_avatars(states)
		if not _peers.is_empty():
			_players_state.rpc(states)
	elif is_client() and _welcomed:
		_client_state.rpc_id(1, local_player.global_position, local_player.global_rotation.y, held_light)


## Other players carrying light: [Vector4(x, y, z, level)] for the terrain shader.
func held_lights() -> Array:
	var out := []
	for id in _avatars:
		var a = _avatars[id]
		if a.light > 0:
			out.append(Vector4(a.position.x, a.position.y, a.position.z, a.light))
	return out


func _update_avatars(states: Dictionary) -> void:
	var me := multiplayer.get_unique_id()
	for id in states:
		if id == me:
			continue
		var avatar = _avatars.get(id)
		if avatar == null:
			avatar = Avatar.new()
			avatar.setup(states[id][2], id)
			avatar.position = states[id][0]
			world.add_child(avatar)
			_avatars[id] = avatar
		avatar.target_position = states[id][0]
		avatar.target_yaw = states[id][1]
		avatar.light = states[id][3] if states[id].size() > 3 else 0
	for id in _avatars.keys():
		if not states.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)
