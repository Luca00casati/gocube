extends VoxelGeneratorScript
## World generation: hills, beaches, sea, caves (native graph) and trees (GDScript).
##
## The voxel module's graph generator only outputs SDF, not block types, so the
## graph outputs a *category code* per voxel into the SDF channel, which is then
## copied into the TYPE channel and turned into block ids with remap_values()
## (a lookup table built once in setup()). Codes:
##     stone -2, dirt -1, grass -0.5, sand 0.5, water 1, air 2
## Stone and air lie beyond the graph's clip threshold (1.5), so blocks that are
## entirely deep rock or open sky are skipped/filled by the graph's range
## analysis; everything else lies inside it and is evaluated exactly.
##
## Trees cross chunk borders, so they are a GDScript pass after the graph: each
## block looks at the tree cells around it and recomputes the ground height there
## from the same noise the graph uses.

const AMPLITUDE := 24.0
const DIRT_DEPTH := 3
const SEA_LEVEL := -4
const CAVE_WIDTH := 0.11          # smaller = thinner tunnels
const CAVE_Y_SQUASH := 1.6        # >1 = flatter, more horizontal tunnels
const CAVE_MIN_Y := -60
const TREE_CELL := 8              # at most one tree per 8x8 columns
const TREE_CHANCE := 30           # percent of cells that get a tree
const SDF := VoxelBuffer.CHANNEL_SDF
const TYPE := VoxelBuffer.CHANNEL_TYPE
const COLOR := VoxelBuffer.CHANNEL_COLOR
const FULL_LIGHT := 0xFFFF  # RGBA4444 white: unlit areas look normal

const STONE := -2.0
const DIRT := -1.0
const GRASS := -0.5
const SAND := 0.5
const WATER := 1.0
const AIR := 2.0

var _graph := VoxelGeneratorGraph.new()
var _f: VoxelGraphFunction
var _remap := PackedInt32Array()     # raw quantized SDF value -> block id
var _ids := {}                       # category name -> block id
var _height_noise := ZN_FastNoiseLite.new()
var _cave_a := ZN_FastNoiseLite.new()
var _cave_b := ZN_FastNoiseLite.new()
var _seed := 0
var _write_light := false


func setup(world_seed: int, write_light: bool = false) -> void:
	_seed = world_seed
	_write_light = write_light
	for key in ["stone", "dirt", "grass", "sand", "water", "air", "log", "leaves"]:
		_ids[key] = Registry.block_index("core:" + key)
	_build_graph(world_seed)
	_build_remap()


func _get_used_channels_mask() -> int:
	return (1 << TYPE) | ((1 << COLOR) if _write_light else 0)


func _generate_block(out: VoxelBuffer, origin: Vector3i, lod: int) -> void:
	out.set_channel_depth(SDF, out.get_channel_depth(TYPE))
	_graph.generate_block(out, origin, lod)
	if out.is_uniform(SDF):
		out.fill(_block_for_code(out.get_voxel_f(0, 0, 0, SDF)), TYPE)
	else:
		out.set_channel_from_byte_array(TYPE, out.get_channel_as_byte_array(SDF))
		out.remap_values(TYPE, _remap)
	out.fill_f(0.0, SDF)  # free the scratch channel
	if lod == 0:
		_place_trees(out, origin)
	if _write_light:
		out.fill(FULL_LIGHT, COLOR)


func _block_for_code(code: float) -> int:
	var q := roundi(code * 2.0)
	if q <= -3: return _ids.stone
	if q == -2: return _ids.dirt
	if q == -1: return _ids.grass
	if q == 1: return _ids.sand
	if q == 2: return _ids.water
	return _ids.air


# --- Graph ---------------------------------------------------------------------------

## Creates a node; inputs are node ids (int) or constants (float).
func _node(type: int, inputs: Array = []) -> int:
	var id := _f.create_node(type, Vector2())
	for i in inputs.size():
		if inputs[i] is float:
			_f.set_node_default_input(id, i, inputs[i])
		else:
			_f.add_connection(inputs[i], 0, id, i)
	return id


