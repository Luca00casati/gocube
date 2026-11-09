@tool
extends EditorPlugin
## mods/ has a .gdignore, so Godot neither imports its textures and sounds
## (no .import files, no copies in .godot/imported) nor exports it. The game
## reads those files directly (BlockAtlas, Sounds, ModLoader), so this adds
## every file under mods/ to exported games unchanged.

var _exporter: EditorExportPlugin


func _enter_tree() -> void:
	_exporter = ModsExporter.new()
	add_export_plugin(_exporter)


func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null


class ModsExporter extends EditorExportPlugin:
	func _get_name() -> String:
		return "GoCubeMods"

	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		_add_dir("res://mods")

	func _add_dir(dir: String) -> void:
		var d := DirAccess.open(dir)
		if d == null:
			push_error("GoCube export: can't open " + dir)
			return
		for f in d.get_files():  # hidden files (.gdignore) are skipped
			add_file(dir.path_join(f), FileAccess.get_file_as_bytes(dir.path_join(f)), false)
		for sub in d.get_directories():
			_add_dir(dir.path_join(sub))
