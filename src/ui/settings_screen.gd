class_name SettingsScreen
extends Control
## Settings: view distance, mouse sensitivity, FPS limit, vsync, smooth
## lighting and key bindings. Changes apply live and are saved on close.

signal closed

var _rows: VBoxContainer
var _key_buttons := {}       # action -> Button
var _capturing := ""         # action waiting for a key press
var _view_label: Label
var _sens_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	# Scrolls when the window is too small for everything.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(540, minf(620.0, get_viewport_rect().size.y - 40.0))
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	box.add_child(grid)

	# View distance
	var view := HSlider.new()
	view.min_value = 0
	view.max_value = Settings.VIEW_DISTANCES.size() - 1
	view.step = 1
	view.value = maxi(0, Settings.VIEW_DISTANCES.find(Settings.view_distance))
	view.custom_minimum_size.x = 240
	_view_label = Label.new()
	view.value_changed.connect(func(v):
		Settings.view_distance = Settings.VIEW_DISTANCES[int(v)]
		_update_labels()
		Settings.apply())
	_row(grid, _view_label, view)

	# Mouse sensitivity
	var sens := HSlider.new()
	sens.min_value = 0.0005
	sens.max_value = 0.01
	sens.step = 0.0001
	sens.value = Settings.mouse_sensitivity
	_sens_label = Label.new()
	sens.value_changed.connect(func(v):
		Settings.mouse_sensitivity = v
		_update_labels()
		Settings.apply())
	_row(grid, _sens_label, sens)

	# FPS limit
	var fps := OptionButton.new()
	for limit in Settings.FPS_LIMITS:
		fps.add_item("Unlimited" if limit == 0 else "%d FPS" % limit)
	fps.selected = maxi(0, Settings.FPS_LIMITS.find(Settings.max_fps))
	fps.item_selected.connect(func(i):
		Settings.max_fps = Settings.FPS_LIMITS[i]
		Settings.apply())
	_row(grid, _label("Frame rate limit"), fps)

	var vsync := CheckBox.new()
	vsync.text = "Wait for the screen (no tearing)"
	vsync.button_pressed = Settings.vsync
	vsync.toggled.connect(func(on):
		Settings.vsync = on
		Settings.apply())
	_row(grid, _label("VSync"), vsync)

	var smooth := CheckBox.new()
	smooth.text = "Blend light at block corners"
	smooth.button_pressed = Settings.smooth_lighting
	smooth.toggled.connect(func(on):
		Settings.smooth_lighting = on
		Settings.apply())
	_row(grid, _label("Smooth lighting"), smooth)

	for entry in [["Master volume", "master_volume"], ["Effects volume", "effects_volume"],
			["Ambience volume", "ambience_volume"]]:
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = Settings.get(entry[1])
		slider.custom_minimum_size.x = 240
		var label := _label("")
		var update := func(v):
			label.text = "%s: %d%%" % [entry[0], roundi(v * 100)]
		update.call(slider.value)
		slider.value_changed.connect(func(v):
			Settings.set(entry[1], v)
			update.call(v)
			Settings.apply())
		_row(grid, label, slider)

	var clock := CheckBox.new()
	clock.text = "24-hour clock (07:19 instead of 7:19 AM)"
	clock.button_pressed = Settings.clock_24h
	clock.toggled.connect(func(on):
		Settings.clock_24h = on
		Settings.apply())
	_row(grid, _label("Clock"), clock)

	# Key bindings
	var keys_title := _label("Keys (click, then press a key; Esc cancels)")
	keys_title.add_theme_font_size_override("font_size", 18)
	box.add_child(keys_title)
	var keys := GridContainer.new()
	keys.columns = 2
	keys.add_theme_constant_override("h_separation", 16)
	box.add_child(keys)
	for action in Settings.ACTIONS:
		var b := Button.new()
		b.custom_minimum_size.x = 160
		b.pressed.connect(_capture.bind(action))
		_key_buttons[action] = b
		_row(keys, _label(Settings.ACTIONS[action][0]), b)
	var fixed := _label("Mouse: look, hold left = mine, right = place, wheel/1-9 = hotbar · Esc = pause")
	fixed.modulate = Color(1, 1, 1, 0.6)
	fixed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(fixed)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	var reset := Button.new()
	reset.text = "Reset keys"
	reset.pressed.connect(func():
		Settings.reset_keys()
		_update_labels())
	buttons.add_child(reset)
	var done := Button.new()
	done.text = "Done"
	done.pressed.connect(close)
	buttons.add_child(done)
	_update_labels()


func close() -> void:
	Settings.save()
	closed.emit()


func _input(event: InputEvent) -> void:
	if _capturing == "" or not (event is InputEventKey) or not event.pressed or event.echo:
		if _capturing == "" and event.is_action_pressed(&"ui_cancel"):
			close()
			get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	if event.keycode != KEY_ESCAPE:
		Settings.set_key(_capturing, event.keycode)
	_capturing = ""
	_update_labels()


func _capture(action: String) -> void:
	_capturing = action
	_key_buttons[action].text = "Press a key…"


func _update_labels() -> void:
	_view_label.text = "View distance: %d blocks" % Settings.view_distance
	_sens_label.text = "Mouse sensitivity: %.1f" % (Settings.mouse_sensitivity * 1000.0)
	for action in _key_buttons:
		var name := Settings.key_name(action)
		var clash := Settings.actions_using(Settings.keys[action]).size() > 1
		_key_buttons[action].text = name + ("  (also used!)" if clash else "")


static func _row(grid: GridContainer, left: Control, right: Control) -> void:
	grid.add_child(left)
	grid.add_child(right)


static func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
