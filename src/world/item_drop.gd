class_name ItemDrop
extends Node3D
## An item lying in the world: falls, spins and bobs, and drifts to the local
## player when close, then goes into their inventory. Merges with the same item
## nearby; disappears after LIFETIME seconds. Blocks show as small cubes, other
## items as their icon given depth (each pixel a little block).

signal picked_up(item: String, count: int)

const BOX := Vector3(0.25, 0.25, 0.25)
const GRAVITY := 20.0
const PICKUP_DELAY := 0.5      # don't grab it in the same instant it pops out
const MAGNET_RADIUS := 2.6
const PICKUP_RADIUS := 1.2
const LIFETIME := 300.0

var item := ""
var count := 1
var drop_id := 0              # its id in ItemDrops (shared in multiplayer)
## Multiplayer client: the host simulates this drop; we move it to
## target_position and ask the host for it (request_pickup) when we reach it.
var remote := false
var target_position := Vector3.ZERO
var request_pickup: Callable
var _asked := -INF            # when we last asked the host for it
var world: World
var player: Node3D            # the local player (player.gd)
var velocity := Vector3.ZERO
var _age := 0.0
var _model: MeshInstance3D

const SHADER := preload("res://src/world/item_drop.gdshader")
const CUBE_SIZE := 0.25
const ITEM_SIZE := 0.42      # an item's icon spans this many metres
const ITEM_THICKNESS := 0.035
static var _meshes := {}     # item id -> ArrayMesh (with its materials)
static var _mats: Array[ShaderMaterial] = []


## atlas: for the textures (null = no model, e.g. in tests).
func setup(item_id: String, amount: int, atlas: BlockAtlas) -> void:
	item = item_id
	count = amount
	if atlas == null:
		return
	_model = MeshInstance3D.new()
	_model.mesh = model_mesh(item_id, atlas)
	_model.position.y = BOX.y
	_model.rotation.y = randf() * TAU
	add_child(_model)


## Follows the time of day like the terrain (0..1 daylight).
static func set_daylight(amount: float) -> void:
	var light := lerpf(DayCycle.NIGHT_CREATURE_LIGHT, 1.0, amount)
	for m in _mats:
		m.set_shader_parameter("light", light)


static func _material(tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("tex", tex)
	_mats.append(m)
	return m


## The 3D model of an item: a cube for placeable blocks, else the icon extruded.
static func model_mesh(item_id: String, atlas: BlockAtlas) -> ArrayMesh:
	if not _meshes.has(item_id):
		var index := Registry.block_index(item_id) if Registry.blocks.has(item_id) else -1
		if index >= 0 and Registry.blocks[item_id].get("shape") == "bed":
			_meshes[item_id] = _bed_mesh(item_id, atlas)
		elif index >= 0 and atlas.block_table[index].solid:
			_meshes[item_id] = _cube_mesh(index, atlas, _model_bounds(item_id))
		else:
			_meshes[item_id] = _extruded_mesh(atlas.icon(item_id))
	return _meshes[item_id]


## The part of the block cell a single-box block fills (a slab, a bed), in
## 0..1 cell units; the whole cell for everything else.
static func _model_bounds(item_id: String) -> AABB:
	var def: Dictionary = Registry.blocks.get(item_id, {})
	var boxes: Array = []
	match def.get("shape", "cube"):
		"slab":
			boxes = BlockShapes.model_boxes("slab", {"half": "bottom"})
		"boxes":
			boxes = def.get("boxes", [])
		"bed":
			boxes = BlockShapes.model_boxes("bed", {})
	if boxes.size() != 1:
		return AABB(Vector3.ZERO, Vector3.ONE)
	var b: Array = boxes[0]
	var mn := Vector3(b[0], b[1], b[2]) / 16.0
	return AABB(mn, Vector3(b[3], b[4], b[5]) / 16.0 - mn)


## A cube with each face's own texture (engine face order +X,-X,+Y,-Y,+Z,-Z),
## shrunk to `bounds` (0..1 of the cell; the texture is cropped to match, as
## in the world) and standing on the bottom of the cell.
static func _cube_mesh(block_index: int, atlas: BlockAtlas, bounds := AABB(Vector3.ZERO, Vector3.ONE)) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_add_box(mesh, block_index, atlas, bounds)
	return mesh


## A whole bed in one cell: the head half (pillow) towards -Z, the foot half
## towards +Z, each squeezed to half its length.
static func _bed_mesh(item_id: String, atlas: BlockAtlas) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var height: float = BlockShapes.model_boxes("bed", {})[0][4] / 16.0
	var head := Registry.block_index(BlockShapes.bed_id(item_id, "n", "head"))
	# Without the two faces where the halves meet (the hand draws over everything).
	_add_box(mesh, Registry.block_index(item_id), atlas, AABB(Vector3(0, 0, 0.5), Vector3(1, height, 0.5)), 5)
	_add_box(mesh, head, atlas, AABB(Vector3.ZERO, Vector3(1, height, 0.5)), 4)
	return mesh


## skip: a face index to leave out, or -1.
static func _add_box(mesh: ArrayMesh, block_index: int, atlas: BlockAtlas, bounds: AABB, skip := -1) -> void:
	var h := CUBE_SIZE / 2.0
	var normals := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
	for f in 6:
		if f == skip:
			continue
		var n: Vector3 = normals[f]
		# Two axes across the face: u to the right, v downwards (as seen from outside).
		var up := Vector3.FORWARD if n.y > 0.5 else (Vector3.BACK if n.y < -0.5 else Vector3.UP)
		var right := up.cross(n)
		var center := n * h
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		for c in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			# A point of the unit cube (0..1), squeezed into bounds.
			var unit: Vector3 = (center + right * (c.x - 0.5) * CUBE_SIZE - up * (c.y - 0.5) * CUBE_SIZE) / CUBE_SIZE + Vector3.ONE * 0.5
			var p := bounds.position + unit * bounds.size
			verts.append((p - Vector3.ONE * 0.5) * CUBE_SIZE)
			# Sides show the texture rows the block fills, like the world mesher.
			uvs.append(Vector2(c.x, 1.0 - p.y) if absf(n.y) < 0.5 else c)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(atlas.face_texture(block_index, f)))