## out = a if t < threshold else b
func _select(a, b, t, threshold: float) -> int:
	var id := _node(VoxelGraphFunction.NODE_SELECT, [a, b, t])
	_f.set_node_param(id, 0, threshold)
	return id


func _noise3(noise: ZN_FastNoiseLite, x: int, y: int, z: int) -> int:
	var id := _node(VoxelGraphFunction.NODE_FAST_NOISE_3D, [x, y, z])
	_f.set_node_param(id, 0, noise)
	return id


func _build_graph(world_seed: int) -> void:
	_f = _graph.get_main_function()
	_height_noise.seed = world_seed
	_height_noise.period = 1.0 / 0.008
	_height_noise.fractal_octaves = 4
	for n in [_cave_a, _cave_b]:
		n.seed = world_seed + (101 if n == _cave_a else 202)
		n.period = 48.0
		n.fractal_octaves = 1

	var x := _node(VoxelGraphFunction.NODE_INPUT_X)
	var y := _node(VoxelGraphFunction.NODE_INPUT_Y)
	var z := _node(VoxelGraphFunction.NODE_INPUT_Z)

	# Terrain height h(x, z) and depth below it: d = clamp(y - h, -3, 1)
	var hn := _node(VoxelGraphFunction.NODE_FAST_NOISE_2D, [x, z])
	_f.set_node_param(hn, 0, _height_noise)
	var h := _node(VoxelGraphFunction.NODE_FLOOR, [_node(VoxelGraphFunction.NODE_MULTIPLY, [hn, AMPLITUDE])])
	var d := _node(VoxelGraphFunction.NODE_CLAMP, [_node(VoxelGraphFunction.NODE_SUBTRACT, [y, h]), -float(DIRT_DEPTH), 1.0])

	# Layers: grass on top, dirt below, stone deeper, air above.
	var c := _select(DIRT, GRASS, d, -0.5)
	c = _select(STONE, c, d, -2.5)
	c = _select(c, AIR, d, 0.5)

	# Beaches: columns near or below sea level get sand instead of grass/dirt.
	var sandy := _select(c, _select(SAND, c, c, 0.0), c, -1.5)
	var beach_t := _node(VoxelGraphFunction.NODE_SUBTRACT, [h, SEA_LEVEL + 1.5])
	c = _select(sandy, c, beach_t, 0.0)

	# Sea: air below sea level is water.
	var wet := _select(c, WATER, c, 1.5)
	c = _select(wet, c, y, SEA_LEVEL + 0.5)

	# Caves: tunnels where two 3D noises are both near zero.
	var ys := _node(VoxelGraphFunction.NODE_MULTIPLY, [y, CAVE_Y_SQUASH])
	var ca := _node(VoxelGraphFunction.NODE_ABS, [_noise3(_cave_a, x, ys, z)])
	var cb := _node(VoxelGraphFunction.NODE_ABS, [_noise3(_cave_b, x, ys, z)])
	var cave := _node(VoxelGraphFunction.NODE_ADD, [ca, cb])
	var carved := _select(_select(AIR, c, cave, CAVE_WIDTH), c, c, 0.0)  # only carve solids
	# Allowed on land columns, or deep under the sea floor (so the sea doesn't
	# open into dry tunnels), and not below CAVE_MIN_Y.
	var land := _node(VoxelGraphFunction.NODE_SUBTRACT, [h, SEA_LEVEL + 2.0])
	var deep := _node(VoxelGraphFunction.NODE_SUBTRACT, [_node(VoxelGraphFunction.NODE_SUBTRACT, [h, 5.0]), y])
	var gate := _node(VoxelGraphFunction.NODE_MIN, [
			_node(VoxelGraphFunction.NODE_MAX, [land, deep]),
			_node(VoxelGraphFunction.NODE_SUBTRACT, [y, float(CAVE_MIN_Y)])])
	c = _select(c, carved, gate, 0.0)

	_node(VoxelGraphFunction.NODE_OUTPUT_SDF, [c])
	var result = _graph.compile()
	assert(result.success, "Terrain graph failed to compile: %s" % [result])


