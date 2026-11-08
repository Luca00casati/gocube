class_name LightPrototype
## PROTOTYPE: block-by-block light flood in GDScript, to measure feasibility.
## Computes sky light (from the top of the region) and block light (from
## emitting blocks) for a box, and writes the result into the COLOR channel.
## Each solid block gets the brightest light of its air neighbours (the mesher
## tints whole blocks, not faces).

const MAX_LIGHT := 15


## Returns timings in ms: {"read", "flood", "write", "total"}.
static func relight(tool: VoxelTool, origin: Vector3i, size: Vector3i, emitters: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var buf := VoxelBuffer.new()
	buf.create(size.x, size.y, size.z)
	tool.copy(origin, buf, 1 << VoxelBuffer.CHANNEL_TYPE)
	var types := buf.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
	var n := size.x * size.y * size.z
	# per block id: solid? emission?
	var solid_of := PackedByteArray(); solid_of.resize(Registry.block_ids.size())
	var emit_of := PackedByteArray(); emit_of.resize(Registry.block_ids.size())
	for i in Registry.block_ids.size():
		var def = Registry.blocks.get(Registry.block_ids[i])
		solid_of[i] = 1 if (def == null or def.get("solid", true)) else 0
		emit_of[i] = emitters.get(Registry.block_ids[i], 0)
	var solid := PackedByteArray(); solid.resize(n)
	var sky := PackedByteArray(); sky.resize(n)
	var blk := PackedByteArray(); blk.resize(n)
	var q := PackedInt32Array()
	for i in n:
		var id := types.decode_u16(i * 2)
		solid[i] = solid_of[id]
		var e := emit_of[id]
		if e > 0:
			blk[i] = e
			q.append(i)
	var t1 := Time.get_ticks_usec()

	# ZXY layout: index = y + sy * (x + sx * z)
	var sy := size.y
	var sxy := size.x * size.y
	_flood(q, blk, solid, size, sy, sxy, true)
	# sky: straight down from the top of the region until something solid
	var sq := PackedInt32Array()
	for z in size.z:
		for x in size.x:
			var base := sy * (x + size.x * z)
			var y := sy - 1
			while y >= 0 and solid[base + y] == 0:
				sky[base + y] = MAX_LIGHT
				sq.append(base + y)
				y -= 1
	_flood(sq, sky, solid, size, sy, sxy, false)
	var t2 := Time.get_ticks_usec()

	# colour per solid block from its brightest air neighbour
	var colors := PackedByteArray(); colors.resize(n * 2)
	var offsets := [1, -1, sy, -sy, sxy, -sxy]
	for i in n:
		var s := 0
		var b := 0
		if solid[i] == 0:
			s = sky[i]; b = blk[i]
		else:
			for o in offsets:
				var j: int = i + o
				if j >= 0 and j < n and solid[j] == 0:
					s = maxi(s, sky[j]); b = maxi(b, blk[j])
			if emit_of[types.decode_u16(i * 2)] > 0:
				b = MAX_LIGHT
		colors.encode_u16(i * 2, _encode(s, b))
	buf.set_channel_depth(VoxelBuffer.CHANNEL_COLOR, VoxelBuffer.DEPTH_16_BIT)
	buf.set_channel_from_byte_array(VoxelBuffer.CHANNEL_COLOR, colors)
	tool.paste(origin, buf, 1 << VoxelBuffer.CHANNEL_COLOR)
	var t3 := Time.get_ticks_usec()
	return {"read": (t1 - t0) / 1000.0, "flood": (t2 - t1) / 1000.0, "write": (t3 - t2) / 1000.0, "total": (t3 - t0) / 1000.0}


## BFS: each step loses 1 level. emitting=true also lets light leave emitter blocks.
static func _flood(q: PackedInt32Array, light: PackedByteArray, solid: PackedByteArray,
		size: Vector3i, sy: int, sxy: int, emitting: bool) -> void:
	var head := 0
	while head < q.size():
		var i := q[head]; head += 1
		var l := light[i] - 1
		if l <= 0:
			continue
		var y := i % sy
		var x := (i / sy) % size.x
		var z := i / sxy
		if y > 0: _try(q, light, solid, i - 1, l)
		if y < sy - 1: _try(q, light, solid, i + 1, l)
		if x > 0: _try(q, light, solid, i - sy, l)
		if x < size.x - 1: _try(q, light, solid, i + sy, l)
		if z > 0: _try(q, light, solid, i - sxy, l)
		if z < size.z - 1: _try(q, light, solid, i + sxy, l)


static func _try(q: PackedInt32Array, light: PackedByteArray, solid: PackedByteArray, j: int, l: int) -> void:
	if solid[j] == 0 and light[j] < l:
		light[j] = l
		q.append(j)


## Sky light is neutral white, block light warm. 4 bits per channel.
static func _encode(sky_level: int, block_level: int) -> int:
	var s := _curve(sky_level)
	var b := _curve(block_level)
	var r := clampf(s + b * 1.0, 0, 1)
	var g := clampf(s + b * 0.82, 0, 1)
	var bl := clampf(s + b * 0.55, 0, 1)
	return (roundi(r * 15) << 12) | (roundi(g * 15) << 8) | (roundi(bl * 15) << 4) | 0xF


static func _curve(level: int) -> float:
	return 0.0 if level <= 0 else pow(0.8, MAX_LIGHT - level)
