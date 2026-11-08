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

const Avatar := preload("res://src/player/avatar.gd")
const Player := preload("res://src/player/player.gd")

const PROTOCOL := 1
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
var player_name := "Player"
## Time of day; the host's is authoritative.
var day_cycle: DayCycle

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
func _client_state(pos: Vector3, yaw: float) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id) or not pos.is_finite():
		return
	var p: Dictionary = _peers[id]
	p.position = pos
	p.yaw = yaw


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
	world.set_block(pos, block)  # -> block_changed -> sent to everyone (fails if not loaded)


func _on_block_changed(pos: Vector3i, block: int) -> void:
	if is_host() and not _peers.is_empty():
		_block.rpc(pos, block)


## Client: a block changed on the host.
@rpc("authority", "call_remote", "reliable")
func _block(pos: Vector3i, block: int) -> void:
	if world and not world.apply_remote_block(pos, block):
		_request_chunk.rpc_id(1, World.chunk_of(pos))  # not loaded here: get the whole chunk


## Client: the host's time of day (snap only if we drifted noticeably).
@rpc("authority", "call_remote", "unreliable_ordered")
func _time(host_time: float) -> void:
	if day_cycle:
		var drift := absf(wrapf(host_time - day_cycle.time, -0.5, 0.5))
		if drift > 0.0005:  # ~0.6 s with a 20-minute day
			day_cycle.time = host_time


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
		states[1] = [local_player.global_position, local_player.global_rotation.y, player_name]
	for id in _peers:
		states[id] = [_peers[id].position, _peers[id].yaw, _peers[id].name]
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
		_client_state.rpc_id(1, local_player.global_position, local_player.global_rotation.y)


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
	for id in _avatars.keys():
		if not states.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)
