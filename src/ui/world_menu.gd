extends Control
## Title screen: pick, create or delete a world, play it alone or host it,
## or join someone else's game.
## `-- --world=NAME`, `-- --join=ADDR` or `-- --bench` skip straight to the game.

const SETTINGS_PATH := "user://settings.cfg"

## Message to show once when the menu opens (e.g. why a connection ended).
static var notice := ""
## Command-line options start the game only once, not every time we return here.
static var _cli_used := false

var _settings := ConfigFile.new()
var _name_edit: LineEdit
var _notice: Label
var _host: Button
var _join_dialog: ConfirmationDialog
var _join_address: LineEdit

var _list: ItemList
var _play: Button
var _delete: Button
var _info: Label
var _worlds: Array[Dictionary] = []

var _new_dialog: ConfirmationDialog
var _new_name: LineEdit
var _new_seed: LineEdit
var _new_error: Label
var _delete_dialog: ConfirmationDialog


func _ready() -> void:
	ModLoader.load_all()
	var args := OS.get_cmdline_user_args()
	if not _cli_used and Array(args).any(func(a): return a.begins_with("--world=") or a.begins_with("--join=") or a == "--bench"):
		_cli_used = true
		_start_game.call_deferred({"use_cmdline": true})  # main reads the options itself
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_settings.load(SETTINGS_PATH)  # missing file is fine
	_build_ui()
	_refresh()
	_notice.text = notice
	_notice.visible = notice != ""
	notice = ""


## options: world_name, new_seed, net_mode ("offline"/"host"/"client"),
## join_address, port, player_name; use_cmdline = read them from the command line.
func _start_game(options: Dictionary) -> void:
	var game: Node = load("res://src/main.tscn").instantiate()
	game.name = "Main"  # RPC paths must match on every peer
	for key in options:
		game.set(key, options[key])
	var tree := get_tree()
	tree.root.add_child(game)
	tree.current_scene = game
	queue_free()


func _player_name() -> String:
	var n := _name_edit.text.strip_edges().left(16)
	_settings.set_value("player", "name", n)
	_settings.save(SETTINGS_PATH)
	return n if n != "" else "Player"


# --- UI ---------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.13, 0.17)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "GoCube"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	box.add_child(title)

	_notice = Label.new()
	_notice.modulate = Color(1, 0.6, 0.5)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.visible = false
	box.add_child(_notice)

	var name_row := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = "Your name"
	name_row.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.max_length = 16
	_name_edit.text = _settings.get_value("player", "name", "Player")
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	box.add_child(name_row)

	var heading := Label.new()
	heading.text = "Select a world"
	box.add_child(heading)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 260)
	_list.item_selected.connect(func(_i): _update_buttons())
	_list.item_activated.connect(func(_i): _on_play())  # double-click / Enter
	box.add_child(_list)

	_info = Label.new()
	_info.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_info)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	_play = _button(buttons, "Play", _on_play)
	_host = _button(buttons, "Host", _on_host)
	_button(buttons, "New world…", _on_new)
	_delete = _button(buttons, "Delete…", _on_delete)

	var join_row := HBoxContainer.new()
	box.add_child(join_row)
	_button(join_row, "Join a game…", _on_join)
	_button(join_row, "Licenses", _on_licenses)
	_build_join_dialog()

	_build_new_dialog()
	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete world"
	_delete_dialog.ok_button_text = "Move to trash"
	_delete_dialog.confirmed.connect(_on_delete_confirmed)
	add_child(_delete_dialog)


