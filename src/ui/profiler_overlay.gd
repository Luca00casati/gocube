extends Control
## F4: where the frame's time goes. A graph of the last frames' times (lines
## at 60 and 30 FPS), then each system's share of a frame, averaged over the
## last second, and what the worst frame of that second spent its time on.
##
## Systems time themselves (FrameProfiler); the world engine reports its own
## step and mesh uploads (get_frame_stats); rendering comes from Godot's
## measured CPU and GPU time for the viewport. "rest" is the frame's time
## left over: waiting for the screen (vsync) or the GPU, and Godot's own work
## (UI, physics steps, messages arriving).

const HISTORY := 240           # frames in the graph
const GRAPH_MS := 50.0         # top of the graph
const WIDTH := 440.0
const GRAPH_HEIGHT := 70.0
const LINE := 17.0
const FONT_SIZE := 13
const PAD := 8.0
const TEXT_EVERY := 0.25       # seconds between updates of the numbers
## Rows in the order shown: [key, label, indented].
const ROWS := [
	["world", "world (engine)", false], ["uploads", "mesh uploads", true],
	["game", "game", false], ["player", "player", false], ["figures", "figures", false],
	["mobs", "creatures", false], ["drops", "dropped items", false], ["fluids", "fluids", false],
	["plants", "plants", false], ["furnaces", "furnaces", false], ["network", "network", false],
	["render_cpu", "render CPU", false], ["render_gpu", "render GPU", false],
	["rest", "rest (vsync)", false],
]
const SCRIPTS := ["game", "player", "figures", "mobs", "drops", "fluids", "plants", "furnaces", "network"]

var world: World
var _history: Array[Dictionary] = []  # per frame: "frame" and each row's key, in ms
var _text_timer := 0.0
var _averages := {}
var _worst := {}
var _footer: PackedStringArray = []
var _workers_timer := 0.0
var _workers := ""


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000  # after the systems it times
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	custom_minimum_size = Vector2(WIDTH, 0)
	size = Vector2(WIDTH, PAD * 3 + GRAPH_HEIGHT + LINE * (ROWS.size() + 4) + 6.0)
	position = Vector2(get_viewport_rect().size.x - size.x - 8.0, 8.0)


func toggle() -> void:
	visible = not visible
	FrameProfiler.on = visible
	FrameProfiler.take()
	_history.clear()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), visible)


func _process(delta: float) -> void:
	if not visible:
		return
	position.x = get_viewport_rect().size.x - size.x - 8.0
	var row := {"frame": delta * 1000.0}
	var sums := FrameProfiler.take()
	var scripts := 0.0
	for k in SCRIPTS:
		row[k] = float(sums.get(StringName(k), 0)) / 1000.0
		scripts += row[k]
	var engine := Vector3i.ZERO
	if world and world.engine:
		engine = world.engine.get_frame_stats()
	row.world = engine.x / 1000.0
	row.uploads = engine.y / 1000.0
	row.upload_count = engine.z
	var rid := get_viewport().get_viewport_rid()
	row.render_cpu = RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
	row.render_gpu = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	row.rest = maxf(0.0, row.frame - scripts - row.world - row.render_cpu)
	_history.append(row)
	if _history.size() > HISTORY:
		_history.pop_front()
	_text_timer -= delta
	if _text_timer <= 0.0:
		_text_timer = TEXT_EVERY
		_summarize()
	_workers_timer -= delta
	if _workers_timer <= 0.0 and world and world.engine:
		_workers_timer = 1.0
		var st: Dictionary = world.engine.get_stats()
		_workers = "%d workers · per chunk: gen %.1f · light %.1f · mesh %.1f ms · %d queued" % [
				int(st.get("workers", 0)), st.get("generate_ms_avg", 0.0), st.get("light_ms_avg", 0.0),
				st.get("mesh_ms_avg", 0.0), int(st.get("queued_jobs", 0))]
	queue_redraw()


