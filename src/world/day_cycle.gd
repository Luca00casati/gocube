class_name DayCycle
extends Node
## Time of day: 0.0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset (wraps at 1.0).
## Drives the chunk shaders' `daylight` (sky light only: lamps don't change),
## the sky colours and the sun. Saved with the world; in multiplayer the host's
## clock is authoritative and clients are corrected now and then.

## Real time: one second in the game is one second in real life, so a full
## day lasts 24 hours (launch option --day-length=SECONDS changes it).
const DEFAULT_DAY_LENGTH := 86400.0
const NIGHT_LIGHT := 0.14           # sky light at night: dark, but you can see
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
var sky_material: ProceduralSkyMaterial
var environment: Environment
var sun: DirectionalLight3D


func _process(delta: float) -> void:
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
	for m in materials:
		m.set_shader_parameter("daylight", light)
	# Orange near the horizon around sunrise and sunset.
	var dusk := clampf(1.0 - absf(sun_height()) / 0.3, 0.0, 1.0)
	if sky_material:
		sky_material.sky_top_color = NIGHT_TOP.lerp(DAY_TOP, day)
		sky_material.sky_horizon_color = NIGHT_HORIZON.lerp(DAY_HORIZON, day).lerp(DUSK_HORIZON, dusk * 0.65)
		sky_material.ground_horizon_color = sky_material.sky_horizon_color
		sky_material.ground_bottom_color = NIGHT_GROUND.lerp(DAY_GROUND, day)
	if sun:
		# Rises in the east (+x), overhead at noon, sets in the west.
		var angle := (time - 0.25) * TAU
		sun.rotation = Vector3(-angle, deg_to_rad(-90.0), 0.0)
		sun.light_energy = day
		sun.visible = day > 0.01
	if environment:
		environment.ambient_light_energy = lerpf(0.15, 1.0, day)
