class_name BlockShapes
## Block shapes other than full cubes. A block definition's "shape":
##   "slab", "stairs", "torch", "ladder", "door", "fence", "cross" (plants)
## Shapes that face a direction or have states get variant blocks, registered
## next to the base block as "<id>_<suffix>" with "variant_of": base, so they
## drop the base item and stay out of inventories. Placement picks the variant
## from the clicked face and the way the player looks (placement()).
##
## Boxes are in 1/16 block units here and are sent to the engine (0..1) as
## PackedFloat32Array, 7 floats per box: min xyz, max xyz, texture y offset.

const FACINGS := ["n", "e", "s", "w"]           # towards -z, +x, +z, -x
const ENGINE_SHAPE := {"cube": 0, "boxes": 1, "slab": 1, "stairs": 1, "torch": 1, "ladder": 1, "door": 1,
		"fence": 3, "cross": 2}
## Shapes you walk through.
const NOT_SOLID := ["torch", "ladder", "cross"]


## The variant blocks to register for a base block: {suffix: def}. The base
## block itself is the first variant (suffix "").
static func variants(def: Dictionary) -> Dictionary:
	var out := {}
	match def.get("shape", "cube"):
		"slab":
			out[""] = {"half": "bottom"}
			out["_top"] = {"half": "top"}
		"stairs", "ladder":
			for i in 4:
				out["" if i == 0 else "_" + FACINGS[i]] = {"facing": FACINGS[i]}
		"torch":
			out[""] = {"facing": "floor"}
			for f in FACINGS:
				out["_wall_" + f] = {"facing": f}
		"door":
			for f in FACINGS:
				for half in ["lower", "upper"]:
					for open in [false, true]:
						var suffix := "_%s_%s%s" % [f, half, "_open" if open else ""]
						if f == "n" and half == "lower" and not open:
							suffix = ""
						out[suffix] = {"facing": f, "half": half, "open": open}
		_:
			out[""] = {}
	return out


## Expands every shaped block in `blocks` (id -> def) with its variants.
static func expand(blocks: Dictionary) -> void:
	for id in blocks.keys():
		var def: Dictionary = blocks[id]
		if def.get("leaves", false) and not def.has("variant_of"):
			var placed: Dictionary = def.duplicate(true)
			placed.id = id + "_placed"
			placed.variant_of = id
			placed.leaves = false  # placed by a player: never decays
			if not def.has("drops"):
				placed.drops = id
			blocks[placed.id] = placed
		var shape: String = def.get("shape", "cube")
		if shape == "cube" or def.has("variant_of"):
			continue
		if shape in NOT_SOLID:
			def.solid = false
		def.transparent = true
		var vs := variants(def)
		def.state = vs[""]
		for suffix in vs:
			if suffix == "":
				continue
			var v: Dictionary = def.duplicate(true)
			v.id = id + suffix
			v.variant_of = id
			v.state = vs[suffix]
			if not def.has("drops"):
				v.drops = id
			if shape == "door" and vs[suffix].half == "upper" and def.has("textures_upper"):
				v.textures = def.textures_upper
			blocks[v.id] = v


## The base block of a variant (or the block itself).
static func base_of(id: String) -> String:
	return str(Registry.blocks.get(id, {}).get("variant_of", id))


## Engine fields for the block table: shape, model and collision boxes.
static func engine_fields(def: Dictionary) -> Dictionary:
	var shape: String = def.get("shape", "cube")
	if shape == "cube" or not ENGINE_SHAPE.has(shape):
		return {}
	var out := {"shape": ENGINE_SHAPE[shape]}
	if ENGINE_SHAPE[shape] == 1:
		var boxes: Array = def.get("boxes", []).map(func(b): return b + [0]) if shape == "boxes" \
				else model_boxes(shape, def.get("state", {}))
		out.model = _pack(boxes)
		out.collision = _pack([] if shape in NOT_SOLID else boxes)
	elif shape == "cross":
		out.collision = PackedFloat32Array()
	return out


