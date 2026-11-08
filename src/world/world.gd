class_name World
extends Node3D
## A saved world on the native engine (GoCubeWorld). Call build() after mods load.
##
## user://worlds/<name>/
##   world.json   seed, block id table, player state (written atomically)
##   chunks/      chunks the player edited; everything else is regenerated
##                from the seed, so this stays small.

const WORLDS_DIR := "user://worlds"
## 2 = native engine (chunks/). 1 = voxel-module worlds (blocks.sqlite), whose
## edits can't be carried over: their terrain generator was different.
const FORMAT_VERSION := 2
const DEFAULT_VIEW_DISTANCE := 128  # 256 halves FPS on an Intel HD 4600
const CHUNK_SIZE := 32

## A block changed through set_block() (the host forwards these to clients).
signal block_changed(position: Vector3i, block: int)

var engine: GoCubeWorld
## Contents of world.json. "player" is whatever the game passed to save().
var meta: Dictionary = {}
var dir := ""
## True on a multiplayer client: the host's edits come over the network,
## nothing is saved here.
var remote := false
var view_distance := DEFAULT_VIEW_DISTANCE
var atlas: BlockAtlas
var terrain_material: ShaderMaterial
var fluid_material: ShaderMaterial
## Block index -> true, for fluid blocks (swimming, underwater view).
var fluid_ids := {}


## persistent=false runs the world without reading or writing anything (benchmarks).
## new_mode ("survival" / "creative") applies to new worlds only.
func build(world_name: String, distance: int = DEFAULT_VIEW_DISTANCE, new_seed: int = -1,
		persistent: bool = true, new_mode: String = "survival") -> void:
	if persistent:
		dir = WORLDS_DIR.path_join(world_name)
		DirAccess.make_dir_recursive_absolute(dir.path_join("chunks"))
		meta = _read_meta()
	if not meta.is_empty() and int(meta.get("format", 1)) < FORMAT_VERSION:
		push_warning("World '%s' was made with the old voxel engine; its terrain is regenerated and old edits are not carried over" % world_name)
		meta.erase("player")  # the old position may now be inside terrain
	if meta.is_empty():
		meta = {"seed": new_seed if new_seed >= 0 else randi(), "mode": new_mode,
				"created": Time.get_datetime_string_from_system()}
	elif not meta.has("mode"):
		meta.mode = "creative"  # worlds from before game modes played like creative
	elif int(meta.get("format", 0)) > FORMAT_VERSION:
		push_error("World '%s' was saved by a newer version of the game" % world_name)
	meta.format = FORMAT_VERSION

	# Voxels store numeric ids, so a world keeps its own id table. It is written
	# before any chunk can be saved.
	Registry.assign_block_ids(PackedStringArray(meta.get("block_ids", [])))
	meta.block_ids = Array(Registry.block_ids)
	if persistent:
		_write_meta()
	_make_engine(distance, int(meta.seed))
	if persistent:
		engine.set_save_directory(ProjectSettings.globalize_path(dir.path_join("chunks")))
	add_child(engine)
	engine.start()


## Client side of a multiplayer game: same seed and block table as the host,
## plus the host's edited chunks; terrain is generated locally.
func build_remote(block_ids: PackedStringArray, distance: int, world_seed: int, chunks: Dictionary,
		mode: String = "survival") -> void:
	remote = true
	Registry.assign_block_ids(block_ids)
	meta = {"block_ids": Array(block_ids), "seed": world_seed, "format": FORMAT_VERSION, "mode": mode}
	_make_engine(distance, world_seed)
	for pos in chunks:
		engine.set_chunk_override(pos, chunks[pos])
	add_child(engine)
	engine.start()


func _make_engine(distance: int, world_seed: int) -> void:
	view_distance = distance
	atlas = BlockAtlas.new()
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = preload("res://src/engine/chunk.gdshader")
	terrain_material.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(atlas.atlas))
	fluid_material = ShaderMaterial.new()
	fluid_material.shader = preload("res://src/engine/chunk_fluid.gdshader")
	for i in Registry.block_ids.size():
		if atlas.block_table[i].fluid:
			fluid_ids[i] = true

	engine = GoCubeWorld.new()
	engine.name = "Engine"
	engine.configure_blocks(atlas.block_table)
	engine.set_atlas_layout(atlas.cols, atlas.rows, BlockAtlas.CELL, BlockAtlas.FACE_OFFSET)
	engine.set_materials(terrain_material, fluid_material)
	var ids := {}
	for key in ["stone", "dirt", "grass", "sand", "water"]:
		ids[key] = maxi(0, Registry.block_index("core:" + key))
	engine.configure_generator(world_seed, ids, _ore_table(), _tree_table())
	engine.view_distance = distance


## Registered ores/trees -> engine tables. Sorted by id so every player builds
## the same tables; each ore's veins are keyed to its id, so adding a mod
## doesn't move existing veins.
static func _ore_table() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids := Registry.ores.keys()
	ids.sort()
	for id in ids:
		var def: Dictionary = Registry.ores[id]
		var block := Registry.block_index(str(def.get("block", "")))
		var replaces := Registry.block_index(str(def.get("replaces", "core:stone")))
		if block <= 0 or replaces <= 0:
			push_warning("Ore '%s': unknown block; not generated" % id)
			continue
		var size: Array = def.get("size", [3, 6])
		out.append({"block": block, "replaces": replaces,
				"min_y": int(def.get("min_y", -96)), "max_y": int(def.get("max_y", 0)),
				"veins_per_chunk": int(def.get("veins_per_chunk", 4)),
				"min_size": int(size[0]), "max_size": int(size[-1]),
				"salt": hash(id) & 0x7fffffff})
	return out


