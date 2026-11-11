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
##   - survival inventories: the host keeps every joining player's (saved in
##     its world by player name). A client does each inventory action at once
##     and tells the host, which does the same to its copy where allowed and
##     sends the result back (see inventory_action); breaking and tilling drop
##     what the host decides, and placing takes the item from the host's copy
##   - survival health and mining: the host keeps each joining player's health
##     (falls, lava and drowning from where it says it is, creatures, healing,
##     food) and sends it; a break happens no sooner than the block's mining
##     time after the client said it started (start_mining)
##
## Mods: both sides must play with the same mods (id, version and files).
## A player whose mods differ is offered the host's: after they agree
## (mods_offered), they download the ones they lack (in parts, checked against
## the fingerprint) and the game restarts with exactly the host's mods
## (mods_ready, ModLoader.restart). Mods are sandboxed (see mod_sandbox.gd);
## a different core (another game version) is still refused.

signal welcomed(info: Dictionary)  # client: host accepted us, build the world
## Client: the host plays with other mods. `missing`: {entry: bytes} to download
## (may be empty: we have them all). Answer with download_mods() or leave().
signal mods_offered(missing: Dictionary)
signal mods_progress(done: int, total: int)  # client: bytes downloaded so far
## Client: every mod of the host's list is here: restart with `entries`.
signal mods_ready(entries: Array)
signal ended(reason: String)       # client: connection failed / rejected / lost
## Another player changed a block (for sounds): old and new block index.
signal remote_edit(position: Vector3i, old_block: int, new_block: int)
## Client: the host applied a block change we asked for (drop what we broke).
signal own_edit_confirmed(position: Vector3i)
## Client: the host refused a block change we asked for (nothing was broken).
signal own_edit_refused(position: Vector3i)
## Client: the host refused a placement: give back the item it used up.
signal placement_refused(item: String)
## Client: the host gave us a dropped item we asked for. `add`: put it in the
## inventory ourselves (creative); otherwise the host's inventory has it.
signal items_picked(item: String, count: int, add: bool)
## Client in survival: the host's copy of our inventory (Inventory.snapshot),
## once it has done every action we sent.
signal inventory_synced(data: Array)
## Client in survival: our health as the host has it.
signal health_synced(health: int)
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
const Vitals := preload("res://src/net/vitals.gd")

const PROTOCOL := 8
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
var _inventory_seq := 0      # client: inventory actions sent (the host answers with the last it did)
var _host_owns_inventory := false  # client: survival (from the welcome)
var held_light := 0         # light level of what the local player holds (a torch: 13); set by main
## How the local player looks to others (set by main every frame): head pitch,
## held item, Avatar.FLAG_* (sneaking, asleep, flying), swing counter.
var local_pose := {"pitch": 0.0, "item": "", "flags": 0, "swings": 0}
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
var _placements := {}  # client: placement number -> {item, cells, time}, until the host answers
var _next_placement := 1
const MAX_PLACEMENT_CELLS := 4
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
## Host: walls. A move is followed in steps of WALL_STEP blocks with a thinner
## body (WALL_GRACE off each side, top and bottom), so a corner cut between two
## updates passes but no step may go through a block (even a door is thicker).
const WALL_STEP := 0.1
const WALL_GRACE := 0.15
## Host: how many requests of each kind a client may send per second, and in
## one burst (lag can bunch them up). Requests over the limit are ignored.
const RATES := {
	"edit": [20.0, 40.0],       # breaking and placing (creative mines fast; doors and beds are two)
	"hit": [8.0, 12.0],
	"chunk": [30.0, 120.0],
	"pickup": [20.0, 60.0],
	"container": [20.0, 40.0],
	"other": [4.0, 10.0],       # bed, sleeping
	"inventory": [30.0, 60.0],  # clicks in the inventory, crafting, eating
	"mine": [20.0, 40.0],       # starting to mine a block
}
## Host: a survival break happens no sooner than this share of the block's
## mining time (Player.mine_seconds) after the client started mining it, less
## MINE_LAG seconds (the two messages may travel at different speeds). One
## that comes sooner (a stall here, or a cheat) waits until then.
const MINE_SLACK := 0.8
const MINE_LAG := 0.1
const NAME_LENGTH := 16
const MAX_MODS := 256             # longest mod list accepted in a hello
const MOD_PART := 60000           # bytes per message of a mod download
const MAX_MOD_DOWNLOAD := 64 << 20  # most bytes of mods a player downloads to join
const MOD_PARTS_PER_SECOND := 80.0  # host: parts sent to one player per second at most

## This game's mods ("id@version#fingerprint") and, for the host, their folders.
var my_mods: Array = mod_list()
var _mod_paths := {}
var _offered := {}    # host: peer id -> {tokens, time}, players we offered our mods to
var _zips := {}       # host: entry -> the mod folder zipped (made once)
var _host_mods: Array = []  # client: the host's mod list, when offered
var _downloads := {}  # client: entry -> {parts, data: PackedByteArray, size}


