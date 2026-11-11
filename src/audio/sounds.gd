class_name Sounds
extends Node
## Plays the game's sounds from the Registry's sound sets (content "sound_sets").
## Blocks pick a set with "sound": "mod:set"; a set lists files per kind
## ("step", "break", "place", ...). A random file is chosen and its pitch varied
## a little, so repeats don't sound identical.
##
## Effects play through a fixed set of always-playing polyphonic players:
## Godot 4.7.2 never frees the playback object a play() creates (~7 KB per
## sound with a real audio driver, so ~70 MB an hour of footsteps), while a
## polyphonic stream reuses a fixed number of slots.

const POOL_SIZE := 12
const VOICES_PER_PLAYER := 2
const MAX_DISTANCE := 32.0
const AMBIENCE_DB := -14.0

var _streams := {}               # path -> AudioStream
var _pool: Array[AudioStreamPlayer3D] = []
var _next := 0
var _day: AudioStreamPlayer
var _night: AudioStreamPlayer
var _lowpass_index := -1


func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"Effects"
		p.max_distance = MAX_DISTANCE
		p.unit_size = 6.0
		var poly := AudioStreamPolyphonic.new()
		poly.polyphony = VOICES_PER_PLAYER
		p.stream = poly
		add_child(p)
		p.play()
		_pool.append(p)
	_day = _ambience_player("day")
	_night = _ambience_player("night")
	# Underwater: muffle everything (a low-pass filter on the master bus).
	var filter := AudioEffectLowPassFilter.new()
	filter.cutoff_hz = 700.0
	AudioServer.add_bus_effect(0, filter)
	_lowpass_index = AudioServer.get_bus_effect_count(0) - 1
	AudioServer.set_bus_effect_enabled(0, _lowpass_index, false)


## Stops every sound. Call it a frame before quitting: the audio thread
## releases stopped sounds asynchronously, so stopping in the very last frame
## leaves them "still in use" at exit.
func stop_all() -> void:
	for p in [_day, _night]:
		if p:
			p.stop()
			p.stream = null
	for p in _pool:
		p.stop()
		p.stream = null
	_streams.clear()


func _exit_tree() -> void:
	if _lowpass_index >= 0 and _lowpass_index < AudioServer.get_bus_effect_count(0):
		AudioServer.remove_bus_effect(0, _lowpass_index)
	for p in [_day, _night]:
		if p:
			p.stop()
			p.stream = null
	for p in _pool:
		p.stop()
		p.stream = null
	_streams.clear()


## A block's sound of the given kind ("step", "break", "place") at a position.
func play_block(block_id: String, kind: String, at: Vector3, volume_db: float = 0.0) -> void:
	var def: Dictionary = Registry.blocks.get(block_id, {})
	if def.has("sound"):
		play(str(def.sound), kind, at, volume_db)


## Any sound set's sound, e.g. play("core:effects", "splash", position).
func play(set_id: String, kind: String, at: Vector3, volume_db: float = 0.0) -> void:
	var stream := _pick(set_id, kind)
	if stream == null:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	if not p.playing:
		p.play()
	var playback := p.get_stream_playback() as AudioStreamPlaybackPolyphonic
	if playback == null:
		return
	p.global_position = at
	playback.play_stream(stream, 0.0, volume_db, randf_range(0.9, 1.1))


func set_underwater(on: bool) -> void:
	if _lowpass_index >= 0:
		AudioServer.set_bus_effect_enabled(0, _lowpass_index, on)


## day: 0 at night .. 1 in full day; crossfades the two ambience loops.
func update_ambience(day: float) -> void:
	if _day:
		_day.volume_db = AMBIENCE_DB + linear_to_db(maxf(day, 0.001))
	if _night:
		_night.volume_db = AMBIENCE_DB + linear_to_db(maxf(1.0 - day, 0.001))


func _ambience_player(kind: String) -> AudioStreamPlayer:
	var stream := _pick("core:ambience", kind)
	if stream == null:
		return null
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2  # 16-bit mono frames
	var p := AudioStreamPlayer.new()
	p.bus = &"Ambience"
	p.stream = stream
	p.volume_db = AMBIENCE_DB
	add_child(p)
	p.play()
	return p


func _pick(set_id: String, kind: String) -> AudioStream:
	var def: Dictionary = Registry.sound_sets.get(set_id, {})
	var files: Array = def.get(kind, [])
	if files.is_empty():
		return null
	var path := ModLoader.asset_path(def.get("mod", ""), str(files[randi() % files.size()]))
	if not _streams.has(path):
		_streams[path] = _load(path)
	return _streams[path]


## res:// sounds come through the import system (also in exported games and
## mod packs); unpacked user:// mods are read straight from the WAV file.
## An installed mod's sounds are only read as WAV files (a resource could carry
## a script, see mod_loader.gd).
static func _load(path: String) -> AudioStream:
	if path == "":
		return null
	if ModLoader.is_builtin(path) and ResourceLoader.exists(path):
		return load(path) as AudioStream
	if FileAccess.file_exists(path) and path.get_extension() == "wav":
		return AudioStreamWAV.load_from_file(path)
	push_warning("Sound not found: " + path)
	return null
