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
## Newest world generator (see _make_engine).
const GENERATOR_VERSION := 3
const DEFAULT_VIEW_DISTANCE := 128  # 256 halves FPS on an Intel HD 4600
const CHUNK_SIZE := 32
const CHUNK_Y_MIN := -3  # the engine's chunk layers (GoCubeWorld::CHUNK_Y_MIN/MAX)
const CHUNK_Y_MAX := 3
## Highest block y in the world (the engine's vertical range is y -96..127);
## start downward raycasts here, above it nothing is loaded.
const TOP_Y := 127

## A block changed through set_block() (the host forwards these to clients).
signal block_changed(position: Vector3i, block: int)
## Goes up with every block change here, local or from the host (what's
## drawn from blocks, like the target outline, can tell it is out of date).
var revision := 0

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
var cutout_material: ShaderMaterial  # blocks with see-through pixels
var fluid_material: ShaderMaterial
## Block index -> true, for fluid blocks (swimming, underwater view).
var fluid_ids := {}
## Flowing fluids (single player and host; clients get the result as edits).
var fluids: FluidSim
## Chests and furnaces (single player and host; clients go through the host).
var block_entities: BlockEntities
## Crop growth and blocks that need support (single player and host).
var plants: PlantSim
## Multiplayer peer whose edit is being applied (0 = the local player).
var editor := 0
## Chunk worker threads for this world (0 automatic); -1 uses Settings.
var worker_threads := -1


## persistent=false runs the world without reading or writing anything (benchmarks).
## new_mode ("survival" / "creative") applies to new worlds only.
## Returns "" when built, else why the world can't be opened (then nothing is
## built and nothing on disk is touched).
func build(world_name: String, distance: int = DEFAULT_VIEW_DISTANCE, new_seed: int = -1,
		persistent: bool = true, new_mode: String = "survival") -> String:
	if persistent:
		dir = WORLDS_DIR.path_join(world_name)
		var problem := check_meta(dir)
		if problem != "":
			push_warning("World '%s': %s" % [world_name, problem])
			dir = ""  # so nothing saves into it
			return problem
		DirAccess.make_dir_recursive_absolute(dir.path_join("chunks"))
		meta = _read_meta()
	if not meta.is_empty() and int(meta.get("format", 1)) < FORMAT_VERSION:
		if persistent:
			DirAccess.copy_absolute(dir.path_join("world.json"),
					dir.path_join("world.json.format%d.bak" % int(meta.get("format", 1))))
		migrate(meta, world_name)
	if meta.is_empty():
		meta = {"seed": new_seed if new_seed >= 0 else randi(), "mode": new_mode,
				"first_night": "ahead",  # no ninjas until it's over (see main.gd)
				"created": Time.get_datetime_string_from_system(), "generator": GENERATOR_VERSION}
	elif not meta.has("mode"):
		meta.mode = "creative"  # worlds from before game modes played like creative
	meta.format = FORMAT_VERSION

	# Voxels store numeric ids, so a world keeps its own id table. It is written
	# before any chunk can be saved.
	Registry.assign_block_ids(PackedStringArray(meta.get("block_ids", [])))
	meta.block_ids = Array(Registry.block_ids)
	if persistent:
		_write_meta()
	_make_engine(distance, int(meta.seed), int(meta.get("generator", 1)))
	if persistent:
		engine.set_save_directory(ProjectSettings.globalize_path(dir.path_join("chunks")))
	add_child(engine)
	engine.start()
	fluids = FluidSim.new()
	fluids.name = "Fluids"
	fluids.world = self
	add_child(fluids)
	block_entities = BlockEntities.new()
	block_entities.name = "BlockEntities"
	block_entities.world = self
	block_entities.deserialize(meta.get("block_entities", {}))
	add_child(block_entities)
	plants = PlantSim.new()
	plants.name = "Plants"
	plants.world = self
	plants.deserialize(meta.get("plants", []))
	add_child(plants)
	return ""


## Client side of a multiplayer game: same seed and block table as the host,
## plus the host's edited chunks; terrain is generated locally.
func build_remote(block_ids: PackedStringArray, distance: int, world_seed: int, chunks: Dictionary,
		mode: String = "survival", generator: int = 1) -> void:
	remote = true
	Registry.assign_block_ids(block_ids)
	meta = {"block_ids": Array(block_ids), "seed": world_seed, "format": FORMAT_VERSION, "mode": mode,
			"generator": generator}
	_make_engine(distance, world_seed, generator)
	for pos in chunks:
		engine.set_chunk_override(pos, chunks[pos])
	add_child(engine)
	engine.start()


