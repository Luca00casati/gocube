class_name ItemDrops
extends Node3D
## Every item lying in the world (ItemDrop children), shared by all players.
##
## Single player and host: drops are simulated here (falling, merging, the
## local player picking them up). In multiplayer the host sends their state to
## the clients (Session, ~10 times a second). A client only shows them: new
## drops are asked of the host (request_spawn), and when the local player
## reaches one the client asks the host for it (request_pickup); whoever asks
## first gets it, so an item can't be picked up twice.

signal picked_up(item: String, count: int)

const MERGE_DISTANCE := 0.8
## Host: how close a client must be (eye to drop) to be given a drop.
const PEER_PICKUP_REACH := 4.5  # generous: the host sees players a little late

var world: World
var player: Node3D           # the local player (player.gd), picks up drops
var remote := false          # multiplayer client: drops mirror the host's
var request_spawn: Callable  # client: (item, count, at) -> asks the host to drop it
var request_pickup: Callable # client: (drop id) -> asks the host for it

var _next_id := 1
var _by_id := {}             # id -> ItemDrop


## Drops `count` of `item` at `at` (merged with the same item lying close by).
func spawn(item: String, count: int, at: Vector3) -> void:
	if count <= 0 or item == "":
		return
	if remote:
		request_spawn.call(item, count, at)
		return
	for d in _by_id.values():
		if d.item == item and d.global_position.distance_to(at) < MERGE_DISTANCE and not d.is_queued_for_deletion():
			d.count += count
			return
	var d := _add(_next_id, item, count, at)
	d.velocity = Vector3(randf_range(-1.5, 1.5), 3.0, randf_range(-1.5, 1.5))
	_next_id += 1


func count() -> int:
	return _by_id.size()


func get_drop(id: int) -> ItemDrop:
	return _by_id.get(id)


## Host: {id: [item, count, position]} of every drop, for the clients.
func states() -> Dictionary:
	var out := {}
	for id in _by_id:
		var d: ItemDrop = _by_id[id]
		if not d.is_queued_for_deletion():
			out[id] = [d.item, d.count, d.global_position]
	return out


## Client: show the host's drops (add new ones, move and update the rest,
## remove those that are gone).
func apply_states(states: Dictionary) -> void:
	for id in _by_id.keys():
		if not states.has(id):
			_by_id[id].queue_free()
			_by_id.erase(id)
	for id in states:
		var s: Array = states[id]
		if s.size() != 3 or not s[2] is Vector3:
			continue
		var d: ItemDrop = _by_id.get(id)
		if d == null:
			d = _add(id, str(s[0]), int(s[1]), s[2])
		elif d.item != str(s[0]):
			d.queue_free()
			d = _add(id, str(s[0]), int(s[1]), s[2])
		d.count = int(s[1])
		d.target_position = s[2]


## Host: a client at `from` (its eye) wants drop `id`. Returns [item, count]
## and removes the drop, or [] if it's gone or too far.
func take(id: int, from: Vector3) -> Array:
	var d: ItemDrop = _by_id.get(id)
	if d == null or d.is_queued_for_deletion() or d.global_position.distance_to(from) > PEER_PICKUP_REACH:
		return []
	_by_id.erase(id)
	d.queue_free()
	return [d.item, d.count]


func _add(id: int, item: String, count: int, at: Vector3) -> ItemDrop:
	var d := ItemDrop.new()
	d.drop_id = id
	d.setup(item, count, world.atlas if world else null)
	d.world = world
	d.player = player
	d.remote = remote
	d.target_position = at
	if remote:
		d.request_pickup = func(drop_id: int): request_pickup.call(drop_id)
	d.picked_up.connect(func(i, n): picked_up.emit(i, n))
	d.tree_exiting.connect(func():
		if _by_id.get(id) == d:
			_by_id.erase(id))
	_by_id[id] = d
	add_child(d)
	d.global_position = at
	return d


## The local player changed (spawned, respawned in a new game).
func set_player(p: Node3D) -> void:
	player = p
	for d in _by_id.values():
		d.player = p