## Raw stored SDF value -> block id, for every possible value (quantization is
## an engine detail, so each raw value is decoded once via a probe buffer).
func _build_remap() -> void:
	var probe := VoxelBuffer.new()
	probe.create(1, 1, 1)
	var count := 1 << (8 << probe.get_channel_depth(SDF))  # 8/16-bit only
	_remap.resize(count)
	for raw in count:
		probe.set_voxel(raw, 0, 0, 0, SDF)
		_remap[raw] = _block_for_code(probe.get_voxel_f(0, 0, 0, SDF))


# --- Trees ---------------------------------------------------------------------------

## Same height the graph computes (float32 there, so rare off-by-one at exact
## integer boundaries; a tree may then sit one block high or low).
func height_at(x: int, z: int) -> int:
	return floori(_height_noise.get_noise_2d(x, z) * AMPLITUDE)


func _is_cave(x: int, y: int, z: int) -> bool:
	var ys := y * CAVE_Y_SQUASH
	return absf(_cave_a.get_noise_3d(x, ys, z)) + absf(_cave_b.get_noise_3d(x, ys, z)) < CAVE_WIDTH


## Trees whose leaves can reach columns in `rect` (x/y = world x/z):
## [{x, z, ground, trunk}]. Deterministic, so generation and skylight agree.
func trees_near(rect: Rect2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var reach := 3  # leaves extend 2 blocks from the trunk
	for cz in range(floori(float(rect.position.y - reach) / TREE_CELL), floori(float(rect.end.y + reach) / TREE_CELL) + 1):
		for cx in range(floori(float(rect.position.x - reach) / TREE_CELL), floori(float(rect.end.x + reach) / TREE_CELL) + 1):
			var r: int = hash([_seed, cx, cz]) & 0x7fffffff
			if r % 100 >= TREE_CHANCE:
				continue
			var tx := cx * TREE_CELL + 1 + (r >> 8) % (TREE_CELL - 2)
			var tz := cz * TREE_CELL + 1 + (r >> 12) % (TREE_CELL - 2)
			var ground := height_at(tx, tz)
			if ground <= SEA_LEVEL + 1 or _is_cave(tx, ground, tz):
				continue  # beach, sea or a cave mouth: no tree
			out.append({"x": tx, "z": tz, "ground": ground, "trunk": 4 + (r >> 16) % 3})
	return out


func _place_trees(out: VoxelBuffer, origin: Vector3i) -> void:
	var size := out.get_size()
	if origin.y > AMPLITUDE + 10 or origin.y + size.y < SEA_LEVEL + 2:
		return  # no tree can reach this block
	for t in trees_near(Rect2i(origin.x, origin.z, size.x, size.z)):
		if t.ground + t.trunk + 2 < origin.y or t.ground + 1 >= origin.y + size.y:
			continue
		_tree(out, origin, size, Vector3i(t.x, t.ground + 1, t.z), t.trunk)


func _tree(out: VoxelBuffer, origin: Vector3i, size: Vector3i, base: Vector3i, trunk: int) -> void:
	# Leaves: two wide layers around the top of the trunk, two narrow ones above.
	for dy in range(trunk - 2, trunk + 2):
		var radius := 2 if dy < trunk else 1
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius == 2 and absi(dx) == 2 and absi(dz) == 2:
					continue  # round off the corners
				_set_if_air(out, base + Vector3i(dx, dy, dz) - origin, size, _ids.leaves)
	for dy in trunk:
		var p := base + Vector3i(0, dy, 0) - origin
		if p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < size.x and p.y < size.y and p.z < size.z:
			out.set_voxel(_ids.log, p.x, p.y, p.z, TYPE)


func _set_if_air(out: VoxelBuffer, p: Vector3i, size: Vector3i, id: int) -> void:
	if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= size.x or p.y >= size.y or p.z >= size.z:
		return
	if out.get_voxel(p.x, p.y, p.z, TYPE) == _ids.air:
		out.set_voxel(id, p.x, p.y, p.z, TYPE)
