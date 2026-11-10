class_name ContainerScreen
extends Control
## A chest or furnace (top) and the player's inventory (bottom). Click a slot to
## pick its stack up, click another to put it down (same items stack, others
## swap). The container side goes through a backend: Local (this process owns
## the world) or Remote (a multiplayer client, through the host).

signal closed
## Closing with something on the mouse that no longer fits: drop it.
signal left_over(stack: Dictionary)

const SLOT := 52


## Backend over this process's BlockEntities.
class Local extends RefCounted:
	signal updated
	signal held_changed(held: Dictionary)
	var entities: BlockEntities
	var pos: Vector3i

	func _init(be: BlockEntities, p: Vector3i) -> void:
		entities = be
		pos = p
		entities.changed.connect(_on_changed)

	func _on_changed(p: Vector3i) -> void:
		if p == pos:
			updated.emit()

	func entity() -> Dictionary:
		return entities.get_entity(pos)

	func click(slot: int, held: Dictionary) -> void:
		held_changed.emit(entities.click(pos, slot, held))

	func close() -> void:
		entities.changed.disconnect(_on_changed)


## Backend for a multiplayer client: the host has the contents.
class Remote extends RefCounted:
	signal updated
	signal held_changed(held: Dictionary)
	var session: Session
	var pos: Vector3i
	var _data := {}

	func _init(s: Session, p: Vector3i) -> void:
		session = s
		pos = p
		session.container_updated.connect(_on_data)
		session.container_held.connect(_on_held)
		session.open_container(pos)

	func _on_data(p: Vector3i, data: Dictionary) -> void:
		if p == pos:
			_data = data
			updated.emit()

	func _on_held(p: Vector3i, held: Dictionary) -> void:
		if p == pos:
			held_changed.emit(held)

	func entity() -> Dictionary:
		return _data

	func click(slot: int, held: Dictionary) -> void:
		session.container_click(pos, slot, held)

	func close() -> void:
		session.container_updated.disconnect(_on_data)
		session.container_held.disconnect(_on_held)
		session.close_container(pos)


var player: Node3D        # player.gd
var atlas: BlockAtlas
var backend               # Local or Remote
var _waiting := false     # a remote click is on its way
var _container_buttons: Array[Button] = []
var _inventory_buttons: Array[Button] = []
var _held_icon: TextureRect
var _burn: ProgressBar
var _progress: ProgressBar
var _box: VBoxContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	style_panel(panel)
	center.add_child(panel)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 10)
	panel.add_child(_box)

	_held_icon = TextureRect.new()
	_held_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_held_icon.size = Vector2(36, 36)
	_held_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_held_icon)

	backend.updated.connect(_refresh)
	backend.held_changed.connect(func(h):
		player.inventory.cursor = h
		_waiting = false
		_refresh())
	player.inventory.changed.connect(_refresh)
	_build()


func _build() -> void:
	for c in _box.get_children():
		c.queue_free()
	_container_buttons.clear()
	_inventory_buttons.clear()
	var e: Dictionary = backend.entity()
	var kind: String = e.get("type", "")
	_box.add_child(_label("Furnace" if kind == "furnace" else ("Chest" if kind == "chest" else "Loading…")))
	if kind == "chest":
		var grid := GridContainer.new()
		grid.columns = 9
		_box.add_child(grid)
		for i in e.slots.size():
			grid.add_child(_slot_button(_on_container_slot.bind(i), _container_buttons))
	elif kind == "furnace":
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		_box.add_child(row)
		var left := VBoxContainer.new()
		row.add_child(left)
		left.add_child(_label("Input"))
		left.add_child(_slot_button(_on_container_slot.bind(BlockEntities.FURNACE_INPUT), _container_buttons))
		left.add_child(_label("Fuel"))
		left.add_child(_slot_button(_on_container_slot.bind(BlockEntities.FURNACE_FUEL), _container_buttons))
		_burn = _bar(Color(0.95, 0.5, 0.15))
		left.add_child(_burn)
		var middle := VBoxContainer.new()
		middle.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_child(middle)
		_progress = _bar(Color(0.9, 0.9, 0.9))
		_progress.custom_minimum_size = Vector2(120, 14)
		middle.add_child(_label("Smelting"))
		middle.add_child(_progress)
		var right := VBoxContainer.new()
		right.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_child(right)
		right.add_child(_label("Output"))
		right.add_child(_slot_button(_on_container_slot.bind(BlockEntities.FURNACE_OUTPUT), _container_buttons))
	_box.add_child(_label("Inventory"))
	var inv := GridContainer.new()
	inv.columns = Inventory.HOTBAR
	_box.add_child(inv)
	for i in range(Inventory.HOTBAR, Inventory.SIZE):
		inv.add_child(_slot_button(_on_inventory_slot.bind(i), _inventory_buttons))
	var hotbar := GridContainer.new()
	hotbar.columns = Inventory.HOTBAR
	_box.add_child(hotbar)
	for i in Inventory.HOTBAR:
		hotbar.add_child(_slot_button(_on_inventory_slot.bind(i), _inventory_buttons))
	_box.add_child(_label("E or Esc to close"))
	_refresh()