func _button(parent: Control, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


func _build_new_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New world"
	_new_dialog.ok_button_text = "Create"
	_new_dialog.get_ok_button().disabled = true
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(340, 0)
	var name_label := Label.new()
	name_label.text = "Name"
	form.add_child(name_label)
	_new_name = LineEdit.new()
	_new_name.max_length = 32
	_new_name.text_changed.connect(func(_t): _validate_new())
	_new_name.text_submitted.connect(_on_new_name_submitted)
	form.add_child(_new_name)
	var seed_label := Label.new()
	seed_label.text = "Seed (optional, a number)"
	form.add_child(seed_label)
	_new_seed = LineEdit.new()
	_new_seed.placeholder_text = "random"
	_new_seed.text_changed.connect(func(_t): _validate_new())
	form.add_child(_new_seed)
	_new_error = Label.new()
	_new_error.modulate = Color(1, 0.5, 0.45)
	form.add_child(_new_error)
	_new_dialog.add_child(form)
	_new_dialog.confirmed.connect(_on_create)
	add_child(_new_dialog)


func _build_join_dialog() -> void:
	_join_dialog = ConfirmationDialog.new()
	_join_dialog.title = "Join a game"
	_join_dialog.ok_button_text = "Join"
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(340, 0)
	var label := Label.new()
	label.text = "Host address (IP, or IP:port)"
	form.add_child(label)
	_join_address = LineEdit.new()
	_join_address.text = _settings.get_value("net", "last_address", "127.0.0.1")
	_join_address.text_submitted.connect(func(_t): _join_dialog.hide(); _on_join_confirmed())
	form.add_child(_join_address)
	var hint := Label.new()
	hint.text = "The host's address is shown at the top of their screen."
	hint.modulate = Color(1, 1, 1, 0.6)
	form.add_child(hint)
	_join_dialog.add_child(form)
	_join_dialog.confirmed.connect(_on_join_confirmed)
	add_child(_join_dialog)


## Shows GoCube's license and every third-party notice the build must carry.
func _on_licenses() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Licenses"
	var text := TextEdit.new()
	text.editable = false
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.custom_minimum_size = Vector2(760, 460)
	text.text = license_text()
	dialog.add_child(text)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


static func license_text() -> String:
	var parts := PackedStringArray()
	for entry in [["GoCube", "res://LICENSE.md"],
			["Godot Engine", "res://licenses/godot.txt"],
			["godot-cpp", "res://licenses/godot_cpp.txt"]]:
		parts.append("==== %s ====\n\n%s" % [entry[0], FileAccess.get_file_as_string(entry[1]).strip_edges()])
	# Libraries bundled in this engine build, straight from the engine.
	var lines := PackedStringArray(["==== Third-party libraries in the Godot engine ===="])
	for component in Engine.get_copyright_info():
		for part in component.parts:
			lines.append("\n%s\n  %s\n  License: %s" % [component.name,
					"\n  ".join(part.copyright), part.license])
	parts.append("\n".join(lines))
	var licenses: Dictionary = Engine.get_license_info()
	for license_name in licenses:
		parts.append("==== License: %s ====\n\n%s" % [license_name, licenses[license_name].strip_edges()])
	return "\n\n\n".join(parts)


func _refresh() -> void:
	_worlds = World.list_worlds()
	_list.clear()
	for w in _worlds:
		var played: String = str(w.meta.get("saved", w.meta.get("created", "?"))).replace("T", " ")
		_list.add_item("%s    —    last played %s" % [w.name, played.left(16)])
	if not _worlds.is_empty():
		_list.select(0)
	_update_buttons()


func _selected() -> Dictionary:
	var sel := _list.get_selected_items()
	return _worlds[sel[0]] if not sel.is_empty() else {}


func _update_buttons() -> void:
	var w := _selected()
	_play.disabled = w.is_empty()
	_host.disabled = w.is_empty()
	_delete.disabled = w.is_empty()
	if w.is_empty():
		_info.text = "No worlds yet. Create one to start." if _worlds.is_empty() else ""
	else:
		_info.text = "Seed %d · created %s" % [int(w.meta.get("seed", 0)),
				str(w.meta.get("created", "?")).replace("T", " ").left(16)]


# --- Actions ------------------------------------------------------------------------

func _on_play() -> void:
	var w := _selected()
	if not w.is_empty():
		_start_game({"world_name": w.name, "player_name": _player_name()})


func _on_host() -> void:
	var w := _selected()
	if not w.is_empty():
		_start_game({"world_name": w.name, "net_mode": "host", "player_name": _player_name()})


func _on_join() -> void:
	_join_dialog.popup_centered()
	_join_address.grab_focus()
	_join_address.select_all()


func _on_join_confirmed() -> void:
	var text := _join_address.text.strip_edges()
	if text == "":
		return
	_settings.set_value("net", "last_address", text)
	var address := text
	var port := Session.DEFAULT_PORT
	var colon := text.rfind(":")
	if colon > 0 and text.count(":") == 1 and text.substr(colon + 1).is_valid_int():
		address = text.left(colon)
		port = text.substr(colon + 1).to_int()
	_start_game({"net_mode": "client", "join_address": address, "port": port,
			"player_name": _player_name()})


func _on_new() -> void:
	var n := 1
	while World.world_exists("World %d" % n):
		n += 1
	_new_name.text = "World %d" % n
	_new_seed.text = ""
	_validate_new()
	_new_dialog.popup_centered()
	_new_name.grab_focus()
	_new_name.select_all()


func _validate_new() -> void:
	var world_name := _new_name.text.strip_edges()
	var err := ""
	if world_name == "":
		err = "Enter a name."
	elif not World.is_valid_name(world_name):
		err = "Use letters, numbers, spaces, - and _ (max 32)."
	elif World.world_exists(world_name):
		err = "A world with this name already exists."
	elif _new_seed.text.strip_edges() != "" and not _new_seed.text.strip_edges().is_valid_int():
		err = "Seed must be a whole number."
	_new_error.text = err
	_new_dialog.get_ok_button().disabled = err != ""


func _on_new_name_submitted(_text: String) -> void:
	if not _new_dialog.get_ok_button().disabled:
		_new_dialog.hide()
		_on_create()


func _on_create() -> void:
	var seed_text := _new_seed.text.strip_edges()
	var new_seed := absi(seed_text.to_int()) if seed_text != "" else -1
	_start_game({"world_name": _new_name.text.strip_edges(), "new_seed": new_seed,
			"player_name": _player_name()})


func _on_delete() -> void:
	var w := _selected()
	if w.is_empty():
		return
	_delete_dialog.dialog_text = "Delete \"%s\"?\nIt will be moved to the trash." % w.name
	_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	var w := _selected()
	var err := World.delete_world(w.name)
	if err != OK:
		var alert := AcceptDialog.new()
		alert.dialog_text = "Couldn't delete \"%s\": %s" % [w.name, error_string(err)]
		add_child(alert)
		alert.popup_centered()
	_refresh()