static func _tree_table() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids := Registry.trees.keys()
	ids.sort()
	for id in ids:
		var def: Dictionary = Registry.trees[id]
		var log_id := Registry.block_index(str(def.get("log", "")))
		var leaves := Registry.block_index(str(def.get("leaves", "")))
		if log_id <= 0 or leaves <= 0:
			push_warning("Tree '%s': unknown block; not generated" % id)
			continue
		var trunk: Array = def.get("trunk", [4, 6])
		out.append({"log": log_id, "leaves": leaves, "min_trunk": int(trunk[0]),
				"max_trunk": int(trunk[-1]), "chance": int(def.get("chance", 30))})
	return out


# --- Blocks ------------------------------------------------------------------------

func get_block(pos: Vector3i) -> int:
	return engine.get_block(pos)


## Changes a block and tells listeners (multiplayer). Returns false if its chunk
## isn't loaded.
func set_block(pos: Vector3i, block: int) -> bool:
	if not engine.set_block(pos, block):
		return false
	block_changed.emit(pos, block)
	return true


## Applies a block change from the host (no signal: the host already knows).
## Returns false if the chunk isn't loaded here: then ask the host for the
## whole chunk (chunk_bytes / set_chunk) so the edit isn't lost.
func apply_remote_block(pos: Vector3i, block: int) -> bool:
	return engine.set_block(pos, block)


static func chunk_of(pos: Vector3i) -> Vector3i:
	return Vector3i(floori(pos.x / float(CHUNK_SIZE)), floori(pos.y / float(CHUNK_SIZE)), floori(pos.z / float(CHUNK_SIZE)))


func chunk_bytes(chunk_pos: Vector3i) -> PackedByteArray:
	return engine.get_chunk_bytes(chunk_pos)


func set_chunk(chunk_pos: Vector3i, bytes: PackedByteArray) -> void:
	engine.set_chunk_override(chunk_pos, bytes)


## {hit, position, previous, normal, block, distance}
func raycast(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	return engine.raycast(origin, direction, max_distance)


func move_box(position: Vector3, size: Vector3, motion: Vector3, step_height: float = 0.0) -> Dictionary:
	return engine.move_box(position, size, motion, step_height)


func is_box_free(position: Vector3, size: Vector3) -> bool:
	return engine.is_box_free(position, size)


func is_area_meshed(area: AABB) -> bool:
	return engine.is_area_meshed(area)


func is_fluid(block: int) -> bool:
	return fluid_ids.has(block)


func set_view_distance(distance: int) -> void:
	view_distance = distance
	engine.view_distance = distance


## Where chunks are loaded around (the local player).
func set_viewer(position: Vector3) -> void:
	engine.viewer_position = position


## For multiplayer: every edited chunk, to send to a joining player.
func edited_chunks() -> Dictionary:
	return engine.get_edited_chunks()


# --- World folders -------------------------------------------------------------

static var _name_regex := RegEx.create_from_string("^[A-Za-z0-9][A-Za-z0-9 _-]{0,31}$")


## Saved worlds, most recently played first: [{"name": String, "meta": Dictionary}].
static func list_worlds() -> Array[Dictionary]:
	DirAccess.make_dir_recursive_absolute(WORLDS_DIR)
	var out: Array[Dictionary] = []
	for world_name in DirAccess.get_directories_at(WORLDS_DIR):
		var path := WORLDS_DIR.path_join(world_name).path_join("world.json")
		if not FileAccess.file_exists(path):
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		out.append({"name": world_name, "meta": data if data is Dictionary else {}})
	var last_played := func(w): return str(w.meta.get("saved", w.meta.get("created", "")))
	out.sort_custom(func(a, b): return last_played.call(a) > last_played.call(b))
	return out


## Letters, digits, spaces, '_' and '-'; it is used as a folder name.
static func is_valid_name(world_name: String) -> bool:
	return _name_regex.search(world_name) != null


static func world_exists(world_name: String) -> bool:
	return DirAccess.dir_exists_absolute(WORLDS_DIR.path_join(world_name))


## Moves the world folder to the system trash (recoverable), not a hard delete.
static func delete_world(world_name: String) -> Error:
	if not is_valid_name(world_name) or not world_exists(world_name):
		return ERR_INVALID_PARAMETER
	return OS.move_to_trash(ProjectSettings.globalize_path(WORLDS_DIR.path_join(world_name)))


# --- Saving ----------------------------------------------------------------------

func is_persistent() -> bool:
	return dir != ""


## Writes world.json and all edited chunks.
func save(player: Dictionary = {}) -> void:
	if not is_persistent():
		return
	if not player.is_empty():
		meta.player = player
	meta.saved = Time.get_datetime_string_from_system()
	_write_meta()
	engine.save_modified()


func _read_meta() -> Dictionary:
	var path := dir.path_join("world.json")
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		return data
	push_error("Corrupt %s; not loading it" % path)
	return {}


## Write to a temp file then rename, so a crash mid-write can't corrupt the save.
func _write_meta() -> void:
	var path := dir.path_join("world.json")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Can't write %s: %s" % [tmp, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(meta, "\t"))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("Can't replace %s: %s" % [path, error_string(err)])