# --- Setup / teardown ----------------------------------------------------------

func host(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	# Everything goes through the host: clients needn't hear of each other
	# (nor a player being turned away of the others).
	(multiplayer as SceneMultiplayer).server_relay = false
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
	var mods := ModLoader.mods.map(ModLoader.entry_of)
	mods.sort()
	return mods


func _init() -> void:
	for m in ModLoader.mods:
		_mod_paths[ModLoader.entry_of(m)] = m.path


func _end(reason: String) -> void:
	if _ended:
		return
	_ended = true
	ended.emit(reason)


# --- Client side ---------------------------------------------------------------

func _on_connected() -> void:
	_hello.rpc_id(1, PROTOCOL, my_mods, player_name)


func _on_connection_failed() -> void:
	_end("Couldn't connect to the server.")


func _on_server_disconnected() -> void:
	_end("The server closed the connection.")


@rpc("authority", "call_remote", "reliable")
func _welcome(info: Dictionary) -> void:
	_welcomed = true
	_host_owns_inventory = str(info.get("mode", "survival")) != "creative"
	welcomed.emit(info)


@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_end(reason)


@rpc("authority", "call_remote", "reliable")
func _offer_mods(entries: Array, sizes: Dictionary) -> void:
	if not is_client() or not entries.all(func(e): return e is String and e.length() <= 200) \
			or entries.size() > MAX_MODS:
		return
	if entries == ModLoader.server_mods:
		_end("Still not the server's mods after restarting with them; check the log.")
		return
	_host_mods = entries
	var missing := {}
	var total := 0
	for entry in entries:
		if ModLoader.entry_id(entry) == ModLoader.CORE_ID or ModLoader.local_copy(entry) != "":
			continue
		if not ModLoader._id_regex.search(ModLoader.entry_id(entry)) or not ModLoader.entry_hash(entry).is_valid_hex_number():
			_end("The server sent a bad mod list.")
			return
		missing[entry] = int(sizes.get(entry, 0))
		total += missing[entry]
	if total > MAX_MOD_DOWNLOAD:
		_end("The server's mods are too big to download (%d MB)." % (total >> 20))
		return
	mods_offered.emit(missing)


## Client: the player agreed to the host's mods: fetch what's missing (then
## mods_ready).
func download_mods() -> void:
	for entry in _host_mods:
		if ModLoader.entry_id(entry) != ModLoader.CORE_ID and ModLoader.local_copy(entry) == "":
			_downloads[entry] = {"parts": -1, "data": PackedByteArray()}
			_request_mod_part.rpc_id(1, entry, 0)
	if _downloads.is_empty():
		mods_ready.emit(_host_mods)


@rpc("authority", "call_remote", "reliable")
func _mod_part(entry: String, part: int, parts: int, data: PackedByteArray) -> void:
	if not is_client() or not _downloads.has(entry):
		return
	var d: Dictionary = _downloads[entry]
	if d.parts == -1:
		d.parts = parts
	if part != d.data.size() / MOD_PART or parts != d.parts or parts * MOD_PART > MAX_MOD_DOWNLOAD + MOD_PART \
			or (part < parts - 1 and data.size() != MOD_PART):
		_end("A mod download from the server went wrong.")
		return
	d.data.append_array(data)
	var done := 0
	for e in _downloads:
		done += _downloads[e].data.size()
	mods_progress.emit(done, done + _downloads.values().reduce(func(acc, x):
		return acc + (0 if x.parts == -1 else maxi(0, x.parts * MOD_PART - x.data.size())), 0))
	if part < parts - 1:
		_request_mod_part.rpc_id(1, entry, part + 1)
		return
	var problem := _unpack_mod(entry, d.data)
	if problem != "":
		_end("The server's mod %s: %s" % [ModLoader.entry_id(entry), problem])
		return
	d.done = true
	if _downloads.values().all(func(x): return x.get("done", false)):
		mods_ready.emit(_host_mods)


## Puts a downloaded mod zip in the server mod cache; "" or what's wrong.
static func _unpack_mod(entry: String, data: PackedByteArray) -> String:
	var dir := ModLoader.cache_dir(entry)
	DirAccess.make_dir_recursive_absolute(ModLoader.SERVER_DIR)
	var zip := dir + ".zip"
	var f := FileAccess.open(zip, FileAccess.WRITE)
	if f == null:
		return "can't write " + zip
	f.store_buffer(data)
	f.close()
	var problem := ModLoader.unzip_mod(zip, dir)
	DirAccess.remove_absolute(zip)
	if problem == "":
		var m = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("mod.json")))
		if not m is Dictionary or m.get("id") != ModLoader.entry_id(entry):
			problem = "its mod.json doesn't match"
		elif ModLoader.fingerprint(dir) != ModLoader.entry_hash(entry):
			problem = "its files don't match its fingerprint"
	if problem != "":
		ModLoader._remove_dir(dir)
	return problem


