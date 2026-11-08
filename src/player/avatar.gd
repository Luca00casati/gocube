extends Node3D
## Another player as seen by us: a simple coloured figure with a name tag.
## The node's origin is the player's eye (camera) position.

var target_position := Vector3.ZERO
var target_yaw := 0.0


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
