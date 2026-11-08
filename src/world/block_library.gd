class_name BlockLibrary
extends RefCounted
## Builds the voxel module's VoxelBlockyLibrary plus a texture atlas material
## from the content Registry. Model index n == Registry.block_ids[n], so voxel
## values are registry indices.
##
## Block definition keys used here:
##   "textures": {"all": "textures/stone.png"}            same on every face
##               {"top": ..., "bottom": ..., "side": ...}  per face ("all" fills gaps)
##     Paths are relative to the block's mod folder, or "othermod:path" to use
##     another mod's file. PNGs of any square size are scaled to TILE_SIZE.
##   "color": "#rrggbb"     flat color, used when a block has no textures
##   "solid": false         no geometry (e.g. air)
##   "transparent": true    neighbours' faces stay visible

const TILE_SIZE := 16
## Each tile gets a CELL x CELL tile area in the atlas, filled with repeats of
## the (seamless) texture, and faces use the copy at (1, 1). Cells are
## power-of-two aligned, so every mip level only averages a tile with itself:
## mipmaps without color bleeding between neighbouring tiles.
const CELL := 4
const FACE_OFFSET := Vector2i(1, 1)
const MISSING_COLOR := Color(1, 0, 1)  # magenta = no texture or color given

var library: VoxelBlockyLibrary
var material: StandardMaterial3D

var _tiles: Array[Image] = []
var _tile_index: Dictionary = {}  # texture path or color key -> tile index


func _init() -> void:
	assert(Registry.is_frozen(), "Build the block library after mods are loaded")
	# Pass 1: collect tiles for every face of every block.
	var faces_by_block: Array[Dictionary] = []
	for id in Registry.block_ids:
		faces_by_block.append(_collect_faces(Registry.blocks.get(id, {})))

	var atlas := _build_atlas()
	var cols := atlas.get_width() / (TILE_SIZE * CELL)
	var rows := atlas.get_height() / (TILE_SIZE * CELL)

	# Pass 2: one voxel model per block, pointing at its atlas tiles.
	var models: Array[VoxelBlockyModel] = []
	for i in Registry.block_ids.size():
		var id := Registry.block_ids[i]
		var def: Dictionary = Registry.blocks.get(id, {})
		var model: VoxelBlockyModel
		if not def.get("solid", true):
			model = VoxelBlockyModelEmpty.new()
		else:
			var cube := VoxelBlockyModelCube.new()
			cube.atlas_size_in_tiles = Vector2i(cols, rows) * CELL
			var faces := faces_by_block[i]
			for side in VoxelBlockyModel.SIDE_COUNT:
				var tile: int = faces[_face_name(side)]
				cube.set_tile(side, Vector2i(tile % cols, tile / cols) * CELL + FACE_OFFSET)
			if def.get("transparent", false):
				cube.transparency_index = 1
			model = cube
		model.resource_name = id
		models.append(model)

	library = VoxelBlockyLibrary.new()
	library.models = models
	library.bake()

	material = StandardMaterial3D.new()
	atlas.generate_mipmaps()
	material.albedo_texture = ImageTexture.create_from_image(atlas)
	# Crisp pixels up close, filtered mips at distance (no shimmer). Not the
	# anisotropic variant: Vulkan lets drivers use linear filtering when
	# anisotropy is on, and e.g. Intel/Mesa does, which blurs nearby pixel art.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	# The blocky mesher bakes ambient occlusion into vertex colors.
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true


static func _face_name(side: int) -> String:
	match side:
		VoxelBlockyModel.SIDE_POSITIVE_Y: return "top"
		VoxelBlockyModel.SIDE_NEGATIVE_Y: return "bottom"
		_: return "side"


## Returns {"top": tile, "bottom": tile, "side": tile} for a block definition.
func _collect_faces(def: Dictionary) -> Dictionary:
	if not def.get("solid", true):
		return {}
	var textures: Dictionary = def.get("textures", {})
	var faces := {}
	for face in ["top", "bottom", "side"]:
		var rel = textures.get(face, textures.get("all"))
		var tile := -1
		if rel != null:
			tile = _texture_tile(_resolve_path(def.get("mod", ""), rel))
		if tile < 0:
			tile = _color_tile(Color.html(def["color"]) if def.has("color") else MISSING_COLOR)
		faces[face] = tile
	return faces


static func _resolve_path(mod_id: String, rel: String) -> String:
	var parts := rel.split(":", true, 1)
	if parts.size() == 2:
		mod_id = parts[0]
		rel = parts[1]
	return ModLoader.get_mod_path(mod_id).path_join(rel)


func _texture_tile(path: String) -> int:
	if _tile_index.has(path):
		return _tile_index[path]
	var img := _load_image(path)
	if img == null:
		push_error("Block texture not found: " + path)
		return -1
	if img.get_size() != Vector2i(TILE_SIZE, TILE_SIZE):
		img.resize(TILE_SIZE, TILE_SIZE, Image.INTERPOLATE_NEAREST)
	return _add_tile(path, img)


func _color_tile(color: Color) -> int:
	var key := "#color:" + color.to_html()
	if _tile_index.has(key):
		return _tile_index[key]
	var img := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return _add_tile(key, img)


func _add_tile(key: String, img: Image) -> int:
	_tiles.append(img)
	_tile_index[key] = _tiles.size() - 1
	return _tiles.size() - 1


## res:// textures go through the import system (works in exported games and
## mod .pck files); unpacked user:// mods are read straight from disk.
static func _load_image(path: String) -> Image:
	var img: Image = null
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex:
			img = tex.get_image()
	if img == null and FileAccess.file_exists(path):
		img = Image.load_from_file(path)
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


func _build_atlas() -> Image:
	if _tiles.is_empty():
		_color_tile(MISSING_COLOR)
	# Power-of-two columns keep the atlas size halving cleanly at every mip level.
	var cols := 1
	while cols * cols < _tiles.size():
		cols *= 2
	var rows := ceili(float(_tiles.size()) / cols)
	var cell_px := TILE_SIZE * CELL
	var atlas := Image.create(cols * cell_px, rows * cell_px, false, Image.FORMAT_RGBA8)
	var rect := Rect2i(Vector2i.ZERO, Vector2i(TILE_SIZE, TILE_SIZE))
	for i in _tiles.size():
		var cell := Vector2i(i % cols, i / cols) * cell_px
		for y in CELL:
			for x in CELL:
				atlas.blit_rect(_tiles[i], rect, cell + Vector2i(x, y) * TILE_SIZE)
	return atlas