## Clients ask the host to change a block; the host validates and applies it.
## `slot`: the inventory slot holding the tool used (what breaking drops).
func request_edit(pos: Vector3i, block: int, slot: int = -1) -> void:
	_own_edits[pos] = _now()
	_request_edit.rpc_id(1, pos, block, slot)


## Client in survival: we started mining the block at `pos` (the break comes
## once it has taken long enough, see _mining_wait).
func start_mining(pos: Vector3i) -> void:
	_mining.rpc_id(1, pos)


## Client: we came back to life (the death screen's button).
func respawned() -> void:
	if is_client():
		_respawned.rpc_id(1)


@rpc("authority", "call_remote", "reliable")
func _health(h: int) -> void:
	health_synced.emit(h)


## Client in survival: tell the host about an inventory action we did
## (Inventory.on_action). Numbered, so we know when its copy has caught up.
func inventory_action(action: Array) -> void:
	_inventory_seq += 1
	_inventory_action.rpc_id(1, _inventory_seq, action)


func _next_inventory_seq() -> int:
	_inventory_seq += 1
	return _inventory_seq


## Client: the host's copy of our inventory after action `done`. Shown only
## when no action of ours is still on its way (it would be undone for a moment).
@rpc("authority", "call_remote", "reliable")
func _inventory(done: int, data: Array) -> void:
	if done >= _inventory_seq:
		inventory_synced.emit(data)


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
## together pass) and is spent by moving; the way there mustn't go through
## blocks. Respawning jumps to the world spawn (or the player's bed).
## `flags`: the new Avatar.FLAG_*.
func _move_allowed(p: Dictionary, pos: Vector3, flags: int = 0) -> bool:
	var now := _now()
	var budget: Vector3 = p.get("budget", Vector3.ZERO) + _move_speeds() * (now - float(p.get("time", now)))
	budget = budget.min(_move_cap())
	p.time = now
	var d: Vector3 = pos - (p.position as Vector3)
	var cost := Vector3(Vector2(d.x, d.z).length(), maxf(d.y, 0.0), maxf(-d.y, 0.0))
	if cost.x <= budget.x and cost.y <= budget.y and cost.z <= budget.z \
			and ((int(p.get("flags", 0)) | flags) & Avatar.FLAG_SLEEP != 0  # into or out of bed: eyes low
				or _way_clear(p.position, pos, p)):
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


## Host: whether a body can get from eye position `from` to `to` without going
## through blocks. Where the host hasn't loaded the chunks it can't tell, so
## no (it keeps chunks loaded around every player, so that's only for a moment
## after a long jump). A body in a block (one appeared there) may get out, but
## only within ESCAPE_DISTANCE of where it got stuck (`p.stuck_at`, kept until
## it is out), and once out the rest of the way must be clear: being stuck
## doesn't let it tunnel on through walls.
const ESCAPE_DISTANCE := 1.5


func _way_clear(from: Vector3, to: Vector3, p: Dictionary = {}) -> bool:
	var feet := Vector3(0, Player.EYE_HEIGHT - WALL_GRACE, 0)
	var body := Player.BODY - Vector3.ONE * WALL_GRACE * 2.0
	var a := from - feet
	var b := to - feet
	var lo := a.min(b) - Vector3(Player.RADIUS, 1, Player.RADIUS)
	var hi := a.max(b) + Vector3(Player.RADIUS, Player.HEIGHT + 1, Player.RADIUS)
	var c0 := World.chunk_of(Vector3i(lo.floor()))
	var c1 := World.chunk_of(Vector3i(hi.floor()))
	for cx in range(c0.x, c1.x + 1):
		for cy in range(maxi(c0.y, World.CHUNK_Y_MIN), mini(c1.y, World.CHUNK_Y_MAX) + 1):
			for cz in range(c0.z, c1.z + 1):
				if not world.engine.is_chunk_loaded(Vector3i(cx, cy, cz)):
					return false
	var stuck_at = p.get("stuck_at")
	if world.is_box_free(a, body):
		stuck_at = null
	elif stuck_at == null:
		stuck_at = from  # it just got stuck here
	var escaping: bool = stuck_at != null
	var steps := ceili(a.distance_to(b) / WALL_STEP)
	for i in range(1, steps + 1):
		var at := a.lerp(b, float(i) / steps)
		var free := world.is_box_free(at, body)
		if escaping and free:
			escaping = false  # out: from here on the way must be clear
		elif escaping and (at + feet).distance_to(stuck_at) > ESCAPE_DISTANCE:
			return false
		elif not escaping and not free:
			return false
	if escaping:
		p.stuck_at = stuck_at  # still in a block
	else:
		p.erase("stuck_at")
	return true


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
	elif mods != my_mods:
		var core := func(list: Array): return list.filter(func(e): return ModLoader.entry_id(e) == ModLoader.CORE_ID)
		if core.call(mods) != core.call(my_mods):
			reason = "Game version mismatch (the base game's files differ from the server's)."
		else:
			_offer(id)
			return
	if reason != "":
		print("Rejected peer %d: %s" % [id, reason])
		_rejected.rpc_id(id, reason)
		# Give the message time to arrive before dropping the connection.
		get_tree().create_timer(1.0).timeout.connect(_kick.bind(id))
		return

	var pname := clean_name(requested_name)
	if pname == "":
		pname = "Player %d" % id
	if _peers.values().any(func(p): return p.name == pname):
		# Survival inventories are kept by name: one player per name.
		_rejected.rpc_id(id, "Someone called %s is already playing here: pick another name." % pname)
		get_tree().create_timer(1.0).timeout.connect(_kick.bind(id))
		return
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
	if world.meta.get("mode", "survival") != "creative":
		# Survival: the host keeps the player's inventory (back from last time).
		var inv := Inventory.new()
		var saved = world.meta.get("players", {}).get(pname, {}).get("inventory")
		if saved is Array:
			inv.deserialize(saved)
		else:
			for i in Player.STARTING_ITEMS.size():
				inv.slots[i] = Player.STARTING_ITEMS[i].duplicate()
		_peers[id].inv = inv
		_peers[id].done = 0
		_peers[id].inv_changed = true  # sent with the next update
		var vitals := Vitals.new()  # and its health (full after dying)
		var health = world.meta.get("players", {}).get(pname, {}).get("health")
		if health is int or health is float:
			vitals.health = clampi(int(health), 1, Player.MAX_HEALTH)
		_peers[id].vitals = vitals
	print("%s joined (peer %d)" % [pname, id])


