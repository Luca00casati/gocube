class_name VoxelWanderer
extends Node3D
## PROTOTYPE creature moved by the voxel module's VoxelBoxMover: box-vs-voxel
## collision straight on the voxel data, no physics engine. Steps up 1 block.

const SPEED := 1.6
const GRAVITY := 28.0
const BOX := AABB(Vector3(-0.4, 0.0, -0.55), Vector3(0.8, 0.9, 1.1))

var terrain: VoxelTerrain
var _mover := VoxelBoxMover.new()
var _velocity := Vector3.ZERO
var _heading := 0.0
var _turn_timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = get_instance_id()
	_mover.set_step_climbing_enabled(true)
	_mover.set_max_step_height(1.0)
	var mesh := MeshInstance3D.new()
	mesh.mesh = _shared_mesh()
	mesh.material_override = _shared_materials()[_rng.randi() % 8]
	mesh.position.y = BOX.size.y / 2
	add_child(mesh)
	_heading = _rng.randf() * TAU


## Shared mesh and a small shared palette: unique materials per creature stop
## Godot from batching draws and cost far more than the movement itself.
static var _mesh: BoxMesh
static var _materials: Array[StandardMaterial3D] = []


static func _shared_mesh() -> BoxMesh:
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = BOX.size
	return _mesh


static func _shared_materials() -> Array[StandardMaterial3D]:
	if _materials.is_empty():
		for i in 8:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color.from_hsv(i / 8.0, 0.4, 0.85)
			_materials.append(mat)
	return _materials


func _physics_process(delta: float) -> void:
	_turn_timer -= delta
	if _turn_timer <= 0.0:
		_turn_timer = _rng.randf_range(1.5, 4.0)
		_heading += _rng.randf_range(-1.5, 1.5)
	rotation.y = _heading
	_velocity.x = sin(_heading) * SPEED
	_velocity.z = cos(_heading) * SPEED
	_velocity.y = maxf(_velocity.y - GRAVITY * delta, -60.0)
	var wanted := _velocity * delta
	var moved := _mover.get_motion(position, wanted, BOX, terrain)
	if wanted.y < 0.0 and moved.y > wanted.y + 0.0001:
		_velocity.y = 0.0  # landed
	position += moved
