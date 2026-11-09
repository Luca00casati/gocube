extends "res://tests/test_suite.gd"


func test_core_mod_loaded_with_content() -> void:
	check(ModLoader.mods.any(func(m): return m.id == "core"), "core mod loaded")
	check_eq(ModLoader.get_mod_path("core"), "res://mods/core", "core path")
	for id in ["core:stone", "core:grass", "core:water", "core:lamp", "core:coal_ore", "core:planks"]:
		check(Registry.blocks.has(id), "%s registered" % id)
	check(Registry.recipes.has("core:planks_to_sticks"), "recipe from the mod's script registered")


func test_registry_is_frozen_after_loading() -> void:
	check(Registry.is_frozen(), "frozen")


func test_bad_manifests_are_refused() -> void:
	var root := "user://_test_mod"
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join("blocks.json"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	check_eq(ModLoader.manifest_problem({"id": "ok_mod", "content": ["blocks.json"], "dependencies": ["core"]}, root),
			"", "a good manifest passes")
	for bad in [[], {"id": "Bad Id"}, {"id": 5}, {"id": "m", "version": 2}, {"id": "m", "dependencies": "core"},
			{"id": "m", "dependencies": [3]}, {"id": "m", "content": "blocks.json"},
			{"id": "m", "content": ["../../etc/passwd.json"]}, {"id": "m", "content": ["/abs.json"]},
			{"id": "m", "content": ["missing.json"]}, {"id": "m", "entry": "blocks.json"},
			{"id": "m", "entry": "res://src/main.gd"}, {"id": "m", "api_version": "1"}]:
		check(ModLoader.manifest_problem(bad, root) != "", "refused: %s" % [bad])
	DirAccess.remove_absolute(root.path_join("blocks.json"))
	DirAccess.remove_absolute(root)



func _zip(path: String, files: Dictionary) -> void:
	var z := ZIPPacker.new()
	z.open(path)
	for name in files:
		z.start_file(name)
		z.write_file(files[name].to_utf8_buffer())
		z.close_file()
	z.close()


func test_zipped_mods_unpack() -> void:
	var dir := "user://_test_zips"
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := '{"id": "zipped", "content": ["c/blocks.json"]}'
	# mod.json at the top of the zip
	_zip(dir.path_join("flat.zip"), {"mod.json": manifest, "c/blocks.json": "{}"})
	check_eq(ModLoader.unzip_mod(dir.path_join("flat.zip"), dir.path_join("out_flat")), "", "flat zip")
	check(FileAccess.file_exists(dir.path_join("out_flat/c/blocks.json")), "its files are unpacked")
	# or inside one folder (zipping the mod folder itself)
	_zip(dir.path_join("nested.zip"), {"zipped/mod.json": manifest, "zipped/c/blocks.json": "{}"})
	check_eq(ModLoader.unzip_mod(dir.path_join("nested.zip"), dir.path_join("out_nested")), "", "zipped folder")
	check_eq(ModLoader.manifest_problem(JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("out_nested/mod.json"))),
			dir.path_join("out_nested")), "", "unpacked into a normal mod folder")
	# refused
	_zip(dir.path_join("evil.zip"), {"mod.json": manifest, "../../escape.txt": "x"})
	check(ModLoader.unzip_mod(dir.path_join("evil.zip"), dir.path_join("out_evil")) != "", "paths out of the mod are refused")
	check(not FileAccess.file_exists("user://escape.txt") and not DirAccess.dir_exists_absolute(dir.path_join("out_evil")),
			"and nothing is written")
	_zip(dir.path_join("none.zip"), {"readme.txt": "hi"})
	check(ModLoader.unzip_mod(dir.path_join("none.zip"), dir.path_join("out_none")) != "", "a zip without mod.json is refused")
	ModLoader._remove_dir(dir)
	check(not DirAccess.dir_exists_absolute(dir), "cleaned up")
