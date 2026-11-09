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
## Client: items the host gave us to drop at a position ([[id, count], ...]).
signal drops_received(at: Vector3, items: Array)
## Client: a container's contents / what we hold after clicking it.
signal container_updated(position: Vector3i, data: Dictionary)
signal container_held(position: Vector3i, held: Dictionary)
## Client: a creature hit us (damage, knockback).
signal struck(damage: int, push: Vector3)

const Avatar := preload("res://src/player/avatar.gd")
const Player := preload("res://src/player/player.gd")

const PROTOCOL := 2
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
var held_light := 0         # light level of what the local player holds (a torch: 13); set by main
var player_name := "Player"
## Time of day; the host's is authoritative.
var day_cycle: DayCycle
## Creatures: the host simulates them and sends their positions.
var mobs: MobManager
const MOB_INTERVAL := 0.1
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
var _own_edits := {}  # client: positions we asked the host to change (no echo sound)
var _viewers := {}    # host: container position -> [peer ids looking at it]
const CONTAINER_REACH := 8.0


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


static func mod_list() -> Array:
	var mods := ModLoader.mods.map(func(m): return "%s@%s" % [m.id, m.get("version", "")])
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
	_own_edits[pos] = true
	_request_edit.rpc_id(1, pos, block)


@rpc("authority", "call_remote", "unreliable_ordered")
func _players_state(states: Dictionary) -> void:
	_player_count = states.size()
	_update_avatars(states)


# --- Host side -----------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _hello(protocol: int, mods: Array, requested_name: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var reason := ""
	if protocol != PROTOCOL:
		reason = "Game version mismatch (server protocol %d, yours %d)." % [PROTOCOL, protocol]
	elif mods != mod_list():
		reason = "Your mods don't match the server's.\nServer: %s\nYours: %s" % [
				", ".join(mod_list()), ", ".join(mods)]
	if reason != "":
		print("Rejected peer %d: %s" % [id, reason])
		_rejected.rpc_id(id, reason)
		# Give the message time to arrive before dropping the connection.
		get_tree().create_timer(1.0).timeout.connect(_kick.bind(id))
		return

	var pname := requested_name.strip_edges().left(16)
	if pname == "":
		pname = "Player %d" % id
	var spawn := local_player.global_position + Vector3(2, 0, 2)

	# Reliable messages on one channel arrive in order, so the client has the
	# world before any later block edit reaches it.
	_welcome.rpc_id(id, {
		"block_ids": Array(Registry.block_ids),
		"view_distance": world.view_distance,
		"spawn": [spawn.x, spawn.y, spawn.z],
		"seed": int(world.meta.seed),
		"generator": int(world.meta.get("generator", 1)),
		"mode": world.meta.get("mode", "survival"),
		"chunks": world.edited_chunks(),  # {Vector3i: PackedByteArray}
		"time": day_cycle.time if day_cycle else DayCycle.START_TIME,
		"day_length": day_cycle.day_length if day_cycle else DayCycle.DEFAULT_DAY_LENGTH,
	})
	if not world.block_changed.is_connected(_on_block_changed):
		world.block_changed.connect(_on_block_changed)

	_peers[id] = {"name": pname, "position": spawn, "yaw": 0.0}
	print("%s joined (peer %d)" % [pname, id])


func _kick(id: int) -> void:
	if is_host() and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if not _peers.has(id):
		return
	print("%s left" % _peers[id].name)
	_peers.erase(id)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _client_state(pos: Vector3, yaw: float, light: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id) or not pos.is_finite():
		return
	var p: Dictionary = _peers[id]
	p.position = pos
	p.yaw = yaw
	p.light = clampi(light, 0, 15)


@rpc("any_peer", "call_remote", "reliable")
func _request_edit(pos: Vector3i, block: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id):
		return
	if block < 0 or block >= Registry.block_ids.size():
		return
	var def = Registry.blocks.get(Registry.block_ids[block])
	if block != Registry.block_index("core:air") and (def == null or not def.get("solid", true)):
		return  # unknown/missing or non-placeable block
	var player_pos: Vector3 = _peers[id].position
	if player_pos.distance_to(Vector3(pos) + Vector3.ONE * 0.5) > EDIT_REACH:
		return
	if block != Registry.block_index("core:air"):
		for state in _host_states().values():  # nobody may get built into a block
			if Player.overlaps_block(state[0] - Vector3(0, Player.EYE_HEIGHT, 0), pos):
				return
	var old := world.get_block(pos)
	world.editor = id  # spilled container contents go to this player
	var ok := world.set_block(pos, block)  # -> block_changed -> sent to everyone
	world.editor = 0
	if ok:
		remote_edit.emit(pos, old, block)


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
	if not is_host() or mobs == null or not _peers.has(peer):
		return
	var from: Vector3 = _peers[peer].position
	for mob in mobs.mobs():
		if mob.id == id and mob.global_position.distance_to(from) <= MOB_REACH:
			mobs.hit(id, from, peer, load("res://src/player/player.gd").attack_damage(item))
			return


## Host: give a player items to drop at a position (container contents, creature drops).
func give_drops(peer: int, at: Vector3, items: Array) -> void:
	if peer != 0 and _peers.has(peer):
		_drops.rpc_id(peer, at, items)


@rpc("authority", "call_remote", "reliable")
func _drops(at: Vector3, items: Array) -> void:
	drops_received.emit(at, items)


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


func _can_reach(id: int, pos: Vector3i) -> bool:
	return _peers.has(id) and (_peers[id].position as Vector3).distance_to(Vector3(pos) + Vector3.ONE * 0.5) <= CONTAINER_REACH


@rpc("any_peer", "call_remote", "reliable")
func _open_container(pos: Vector3i) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not world.block_entities.has_entity(pos) or not _can_reach(id, pos):
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
	if not is_host() or not _can_reach(id, pos):
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
	if is_host() and _peers.has(id):
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
	if is_client() and not _welcomed and not _ended \
			and Time.get_ticks_msec() - _connect_started > CONNECT_TIMEOUT_MS:
		_end("Connection timed out.")
		return
	if is_host() and day_cycle and not _peers.is_empty():
		_time_sync_timer += delta
		if _time_sync_timer >= TIME_SYNC_SECONDS:
			_time_sync_timer = 0.0
			_time.rpc(day_cycle.time)
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