## Host: keeps every joined player's inventory in the world's meta (saved
## with it), by name. What the mouse holds goes back in first.
func store_inventories() -> void:
	for id in _peers:
		_store_inventory(_peers[id])


func _store_inventory(p: Dictionary) -> void:
	var inv: Inventory = p.get("inv")
	if inv == null:
		return
	var copy := Inventory.new()
	copy.deserialize(inv.serialize())
	if not inv.cursor.is_empty():
		copy.add(inv.cursor.id, inv.cursor.count)
	if not world.meta.has("players"):
		world.meta.players = {}
	world.meta.players[p.name] = {"inventory": copy.serialize()}
	if p.has("vitals") and not p.vitals.dead:
		world.meta.players[p.name].health = p.vitals.health


## Host: a client's inventory action (Inventory.apply_action on our copy).
## Every numbered request is counted as done, refused or not, so the client
## knows when our copy has caught up with it.
@rpc("any_peer", "call_remote", "reliable")
func _inventory_action(seq: int, action: Array) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id):
		return
	_done(id, seq)
	var inv: Inventory = _peers[id].get("inv")
	if inv == null or not _allow(id, "inventory"):
		return
	var vitals: Vitals = _peers[id].vitals
	if action.size() == 2 and action[0] is String and action[0] == "eat":
		# Only when hurt (and alive), and the food heals here.
		var food: Dictionary = Registry.items.get(inv.slots[action[1]].get("id", ""), {}) \
				if action[1] is int and action[1] >= 0 and action[1] < Inventory.SIZE else {}
		if not food.has("food") or vitals.dead or vitals.health >= Player.MAX_HEALTH:
			return
		vitals.heal(int(food.food))
	var left := inv.apply_action(action)
	if not left.is_empty() and drops and valid_stack(left):
		drops.spawn(left.id, left.count, (_peers[id].position as Vector3) - Vector3(0, 1.0, 0))


func _done(id: int, seq: int) -> void:
	var p: Dictionary = _peers[id]
	if p.has("inv"):
		p.done = seq
		p.inv_changed = true


## Host: calls `method` (an rpc) on every player we accepted (not on one we
## turned away and are about to drop, nor on one still saying hello).
func _to_players(method: Callable, a = null, b = null) -> void:
	for id in _peers:
		if id not in multiplayer.get_peers():
			continue
		if a == null:
			method.rpc_id(id)
		elif b == null:
			method.rpc_id(id, a)
		else:
			method.rpc_id(id, a, b)


## Host: what a survival client holds (its selected slot in our copy).
func _held_item(id: int) -> String:
	var p: Dictionary = _peers[id]
	var inv: Inventory = p.get("inv")
	return inv.slots[int(p.get("selected", 0))].get("id", "") if inv else str(p.get("item", ""))


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


## Host: a player with other mods may download ours (see _request_mod_part).
func _offer(id: int) -> void:
	var sizes := {}
	for entry in my_mods:
		if ModLoader.entry_id(entry) != ModLoader.CORE_ID:
			sizes[entry] = _mod_zip(entry).size()
	_offered[id] = {"tokens": MOD_PARTS_PER_SECOND, "time": _now()}
	print("Peer %d has other mods; offering ours" % id)
	_offer_mods.rpc_id(id, my_mods, sizes)


