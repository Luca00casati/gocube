extends "res://tests/test_suite.gd"

const OK_SCRIPT := """extends RefCounted
## A doc comment with OS.execute("rm") in it is just a comment.

const COLORS := {"red": "#ff0000", "blue": "#0000ff"}
static var made := 0

func init_mod(registry) -> bool:
	for name in COLORS:
		var id: String = registry.register_block(name + "_wool", {"color": COLORS[name], "hardness": 0.8})
		made += 1
		print("made %s" % id, " ", "load('x')")
	var sizes := range(3).map(func(i: int) -> int: return i * 2)
	var stone: Dictionary = registry.get_block("core:stone")
	var hardness: float = stone.get("hardness", 1.0) * 1.5e0 + 0x10 + .5
	registry.register_item("dust", {"color": Color(0.5, 0.5, 0.5).to_html(), "stack": maxi(sizes.size(), 1)})
	match made:
		2: pass
		_: return false
	for k in 2:
		made += k
	return made == 3 and hardness > 0 and Vector3.UP.y == 1 and TYPE_INT == typeof(1)
"""


func test_plain_mod_scripts_pass() -> void:
	check_eq(ModSandbox.check(OK_SCRIPT), "", "a mod using only the API and plain values")
	check_eq(ModSandbox.check(FileAccess.get_file_as_string("res://mods/core/main.gd")), "", "the core mod's script")
	check_eq(ModSandbox.check("func init_mod(r):\n\tr.register_block(\"a\")\n"), "", "no extends is fine")


func test_escapes_are_refused() -> void:
	var body := "extends RefCounted\nfunc init_mod(registry):\n\t%s\n"
	for bad in [
		"OS.execute(\"sh\", [])",                      # engine singletons
		"FileAccess.open(\"user://x\", 2)",
		"var f = load(\"res://src/main.gd\")",           # loading code
		"var s = preload(\"res://src/main.gd\")",
		"var v = str_to_var(\"Object(Node,{})\")",       # making objects from text
		"Registry.blocks.clear()",                        # the game's autoloads
		"ModLoader.mods.clear()",
		"var w = World.new()",                            # the game's classes
		"self.call(\"free\")",                            # the script's own object
		"call(\"free\")",
		"get_script()",
		"set_script(null)",
		"registry.call(\"_set_handler\", Callable())",    # dynamic calls on the API
		"registry._set_handler(Callable())",
		"registry.set(\"script\", null)",
		"registry.connect(\"x\", init_mod)",
		"var c = Callable(registry, \"free\")",
		"var x = registry.register_block.call(\"a\")",
		"var x = Engine.get_singleton(\"OS\")",
		"var x = ClassDB.instantiate(\"Node\")",
		"var x = JavaScriptBridge",
		"var x = $Node",
		"await registry",
		"var x = instance_from_id(1)",
		"var x = Expression.new()",
		"var d = {}; d.free()",
		"var x = super.init_mod(registry)",
	]:
		var problem := ModSandbox.check(body % bad)
		check(problem != "", "refused: %s" % bad)
	for bad in [
		"extends Node\nfunc init_mod(r):\n\tpass\n",                   # nodes reach the scene tree
		"extends \"res://src/main.gd\"\n",
		"@tool\nextends RefCounted\n",                                   # annotations
		"class_name Evil\n",
		"class Inner:\n\tvar a = 1\n",
		"signal boom\n",
		"func init_mod(r):\n\tvar OS = 1\n",                             # shadowing engine names
		"func init_mod(r):\n\tvar call = 1\nfunc other():\n\tcall(\"free\")\n",
		"func get_script():\n\tpass\n",
		"func init_mod(load):\n\tpass\n",
		"func init_mod(r):\n\tvar x = r.get(\"a\").get_script()\n",
		"func init_mod(r):\n\tvar ОS = 1\n",                             # a look-alike letter (Cyrillic O)
		"func init_mod(r):\n\tvar s = \"unterminated\n",
		"var x = 1\nextends RefCounted\n",                               # extends after code
	]:
		check(ModSandbox.check(bad) != "", "refused: %s" % bad.c_escape())


func test_problem_says_where() -> void:
	var problem := ModSandbox.check("extends RefCounted\n\n\nfunc init_mod(r):\n\tOS.crash(\"x\")\n")
	check(problem.begins_with("line 5:") and "OS" in problem, "line and name: %s" % problem)


