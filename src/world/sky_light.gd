class_name SkyLight
extends RefCounted
## Classic column skylight. Keeps, for a window of world columns around the
## player, the "top" of each column (first air y above its highest opaque
## block) in an R32F texture the terrain shader reads (terrain.gdshader).
##
## Tops come from the world generator's own height function (+ tree canopies),
## so nothing has to scan voxel data. Player edits change columns; those are
## kept in `overrides`, saved with the world and sent to multiplayer clients.

const SIZE := 320                # columns per side; covers view distance 128 + margin
const RECENTER_DISTANCE := 48    # shift the window after moving this far
const UNSET := Vector2i(1 << 30, 1 << 30)

## Column (Vector2i x, z) -> top, for columns changed by edits.
var overrides := {}

var _gen        # the terrain generator: height_at(), trees_near()
var _material: ShaderMaterial
var _tool: VoxelTool
var _opaque := PackedByteArray()  # per block index
var _image: Image
var _texture: ImageTexture
var _origin := UNSET


func _init(generator, material: ShaderMaterial, tool: VoxelTool, saved: Dictionary = {}) -> void:
	_gen = generator
	_material = material
	_tool = tool
	_tool.channel = VoxelBuffer.CHANNEL_TYPE
	_opaque.resize(Registry.block_ids.size())
	for i in Registry.block_ids.size():
		var def = Registry.blocks.get(Registry.block_ids[i])
		_opaque[i] = 1 if def == null or (def.get("solid", true) and not def.has("fluid")) else 0
	_opaque[Registry.block_index("core:air")] = 0
	for key in saved:
		var xz: PackedStringArray = str(key).split(",")
		overrides[Vector2i(int(xz[0]), int(xz[1]))] = int(saved[key])
	_image = Image.create(SIZE, SIZE, false, Image.FORMAT_RF)
	_texture = ImageTexture.create_from_image(_image)
	_material.set_shader_parameter("sky_tops", _texture)


## Call every frame with the player position; refills the window when needed.
func follow(pos: Vector3) -> void:
	var want := Vector2i(floori(pos.x), floori(pos.z)) - Vector2i(SIZE / 2, SIZE / 2)
	if _origin == UNSET:
		_set_origin(want)
		_fill(Rect2i(want, Vector2i(SIZE, SIZE)))
	elif maxi(absi(want.x - _origin.x), absi(want.y - _origin.y)) > RECENTER_DISTANCE:
		_shift_to(want)
	else:
		return
	_texture.update(_image)


func serialize() -> Dictionary:
	var out := {}
	for col in overrides:
		out["%d,%d" % [col.x, col.y]] = overrides[col]
	return out


## After a block changed at `pos`: recompute its column. Returns the new top.
func on_edit(pos: Vector3i, block: int) -> int:
	var col := Vector2i(pos.x, pos.z)
	var top := get_top(col)
	if _opaque[block] and pos.y >= top:
		top = pos.y + 1
	elif not _opaque[block] and pos.y == top - 1:
		top = _scan_down(col, pos.y - 1)
	else:
		return top
	set_top(col, top)
	return top


## Sets a column's top (from an edit here, or one the host sent us).
func set_top(col: Vector2i, top: int) -> void:
	overrides[col] = top
	var px := col - _origin
	if _origin != UNSET and px.x >= 0 and px.y >= 0 and px.x < SIZE and px.y < SIZE:
		_image.set_pixel(px.x, px.y, Color(top, 0, 0))
		_texture.update(_image)


func get_top(col: Vector2i) -> int:
	if overrides.has(col):
		return overrides[col]
	var px := col - _origin
	if _origin != UNSET and px.x >= 0 and px.y >= 0 and px.x < SIZE and px.y < SIZE:
		return int(_image.get_pixel(px.x, px.y).r)
	var tops := _base_tops(Rect2i(col, Vector2i.ONE))
	return int(tops[0])


func _scan_down(col: Vector2i, from_y: int) -> int:
	for y in range(from_y, from_y - 256, -1):
		if _opaque[_tool.get_voxel(Vector3i(col.x, y, col.y))]:
			return y + 1
	return from_y - 255


func _set_origin(origin: Vector2i) -> void:
	_origin = origin
	_material.set_shader_parameter("sky_origin", Vector2(origin))
	_material.set_shader_parameter("sky_size", float(SIZE))


## Moves the window, keeping the overlapping part and computing only new strips.
func _shift_to(origin: Vector2i) -> void:
	var old := _image
	var old_origin := _origin
	_image = Image.create(SIZE, SIZE, false, Image.FORMAT_RF)
	_set_origin(origin)
	var keep := Rect2i(old_origin, Vector2i(SIZE, SIZE)).intersection(Rect2i(origin, Vector2i(SIZE, SIZE)))
	if keep.has_area():
		_image.blit_rect(old, Rect2i(keep.position - old_origin, keep.size), keep.position - origin)
	var full := Rect2i(origin, Vector2i(SIZE, SIZE))
	# New columns: the parts of `full` outside `keep` (at most two strips).
	if not keep.has_area():
		_fill(full)
		return
	if keep.position.x > full.position.x:
		_fill(Rect2i(full.position.x, full.position.y, keep.position.x - full.position.x, SIZE))
	if keep.end.x < full.end.x:
		_fill(Rect2i(keep.end.x, full.position.y, full.end.x - keep.end.x, SIZE))
	var x0 := keep.position.x
	var x1 := keep.end.x
	if keep.position.y > full.position.y:
		_fill(Rect2i(x0, full.position.y, x1 - x0, keep.position.y - full.position.y))
	if keep.end.y < full.end.y:
		_fill(Rect2i(x0, keep.end.y, x1 - x0, full.end.y - keep.end.y))


## Computes tops for a world rect and writes them into the window image.
func _fill(rect: Rect2i) -> void:
	var tops := _base_tops(rect)
	var sub := Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_RF, tops.to_byte_array())
	_image.blit_rect(sub, Rect2i(Vector2i.ZERO, rect.size), rect.position - _origin)


## Generator height + tree canopies + edit overrides, row-major over `rect`.
func _base_tops(rect: Rect2i) -> PackedFloat32Array:
	var w := rect.size.x
	var tops := PackedFloat32Array()
	tops.resize(w * rect.size.y)
	var i := 0
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			tops[i] = _gen.height_at(x, z) + 1
			i += 1
	for tree in _gen.trees_near(rect):
		# Leaves: radius 1 up to base+trunk+1, radius 2 (no corners) up to base+trunk-1.
		var base: int = tree.ground + 1
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				var inner := absi(dx) <= 1 and absi(dz) <= 1
				if not inner and absi(dx) == 2 and absi(dz) == 2:
					continue
				var top: int = base + tree.trunk + (2 if inner else 0)
				var c := Vector2i(tree.x + dx, tree.z + dz) - rect.position
				if c.x >= 0 and c.y >= 0 and c.x < w and c.y < rect.size.y:
					tops[c.y * w + c.x] = maxf(tops[c.y * w + c.x], top)
	for col in overrides:
		var c: Vector2i = col - rect.position
		if c.x >= 0 and c.y >= 0 and c.x < w and c.y < rect.size.y:
			tops[c.y * w + c.x] = overrides[col]
	return tops
