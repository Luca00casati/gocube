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
		if id == "core:air" or (not solid and not fluid and def.get("shape", "cube") == "cube"):
			tiles.resize(6)
		else:
			# Engine face order: +X, -X, +Y, -Y, +Z, -Z.
			for face in ["side", "side", "top", "bottom", "side", "side"]:
				tiles.append(_face_tile(def, face, int(def.get("texture_turns", 0)) if face == "top" else 0))
			_icon_tiles[id] = tiles[0]  # the side face shows best as a flat icon
		var entry := {"solid": solid, "opaque": opaque, "fluid": fluid, "tiles": tiles,
				"light": int(def.get("light", 0)), "fluid_level": int(def.get("level", 8)),
				"random_rotation": bool(def.get("random_rotation", false))}
		entry.merge(BlockShapes.engine_fields(def))
		block_table.append(entry)
	atlas = _build_atlas()


## turns: quarter turns clockwise (seen from above) of a top texture, for
## blocks that face a direction (beds).
func _face_tile(def: Dictionary, face: String, turns := 0) -> int:
	var textures: Dictionary = def.get("textures", {})
	var rel = textures.get(face, textures.get("all"))
	if rel != null:
		var mod_id: String = def.get("mod", "")
		var path: String = rel
		if ":" in path:
			mod_id = path.get_slice(":", 0)
			path = path.get_slice(":", 1)
		var full := ModLoader.get_mod_path(mod_id).path_join(path)
		var key := full if turns % 4 == 0 else "%s@%d" % [full, turns % 4]
		if _tile_index.has(key):
			return _tile_index[key]
		var img := _load_image(full)
		if img:
			if img.get_size() != Vector2i(TILE_SIZE, TILE_SIZE):
				img.resize(TILE_SIZE, TILE_SIZE, Image.INTERPOLATE_NEAREST)
			for t in turns % 4:
				img.rotate_90(CLOCKWISE)
			return _add(key, img)
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
## One face's texture of a block (engine face order: +X, -X, +Y, -Y, +Z, -Z).
func face_texture(block_index: int, face: int) -> Texture2D:
	var key := "%d/%d" % [block_index, face]
	if not _icons.has(key):
		var tiles: PackedInt32Array = block_table[block_index].tiles
		_icons[key] = ImageTexture.create_from_image(_tiles[tiles[face]])
	return _icons[key]


const ICON_SIZE := 64

## A whole bed seen from above in one tile: the head's top (north half) over
## the foot's, each squeezed to half its length.
func _bed_top(id: String) -> Image:
	var head := Registry.block_index(BlockShapes.bed_id(id, "n", "head"))
	var out := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	var half := Vector2i(TILE_SIZE, TILE_SIZE / 2)
	for part in [[head, 0], [Registry.block_index(id), TILE_SIZE / 2]]:
		var img: Image = _tiles[block_table[part[0]].tiles[2]].duplicate()
		img.resize(half.x, half.y, Image.INTERPOLATE_NEAREST)
		out.blit_rect(img, Rect2i(Vector2i.ZERO, half), Vector2i(0, part[1]))
	return out


## A block drawn as a small 3D cube (top, left and right faces, shaded like the
## terrain) for inventory slots.
func _cube_icon(block_index: int, height := 1.0, top_image: Image = null) -> Image:
	var tiles: PackedInt32Array = block_table[block_index].tiles
	var top: Image = top_image if top_image else _tiles[tiles[2]]
	var left: Image = _tiles[tiles[5]]   # -Z: the face towards the viewer on the left
	var right: Image = _tiles[tiles[0]]  # +X
	var img := Image.create(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	var k := ICON_SIZE / 64.0
	# Corners of the cube outline (a 2:1 isometric view).
	var l := Vector2(4, 18) * k
	var back := Vector2(32, 4) * k
	var front := Vector2(32, 32) * k
	var rgt := Vector2(60, 18) * k
	var down := Vector2(0, 30) * k * height
	# A lower block (slab) sits at the bottom of the icon.
	var drop := Vector2(0, 30) * k * (1.0 - height)
	l += drop
	back += drop
	front += drop
	rgt += drop
	var faces := [
		[top, l, back - l, front - l, 1.0],
		[left, l, front - l, down, 0.8],
		[right, front, rgt - front, down, 0.62],
	]
	for y in ICON_SIZE:
		for x in ICON_SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			for f in faces:
				var o: Vector2 = f[1]
				var a: Vector2 = f[2]
				var b: Vector2 = f[3]
				# Solve p = o + u*a + v*b.
				var det := a.x * b.y - a.y * b.x
				var d := p - o
				var u := (d.x * b.y - d.y * b.x) / det
				var v := (a.x * d.y - a.y * d.x) / det
				if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
					continue
				var tex: Image = f[0]
				var ty := v if f[0] == top else 1.0 - (1.0 - v) * height
				var c := tex.get_pixel(int(u * TILE_SIZE), mini(int(ty * TILE_SIZE), TILE_SIZE - 1))
				if c.a < 0.5:
					continue
				var shade: float = f[4]
				img.set_pixel(x, y, Color(c.r * shade, c.g * shade, c.b * shade, 1.0))
				break
	return img


func icon(id: String) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var img: Image = null
	var shape: String = Registry.blocks.get(id, {}).get("shape", "cube")
	if Registry.blocks.has(id) and Registry.blocks[id].has("icon"):
		var def: Dictionary = Registry.blocks[id]
		img = _load_image(ModLoader.get_mod_path(def.get("mod", "")).path_join(def.icon))
	elif _icon_tiles.has(id) and shape in ["torch", "ladder", "cross", "door"]:
		img = _tiles[_icon_tiles[id]]  # flat things show their texture
	elif _icon_tiles.has(id):
		var top: Image = _bed_top(id) if shape == "bed" else null
		img = _cube_icon(Registry.block_index(id), 0.5 if shape == "slab" else (0.5625 if shape == "bed" else 1.0), top)
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