## The icon with depth: front and back faces, plus side walls wherever an
## opaque pixel borders a transparent one.
static func _extruded_mesh(icon: Texture2D) -> ArrayMesh:
	var img := icon.get_image()
	img.decompress()
	var w := img.get_width()
	var hgt := img.get_height()
	var px := ITEM_SIZE / float(maxi(w, hgt))
	var t := ITEM_THICKNESS / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var solid := func(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < w and y < hgt and img.get_pixel(x, y).a >= 0.5
	var quad := func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, uv: Vector2) -> void:
		for v in [a, b, c, a, c, d]:
			st.set_normal(n)
			st.set_uv(uv)
			st.add_vertex(v)
	for y in hgt:
		for x in w:
			if not solid.call(x, y):
				continue
			var x0 := (x - w / 2.0) * px
			var x1 := x0 + px
			var y0 := (hgt / 2.0 - y) * px  # image rows go down
			var y1 := y0 - px
			var uv := Vector2((x + 0.5) / w, (y + 0.5) / hgt)
			# Front (+Z) and back (-Z): the same pixel texture.
			var front_uvs := [Vector2(float(x) / w, float(y) / hgt), Vector2(float(x + 1) / w, float(y) / hgt),
					Vector2(float(x + 1) / w, float(y + 1) / hgt), Vector2(float(x) / w, float(y + 1) / hgt)]
			var fv := [Vector3(x0, y0, t), Vector3(x1, y0, t), Vector3(x1, y1, t), Vector3(x0, y1, t)]
			for i in [0, 2, 1, 0, 3, 2]:
				st.set_normal(Vector3.BACK)
				st.set_uv(front_uvs[i])
				st.add_vertex(fv[i])
			var bv := [Vector3(x0, y0, -t), Vector3(x1, y0, -t), Vector3(x1, y1, -t), Vector3(x0, y1, -t)]
			for i in [0, 1, 2, 0, 2, 3]:
				st.set_normal(Vector3.FORWARD)
				st.set_uv(front_uvs[i])
				st.add_vertex(bv[i])
			# Walls where the neighbour is empty.
			if not solid.call(x, y - 1):
				quad.call(Vector3(x0, y0, -t), Vector3(x0, y0, t), Vector3(x1, y0, t), Vector3(x1, y0, -t), Vector3.UP, uv)
			if not solid.call(x, y + 1):
				quad.call(Vector3(x0, y1, t), Vector3(x0, y1, -t), Vector3(x1, y1, -t), Vector3(x1, y1, t), Vector3.DOWN, uv)
			if not solid.call(x - 1, y):
				quad.call(Vector3(x0, y0, -t), Vector3(x0, y1, -t), Vector3(x0, y1, t), Vector3(x0, y0, t), Vector3.LEFT, uv)
			if not solid.call(x + 1, y):
				quad.call(Vector3(x1, y0, t), Vector3(x1, y1, t), Vector3(x1, y1, -t), Vector3(x1, y0, -t), Vector3.RIGHT, uv)
	var mesh := st.commit()
	mesh.surface_set_material(0, _material(icon))
	return mesh


func _physics_process(delta: float) -> void:
	_age += delta
	if remote:
		_follow_host(delta)
		return
	if _age > LIFETIME:
		queue_free()
		return
	var to_player := Vector3.ZERO
	if player and not player.dead and _age > PICKUP_DELAY:
		to_player = player.global_position + Vector3(0, 0.9, 0) - global_position
		if to_player.length() < PICKUP_RADIUS:
			var left: int = player.inventory.add(item, count)
			if left < count:
				picked_up.emit(item, count - left)
			count = left
			if count == 0:
				queue_free()
				return
	if to_player != Vector3.ZERO and to_player.length() < MAGNET_RADIUS and player.inventory.can_fit(item):
		velocity = to_player.normalized() * 6.0  # drift towards the player
		global_position += velocity * delta
	else:
		velocity.y = maxf(velocity.y - GRAVITY * delta, -30.0)
		velocity.x *= 0.92
		velocity.z *= 0.92
		var r: Dictionary = world.move_box(global_position, BOX, velocity * delta)
		global_position = r.position
		if r.on_floor:
			velocity = Vector3(velocity.x * 0.5, 0, velocity.z * 0.5)
	_animate(delta)


func _animate(delta: float) -> void:
	if _model:
		_model.position.y = BOX.y + 0.06 + 0.06 * sin(_age * 2.5)
		_model.rotation.y += delta * 1.2  # slowly spinning


## Client: glide to where the host has it; ask for it when we're close enough.
func _follow_host(delta: float) -> void:
	global_position = global_position.lerp(target_position, 1.0 - exp(-12.0 * delta))
	if player and not player.dead and _age > PICKUP_DELAY and request_pickup.is_valid() \
			and player.global_position.distance_to(global_position) < MAGNET_RADIUS \
			and player.inventory.can_fit(item) and Time.get_ticks_msec() / 1000.0 - _asked > 1.0:
		_asked = Time.get_ticks_msec() / 1000.0
		request_pickup.call(drop_id)
	_animate(delta)
