class_name Figure
extends Node3D
## A jointed figure made of boxes (players and ninjas), animated from how it
## moves. The node's origin is at the feet; it faces -Z; 1.8 m tall.
##
## Joints: hips -> torso (bends at the waist) -> neck/head, shoulders ->
## upper arm -> elbow -> forearm (the right hand holds `hand`), and hips ->
## thigh -> knee -> shin. Every frame the owner sets the inputs below; the
## figure blends towards the pose they ask for, so changes never snap.
##
## Inputs: move_speed (horizontal m/s), vertical_speed, on_floor, sneaking,
## lying (asleep), pitch (looking up +/down -), style ("" or "ninja": runs
## with the arms swept back). swing() plays a strike, flash() a hurt tint.

const HIP_Y := 0.76
const THIGH := 0.38
const SHIN := 0.38
const TORSO := 0.62
const UPPER_ARM := 0.3
const FOREARM := 0.32
const STRIDE := 1.5            # metres per full walk cycle (two steps)
const RUN_SPEED := 5.0         # at this speed the stride is fully stretched
const SWING_TIME := 0.4        # one strike: wind up, chop, come back
## Phases of a strike (fractions of SWING_TIME): winding up ends at WIND, the
## chop lands at HIT, then the arm eases back to where it was.
const SWING_WIND := 0.4
const SWING_HIT := 0.62
## The arm at the top of the wind-up and where the chop lands:
## [shoulder (up/forward), out to the side (+) or across (-), elbow bend].
const SWING_TOP := [2.5, 0.4, 1.25]
const SWING_LAND := [0.3, -0.45, 0.5]

var move_speed := 0.0
var vertical_speed := 0.0
var on_floor := true
var sneaking := false
var lying := false
var pitch := 0.0
var style := ""

## Joints (Node3D pivots), by name: hips, torso, head, arm_l, arm_r, elbow_l,
## elbow_r, leg_l, leg_r, knee_l, knee_r. `hand` is where the right hand
## holds an item (its -Z points along the forearm's grip).
var joints := {}
var hand: Node3D

var _phase := 0.0
var _amount := 0.0      # 0 standing .. 1 running, smoothed
var _air := 0.0         # 0 on the ground .. 1 in the air, smoothed
var _sneak := 0.0
var _lie := 0.0
var _swing := -1.0      # time into the strike (-1: none)
var _swing_next := false  # another strike asked for while one plays: it follows
var _flash := 0.0
var _meshes: Array[MeshInstance3D] = []


## Builds the figure from part colours: skin, shirt, sleeve, hands, trousers,
## shoes, hair (any missing one falls back to a neighbour's). Call once.
func build(colours: Dictionary) -> void:
	# Each part's colour, or the first given of the parts it falls back to.
	var c := func(keys: Array) -> Material:
		for key in keys:
			if colours.has(key):
				return BlockEater._mat("figure_" + str(colours[key]), colours[key])
		return BlockEater._mat("figure_grey", Color(0.5, 0.5, 0.5))
	var skin: Material = c.call(["skin"])
	var shirt: Material = c.call(["shirt"])
	var sleeve: Material = c.call(["sleeve", "shirt"])
	var hands: Material = c.call(["hands", "skin"])
	var trousers: Material = c.call(["trousers", "shirt"])
	var shoes: Material = c.call(["shoes", "trousers", "shirt"])

	var hips := _joint("hips", self, Vector3(0, HIP_Y, 0))
	var torso := _joint("torso", hips, Vector3.ZERO)
	add_box(torso, Vector3(0.5, TORSO, 0.27), Vector3(0, TORSO / 2, 0), shirt)
	var head := _joint("head", torso, Vector3(0, TORSO + 0.02, 0))
	add_box(head, Vector3(0.44, 0.44, 0.44), Vector3(0, 0.22, 0), skin)
	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		var arm := _joint("arm_" + s, torso, Vector3(0.335 * side, TORSO - 0.06, 0))
		add_box(arm, Vector3(0.17, UPPER_ARM + 0.06, 0.17), Vector3(0, -UPPER_ARM / 2 + 0.03, 0), sleeve)
		var elbow := _joint("elbow_" + s, arm, Vector3(0, -UPPER_ARM, 0))
		add_box(elbow, Vector3(0.155, FOREARM - 0.08, 0.155), Vector3(0, -(FOREARM - 0.08) / 2, 0), sleeve)
		add_box(elbow, Vector3(0.15, 0.1, 0.15), Vector3(0, -FOREARM + 0.05, 0), hands)
		var leg := _joint("leg_" + s, hips, Vector3(0.125 * side, 0, 0))
		add_box(leg, Vector3(0.22, THIGH + 0.02, 0.22), Vector3(0, -THIGH / 2, 0), trousers)
		var knee := _joint("knee_" + s, leg, Vector3(0, -THIGH, 0))
		add_box(knee, Vector3(0.21, SHIN - 0.1, 0.21), Vector3(0, -(SHIN - 0.1) / 2, 0), trousers)
		add_box(knee, Vector3(0.22, 0.1, 0.28), Vector3(0, -SHIN + 0.05, -0.03), shoes)
	hand = Node3D.new()
	hand.position = Vector3(0, -FOREARM + 0.04, -0.06)
	joints.elbow_r.add_child(hand)


