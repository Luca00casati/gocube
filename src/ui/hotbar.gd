class_name Hotbar
extends Control
## The 9 hotbar slots at the bottom of the screen, plus the mining progress bar
## under the crosshair. Reads the player's inventory; draws only.

const SLOT := 52
const GAP := 4

var player: Node3D       # player.gd
var atlas: BlockAtlas
var _progress: ProgressBar


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.max_value = 1.0
	_progress.custom_minimum_size = Vector2(120, 8)
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_progress)


func _process(_delta: float) -> void:
	queue_redraw()
	if player:
		_progress.visible = player.mining_progress > 0.0
		_progress.value = player.mining_progress
		_progress.position = size / 2 + Vector2(-60, 22)


func _draw() -> void:
	if player == null or atlas == null:
		return
	var total := Inventory.HOTBAR * SLOT + (Inventory.HOTBAR - 1) * GAP
	var origin := Vector2((size.x - total) / 2, size.y - SLOT - 12)
	var font := get_theme_default_font()
	for i in Inventory.HOTBAR:
		var r := Rect2(origin + Vector2(i * (SLOT + GAP), 0), Vector2(SLOT, SLOT))
		draw_rect(r, Color(0, 0, 0, 0.45))
		var slot: Dictionary = player.inventory.slots[i]
		if not slot.is_empty():
			draw_texture_rect(atlas.icon(slot.id), r.grow(-8), false)
			if not player.creative and slot.count > 1:
				var text := str(slot.count)
				draw_string_outline(font, r.position + Vector2(SLOT - 6 - text.length() * 8, SLOT - 6), text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK)
				draw_string(font, r.position + Vector2(SLOT - 6 - text.length() * 8, SLOT - 6), text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		var border := Color(1, 1, 1, 0.95) if i == player.selected else Color(1, 1, 1, 0.25)
		draw_rect(r, border, false, 3.0 if i == player.selected else 1.0)
	var item: String = player.selected_item()
	if item != "":
		var name := item.get_slice(":", 1).capitalize()
		var w := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		draw_string_outline(font, Vector2((size.x - w) / 2, origin.y - 10), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK)
		draw_string(font, Vector2((size.x - w) / 2, origin.y - 10), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
