class_name World
extends Node3D
## A saved world: terrain plus its folder on disk. Call build() after mods load.
##
## user://worlds/<name>/
##   world.json     seed, block id table, player state (written atomically)
##   blocks.sqlite  chunks the player edited; untouched chunks are regenerated
##                  from the seed, so this stays small.

const TerrainGenerator := preload("res://src/world/graph_terrain_generator.gd")

const WORLDS_DIR := "user://worlds"
const FORMAT_VERSION := 1
const DEFAULT_VIEW_DISTANCE := 128  # 256 halves FPS on an Intel HD 4600
## PROTOTYPE: per-voxel light in the COLOR channel (see LightPrototype). Off by
## default: costs 2 bytes/voxel and GDScript light is far too slow (PROTOTYPES.md).
const LIGHTING_PROTOTYPE := false

var terrain: VoxelTerrain
## Contents of world.json. "player" is whatever the game passed to save().
var meta: Dictionary = {}
var dir := ""
## True on a multiplayer client: voxels come from the host, nothing is generated or saved.
var remote := false
## Classic column skylight for the terrain shader (see SkyLight).
var sky: SkyLight

## A column's skylight changed because of an edit (the host forwards it to clients).
signal sky_changed(column: Vector2i, top: int)


## persistent=false runs the world without reading or writing anything (benchmarks).
## networked=true makes this the authoritative copy of a multiplayer game (host).
## Multiplayer must already be set up: the synchronizer checks it on entering the tree.
func build(world_name: String, view_distance: int = DEFAULT_VIEW_DISTANCE,
		new_seed: int = -1, persistent: bool = true, networked: bool = false) -> void:
	if persistent:
		dir = WORLDS_DIR.path_join(world_name)
		DirAccess.make_dir_recursive_absolute(dir)
		meta = _read_meta()
	if meta.is_empty():
		meta = {
			"format": FORMAT_VERSION,
			"seed": new_seed if new_seed >= 0 else randi(),
			"created": Time.get_datetime_string_from_system(),
		}
	elif int(meta.get("format", 0)) > FORMAT_VERSION:
		push_error("World '%s' was saved by a newer version of the game" % world_name)

	# Voxels store numeric ids, so a world must keep its own id table. It is
	# written before any chunk can be saved.
	Registry.assign_block_ids(PackedStringArray(meta.get("block_ids", [])))
	meta.block_ids = Array(Registry.block_ids)
	if persistent:
		_write_meta()

	_make_terrain(view_distance)
	var generator := TerrainGenerator.new()
	generator.setup(int(meta.seed), LIGHTING_PROTOTYPE)
	terrain.generator = generator
	sky = SkyLight.new(generator, terrain.material_override, terrain.get_voxel_tool(), meta.get("sky_overrides", {}))
	if persistent:
		var stream := VoxelStreamSQLite.new()
		stream.database_path = ProjectSettings.globalize_path(dir.path_join("blocks.sqlite"))
		terrain.stream = stream
	if networked:
		_add_synchronizer()
	add_child(terrain)


## Client side of a multiplayer game. Uses the host's block table; the terrain
## only shows chunks the host sends (the synchronizer disables local loading).
func build_remote(block_ids: PackedStringArray, view_distance: int, world_seed: int,
		sky_overrides: Dictionary) -> void:
	remote = true
	Registry.assign_block_ids(block_ids)
	meta = {"block_ids": Array(block_ids), "seed": world_seed}
	# Slightly larger than the host's, so chunks aren't unloaded before the host
	# stops sending them (avoids holes at the edge).
	_make_terrain(view_distance + 16)
	# The client doesn't generate terrain, but skylight uses the same height
	# function as the host's generator, so it needs one for that.
	var heights := TerrainGenerator.new()
	heights.setup(world_seed)
	sky = SkyLight.new(heights, terrain.material_override, terrain.get_voxel_tool(), sky_overrides)
	_add_synchronizer()
	add_child(terrain)


func _make_terrain(view_distance: int) -> void:
	var blocks := BlockLibrary.new()
	var mesher := VoxelMesherBlocky.new()
	mesher.library = blocks.library
	terrain = VoxelTerrain.new()
	terrain.name = "Terrain"
	if LIGHTING_PROTOTYPE:
		# Light lives in the COLOR channel (RGBA4444 = 16 levels per channel); the
		# blocky mesher multiplies each block's vertices by it (TINT_RAW_COLOR).
		mesher.tint_mode = VoxelMesherBlocky.TINT_RAW_COLOR
		var format := VoxelFormat.new()
		format.set_channel_depth(VoxelBuffer.CHANNEL_COLOR, VoxelBuffer.DEPTH_16_BIT)
		terrain.format = format
	# Flat classic look: the shader does face shading; the mesher's per-corner
	# occlusion is off (terrain.gdshader `use_vertex_ao` turns it back on).
	mesher.occlusion_enabled = false
	terrain.mesher = mesher
	terrain.material_override = blocks.material
	terrain.max_view_distance = view_distance
	terrain.generate_collisions = true


## Must have the same node path on host and clients: Main/World/Terrain/Sync.
func _add_synchronizer() -> void:
	var sync := VoxelTerrainMultiplayerSynchronizer.new()
	sync.name = "Sync"
	terrain.add_child(sync)


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


## Call after changing a block (locally, or on the host for a client's request).
func notify_edit(pos: Vector3i, block: int) -> void:
	if sky:
		var col := Vector2i(pos.x, pos.z)
		var before := sky.get_top(col)
		var top := sky.on_edit(pos, block)
		if top != before:
			sky_changed.emit(col, top)


func get_tool() -> VoxelTool:
	return terrain.get_voxel_tool()


func is_persistent() -> bool:
	return dir != ""


## Writes world.json and all edited chunks. Await it to know the save finished.
func save(player: Dictionary = {}) -> void:
	if not is_persistent():
		return
	if not player.is_empty():
		meta.player = player
	if sky:
		meta.sky_overrides = sky.serialize()
	meta.saved = Time.get_datetime_string_from_system()
	_write_meta()
	var tracker := terrain.save_modified_blocks()
	while not (tracker.is_complete() or tracker.is_aborted()):
		await get_tree().process_frame
	if tracker.is_aborted():
		push_error("Saving world chunks was aborted")


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