## Averages over the last second, the worst frame in it, and the counters.
func _summarize() -> void:
	var recent: Array[Dictionary] = []
	var t := 0.0
	for i in range(_history.size() - 1, -1, -1):
		recent.append(_history[i])
		t += float(_history[i].frame)
		if t >= 1000.0:
			break
	_averages = {}
	_worst = {}
	var uploads := 0
	for r in recent:
		for k in r:
			_averages[k] = float(_averages.get(k, 0.0)) + float(r[k]) / recent.size()
		if _worst.is_empty() or float(r.frame) > float(_worst.frame):
			_worst = r
		uploads += int(r.upload_count)
	_footer = PackedStringArray()
	_footer.append("%d draw calls · %.2f M triangles · %d objects · %d nodes" % [
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1e6,
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	_footer.append("%d chunk meshes uploaded in the last second · video memory %.0f MB" % [
			uploads, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])


## The system that took longest in a frame (not rendering), as "name 12.3 ms".
func _biggest(r: Dictionary) -> String:
	var best := ""
	for row in ROWS:
		if row[2] or row[0].begins_with("render") or row[0] == "rest":
			continue
		if best == "" or float(r.get(row[0], 0.0)) > float(r.get(best, 0.0)):
			best = row[0]
	for row in ROWS:
		if row[0] == best:
			return "%s %.1f ms" % [row[1], float(r.get(best, 0.0))]
	return ""


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6))
	var y := PAD
	# The graph: one bar per frame, green / yellow (under 30 FPS) / red (under 20).
	var graph := Rect2(PAD, y, size.x - PAD * 2, GRAPH_HEIGHT)
	draw_rect(graph, Color(1, 1, 1, 0.05))
	var bar_w := graph.size.x / HISTORY
	for i in _history.size():
		var ms: float = _history[i].frame
		var h := minf(ms / GRAPH_MS, 1.0) * graph.size.y
		var c := Color(0.35, 0.85, 0.4) if ms <= 1000.0 / 30.0 else (Color(0.95, 0.8, 0.2) if ms <= 50.0 else Color(0.95, 0.3, 0.25))
		var x := graph.position.x + (HISTORY - _history.size() + i) * bar_w
		draw_rect(Rect2(x, graph.end.y - h, maxf(bar_w - 0.5, 1.0), h), c)
	for target in [1000.0 / 60.0, 1000.0 / 30.0]:
		var ly: float = graph.end.y - target / GRAPH_MS * graph.size.y
		draw_line(Vector2(graph.position.x, ly), Vector2(graph.end.x, ly), Color(1, 1, 1, 0.3))
	y = graph.end.y + PAD + LINE - 4.0
	if _averages.is_empty():
		return
	var frame: float = _averages.frame
	_text(font, Vector2(PAD, y), "frame %.1f ms (%d FPS) · worst %.1f ms: %s" % [
			frame, roundi(1000.0 / maxf(frame, 0.001)), float(_worst.frame), _biggest(_worst)], Color.WHITE)
	y += LINE + 2.0
	var bar_x := 190.0
	var bar_max := size.x - bar_x - PAD
	for row in ROWS:
		var ms := float(_averages.get(row[0], 0.0))
		var label: String = ("   " if row[2] else "") + row[1]
		var dim := ms < 0.05
		_text(font, Vector2(PAD, y), label, Color(1, 1, 1, 0.45 if dim else 0.9))
		_text(font, Vector2(130.0, y), "%5.2f ms" % ms, Color(1, 1, 1, 0.45 if dim else 0.9))
		var w := minf(ms / maxf(frame, 1.0), 1.0) * bar_max
		if w > 0.5:
			draw_rect(Rect2(bar_x, y - 10.0, w, 9.0),
					Color(0.45, 0.65, 1.0, 0.85) if row[0].begins_with("render") else Color(0.95, 0.65, 0.3, 0.85))
		y += LINE
	y += 4.0
	for line in [_workers] + Array(_footer):
		_text(font, Vector2(PAD, y), line, Color(1, 1, 1, 0.7))
		y += LINE


func _text(font: Font, at: Vector2, text: String, color: Color) -> void:
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 3, Color(0, 0, 0, 0.8))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