## One of our mods' folder as a zip (the same files its fingerprint covers).
func _mod_zip(entry: String) -> PackedByteArray:
	if _zips.has(entry):
		return _zips[entry]
	var root: String = _mod_paths.get(entry, "")
	var tmp := ModLoader.USER_DIR.path_join(".outgoing_%d.zip" % get_instance_id())
	var zip := ZIPPacker.new()
	var data := PackedByteArray()
	if root != "" and zip.open(tmp) == OK:
		for rel in ModLoader._files_under(root, ""):
			zip.start_file(rel)
			zip.write_file(FileAccess.get_file_as_bytes(root.path_join(rel)))
			zip.close_file()
		zip.close()
		data = FileAccess.get_file_as_bytes(tmp)
		DirAccess.remove_absolute(tmp)
	_zips[entry] = data
	return data


@rpc("any_peer", "call_remote", "reliable")
func _request_mod_part(entry, part) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _offered.has(id) or not entry is String or not part is int:
		return
	if not entry in my_mods or ModLoader.entry_id(entry) == ModLoader.CORE_ID:
		return
	var o: Dictionary = _offered[id]  # rate limit (token bucket)
	var now := _now()
	o.tokens = minf(MOD_PARTS_PER_SECOND, o.tokens + (now - o.time) * MOD_PARTS_PER_SECOND)
	o.time = now
	if o.tokens < 1.0:
		if o.get("waiting", 0) < MAX_MODS:  # answered a little later (a flood is dropped)
			o.waiting = o.get("waiting", 0) + 1
			get_tree().create_timer(0.1).timeout.connect(func():
				if _offered.has(id):
					o.waiting -= 1
					_request_mod_part_later(id, entry, part))
		return
	o.tokens -= 1.0
	_send_mod_part(id, entry, part)


func _request_mod_part_later(id: int, entry: String, part: int) -> void:
	if id in multiplayer.get_peers():
		_send_mod_part(id, entry, part)


func _send_mod_part(id: int, entry: String, part: int) -> void:
	var data := _mod_zip(entry)
	var parts := maxi(1, ceili(data.size() / float(MOD_PART)))
	if part < 0 or part >= parts:
		return
	_mod_part.rpc_id(id, entry, part, parts, data.slice(part * MOD_PART, (part + 1) * MOD_PART))


func _kick(id: int) -> void:
	if is_host() and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	_offered.erase(id)
	if not _peers.has(id):
		return
	print("%s left" % _peers[id].name)
	_store_inventory(_peers[id])
	_peers.erase(id)
	for pos in _viewers:
		_viewers[pos].erase(id)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _client_state(pos: Vector3, yaw: float, pitch: float, item: String, flags: int, swings: int,
		selected: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id) or not pos.is_finite() or not is_finite(yaw) or not is_finite(pitch):
		return
	var p: Dictionary = _peers[id]
	if not _move_allowed(p, pos, flags):
		if _now() - float(p.get("corrected", -INF)) >= CORRECT_EVERY:
			p.corrected = _now()
			_correct.rpc_id(id, p.position)
		return
	p.position = pos
	p.yaw = wrapf(yaw, -PI, PI)
	p.pitch = clampf(pitch, -PI / 2, PI / 2)
	p.selected = clampi(selected, 0, Inventory.HOTBAR - 1)
	# Only a real item (survival: the one in its hand in our copy); its light
	# comes from its definition, not from the client.
	p.item = item if valid_stack({"id": item, "count": 1}) else ""
	if p.has("inv"):
		p.item = _held_item(id)
	p.light = clampi(int(Registry.blocks.get(p.item, {}).get("light", 0)), 0, 15)
	p.flags = flags & 7
	p.swings = swings
	if p.has("vitals"):
		p.vitals.moved(world, pos - Vector3(0, Player.EYE_HEIGHT, 0),
				p.flags & (Avatar.FLAG_FLY | Avatar.FLAG_SLEEP) != 0)


@rpc("any_peer", "call_remote", "reliable")
func _request_edit(pos: Vector3i, block: int, slot: int) -> void:
	_edit_for(multiplayer.get_remote_sender_id(), pos, block, slot)