## Names the sandbox lets a mod use after a dot must not be methods of the API
## object (or Object) other than its own and `get` (which only reads its
## properties: it has none).
func test_api_object_exposes_only_its_methods() -> void:
	var object_methods := {}
	for m in ClassDB.class_get_method_list("GoCubeModApi"):
		object_methods[m.name] = true
	var api_own := ["register_block", "register_item", "register_recipe", "register_ore",
		"register_tree", "register_biome", "register_sound_set", "get_block", "get_item"]
	for name in ModSandbox.ALLOWED_MEMBERS:
		if object_methods.has(name):
			check(name in api_own or name == "get", "`%s` is an Object method mods could call" % name)
	var api := GoCubeModApi.new()
	check_eq(api.get("script"), null, "the API object has no script to reach")
	check_eq(api.get_property_list().filter(func(p): return p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE).size(), 0,
			"and no properties")
	expect_error("only be used while the mod loads")
	check_eq(api.register_block("late", {}), "", "it does nothing outside loading")


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _load_test_mod(id: String, root: String, entry: String) -> bool:
	Registry._frozen = false  # as while mods load
	var ok: bool = ModLoader._load_mod({"id": id, "entry": entry, "path": root, "_content": []})
	Registry._frozen = true
	return ok


func test_sandboxed_mod_loads_and_registers() -> void:
	var root := "user://_test_sandboxed"
	_write(root.path_join("main.gd"), OK_SCRIPT)
	var count := Registry.blocks.size()
	check(_load_test_mod("sandboxed", root, "main.gd"), "a mod that passes the check loads")
	check(Registry.blocks.has("sandboxed:red_wool") and Registry.items.has("sandboxed:dust"), "and registers through the API")
	check_eq(Registry.blocks.size(), count + 2, "two blocks")
	for id in ["sandboxed:red_wool", "sandboxed:blue_wool"]:
		Registry.blocks.erase(id)
	Registry.items.erase("sandboxed:dust")
	ModLoader.mods = ModLoader.mods.filter(func(m): return m.id != "sandboxed")
	ModLoader._remove_dir(root)


func test_refused_mod_runs_nothing() -> void:
	var root := "user://_test_evil"
	var marker := "user://_test_evil_ran"
	_write(root.path_join("main.gd"), "extends RefCounted\nstatic var ran = FileAccess.open(\"%s\", FileAccess.WRITE)\nfunc init_mod(r):\n\tr.register_block(\"evil\")\n" % marker)
	expect_error("Mod 'evil'")
	check(not _load_test_mod("evil", root, "main.gd"), "refused")
	check(not FileAccess.file_exists(marker), "none of its code ran")
	check(not Registry.blocks.has("evil:evil"), "nothing registered")
	ModLoader._remove_dir(root)


func test_definitions_must_be_plain_data() -> void:
	var root := "user://_test_lambda"
	_write(root.path_join("main.gd"), "func init_mod(r):\n\tr.register_block(\"a\", {\"on_use\": func(): return 1})\n\tr.register_block(\"b\", {\"list\": [r]})\n")
	expect_error("isn't plain data")
	check(_load_test_mod("lambda", root, "main.gd"), "loads")
	check(not Registry.blocks.has("lambda:a") and not Registry.blocks.has("lambda:b"), "callables and objects aren't registered")
	ModLoader.mods = ModLoader.mods.filter(func(m): return m.id != "lambda")
	ModLoader._remove_dir(root)


func test_mod_files_stay_in_the_mod_and_are_read_raw() -> void:
	check_eq(ModLoader.asset_path("core", "textures/stone.png"), "res://mods/core/textures/stone.png", "a file of the mod")
	for bad in ["../../src/main.gd", "/etc/passwd", "res://src/main.gd", "textures/../../x.png",
			"nosuchmod:textures/a.png", "core:../src/main.gd", "a\\..\\b.png", ""]:
		check_eq(ModLoader.asset_path("core", bad), "", "refused: %s" % bad)
	check(not ModLoader.is_builtin("user://mods/x/a.png") and ModLoader.is_builtin("res://mods/core/a.png"), "builtin = res://")
	# An installed mod's "texture" that is really a resource with a script is
	# not loaded through the resource loader.
	var dir := "user://_test_rawtex"
	var marker := "user://_test_rawtex_ran"
	_write(dir.path_join("evil.tres"), "[gd_resource type=\"Resource\" load_steps=2 format=3]\n\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"extends Resource\nfunc _init():\n\tFileAccess.open(\\\"%s\\\", FileAccess.WRITE)\n\"\n\n[resource]\nscript = SubResource(\"1\")\n" % marker)
	_write(dir.path_join("evil.png.import"), "[remap]\nimporter=\"texture\"\ntype=\"Resource\"\npath=\"%s\"\n" % dir.path_join("evil.tres"))
	_write(dir.path_join("evil.png"), "not a png")
	var BlockAtlas = load("res://src/engine/block_atlas.gd")
	for e in ["Not a PNG", "ERR_FILE_CORRUPT", "Error loading image", "Failed to load image"]:
		expect_error(e)
	check_eq(BlockAtlas._load_image(dir.path_join("evil.tres")), null, "a .tres isn't an image")
	check_eq(BlockAtlas._load_image(dir.path_join("evil.png")), null, "a .png with a remap isn't loaded as a resource")
	check(not FileAccess.file_exists(marker), "no script ran")
	ModLoader._remove_dir(dir)
