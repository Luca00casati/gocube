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


func test_content_is_checked_before_anything_registers() -> void:
	check_eq(ModLoader.content_problem({"blocks": {"a": {}}, "items": {}}), "", "good content")
	for bad in [[], "x", {"blocks": []}, {"blocks": {"a": 5}}, {"items": {"a": {}, "b": "c"}}]:
		check(ModLoader.content_problem(bad) != "", "refused: %s" % [bad])
	var root := "user://_test_badmod"
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join("mod.json"), FileAccess.WRITE)
	f.store_string('{"id": "badmod", "content": ["a.json", "b.json"]}')
	f.close()
	for pair in [["a.json", '{"blocks": {"fine": {}}}'], ["b.json", '{"blocks": {"broken": 3}}']]:
		f = FileAccess.open(root.path_join(pair[0]), FileAccess.WRITE)
		f.store_string(pair[1])
		f.close()
	var found := {}
	expect_error("Mod 'badmod'")
	ModLoader._add_found(root, found)
	check(not found.has("badmod"), "a mod with one bad content file is skipped whole")
	ModLoader._remove_dir(root)


func test_failed_mod_is_undone() -> void:
	var root := "user://_test_failmod"
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join("main.gd"), FileAccess.WRITE)
	f.store_string("extends RefCounted\n\nfunc init_mod(registry) -> bool:\n\tregistry.register_block(\"half_done\", {})\n\tregistry.register_block(\"core:stone\", {\"color\": \"#ff00ff\"})\n\treturn false\n")
	f.close()
	var stone: Dictionary = Registry.blocks["core:stone"]
	var count := Registry.blocks.size()
	expect_error("Mod 'failmod'")
	Registry._frozen = false  # as while mods load
	var ok: bool = ModLoader._load_mod({"id": "failmod", "entry": "main.gd", "path": root,
			"_content": [{"items": {"thing": {}}}]})
	Registry._frozen = true
	check(not ok, "reported as failed")
	check(not Registry.blocks.has("failmod:half_done") and not Registry.items.has("failmod:thing"), "its content is gone")
	check(Registry.blocks["core:stone"] == stone and Registry.blocks.size() == count, "what it overrode is back")
	check(not ModLoader.mods.any(func(m): return m.id == "failmod"), "not listed as loaded")
	ModLoader._remove_dir(root)


func test_mod_fingerprints() -> void:
	var core: Dictionary = ModLoader.mods[0]
	check_eq(str(core.get("hash", "")).length(), 12, "core has a fingerprint")
	var root := "user://_test_fp"
	DirAccess.make_dir_recursive_absolute(root.path_join("c"))
	var f := FileAccess.open(root.path_join("c/a.json"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	var first := ModLoader.fingerprint(root)
	check_eq(ModLoader.fingerprint(root), first, "the same files, the same fingerprint")
	f = FileAccess.open(root.path_join("c/a.json"), FileAccess.WRITE)
	f.store_string("{ }")
	f.close()
	check(ModLoader.fingerprint(root) != first, "a changed file changes it")
	ModLoader._remove_dir(root)
