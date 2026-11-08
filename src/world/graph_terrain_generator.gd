extends VoxelGeneratorScript
## Heightmap world (grass / dirt / stone) computed natively.
##
## The voxel module's graph generator only outputs SDF, not block types, so:
##  1. A VoxelGeneratorGraph evaluates  d = clamp(y - floor(height(x, z)), -3, 1)
##     into the SDF channel (native, vectorized, skips uniform blocks).
##  2. The raw SDF channel is copied into the TYPE channel and turned into block
##     ids with remap_values() via a lookup table built once in setup().
## GDScript only makes a handful of calls per block.

const AMPLITUDE := 24.0
const DIRT_DEPTH := 3
const SDF := VoxelBuffer.CHANNEL_SDF
const TYPE := VoxelBuffer.CHANNEL_TYPE

var _graph := VoxelGeneratorGraph.new()
var _remap := PackedInt32Array()     # raw quantized SDF value -> block id
var _uniform := {}                   # float d -> block id, for uniform blocks


func setup(world_seed: int) -> void:
	_build_graph(world_seed)
	var stone := Registry.block_index("core:stone")
	var dirt := Registry.block_index("core:dirt")
	var grass := Registry.block_index("core:grass")
	var air := Registry.block_index("core:air")
	# d is an integer in [-3, 1]: 1 air, 0 grass, -1..-2 dirt, -3 stone.
	var by_d := {1: air, 0: grass}
	for d in range(-DIRT_DEPTH + 1, 0):
		by_d[d] = dirt
	by_d[-DIRT_DEPTH] = stone
	_uniform = by_d
	_build_remap(by_d)


func _get_used_channels_mask() -> int:
	return 1 << TYPE


func _generate_block(out: VoxelBuffer, origin: Vector3i, lod: int) -> void:
	out.set_channel_depth(SDF, out.get_channel_depth(TYPE))
	_graph.generate_block(out, origin, lod)
	if out.is_uniform(SDF):
		var d := roundi(out.get_voxel_f(0, 0, 0, SDF))
		out.fill(_uniform[clampi(d, -DIRT_DEPTH, 1)], TYPE)
	else:
		out.set_channel_from_byte_array(TYPE, out.get_channel_as_byte_array(SDF))
		out.remap_values(TYPE, _remap)
	out.fill_f(0.0, SDF)  # free the scratch channel


func _build_graph(world_seed: int) -> void:
	var f := _graph.get_main_function()
	var noise := ZN_FastNoiseLite.new()
	noise.seed = world_seed
	noise.period = 1.0 / 0.008
	noise.fractal_octaves = 4

	var x := f.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2())
	var y := f.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2())
	var z := f.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2())
	var n := f.create_node(VoxelGraphFunction.NODE_FAST_NOISE_2D, Vector2())
	f.set_node_param(n, 0, noise)
	var amp := f.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2())
	f.set_node_default_input(amp, 1, AMPLITUDE)
	var fl := f.create_node(VoxelGraphFunction.NODE_FLOOR, Vector2())
	var sub := f.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2())
	var cl := f.create_node(VoxelGraphFunction.NODE_CLAMP, Vector2())
	f.set_node_default_input(cl, 1, -DIRT_DEPTH)
	f.set_node_default_input(cl, 2, 1.0)
	var out := f.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2())

	f.add_connection(x, 0, n, 0)
	f.add_connection(z, 0, n, 1)
	f.add_connection(n, 0, amp, 0)
	f.add_connection(amp, 0, fl, 0)
	f.add_connection(y, 0, sub, 0)
	f.add_connection(fl, 0, sub, 1)
	f.add_connection(sub, 0, cl, 0)
	f.add_connection(cl, 0, out, 0)
	var result = _graph.compile()
	assert(result.success, "Terrain graph failed to compile: %s" % [result])


## Builds a raw-value -> block-id table covering every possible stored value.
## The graph may write any SDF (e.g. large values in sub-blocks it skips), and
## quantization is an engine detail, so decode each raw value once via a probe.
func _build_remap(by_d: Dictionary) -> void:
	var probe := VoxelBuffer.new()
	probe.create(1, 1, 1)
	var count := 1 << (8 << probe.get_channel_depth(SDF))  # 8/16-bit only
	_remap.resize(count)
	for raw in count:
		probe.set_voxel(raw, 0, 0, 0, SDF)
		var d := clampi(roundi(probe.get_voxel_f(0, 0, 0, SDF)), -DIRT_DEPTH, 1)
		_remap[raw] = by_d[d]