func _joint(joint_name: String, parent: Node3D, at: Vector3) -> Node3D:
	var j := Node3D.new()
	j.name = joint_name
	j.position = at
	parent.add_child(j)
	joints[joint_name] = j
	return j


## A box on a joint (for the figure itself and for what dresses it up).
func add_box(parent: Node3D, size: Vector3, at: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_meshes.append(mi)
	return mi


## 0 standing .. 1 lying down (smoothed).
func lie_amount() -> float:
	return _lie


## A strike with the right arm (hitting, mining, placing, using). One asked
## for during another plays right after it, so strikes never cut each other off.
func swing() -> void:
	if _swing < 0.0:
		_swing = 0.0
	else:
		_swing_next = true


func swinging() -> bool:
	return _swing >= 0.0


## Turns red for a moment (hurt).
func flash() -> void:
	_flash = 1.0


func _process(delta: float) -> void:
	var k := func(rate: float) -> float: return 1.0 - exp(-rate * delta)
	var target_amount := clampf(move_speed / RUN_SPEED, 0.0, 1.0) if on_floor else 0.0
	_amount = lerpf(_amount, target_amount, k.call(10.0))
	_air = lerpf(_air, 0.0 if on_floor else 1.0, k.call(12.0))
	_sneak = lerpf(_sneak, 1.0 if sneaking and not lying else 0.0, k.call(12.0))
	_lie = lerpf(_lie, 1.0 if lying else 0.0, k.call(8.0))
	# Steps follow the distance walked, so the feet don't slide.
	if on_floor:
		_phase = fmod(_phase + move_speed * delta / STRIDE * TAU, TAU)
	elif _amount < 0.05:
		_phase = lerpf(_phase, 0.0, k.call(6.0))
	if _swing >= 0.0:
		_swing += delta
		if _swing >= SWING_TIME:
			_swing = 0.0 if _swing_next else -1.0
			_swing_next = false
	_flash = maxf(0.0, _flash - delta * 3.0)
	_pose(k)
	for mi in _meshes:
		if is_instance_valid(mi):
			mi.set_instance_shader_parameter("flash", _flash)


func _pose(k: Callable) -> void:
	var walk := _amount
	var run := clampf((_amount - 0.55) / 0.45, 0.0, 1.0)  # past a walk: running
	var s := sin(_phase)
	var c := cos(_phase)
	var ninja_run := run if style == "ninja" else 0.0

	# Legs: swing forward and back; the knee bends as the leg comes forward
	# (and more when running); in the air one knee is pulled up.
	var leg_amp := 0.55 * walk + 0.35 * run
	var legs := {}
	for side in [-1, 1]:
		var sw: float = s * side
		var swing_leg: float = sw * leg_amp
		var knee: float = maxf(0.0, -c * side) * (0.5 * walk + 0.7 * run)
		var air_leg: float = (0.55 if side < 0 else -0.25) * _air
		var air_knee: float = (1.0 if side < 0 else 0.35) * _air
		legs[side] = [swing_leg + air_leg + 0.55 * _sneak, knee + air_knee + 0.9 * _sneak]

	# Arms: swing against the legs; elbows bend more when running; a ninja
	# running sweeps them straight back; in the air they lift out a little.
	var arm_amp := 0.7 * walk + 0.4 * run
	var arms := {}
	for side in [-1, 1]:
		var sw: float = -s * side * arm_amp * (1.0 - ninja_run)
		var x: float = sw - 1.25 * ninja_run + 0.25 * _sneak
		var z: float = side * (0.06 + 0.35 * _air + 0.25 * ninja_run)  # out from the body
		var elbow: float = 0.15 + 0.9 * run * (1.0 - ninja_run) + 0.2 * _sneak
		arms[side] = [x, z, elbow]

	# The right arm strikes like an axe blow: it winds up (the elbow comes up
	# beside the head with the forearm back behind it: never a straight raised
	# arm, and the hand never by the face), chops down and across the body,
	# speeding up, then eases back. The pose is worked out directly from the
	# time into the strike, so it moves smoothly however fast frames come.
	var twist_swing := 0.0
	if _swing >= 0.0:
		var t := _swing / SWING_TIME
		var rest: Array = arms[1]
		var pose: Array
		if t < SWING_WIND:
			var u := _ease(t / SWING_WIND)
			pose = [lerpf(rest[0], SWING_TOP[0], u), lerpf(rest[1], SWING_TOP[1], u),
					# the elbow bends first, so a raised arm is always bent
					lerpf(rest[2], SWING_TOP[2], minf(1.0, u * 2.0))]
			twist_swing = -0.2 * u
		elif t < SWING_HIT:
			var u := (t - SWING_WIND) / (SWING_HIT - SWING_WIND)
			var fall := u * u  # speeds up into the blow
			pose = [lerpf(SWING_TOP[0], SWING_LAND[0], fall), lerpf(SWING_TOP[1], SWING_LAND[1], fall),
					# and straightens last
					lerpf(SWING_TOP[2], SWING_LAND[2], fall * fall)]
			twist_swing = lerpf(-0.2, 0.35, fall)
		else:
			var u := _ease((t - SWING_HIT) / (1.0 - SWING_HIT))
			pose = [lerpf(SWING_LAND[0], rest[0], u), lerpf(SWING_LAND[1], rest[1], u),
					lerpf(SWING_LAND[2], rest[2], u)]
			twist_swing = lerpf(0.35, 0.0, u)
		arms[1] = pose

	var lean := 0.12 * walk + 0.2 * run + 0.45 * ninja_run + 0.5 * _sneak
	var bob := -absf(c) * 0.04 * walk - 0.05 * run - 0.16 * _sneak
	var twist := s * 0.12 * walk  # shoulders turn with the stride
	twist += twist_swing

	var r := 18.0
	_rot(joints.hips, Vector3(0, -twist * 0.4, 0), k, r)
	joints.hips.position.y = lerpf(joints.hips.position.y, HIP_Y + bob, k.call(r))
	_rot(joints.torso, Vector3(-lean, twist, 0), k, r)
	# The head keeps looking where the player looks, whatever the body does.
	_rot(joints.head, Vector3(clampf(pitch, -1.2, 1.2) + lean * 0.8, -twist, 0), k, 25.0)
	for side in [-1, 1]:
		var n := "l" if side < 0 else "r"
		_rot(joints["leg_" + n], Vector3(legs[side][0], 0, 0), k, r)
		_rot(joints["knee_" + n], Vector3(-legs[side][1], 0, 0), k, r)
		if side > 0 and _swing >= 0.0:  # the strike sets the arm exactly
			joints.arm_r.rotation = Vector3(arms[1][0], 0, arms[1][1])
			joints.elbow_r.rotation = Vector3(arms[1][2], 0, 0)
		else:
			_rot(joints["arm_" + n], Vector3(arms[side][0], 0, arms[side][1]), k, r)
			_rot(joints["elbow_" + n], Vector3(arms[side][2], 0, 0), k, r)

	# Asleep: lying on the back, head towards +Z (the owner moves the figure
	# so the head ends up on the pillow, see lie_amount).
	rotation.x = PI / 2 * _lie


## Smooth start and end (0..1 -> 0..1).
static func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


func _rot(j: Node3D, target: Vector3, k: Callable, rate: float) -> void:
	var w: float = k.call(rate)
	j.rotation = Vector3(lerp_angle(j.rotation.x, target.x, w), lerp_angle(j.rotation.y, target.y, w),
			lerp_angle(j.rotation.z, target.z, w))