## `mined`: a break that waited for its mining time (see _mining_wait).
func _edit_for(id: int, pos: Vector3i, block: int, slot: int, mined := false) -> void:
	if not is_host() or not _peers.has(id):
		return
	if not _edit_allowed(id, pos, block):
		_edit_refused.rpc_id(id, pos)  # so it doesn't wait for an answer
		return
	var old := world.get_block(pos)
	var inv: Inventory = _peers[id].get("inv")
	var drops_here := []
	if inv:  # survival: only what needs no item, and the host decides the drops
		var tool: String = inv.slots[slot].get("id", "") if slot >= 0 and slot < Inventory.SIZE else ""
		var kind := _survival_edit(pos, old, block, tool)
		if kind == "":
			_edit_refused.rpc_id(id, pos)
			return
		if kind == "same":  # (the other half of a door or bed we broke along with it)
			_block.rpc_id(id, pos, old)
			return
		if kind == "break" and not mined:
			var wait := _mining_wait(id, pos, old, tool)
			if wait < 0.0:  # it isn't mining that block
				_edit_refused.rpc_id(id, pos)
				return
			if wait > 0.0:
				get_tree().create_timer(wait).timeout.connect(_edit_for.bind(id, pos, block, slot, true))
				return
		if kind == "break":
			drops_here = [Vector3(pos) + Vector3.ONE * 0.5, Player.drops_of(Registry.block_ids[old], tool)]
		elif kind == "till":
			drops_here = [Vector3(pos) + Vector3(0.5, 1.2, 0.5), Player.till_drops_of(Registry.block_ids[old])]
	var ok := world.set_block(pos, block)  # -> block_changed -> sent to everyone
	if ok:
		remote_edit.emit(pos, old, block)
		if inv and block == 0:  # a door or bed goes as a whole (and drops once)
			var other = BlockShapes.other_part(Registry.block_ids[old], pos)
			if other != null and BlockShapes.base_of(Registry.block_ids[world.get_block(other)]) \
					== BlockShapes.base_of(Registry.block_ids[old]):
				world.set_block(other, 0)
		if drops and not drops_here.is_empty():
			for item in drops_here[1]:
				drops.spawn(item, 1, drops_here[0])
	else:
		_edit_refused.rpc_id(id, pos)  # its chunk isn't loaded here


## Host: a survival client started mining the block at `pos`.
@rpc("any_peer", "call_remote", "reliable")
func _mining(pos: Vector3i) -> void:
	var id := multiplayer.get_remote_sender_id()
	if is_host() and _peers.has(id) and _allow(id, "mine"):
		# (not before a break still waiting is done: one block at a time)
		_peers[id].mining = [pos, maxf(_now(), float(_peers[id].get("mined_at", 0.0)))]


## Host: how long peer `id`'s break of `pos` (block `old`, with `tool`) must
## still wait to have taken the block's mining time, or -1 if it isn't mining
## that block. Each start counts for one break.
func _mining_wait(id: int, pos: Vector3i, old: int, tool: String) -> float:
	var p: Dictionary = _peers[id]
	var m = p.get("mining")
	p.erase("mining")
	if m == null or m[0] != pos:
		return -1.0
	var at := float(m[1]) + Player.mine_seconds(Registry.block_ids[old], tool) * MINE_SLACK - MINE_LAG
	p.mined_at = maxf(at, _now())
	return maxf(0.0, at - _now())


## Host: whether a survival client is dead (until it respawns it does nothing).
func _is_dead(id: int) -> bool:
	return _peers.has(id) and _peers[id].has("vitals") and _peers[id].vitals.dead


## Host: a client came back to life after dying here.
@rpc("any_peer", "call_remote", "reliable")
func _respawned() -> void:
	var id := multiplayer.get_remote_sender_id()
	if is_host() and _is_dead(id):
		_peers[id].vitals.respawn()


## Host: what a survival client's edit of `pos` from `old` to `block` with
## `tool` in hand is: "break", "door", "till", "same" (nothing to change) or ""
## (not allowed: anything else needs an item, see _request_place).
func _survival_edit(pos: Vector3i, old: int, block: int, tool: String) -> String:
	var old_id: String = Registry.block_ids[old]
	var new_id: String = Registry.block_ids[block]
	if block == old:
		return "same"
	if block == 0:
		return "break" if not world.is_fluid(old) else ""
	for t in BlockShapes.toggle_door(old_id, pos):
		if t[0] == pos and t[1] == new_id:
			return "door"
	if new_id == "core:farmland" and old_id in ["core:grass", "core:dirt"] \
			and Player.tool_kind(tool) == "hoe" and world.get_block(pos + Vector3i.UP) == 0:
		return "till"
	return ""


## Host: whether peer `id` may set the block at pos (within its request rate,
## a known placeable block, within reach, nobody inside it).
func _edit_allowed(id: int, pos: Vector3i, block: int) -> bool:
	if not _allow(id, "edit") or block < 0 or block >= Registry.block_ids.size() or _is_dead(id):
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


## Client: ask the host to place blocks that go together ([[pos, block], ...]),
## all or none. `item` was used up from `slot` for them and comes back if it refuses.
func request_place(cells: Array, item: String, slot: int = -1) -> void:
	var n := _next_placement
	_next_placement += 1
	_placements[n] = {"item": item, "cells": cells, "time": _now()}
	for c in cells:
		_own_edits[c[0]] = _now()
	_request_place.rpc_id(1, n, cells, slot, _next_inventory_seq())


