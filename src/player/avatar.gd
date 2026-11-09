extends Node3D
## Another player as seen by us: a simple coloured figure with a name tag.
## The node's origin is the player's eye (camera) position.

var target_position := Vector3.ZERO
var target_yaw := 0.0
var light := 0            # level of the light they hold (a torch), 0 for none
var _torch: Node3D


func setup(player_name: String, peer_id: int) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(fmod(peer_id * 0.618034, 1.0), 0.55, 0.9)

	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.6, 1.3, 0.35)
	body.mesh = body_mesh
	body.material_override = mat
	body.position.y = -1.0
	add_child(body)

	var head := MeshInstance3D.new()
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.45, 0.45, 0.45)
	head.mesh = head_mesh
	head.material_override = mat
	add_child(head)

	var eyes := MeshInstance3D.new()  # shows which way they face (-Z)
	var eyes_mesh := BoxMesh.new()
	eyes_mesh.size = Vector3(0.3, 0.08, 0.02)
	eyes.mesh = eyes_mesh
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.1, 0.1, 0.12)
	eyes.material_override = eye_mat
	eyes.position = Vector3(0, 0.05, -0.23)
	add_child(eyes)

	_torch = Node3D.new()  # shown while they hold a torch
	_torch.position = Vector3(0.38, -0.75, -0.2)
	_torch.rotation.x = -0.4
	_torch.visible = false
	add_child(_torch)
	var stick_mat := StandardMaterial3D.new()
	stick_mat.albedo_color = Color(0.45, 0.3, 0.16)
	var flame_mat := StandardMaterial3D.new()
	flame_mat.albedo_color = Color(1.0, 0.75, 0.25)
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for part in [[Vector3(0.07, 0.5, 0.07), Vector3.ZERO, stick_mat], [Vector3(0.11, 0.12, 0.11), Vector3(0, 0.3, 0), flame_mat]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = part[0]
		mi.mesh = bm
		mi.position = part[1]
		mi.material_override = part[2]
		_torch.add_child(mi)

	var tag := Label3D.new()
	tag.text = player_name
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.fixed_size = true
	tag.pixel_size = 0.0015
	tag.outline_size = 6
	tag.position.y = 0.6
	add_child(tag)


func _process(delta: float) -> void:
	# Smooth between the 20 Hz network updates.
	var t := 1.0 - exp(-15.0 * delta)
	position = position.lerp(target_position, t)
	rotation.y = lerp_angle(rotation.y, target_yaw, t)
	_torch.visible = light > 0