## The boxes of a shape in a state, in 1/16 units: [x0, y0, z0, x1, y1, z1, ty].
static func model_boxes(shape: String, state: Dictionary) -> Array:
	var boxes := []
	var turns := FACINGS.find(str(state.get("facing", "n")))
	match shape:
		"slab":
			boxes = [[0, 8, 0, 16, 16, 16, 0]] if state.get("half") == "top" else [[0, 0, 0, 16, 8, 16, 0]]
		"stairs":
			boxes = [[0, 0, 0, 16, 8, 16, 0], [0, 8, 0, 16, 16, 8, 0]]  # the high side towards the facing
		"torch":
			if state.get("facing") == "floor":
				return [[7, 0, 7, 9, 10, 9, 0]]
			# On a wall: raised by 4/16 against the wall on the facing side (texture
			# offset so the flame stays at the top).
			boxes = [[7, 4, 0.5, 9, 14, 2.5, 4]]
		"ladder":
			boxes = [[0, 0, 0, 16, 16, 1, 0]]
		"door":
			boxes = [[0, 0, 0, 16, 16, 3, 0]]
			if state.get("open", false):
				turns += 3  # swung open against the side wall
	var out := []
	for b in boxes:
		out.append(_rotate(b, turns % 4 if turns >= 0 else 0))
	return out


## Quarter turns clockwise seen from above: north -> east -> south -> west.
static func _rotate(b: Array, turns: int) -> Array:
	var r := b.duplicate()
	for t in turns:
		# (x, z) -> (16 - z, x)
		var x0: float = 16 - r[5]
		var x1: float = 16 - r[2]
		r = [x0, r[1], r[0], x1, r[4], r[3], r[6]]
	return r


static func _pack(boxes: Array) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	for b in boxes:
		for k in 7:
			a.append(b[k] / 16.0)
	return a


# --- Placement --------------------------------------------------------------------

## Where and what to place when using block item `base` on a raycast hit.
## look: the player's view direction. Returns [[pos, id], ...] (doors place
## two blocks) or [] if it can't go there.
static func placement(base: String, hit: Dictionary, look: Vector3, hit_point: Vector3) -> Array:
	var def: Dictionary = Registry.blocks.get(base, {})
	var pos: Vector3i = hit.previous
	var n: Vector3i = hit.normal
	if def.get("leaves", false):
		return [[pos, base + "_placed"]]
	match def.get("shape", "cube"):
		"slab":
			var top := n.y == -1 or (n.y == 0 and fposmod(hit_point.y, 1.0) > 0.5)
			return [[pos, base + ("_top" if top else "")]]
		"stairs":
			return [[pos, _variant(base, _look_facing(look))]]
		"torch":
			if n.y == 1:
				return [[pos, base]]
			if n.y == -1:
				return []
			return [[pos, base + "_wall_" + _wall_facing(n)]]
		"ladder":
			if n.y != 0:
				return []
			return [[pos, _variant(base, _wall_facing(n))]]
		"door":
			var f := _look_facing(look)
			return [[pos, door_id(base, f, "lower", false)], [pos + Vector3i.UP, door_id(base, f, "upper", false)]]
	return [[pos, base]]


## The wall a block sits against when placed on a face with normal n (n points
## from the wall into the new block's cell).
static func _wall_facing(n: Vector3i) -> String:
	if n.z == 1:
		return "n"
	if n.z == -1:
		return "s"
	if n.x == 1:
		return "w"
	return "e"


static func _look_facing(look: Vector3) -> String:
	if absf(look.x) > absf(look.z):
		return "e" if look.x > 0 else "w"
	return "s" if look.z > 0 else "n"


static func _variant(base: String, facing: String) -> String:
	return base if facing == "n" else base + "_" + facing


static func door_id(base: String, facing: String, half: String, open: bool) -> String:
	if facing == "n" and half == "lower" and not open:
		return base
	return "%s_%s_%s%s" % [base, facing, half, "_open" if open else ""]


## For a door half at pos: [[pos, new id], [other half pos, new id]] that opens
## or closes it, or [] if it isn't a door.
static func toggle_door(id: String, pos: Vector3i) -> Array:
	var def: Dictionary = Registry.blocks.get(id, {})
	if def.get("shape") != "door":
		return []
	var base := base_of(id)
	var st: Dictionary = def.get("state", {})
	var open: bool = not st.get("open", false)
	var other := pos + (Vector3i.UP if st.half == "lower" else Vector3i.DOWN)
	var other_half := "upper" if st.half == "lower" else "lower"
	return [[pos, door_id(base, st.facing, st.half, open)], [other, door_id(base, st.facing, other_half, open)]]


## The other half of a door at pos (to remove it too), or null.
static func door_other_half(id: String, pos: Vector3i):
	var def: Dictionary = Registry.blocks.get(id, {})
	if def.get("shape") != "door":
		return null
	return pos + (Vector3i.UP if def.state.half == "lower" else Vector3i.DOWN)