@rpc("any_peer", "call_remote", "reliable")
func _request_place(n: int, cells: Array, slot: int, seq: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id):
		return
	_done(id, seq)
	var ok := cells.size() >= 1 and cells.size() <= MAX_PLACEMENT_CELLS
	var seen := {}
	for c in cells:
		ok = ok and c is Array and c.size() == 2 and c[0] is Vector3i and c[1] is int and not seen.has(c[0]) \
				and c[1] != Registry.block_index("core:air") and _edit_allowed(id, c[0], c[1])
		if ok:
			seen[c[0]] = true
	# Survival: the blocks must come from the item in that slot (a bed's head
	# and foot from one bed), which is used up.
	var inv: Inventory = _peers[id].get("inv")
	if ok and inv:
		var item: String = inv.slots[slot].get("id", "") if slot >= 0 and slot < Inventory.SIZE else ""
		var plants: String = str(Registry.items.get(item, {}).get("plants", ""))
		ok = item != "" and cells.all(func(c):
				var block: String = Registry.block_ids[c[1]]
				return BlockShapes.base_of(block) == item or block == plants)
	var done := []  # [pos, old block] of what was set, to undo if one fails
	if ok:
		world.editor = id
		for c in cells:
			var old := world.get_block(c[0])
			if not world.set_block(c[0], c[1]):  # its chunk isn't loaded here
				ok = false
				break
			done.append([c[0], old])
		if not ok:
			for d in done:
				world.set_block(d[0], d[1])
		world.editor = 0
	if ok:
		if inv:
			inv.take_one(slot)
		for d in done:
			remote_edit.emit(d[0], d[1], world.get_block(d[0]))
	_placed.rpc_id(id, n, ok)


## Client: the host's answer to request_place.
@rpc("authority", "call_remote", "reliable")
func _placed(n: int, ok: bool) -> void:
	var p = _placements.get(n)
	if p == null:
		return
	_placements.erase(n)
	if not ok:
		for c in p.cells:
			_own_edits.erase(c[0])
		if p.item != "":
			placement_refused.emit(p.item)


## Client: the host didn't make a change we asked for.
@rpc("authority", "call_remote", "reliable")
func _edit_refused(pos: Vector3i) -> void:
	if _own_edits.erase(pos):
		own_edit_refused.emit(pos)


func _on_block_changed(pos: Vector3i, block: int) -> void:
	if is_host() and not _peers.is_empty():
		_to_players(_block, pos, block)


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
	return _peers.keys().filter(func(id): return not _is_dead(id)) \
			.map(func(id): return {"position": _peers[id].position, "peer": id})


## Host: a creature hit a joined player (survival: we take the health off,
## less its armour in our copy of its inventory).
func strike_player(peer: int, damage: int, push: Vector3) -> void:
	if not _peers.has(peer):
		return
	var p: Dictionary = _peers[peer]
	if p.has("vitals"):
		p.vitals.hurt(Player.armored(damage, (p.inv as Inventory).armor_points()))
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
	if not is_host() or mobs == null or not _allow(peer, "hit") or _is_dead(peer):
		return
	var from: Vector3 = _peers[peer].position
	if _peers[peer].get("inv"):
		item = _held_item(peer)  # survival: what it really holds
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
		_to_players(_time, day_cycle.time)
	_to_players(_wake_up)


@rpc("authority", "call_remote", "reliable")
func _wake_up() -> void:
	woken.emit()


# Dropped items: the host owns them all (ItemDrops), makes every one of them
# (what breaking drops, chests spilling, creatures) and sends their state to
# everyone; clients ask to pick them up.

