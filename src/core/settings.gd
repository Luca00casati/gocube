extends Node
## Player settings and key bindings, saved in user://settings.cfg.
## Autoload "Settings". Other code reads the values directly and listens to
## `changed` to apply them live. The same file also stores the menu's player
## name and last server address (sections "player" and "net"), so everyone goes
## through this one ConfigFile instead of separate copies.

signal changed

const PATH := "user://settings.cfg"
const VIEW_DISTANCES := [64, 96, 128, 160, 192, 256]
const FPS_LIMITS := [30, 60, 120, 144, 0]  # 0 = unlimited

## Rebindable actions: name -> [label, default key].
const ACTIONS := {
	"move_forward": ["Move forward", KEY_W],
	"move_back": ["Move back", KEY_S],
	"move_left": ["Move left", KEY_A],
	"move_right": ["Move right", KEY_D],
	"jump": ["Jump / swim up / fly up", KEY_SPACE],
	"sneak": ["Sneak / fly down", KEY_SHIFT],
	"sprint": ["Sprint", KEY_CTRL],
	"toggle_fly": ["Toggle flying", KEY_F],
	"inventory": ["Inventory", KEY_E],
}

var config := ConfigFile.new()
var view_distance := 128
var mouse_sensitivity := 0.003
var max_fps := 0
var vsync := true
var smooth_lighting := false
var clock_24h := false  # in-game clock: 12-hour (7:19 AM) or 24-hour (07:19)
## Volumes, 0..1. Effects and ambience have their own audio buses ("Effects",
## "Ambience"), both feeding "Master".
var master_volume := 1.0
var effects_volume := 1.0
var ambience_volume := 0.7
var keys := {}  # action -> Key


func _ready() -> void:
	config.load(PATH)  # a missing file just means defaults
	view_distance = int(config.get_value("settings", "view_distance", view_distance))
	mouse_sensitivity = float(config.get_value("settings", "mouse_sensitivity", mouse_sensitivity))
	max_fps = int(config.get_value("settings", "max_fps", max_fps))
	vsync = bool(config.get_value("settings", "vsync", vsync))
	smooth_lighting = bool(config.get_value("settings", "smooth_lighting", smooth_lighting))
	clock_24h = bool(config.get_value("settings", "clock_24h", clock_24h))
	master_volume = float(config.get_value("settings", "master_volume", master_volume))
	effects_volume = float(config.get_value("settings", "effects_volume", effects_volume))
	ambience_volume = float(config.get_value("settings", "ambience_volume", ambience_volume))
	for action in ACTIONS:
		keys[action] = int(config.get_value("keys", action, ACTIONS[action][1]))
	apply()


## Applies everything (engine settings, input actions) and tells listeners.
func apply() -> void:
	Engine.max_fps = max_fps
	_set_bus_volume("Master", master_volume)
	_set_bus_volume("Effects", effects_volume)
	_set_bus_volume("Ambience", ambience_volume)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		var e := InputEventKey.new()
		e.keycode = keys[action]
		InputMap.action_add_event(action, e)
	changed.emit()


func save() -> void:
	config.set_value("settings", "view_distance", view_distance)
	config.set_value("settings", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("settings", "max_fps", max_fps)
	config.set_value("settings", "vsync", vsync)
	config.set_value("settings", "smooth_lighting", smooth_lighting)
	config.set_value("settings", "clock_24h", clock_24h)
	config.set_value("settings", "master_volume", master_volume)
	config.set_value("settings", "effects_volume", effects_volume)
	config.set_value("settings", "ambience_volume", ambience_volume)
	for action in keys:
		config.set_value("keys", action, keys[action])
	var err := config.save(PATH)
	if err != OK:
		push_error("Can't save settings: %s" % error_string(err))


## Creates the bus if needed (sending to Master) and sets its volume.
static func _set_bus_volume(bus: String, volume: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, bus)
		AudioServer.set_bus_send(index, "Master")
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(index, volume <= 0.001)


func set_key(action: String, key: Key) -> void:
	keys[action] = key
	apply()


func reset_keys() -> void:
	for action in ACTIONS:
		keys[action] = ACTIONS[action][1]
	apply()


func key_name(action: String) -> String:
	return OS.get_keycode_string(keys.get(action, KEY_NONE))


## Actions currently bound to `key` (to warn about conflicts).
func actions_using(key: Key) -> PackedStringArray:
	var out := PackedStringArray()
	for action in keys:
		if keys[action] == key:
			out.append(action)
	return out