## generator: 1 = the original world (worlds made before biomes keep it, so
## their unexplored land matches what's saved), 2 = biomes, lakes, caverns, lava,
## 3 = round oaks instead of the classic blocky oak.
func _make_engine(distance: int, world_seed: int, generator: int = GENERATOR_VERSION) -> void:
	view_distance = distance
	atlas = BlockAtlas.new()
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = preload("res://src/engine/chunk.gdshader")
	terrain_material.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(atlas.atlas))
	cutout_material = ShaderMaterial.new()
	cutout_material.shader = preload("res://src/engine/chunk_cutout.gdshader")
	cutout_material.set_shader_parameter("albedo_texture", terrain_material.get_shader_parameter("albedo_texture"))
	fluid_material = ShaderMaterial.new()
	fluid_material.shader = preload("res://src/engine/chunk_fluid.gdshader")
	fluid_material.set_shader_parameter("albedo_texture", terrain_material.get_shader_parameter("albedo_texture"))
	fluid_material.set_shader_parameter("use_atlas", true)
	for i in Registry.block_ids.size():
		if atlas.block_table[i].fluid:
			fluid_ids[i] = true

	engine = GoCubeWorld.new()
	engine.name = "Engine"
	engine.worker_threads = worker_threads if worker_threads >= 0 else Settings.worker_threads
	engine.configure_blocks(atlas.block_table)
	engine.set_atlas_layout(atlas.cols, atlas.rows, BlockAtlas.CELL, BlockAtlas.FACE_OFFSET)
	engine.set_materials(terrain_material, fluid_material, cutout_material)
	var ids := {}
	for key in ["stone", "dirt", "grass", "sand", "water", "lava", "ice"]:
		ids[key] = maxi(0, Registry.block_index("core:" + key))
	if generator >= 2:
		engine.configure_biomes(_biome_table())
	engine.configure_generator(world_seed, ids, _ore_table(), _tree_table(generator))
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


## generator < 3: "round_oak" trees grow as the classic oak, so older worlds'
## unexplored land matches what they saved.
static func _tree_table(generator: int = GENERATOR_VERSION) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _tree_order():
		var def: Dictionary = Registry.trees[id]
		var log_id := Registry.block_index(str(def.get("log", "")))
		var leaves := Registry.block_index(str(def.get("leaves", "")))
		var trunk: Array = def.get("trunk", [4, 6])
		out.append({"log": log_id, "leaves": maxi(0, leaves), "min_trunk": int(trunk[0]),
				"max_trunk": int(trunk[-1]), "chance": int(def.get("chance", 30)),
				"style": TREE_STYLES.find(_tree_style(def, generator))})
	return out


const TREE_STYLES := ["oak", "big_oak", "birch", "spruce", "cactus", "round_oak"]


static func _tree_style(def: Dictionary, generator: int) -> String:
	var style := str(def.get("style", "oak"))
	return "oak" if style == "round_oak" and generator < 3 else style


## The tree ids in the order _tree_table() sends them (biomes refer to trees
## by index).
static func _tree_order() -> Array:
	var ids := Registry.trees.keys().filter(func(id):
		var def: Dictionary = Registry.trees[id]
		return Registry.block_index(str(def.get("log", ""))) > 0 \
				and (Registry.block_index(str(def.get("leaves", ""))) > 0 or def.get("style") == "cactus"))
	ids.sort()
	return ids


## Registered biomes -> engine table (sorted by id).
static func _biome_table() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tree_ids := _tree_order()
	var ids := Registry.biomes.keys()
	ids.sort()
	for id in ids:
		var def: Dictionary = Registry.biomes[id]
		var b := {}
		for key in ["temperature", "humidity", "height", "base", "filler_depth", "under_depth", "frozen", "lakes",
				"mountains", "rock_above", "cap_above", "cover_above"]:
			if def.has(key):
				b[key] = def[key]
		for key in ["surface", "filler", "under", "rock", "cap", "cover"]:
			if def.has(key):
				b[key] = maxi(0, Registry.block_index(str(def[key])))
		var trees := []
		for tree in def.get("trees", {}):
			var i := tree_ids.find(tree)
			if i >= 0:
				trees.append([i, int(def.trees[tree])])
		b.trees = trees
		var plants := []
		for block in def.get("plants", {}):
			var i := Registry.block_index(block)
			if i > 0:
				plants.append([i, int(def.plants[block])])
		b.plants = plants
		out.append(b)
	return out


## Which biome a column is in (its id), or "" for worlds without biomes.
func biome_name(x: int, z: int) -> String:
	if int(meta.get("generator", 1)) < 2 or Registry.biomes.is_empty():
		return ""
	var ids := Registry.biomes.keys()
	ids.sort()
	return str(ids[engine.biome_at(x, z)])


