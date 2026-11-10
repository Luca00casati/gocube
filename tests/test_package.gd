extends "res://tests/test_suite.gd"
## The game as players get it (tools/package.py): Godot next to the project
## folder. Built into user://_test_package* (deleted afterwards); the Linux one
## is made read-only and started through its launcher into a world.

const PACKAGER := "res://tools/package.py"


## Runs tools/package.py with `args`; [exit code, output].
func _package(args: Array) -> Array:
	var output := []
	var code := OS.execute("python3", [ProjectSettings.globalize_path(PACKAGER)] + args, output, true)
	return [code, "\n".join(output)]


func test_packaged_game_starts_read_only() -> void:
	var out := ProjectSettings.globalize_path("user://_test_package")
	var ran := _package([out, "--godot=" + OS.get_executable_path()])
	check_eq(ran[0], 0, "packaged: %s" % ran[1].strip_edges())
	if ran[0] != 0:
		return
	var dest := out.path_join("GoCube")
	for f in ["gocube", "godot", "game/project.godot", "game/mods/core/mod.json", "game/mods/.gdignore",
			"game/.godot/extension_list.cfg", "game/bin/libgocube.linux.template_debug.x86_64.so",
			"game/licenses/godot.txt"]:
		check(FileAccess.file_exists(dest.path_join(f)), f + " is there")
	for f in ["game/tests", "game/tools", "game/engine", "game/prototypes"]:
		check(not DirAccess.dir_exists_absolute(dest.path_join(f)), f + " is left out")
	OS.execute("chmod", ["-R", "a-w", dest])
	var output := []
	var code := OS.execute(dest.path_join("gocube"), ["--headless", "--quit-after", "300", "--",
			"--world=_test_package_world", "--no-mobs"], output, true)
	OS.execute("chmod", ["-R", "u+w", dest])  # so it can be deleted
	var text: String = "\n".join(output)
	check_eq(code, 0, "the game ran and quit cleanly")
	check("Loaded mods: [\"core\"]" in text, "it loaded the core mod from its own folder")
	check("World '_test_package_world'" in text, "and opened a world")
	var errors := Array(text.split("\n")).filter(func(l): return l.begins_with("ERROR") or l.begins_with("SCRIPT ERROR"))
	check(errors.is_empty(), "no errors: %s" % "; ".join(errors.slice(0, 3)))


## The Windows package (built here, not run: that needs Windows): the
## Windows engine library and Godot, a .cmd launcher, no Linux library. A
## stand-in file plays Godot, so nothing is downloaded.
func test_windows_package_layout() -> void:
	var out := ProjectSettings.globalize_path("user://_test_package_win")
	DirAccess.make_dir_recursive_absolute(out)
	var fake := out.path_join("Godot_win64.exe")
	FileAccess.open(fake, FileAccess.WRITE).store_string("stand-in")
	var ran := _package([out, "--platform=windows", "--godot=" + fake])
	check_eq(ran[0], 0, "packaged for Windows: %s" % ran[1].strip_edges())
	var dest := out.path_join("GoCube")
	for f in ["GoCube.cmd", "godot.exe", "game/bin/libgocube.windows.template_debug.x86_64.dll",
			"game/bin/gocube.gdextension", "game/project.godot"]:
		check(FileAccess.file_exists(dest.path_join(f)), f + " is there")
	check(not FileAccess.file_exists(dest.path_join("game/bin/libgocube.linux.template_debug.x86_64.so")),
			"no Linux library")
	var cmd := FileAccess.get_file_as_string(dest.path_join("GoCube.cmd"))
	check("\r\n" in cmd and "godot.exe\" --path \"%~dp0game\"" in cmd, "the launcher starts godot.exe on .\\game")


## It refuses to overwrite a package and says why.
func test_refuses_existing_package() -> void:
	var out := ProjectSettings.globalize_path("user://_test_package_twice")
	DirAccess.make_dir_recursive_absolute(out.path_join("GoCube"))
	var ran := _package([out, "--godot=" + OS.get_executable_path()])
	check_eq(ran[0], 1, "refused")
	check("already exists" in ran[1], "and said why: %s" % ran[1].strip_edges())


## Downloads are checked against Godot's published SHA512-SUMS.txt.
func test_published_checksums() -> void:
	var script := "import sys; sys.path.insert(0, sys.argv[1]); import package as p\n" \
			+ "s = '%s  Godot_v4.7.2-stable_win64.exe.zip\\n%s  Godot_v4.7.2-stable_linux.x86_64.zip\\n' % ('a' * 128, 'B' * 128)\n" \
			+ "print(p.published_sum(s, 'Godot_v4.7.2-stable_win64.exe.zip') == 'a' * 128,\n" \
			+ "      p.published_sum(s, 'Godot_v4.7.2-stable_linux.x86_64.zip') == 'b' * 128,\n" \
			+ "      p.published_sum(s, 'Godot_v4.7.2-stable_macos.universal.zip') == '')"
	var output := []
	var code := OS.execute("python3", ["-I", "-c", script, ProjectSettings.globalize_path("res://tools")], output, true)
	check_eq(code, 0, "ran: %s" % "\n".join(output))
	check_eq("\n".join(output).strip_edges(), "True True True", "found, lower-cased, missing gives none")