func close() -> void:
	var left: Dictionary = player.inventory.close_cursor()
	if not left.is_empty():
		left_over.emit(left)
	backend.close()
	closed.emit()


func _exit_tree() -> void:
	if player and player.inventory.changed.is_connected(_refresh):
		player.inventory.changed.disconnect(_refresh)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"inventory"):
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_held_icon.visible = not player.inventory.cursor.is_empty()
	_held_icon.global_position = get_global_mouse_position() + Vector2(4, 4)


func _on_container_slot(slot: int) -> void:
	if _waiting:
		return
	var held: Dictionary = player.inventory.cursor
	if backend is Remote:
		_waiting = true  # the host answers with what we hold afterwards
		player.inventory.cursor = {}
	backend.click(slot, held)


func _on_inventory_slot(i: int) -> void:
	if _waiting:
		return
	player.inventory.click(i)
	_refresh()


func _refresh() -> void:
	var e: Dictionary = backend.entity()
	if _container_buttons.size() != (e.get("slots", []) as Array).size():
		_build.call_deferred()
		return
	for i in _container_buttons.size():
		_show(_container_buttons[i], e.slots[i])
	var order := range(Inventory.HOTBAR, Inventory.SIZE) + range(Inventory.HOTBAR)
	for k in _inventory_buttons.size():
		_show(_inventory_buttons[k], player.inventory.slots[order[k]])
	if e.get("type") == "furnace" and _burn:
		var status := BlockEntities.furnace_status(e)
		_burn.value = status.burn
		_progress.value = status.progress
	var held: Dictionary = player.inventory.cursor
	_held_icon.texture = atlas.icon(held.id) if not held.is_empty() else null


func _show(b: Button, s) -> void:
	var slot: Dictionary = s if s is Dictionary else {}
	b.icon = atlas.icon(slot.id) if not slot.is_empty() else null
	b.text = str(slot.count) if not slot.is_empty() and slot.count > 1 else ""
	b.tooltip_text = str(slot.get("id", "")).get_slice(":", 1).capitalize()


func _slot_button(on_press: Callable, into: Array[Button]) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(SLOT, SLOT)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.add_theme_font_size_override("font_size", 13)
	style_slot(b)
	b.pressed.connect(on_press)
	into.append(b)
	return b


## Shared look for item slots and screen panels (also used by InventoryScreen).
static func style_slot(b: Button) -> void:
	for state in [["normal", 0.16], ["hover", 0.26], ["pressed", 0.32], ["focus", 0.16]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(state[1], state[1], state[1] + 0.02, 0.92)
		sb.border_color = Color(0.42, 0.42, 0.46) if state[0] != "hover" else Color(0.75, 0.75, 0.8)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(3)
		sb.set_content_margin_all(4)
		if state[0] == "focus":
			sb.draw_center = false
			sb.border_color = Color(0, 0, 0, 0)
		b.add_theme_stylebox_override(state[0], sb)
	b.add_theme_constant_override("outline_size", 4)
	b.add_theme_color_override("font_outline_color", Color.BLACK)


static func style_panel(p: PanelContainer) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.94)
	sb.border_color = Color(0.3, 0.3, 0.34)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(16)
	p.add_theme_stylebox_override("panel", sb)


static func _bar(color: Color) -> ProgressBar:
	var p := ProgressBar.new()
	p.max_value = 1.0
	p.show_percentage = false
	p.custom_minimum_size = Vector2(SLOT, 8)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	p.add_theme_stylebox_override("fill", fill)
	return p


static func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