## Grows tree `tree_id` (a Registry.trees id) from the sapling at `pos`, the
## same shape the world generator would make there. Its logs need room (air,
## plants, leaves); leaves only fill air. Returns false (nothing changed) when
## there's no room or the area isn't loaded.
func grow_tree(pos: Vector3i, tree_id: String) -> bool:
	var kind := _tree_order().find(tree_id)
	if kind < 0:
		return false
	var blocks: Array = engine.tree_blocks(kind, pos + Vector3i.DOWN)
	if blocks.is_empty():
		return false
	for b in blocks:
		if b[2]:
			continue
		var here := get_block(b[0])
		if b[0] != pos and here != 0 and not _makes_room(here):
			return false
	for b in blocks:
		if not engine.is_chunk_loaded(chunk_of(b[0])):
			return false  # part of it would land in an unloaded chunk
	for b in blocks:
		var here := get_block(b[0])
		if here == 0 or (not b[2] and (b[0] == pos or _makes_room(here))):
			set_block(b[0], b[1])
	return true


## Blocks a growing tree's trunk may push aside: plants and leaves.
func _makes_room(block: int) -> bool:
	var def: Dictionary = Registry.blocks.get(Registry.block_ids[block], {})
	return def.get("replaceable", false) or def.get("leaves", false) or def.get("shape") == "cross"


# --- Blocks ------------------------------------------------------------------------

func get_block(pos: Vector3i) -> int:
	return engine.get_block(pos)


## Changes a block and tells listeners (multiplayer). Returns false if its chunk
## isn't loaded.
func set_block(pos: Vector3i, block: int) -> bool:
	if not engine.set_block(pos, block):
		return false
	revision += 1
	block_changed.emit(pos, block)
	return true


## Applies a block change from the host (no signal: the host already knows).
## Returns false if the chunk isn't loaded here: then ask the host for the
## whole chunk (chunk_bytes / set_chunk) so the edit isn't lost.
func apply_remote_block(pos: Vector3i, block: int) -> bool:
	revision += 1
	return engine.set_block(pos, block)


static func chunk_of(pos: Vector3i) -> Vector3i:
	return Vector3i(floori(pos.x / float(CHUNK_SIZE)), floori(pos.y / float(CHUNK_SIZE)), floori(pos.z / float(CHUNK_SIZE)))


func chunk_bytes(chunk_pos: Vector3i) -> PackedByteArray:
	return engine.get_chunk_bytes(chunk_pos)


func set_chunk(chunk_pos: Vector3i, bytes: PackedByteArray) -> void:
	engine.set_chunk_override(chunk_pos, bytes)
	revision += 1


## Light for things that aren't terrain (creatures, players, dropped and held
## items, the first-person hand), worked out like the terrain shader does:
## sky light (times `sky_light`: day, night, moonlight), placed lights, and
## torches players hold (set_hand_lights). Both are set by the game each frame.
var sky_light := Color.WHITE
var hand_lights: Array = []  # Vector4(x, y, z, level)
const BLOCK_LIGHT_COLOR := Color(1.0, 0.85, 0.62)

## Torches in hand light the blocks around them like placed ones: one level
## less per block, stopped by walls (GoCubeWorld.held_light), in a cube of
## HAND_LIGHT_SIZE blocks around the viewer (moved in steps of
## HAND_LIGHT_STEP blocks, so walking doesn't spread it again every block). The terrain shaders read it
## from hand_light_texture (one light level per block face).
const HAND_LIGHT_SIZE := 48
const HAND_LIGHT_STEP := 8
var hand_light_texture: ImageTexture3D
var hand_light_origin := Vector3i.ZERO
var _hand_volume := PackedByteArray()
var _hand_key := []  # what the volume was worked out for: lights' blocks and levels, world revision


## Each light level is 80% as bright as the one above; level 0 is dark.
static func light_curve(level01: float) -> float:
	return 0.0 if level01 <= 0.0 else pow(0.8, 15.0 - level01 * 15.0)


