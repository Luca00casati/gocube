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


## The Mods part of the settings screen: what each mod is, why one didn't
## load, and the mods downloaded from servers (which can be deleted).
func test_mods_screen_and_server_cache() -> void:
	var cached := ModLoader.SERVER_DIR.path_join("fake_0123456789ab")
	DirAccess.make_dir_recursive_absolute(cached)
	var f := FileAccess.open(cached.path_join("mod.json"), FileAccess.WRITE)
	f.store_string('{"id": "fake"}')
	f.close()
	var cache := ModLoader.server_cache()
	check(cache.any(func(c): return c.name == "fake_0123456789ab" and c.size == 14), "the cache lists it with its size")
	check_eq(ModLoader.origin({"path": "res://mods/core"}), "built-in", "built-in")
	check_eq(ModLoader.origin({"path": ModLoader.UNZIP_DIR + "/x"}), "zip", "from a zip")
	check_eq(ModLoader.origin({"path": "user://mods/x"}), "folder", "a folder")
	ModLoader.problems["_test_broken"] = "Invalid mod.json: _test_broken"
	var screen := SettingsScreen.new()
	add(screen)
	await frames(2)
	var texts := screen.find_children("*", "Label", true, false).map(func(l): return l.text)
	check(texts.has("Mods") and texts.has("Downloaded from servers"), "the Mods part is shown")
	check(texts.has("Invalid mod.json: _test_broken"), "with why a mod didn't load")
	check(texts.any(func(t): return t.begins_with("1 mod(s)") or t.contains("mod(s),")), "and the downloaded mods: %s" % [texts])
	var delete: Button = screen.find_children("*", "Button", true, false).filter(func(b): return b.text == "Delete them")[0]
	check(not delete.disabled, "they can be deleted")
	delete.pressed.emit()
	check(not DirAccess.dir_exists_absolute(ModLoader.SERVER_DIR), "deleted")
	ModLoader.server_mods = ["core@x#y"]
	check(not ModLoader.clear_server_cache(), "not while playing with a server's mods")
	ModLoader.server_mods = []
	ModLoader.problems.erase("_test_broken")
	screen.queue_free()


## Mod zips are external input: their table of contents is checked before
## anything is unpacked (zip bombs, too many files, broken zips), and a zip
## that fails leaves what was unpacked before as it was.
func test_zip_limits() -> void:
	var dir := "user://_test_ziplimits"
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := '{"id": "zl", "content": ["c.json"]}'
	_zip(dir.path_join("good.zip"), {"mod.json": manifest, "c.json": "{}"})
	check_eq(ModLoader.unzip_mod(dir.path_join("good.zip"), dir.path_join("out")), "", "a normal zip")
	var listing = ModLoader.zip_listing(dir.path_join("good.zip"))
	check(listing is Dictionary and listing.has("mod.json") and listing["mod.json"][1] == manifest.length(),
			"its table of contents gives each file's unpacked size")

	var zeros := PackedByteArray()
	zeros.resize(ModLoader.ZIP_MAX_FILE + 1)
	var z := ZIPPacker.new()
	z.open(dir.path_join("bomb.zip"))
	z.start_file("mod.json")
	z.write_file(manifest.to_utf8_buffer())
	z.close_file()
	z.start_file("huge.bin")
	z.write_file(zeros)
	z.close_file()
	z.close()
	check(FileAccess.get_size(dir.path_join("bomb.zip")) < 1 << 20, "(a small zip)")
	var problem := ModLoader.unzip_mod(dir.path_join("bomb.zip"), dir.path_join("out"))
	check(problem.contains("more than"), "that unpacks to more than a file may be is refused: %s" % problem)
	zeros.resize(4 << 20)
	z = ZIPPacker.new()
	z.open(dir.path_join("tight.zip"))
	z.start_file("mod.json")
	z.write_file(manifest.to_utf8_buffer())
	z.close_file()
	z.start_file("tight.bin")
	z.write_file(zeros)
	z.close_file()
	z.close()
	check(ModLoader.unzip_mod(dir.path_join("tight.zip"), dir.path_join("out")) != "", "a file packed 1000 times or more is refused")

	var files := {"mod.json": manifest}
	for i in ModLoader.ZIP_MAX_FILES + 1:
		files["f%d.txt" % i] = "x"
	_zip(dir.path_join("many.zip"), files)
	check(ModLoader.unzip_mod(dir.path_join("many.zip"), dir.path_join("out")).contains("files"), "too many files")
	var f := FileAccess.open(dir.path_join("junk.zip"), FileAccess.WRITE)
	f.store_buffer("PK not really a zip, just some bytes".repeat(10).to_utf8_buffer())
	f.close()
	check(ModLoader.unzip_mod(dir.path_join("junk.zip"), dir.path_join("out")) != "", "a broken zip")
	check(FileAccess.file_exists(dir.path_join("out/mod.json")) and FileAccess.file_exists(dir.path_join("out/c.json")),
			"after all those, the good zip's files are still there")
	check(not DirAccess.dir_exists_absolute(dir.path_join(".out.unpacking")), "and nothing half unpacked is left")
	ModLoader._remove_dir(dir)
