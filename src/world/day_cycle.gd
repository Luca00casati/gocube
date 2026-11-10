class_name DayCycle
extends Node
## Time of day: 0.0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset (wraps at 1.0).
## Drives the chunk shaders' `daylight` (sky light only: lamps don't change),
## the sky colours and the sun. Saved with the world; in multiplayer the host's
## clock is authoritative and clients are corrected now and then.

## Real time: one second in the game is one second in real life, so a full
## day lasts 24 hours (launch option --day-length=SECONDS changes it).
const DEFAULT_DAY_LENGTH := 86400.0
const NIGHT_LIGHT := 0.02           # sky light at night: dark, bring a torch
## Creatures and dropped items at night: a little above the terrain, so a
## ninja coming at you in the dark is a faint shape, not invisible.
const NIGHT_CREATURE_LIGHT := 0.07
const NIGHT_TINT := Color(0.6, 0.7, 1.0)  # moonlight: night sky light is a cool blue
const START_TIME := 0.3             # new worlds start in the morning

const DAY_TOP := Color(0.32, 0.52, 0.86)
const DAY_HORIZON := Color(0.68, 0.79, 0.92)
const DUSK_HORIZON := Color(0.95, 0.55, 0.32)
const NIGHT_TOP := Color(0.015, 0.02, 0.06)
const NIGHT_HORIZON := Color(0.05, 0.07, 0.14)
const DAY_GROUND := Color(0.35, 0.33, 0.30)
const NIGHT_GROUND := Color(0.02, 0.02, 0.03)

var time := START_TIME
var day_length := DEFAULT_DAY_LENGTH
## Follow the computer's local clock (single player / host). Multiplayer
## clients use the host's time instead, so everyone shares one day.
var follow_system_clock := false
## Materials with a `daylight` uniform (terrain, fluids).
var materials: Array[ShaderMaterial] = []
## The sky (src/world/sky.gdshader): gradient, sun, moon, stars, clouds.
var sky_material: ShaderMaterial
## Clouds drift in real time (cells per second), whatever the day length.
const CLOUD_SPEED := Vector2(0.35, 0.12)
var _cloud_offset := Vector2.ZERO
var environment: Environment
var sun: DirectionalLight3D
## Haze over the distance: Environment depth fog in the horizon's colour. By
## day it starts at fog_begin and is thick at fog_end (set from the view
## distance); at night it closes in to NIGHT_FOG_* and turns nearly black,
## so you can't see far in the dark.
var fog := true
var fog_begin := 60.0
var fog_end := 120.0
const NIGHT_FOG_BEGIN := 4.0
const NIGHT_FOG_END := 40.0
const NIGHT_FOG := Color(0.006, 0.008, 0.02)


func _process(delta: float) -> void:
	_cloud_offset += CLOUD_SPEED * delta
	if follow_system_clock:
		time = system_time()
	else:
		time = fposmod(time + delta / day_length, 1.0)
	apply()


## The computer's local time of day as 0..1 (0 = midnight).
static func system_time() -> float:
	var t := Time.get_time_dict_from_system()
	var seconds: float = t.hour * 3600 + t.minute * 60 + t.second
	return seconds / 86400.0


## +1 at noon, 0 at sunrise/sunset, -1 at midnight.
## Sky light's colour and strength now: white by day, faint blue at night.
func sky_color() -> Color:
	return NIGHT_TINT.lerp(Color.WHITE, day_amount()) * daylight()


## How strongly the sun shines (0 at night, low at dawn and dusk): shade,
## shadows and cloud shadows scale with it.
func sun_amount() -> float:
	return day_amount() * clampf(sun_height() * 3.0, 0.0, 1.0)


## The haze's colour: the horizon by day, nearly black at night.
func haze_color() -> Color:
	var day := day_amount()
	var dusk := clampf(1.0 - absf(sun_height()) / 0.3, 0.0, 1.0)
	return NIGHT_FOG.lerp(DAY_HORIZON, day).lerp(DUSK_HORIZON, dusk * 0.4 * day)


func sun_height() -> float:
	return sin((time - 0.25) * TAU)


## 0 at night .. 1 in full day, with a soft dawn and dusk.
func day_amount() -> float:
	return smoothstep(-0.18, 0.22, sun_height())


func daylight() -> float:
	return lerpf(NIGHT_LIGHT, 1.0, day_amount())


## "7:19 AM" (12-hour, the default) or "07:19" (24-hour, see Settings).
func clock_text(use_24h: bool = false) -> String:
	return format_clock(time, use_24h)


static func format_clock(day_time: float, use_24h: bool) -> String:
	var minutes := int(fposmod(day_time, 1.0) * 24.0 * 60.0)
	var hour := minutes / 60
	var minute := minutes % 60
	if use_24h:
		return "%02d:%02d" % [hour, minute]
	var hour12 := hour % 12
	if hour12 == 0:
		hour12 = 12  # midnight = 12 AM, noon = 12 PM
	return "%d:%02d %s" % [hour12, minute, "AM" if hour < 12 else "PM"]


func apply() -> void:
	var day := day_amount()
	var light := lerpf(NIGHT_LIGHT, 1.0, day)
	var tint := NIGHT_TINT.lerp(Color.WHITE, day)
	for m in materials:
		m.set_shader_parameter("daylight", light)
		m.set_shader_parameter("sky_tint", tint)
		m.set_shader_parameter("sun_amount", sun_amount())
		m.set_shader_parameter("cloud_offset", _cloud_offset)
	# Orange near the horizon around sunrise and sunset.
	var dusk := clampf(1.0 - absf(sun_height()) / 0.3, 0.0, 1.0)
	# Rises in the east (+x), overhead at noon, sets in the west.
	var angle := (time - 0.25) * TAU
	# The sun light's +z points at the sun: (cos a, sin a, 0), east in the morning.
	var sun_basis := Basis.from_euler(Vector3(-angle, deg_to_rad(90.0), 0.0))
	if sky_material:
		sky_material.set_shader_parameter("top_color", NIGHT_TOP.lerp(DAY_TOP, day))
		sky_material.set_shader_parameter("horizon_color",
				NIGHT_HORIZON.lerp(DAY_HORIZON, day).lerp(DUSK_HORIZON, dusk * 0.65))
		# Below the horizon (past the edge of the loaded world) the sky is the
		# haze's colour, so faded hills and the sky behind them meet without a seam.
		var below := haze_color() if fog else NIGHT_GROUND.lerp(DAY_GROUND, day)
		sky_material.set_shader_parameter("ground_color", below)
		sky_material.set_shader_parameter("sun_dir", sun_basis.z)  # a light shines along -z
		sky_material.set_shader_parameter("day", day)
		sky_material.set_shader_parameter("dusk", dusk)
		sky_material.set_shader_parameter("sky_angle", angle)
		sky_material.set_shader_parameter("cloud_offset", _cloud_offset)
	if sun:
		sun.basis = sun_basis
		sun.light_energy = day
		sun.visible = sun_amount() > 0.001  # (the terrain takes the sun's share in its light())
	if environment:
		environment.ambient_light_energy = lerpf(0.15, 1.0, day)
		environment.fog_enabled = fog
		environment.fog_light_color = haze_color()
		environment.fog_depth_begin = lerpf(NIGHT_FOG_BEGIN, fog_begin, day)
		environment.fog_depth_end = lerpf(NIGHT_FOG_END, fog_end, day)