## Sets the torches held in hand (Vector4(x, y, z, level)) and spreads their
## light, around `viewer` (null: the first light), when they moved to another
## block, the viewer moved a step or the world changed. Returns whether
## hand_light_texture changed.
func set_hand_lights(lights: Array, viewer = null) -> bool:
	hand_lights = lights
	var half := HAND_LIGHT_SIZE / 2
	if viewer == null:  # the first light, or where the cube already is
		viewer = Vector3(lights[0].x, lights[0].y, lights[0].z) if not lights.is_empty() \
				else Vector3(hand_light_origin + Vector3i(half, half, half))
	var origin := Vector3i((viewer / HAND_LIGHT_STEP).round()) * HAND_LIGHT_STEP - Vector3i(half, half, half)
	var key := [revision, origin]
	for l in lights:
		key.append(Vector4i(floori(l.x), floori(l.y), floori(l.z), int(l.w)))
	if key == _hand_key or engine == null:
		return false
	_hand_key = key
	hand_light_origin = origin
	_hand_volume = engine.held_light(hand_light_origin, HAND_LIGHT_SIZE, PackedVector4Array(lights)) \
			if not lights.is_empty() else PackedByteArray()
	var slices: Array[Image] = []
	var area := HAND_LIGHT_SIZE * HAND_LIGHT_SIZE
	for y in HAND_LIGHT_SIZE:
		var bytes := _hand_volume.slice(y * area, (y + 1) * area) if not _hand_volume.is_empty() else PackedByteArray()
		bytes.resize(area)  # the level itself: the shader reads r * 255
		slices.append(Image.create_from_data(HAND_LIGHT_SIZE, HAND_LIGHT_SIZE, false, Image.FORMAT_R8, bytes))
	if hand_light_texture == null:
		hand_light_texture = ImageTexture3D.new()
		hand_light_texture.create(Image.FORMAT_R8, HAND_LIGHT_SIZE, HAND_LIGHT_SIZE, HAND_LIGHT_SIZE, false, slices)
	else:
		hand_light_texture.update(slices)
	return true


## Held-torch light level (0..15) of the block at `at`.
func hand_light_at(at: Vector3) -> int:
	if _hand_volume.is_empty():
		return 0
	var p := Vector3i(at.floor()) - hand_light_origin
	if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= HAND_LIGHT_SIZE or p.y >= HAND_LIGHT_SIZE or p.z >= HAND_LIGHT_SIZE:
		return 0
	return _hand_volume[(p.y * HAND_LIGHT_SIZE + p.z) * HAND_LIGHT_SIZE + p.x]


## The light at `at` (never below `least`, so things stay faintly visible).
func light_for(at: Vector3, least := 0.0) -> Color:
	var l: Vector2 = engine.light_at(at) if engine else Vector2(1, 0)
	var sky := sky_light * light_curve(l.x)
	var block := light_curve(maxf(l.y, hand_light_at(at) / 15.0))
	var blk := BLOCK_LIGHT_COLOR * block
	return Color(maxf(maxf(sky.r, blk.r), least), maxf(maxf(sky.g, blk.g), least), maxf(maxf(sky.b, blk.b), least))


## The boxes a ray can hit in the block at `pos` (its shape: a slab's half,
## a torch's stick...), as AABBs relative to the block's corner.
func pick_boxes(pos: Vector3i) -> Array:
	return engine.pick_boxes(pos)


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
	if block_entities:
		meta.block_entities = block_entities.serialize()
	if plants:
		meta.plants = plants.serialize()
	meta.saved = Time.get_datetime_string_from_system()
	_write_meta()
	engine.save_modified()


## Why the world saved in `world_dir` can't be opened by this version, or ""
## (also for a new world). Opening a newer world would write our older format
## over it; a corrupt world.json would be replaced by a brand-new world.
static func check_meta(world_dir: String) -> String:
	var path := world_dir.path_join("world.json")
	if not FileAccess.file_exists(path):
		return ""
	var json := JSON.new()
	var data = json.data if json.parse(FileAccess.get_file_as_string(path)) == OK else null
	if not data is Dictionary or not (data.get("seed") is float or data.get("seed") is int):
		return "its world.json is damaged, so it isn't opened (to keep it safe)."
	if int(data.get("format", 1)) > FORMAT_VERSION or int(data.get("generator", 1)) > GENERATOR_VERSION:
		return "it was saved by a newer version of GoCube. Update the game to play it."
	return ""


func _read_meta() -> Dictionary:
	var path := dir.path_join("world.json")
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		return data
	push_error("Corrupt %s; not loading it" % path)
	return {}


## Brings an older world's world.json up to FORMAT_VERSION, one format at a
## time (the caller keeps a backup of the file). To change the save format:
## raise FORMAT_VERSION and add a step from the previous one here.
static func migrate(m: Dictionary, world_name := "") -> void:
	while int(m.get("format", 1)) < FORMAT_VERSION:
		var from := int(m.get("format", 1))
		match from:
			1:
				# Voxel-module worlds (blocks.sqlite): the engine and its terrain
				# generator changed, so the terrain is regenerated.
				push_warning("World '%s' was made with the old voxel engine; its terrain is regenerated and old edits are not carried over" % world_name)
				m.erase("player")  # the old position may now be inside terrain
		m.format = from + 1


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