## Client: ask the host for a dropped item we reached.
func request_pickup(drop_id: int) -> void:
	_request_pickup.rpc_id(1, drop_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(drop_id: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or drops == null or not _allow(id, "pickup") or _is_dead(id):
		return
	var inv: Inventory = _peers[id].get("inv")
	var d := drops.get_drop(drop_id)
	if inv and (d == null or not inv.can_fit(d.item)):
		return
	var at: Vector3 = d.global_position if d else Vector3.ZERO
	var got: Array = drops.take(drop_id, _peers[id].position)
	if got.is_empty():
		return
	var count: int = got[1]
	if inv:  # survival: into the host's copy; what doesn't fit stays on the ground
		var left := inv.add(got[0], count)
		if left > 0:
			drops.spawn(got[0], left, at)
		count -= left
		_peers[id].inv_changed = true
	_picked.rpc_id(id, got[0], count)


@rpc("authority", "call_remote", "reliable")
func _picked(item: String, count: int) -> void:
	items_picked.emit(item, count, not _host_owns_inventory)


@rpc("authority", "call_remote", "unreliable_ordered")
func _drops_state(states: Dictionary) -> void:
	if drops:
		drops.apply_states(states)


func open_container(pos: Vector3i) -> void:
	_open_container.rpc_id(1, pos)


func container_click(pos: Vector3i, slot: int, held: Dictionary) -> void:
	_container_click.rpc_id(1, pos, slot, held, _next_inventory_seq())


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
func _container_click(pos: Vector3i, slot: int, held: Dictionary, seq: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or not _peers.has(id):
		return
	_done(id, seq)
	# Survival: what the mouse holds is the host's (the inventory's cursor), not
	# what the client says.
	var inv: Inventory = _peers[id].get("inv")
	if inv:
		held = inv.cursor
	# Only a player who opened this container (and is still near it) may click
	# it, with a real item stack.
	if not _allow(id, "container") or id not in _viewers.get(pos, []) \
			or not world.block_entities.has_entity(pos) or not _can_reach(id, pos) or not valid_stack(held):
		_held.rpc_id(id, pos, held)  # refused: give it back
		return
	held = world.block_entities.click(pos, slot, held)
	if inv:
		inv.cursor = held
	_held.rpc_id(id, pos, held)


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
		states[1] = [local_player.global_position, local_player.global_rotation.y, player_name, held_light,
				float(local_pose.pitch), str(local_pose.item), int(local_pose.flags), int(local_pose.swings)]
	for id in _peers:
		var p: Dictionary = _peers[id]
		states[id] = [p.position, p.yaw, p.name, p.get("light", 0), p.get("pitch", 0.0), p.get("item", ""),
				p.get("flags", 0), p.get("swings", 0)]
	return states


# --- Both sides ----------------------------------------------------------------

func _process(delta: float) -> void:
	var t := FrameProfiler.begin()
	_process_step(delta)
	FrameProfiler.add(&"network", t)


func _process_step(delta: float) -> void:
	if is_client() and not _own_edits.is_empty():
		var now := _now()
		for pos in _own_edits.keys():
			if now - float(_own_edits[pos]) > EDIT_PENDING_SECONDS:
				_own_edits.erase(pos)  # never answered (lost with a reconnect, say)
				own_edit_refused.emit(pos)
		for n in _placements.keys():
			if now - float(_placements[n].time) > EDIT_PENDING_SECONDS * 6.0:
				_placements.erase(n)  # no answer at all: the connection is gone
	if is_client() and not _welcomed and not _ended and _host_mods.is_empty() \
			and Time.get_ticks_msec() - _connect_started > CONNECT_TIMEOUT_MS:
		_end("Connection timed out.")
		return
	if is_host() and day_cycle and not _peers.is_empty():
		_time_sync_timer += delta
		if _time_sync_timer >= TIME_SYNC_SECONDS:
			_time_sync_timer = 0.0
			_to_players(_time, day_cycle.time)
	if is_host() and world and world.engine:
		# Chunks stay loaded around every player (block data only), so their
		# moves, edits and health are checked against real blocks.
		world.engine.set_extra_viewers(PackedVector3Array(_peers.values().map(func(p): return p.position)))
	if is_host():
		for id in _peers:  # survival: our copy of a client's inventory changed
			var p: Dictionary = _peers[id]
			if p.get("inv_changed", false):
				p.inv_changed = false
				_inventory.rpc_id(id, int(p.done), (p.inv as Inventory).snapshot())
			var vitals: Vitals = p.get("vitals")
			if vitals:  # and its health
				var eye: Vector3 = p.position
				vitals.tick(world, eye - Vector3(0, Player.EYE_HEIGHT, 0), eye,
						int(p.get("flags", 0)) & Avatar.FLAG_SLEEP != 0, delta)
				if vitals.changed:
					vitals.changed = false
					_health.rpc_id(id, vitals.health)
	if is_host() and drops and not _peers.is_empty():
		_drop_timer += delta
		if _drop_timer >= DROP_INTERVAL:
			_drop_timer = 0.0
			_to_players(_drops_state, drops.states())
	if is_host() and mobs and not _peers.is_empty():
		_mob_timer += delta
		if _mob_timer >= MOB_INTERVAL:
			_mob_timer = 0.0
			_to_players(_mobs_state, mobs.states())
	_send_timer += delta
	if _send_timer < STATE_INTERVAL or local_player == null:
		return
	_send_timer = 0.0
	if is_host():
		var states := _host_states()
		_update_avatars(states)
		if not _peers.is_empty():
			_to_players(_players_state, states)
	elif is_client() and _welcomed:
		_client_state.rpc_id(1, local_player.global_position, local_player.global_rotation.y,
				float(local_pose.pitch), str(local_pose.item), int(local_pose.flags), int(local_pose.swings),
				int(local_pose.get("selected", 0)))


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
			avatar.setup(states[id][2], id, world.atlas)
			avatar.world = world
			avatar.position = states[id][0]
			world.add_child(avatar)
			_avatars[id] = avatar
		var st: Array = states[id]
		avatar.target_position = st[0]
		avatar.target_yaw = st[1]
		avatar.light = st[3]
		if st.size() >= 8:
			avatar.pitch = st[4]
			avatar.item = st[5]
			avatar.flags = st[6]
			avatar.swings = st[7]
	for id in _avatars.keys():
		if not states.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)
