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
	var light := lerpf(DayCycle.NIGHT_LIGHT, 1.0, amount)
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
		if index >= 0 and atlas.block_table[index].solid:
			_meshes[item_id] = _cube_mesh(index, atlas)
		else:
			_meshes[item_id] = _extruded_mesh(atlas.icon(item_id))
	return _meshes[item_id]


## A cube with each face's own texture (engine face order +X,-X,+Y,-Y,+Z,-Z).
static func _cube_mesh(block_index: int, atlas: BlockAtlas) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var h := CUBE_SIZE / 2.0
	var normals := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
	for f in 6:
		var n: Vector3 = normals[f]
		# Two axes across the face: u to the right, v downwards (as seen from outside).
		var up := Vector3.FORWARD if n.y > 0.5 else (Vector3.BACK if n.y < -0.5 else Vector3.UP)
		var right := up.cross(n)
		var center := n * h
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		for c in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(center + right * (c.x - 0.5) * CUBE_SIZE - up * (c.y - 0.5) * CUBE_SIZE)
			uvs.append(c)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(f, _material(atlas.face_texture(block_index, f)))
	return mesh


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
	if _model:
		_model.position.y = BOX.y + 0.06 + 0.06 * sin(_age * 2.5)
		_model.rotation.y += delta * 1.2  # slowly spinning
