class_name BlockAtlas
extends RefCounted
## Packs every registered block's textures into one mipmapped atlas and gives
## the native engine (GoCubeWorld) its block table. No voxel-module classes.
## Block definition keys used: textures/color, solid, transparent, fluid, light (0..15).
##
## Each tile gets a CELL x CELL area filled with repeats of the (seamless)
## texture; faces use the copy at FACE_OFFSET. Cells are power-of-two aligned,
## so mip levels never mix neighbouring tiles.

const TILE_SIZE := 32
const CELL := 4
const FACE_OFFSET := Vector2i(1, 1)
const MISSING_COLOR := Color(1, 0, 1)

var atlas: Image
var cols := 1
var rows := 1
## For GoCubeWorld.configure_blocks(): index = block id.
var block_table: Array[Dictionary] = []

var _tiles: Array[Image] = []
var _tile_index := {}
var _icon_tiles := {}   # block id -> tile index used as its icon
var _icons := {}        # item/block id -> Texture2D (cache)


func _init() -> void:
	assert(Registry.is_frozen(), "Build the atlas after mods are loaded")
	for id in Registry.block_ids:
		var def: Dictionary = Registry.blocks.get(id, {})
		var solid: bool = def.get("solid", true) and not def.has("fluid")
		var fluid := def.has("fluid")
		var opaque: bool = solid and not def.get("transparent", false)
		var tiles := PackedInt32Array()
		if id == "core:air" or (not solid and not fluid):
			tiles.resize(6)
		else:
			# Engine face order: +X, -X, +Y, -Y, +Z, -Z.
			for face in ["side", "side", "top", "bottom", "side", "side"]:
				tiles.append(_face_tile(def, face))
			_icon_tiles[id] = tiles[0]  # the side face shows best as a flat icon
		block_table.append({"solid": solid, "opaque": opaque, "fluid": fluid, "tiles": tiles,
				"light": int(def.get("light", 0))})
	atlas = _build_atlas()


func _face_tile(def: Dictionary, face: String) -> int:
	var textures: Dictionary = def.get("textures", {})
	var rel = textures.get(face, textures.get("all"))
	if rel != null:
		var mod_id: String = def.get("mod", "")
		var path: String = rel
		if ":" in path:
			mod_id = path.get_slice(":", 0)
			path = path.get_slice(":", 1)
		var full := ModLoader.get_mod_path(mod_id).path_join(path)
		if _tile_index.has(full):
			return _tile_index[full]
		var img := _load_image(full)
		if img:
			if img.get_size() != Vector2i(TILE_SIZE, TILE_SIZE):
				img.resize(TILE_SIZE, TILE_SIZE, Image.INTERPOLATE_NEAREST)
			return _add(full, img)
		push_error("Block texture not found: " + full)
	var color: Color = Color.html(def["color"]) if def.has("color") else MISSING_COLOR
	var key := "#" + color.to_html()
	if _tile_index.has(key):
		return _tile_index[key]
	var flat := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	flat.fill(color)
	return _add(key, flat)


func _add(key: String, img: Image) -> int:
	_tiles.append(img)
	_tile_index[key] = _tiles.size() - 1
	return _tiles.size() - 1


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
		var flat := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
		flat.fill(MISSING_COLOR)
		_add("#missing", flat)
	cols = 1
	while cols * cols < _tiles.size():
		cols *= 2
	rows = ceili(float(_tiles.size()) / cols)
	var cell_px := TILE_SIZE * CELL
	var img := Image.create(cols * cell_px, rows * cell_px, false, Image.FORMAT_RGBA8)
	var rect := Rect2i(Vector2i.ZERO, Vector2i(TILE_SIZE, TILE_SIZE))
	for i in _tiles.size():
		var cell := Vector2i(i % cols, i / cols) * cell_px
		for y in CELL:
			for x in CELL:
				img.blit_rect(_tiles[i], rect, cell + Vector2i(x, y) * TILE_SIZE)
	img.generate_mipmaps()
	return img


## Icon for an inventory slot: a block's side texture, an item's "texture",
## or a flat colour.
func icon(id: String) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var img: Image = null
	if _icon_tiles.has(id):
		img = _tiles[_icon_tiles[id]]
	else:
		var def: Dictionary = Registry.items.get(id, {})
		if def.has("texture"):
			img = _load_image(ModLoader.get_mod_path(def.get("mod", "")).path_join(def.texture))
		if img == null:
			img = Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color.html(def.get("color", "#b0a080")))
	var tex := ImageTexture.create_from_image(img)
	_icons[id] = tex
	return tex

