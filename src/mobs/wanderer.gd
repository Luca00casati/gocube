class_name Wanderer
extends CharacterBody3D
## PROTOTYPE creature: wanders around, falls, jumps over 1-block steps.
## Used to measure how many physics-driven creatures this setup can run.

const SPEED := 1.6
const GRAVITY := 28.0
const JUMP := 8.4

var _heading := 0.0
var _turn_timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = get_instance_id()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.9, 1.1)
	shape.shape = box
	shape.position.y = 0.45
	add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(_rng.randf(), 0.4, 0.85)
	mesh.material_override = mat
	mesh.position.y = 0.45
	add_child(mesh)
	collision_layer = 2   # creatures don't collide with each other (cheaper)
	collision_mask = 1    # only with terrain
	_heading = _rng.randf() * TAU


func _physics_process(delta: float) -> void:
	_turn_timer -= delta
	if _turn_timer <= 0.0:
		_turn_timer = _rng.randf_range(1.5, 4.0)
		_heading += _rng.randf_range(-1.5, 1.5)
	rotation.y = _heading
	var dir := Vector3(sin(_heading), 0, cos(_heading))
	velocity.x = dir.x * SPEED
	velocity.z = dir.z * SPEED
	velocity.y -= GRAVITY * delta
	if is_on_floor() and is_on_wall():
		velocity.y = JUMP  # hop up a block
	move_and_slide()
