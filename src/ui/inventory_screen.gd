class_name InventoryScreen
extends Control
## The inventory (E): 36 slots and hand crafting. Click a slot to pick its
## stack up, click another to put it down (same items stack, others swap).
## Crafting lists every hand recipe; "Craft" is enabled when you have the
## ingredients (in creative you always do).

signal closed

const SLOT := 52

var player: Node3D        # player.gd
var atlas: BlockAtlas
var _held: Dictionary = {}
var _slot_buttons: Array[Button] = []
var _recipe_rows: Array = []  # [recipe, Button]
var _held_icon: TextureRect


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
	center.add_child(panel)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	panel.add_child(columns)

	# Slots: rows of 9 for the backpack, then the hotbar row.
	var left := VBoxContainer.new()
	columns.add_child(left)
	left.add_child(_label("Inventory"))
	var grid := GridContainer.new()
	grid.columns = Inventory.HOTBAR
	left.add_child(grid)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 10
	var hotbar := GridContainer.new()
	hotbar.columns = Inventory.HOTBAR
	_slot_buttons.resize(Inventory.SIZE)
	for i in range(Inventory.HOTBAR, Inventory.SIZE):
		grid.add_child(_make_slot(i))
	left.add_child(spacer)
	left.add_child(_label("Hotbar"))
	left.add_child(hotbar)
	for i in Inventory.HOTBAR:
		hotbar.add_child(_make_slot(i))

	# Crafting.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 0)
	columns.add_child(right)
	right.add_child(_label("Crafting"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for recipe in Crafting.hand_recipes():
		list.add_child(_make_recipe_row(recipe))
	right.add_child(_label("E or Esc to close"))

	_held_icon = TextureRect.new()
	_held_icon.custom_minimum_size = Vector2(36, 36)
	_held_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_held_icon.size = Vector2(36, 36)
	_held_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_held_icon)

	player.inventory.changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	if player and player.inventory.changed.is_connected(_refresh):
		player.inventory.changed.disconnect(_refresh)


## Puts whatever is held back into the inventory.
func close() -> void:
	if not _held.is_empty():
		player.inventory.add(_held.id, _held.count)
		_held = {}
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey and event.pressed
			and not event.echo and event.keycode == KEY_E):
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_held_icon.visible = not _held.is_empty()
	_held_icon.global_position = get_global_mouse_position() + Vector2(4, 4)


func _make_slot(i: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(SLOT, SLOT)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(_on_slot.bind(i))
	_slot_buttons[i] = b
	return b


func _make_recipe_row(recipe: Dictionary) -> Control:
	var row := HBoxContainer.new()
	var icon := TextureRect.new()
	icon.texture = atlas.icon(recipe.output)
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(icon)
	var text := Label.new()
	var parts := PackedStringArray()
	for item in recipe.ingredients:
		parts.append("%d %s" % [recipe.ingredients[item], _name(item)])
	text.text = "%d × %s\n%s" % [recipe.count, _name(recipe.output), ", ".join(parts)]
	text.add_theme_font_size_override("font_size", 13)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	var craft := Button.new()
	craft.text = "Craft"
	craft.pressed.connect(_on_craft.bind(recipe))
	row.add_child(craft)
	_recipe_rows.append([recipe, craft])
	return row


func _on_slot(i: int) -> void:
	if player.creative and _held.is_empty() and not player.inventory.slots[i].is_empty():
		# Creative: rearrange freely, items never run out.
		_held = player.inventory.slots[i].duplicate()
		player.inventory.slots[i] = {}
		player.inventory.changed.emit()
		return
	_held = player.inventory.put(i, _held)
	_refresh()


func _on_craft(recipe: Dictionary) -> void:
	if player.creative:
		player.inventory.add(recipe.output, recipe.count)
	else:
		Crafting.craft(recipe, player.inventory)


func _refresh() -> void:
	for i in Inventory.SIZE:
		var s: Dictionary = player.inventory.slots[i]
		var b := _slot_buttons[i]
		b.icon = atlas.icon(s.id) if not s.is_empty() else null
		b.text = str(s.count) if not s.is_empty() and s.count > 1 and not player.creative else ""
		b.tooltip_text = _name(s.id) if not s.is_empty() else ""
		b.modulate = Color(1, 1, 0.6) if i == player.selected else Color.WHITE
	for row in _recipe_rows:
		row[1].disabled = not player.creative and not Crafting.can_craft(row[0], player.inventory)
	_held_icon.texture = atlas.icon(_held.id) if not _held.is_empty() else null


static func _name(id: String) -> String:
	return id.get_slice(":", 1).capitalize()


static func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
