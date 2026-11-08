extends "res://tests/test_suite.gd"


func test_core_sound_sets_load() -> void:
	for set_id in ["core:grass", "core:stone", "core:wood", "core:sand", "core:gravel", "core:effects", "core:ambience"]:
		check(Registry.sound_sets.has(set_id), "%s registered" % set_id)
		var def: Dictionary = Registry.sound_sets.get(set_id, {})
		for kind in def:
			if kind in ["mod", "id"]:
				continue
			for file in def[kind]:
				var path := ModLoader.get_mod_path("core").path_join(file)
				check(Sounds._load(path) != null, "%s loads" % path)


func test_blocks_point_at_existing_sets() -> void:
	for id in Registry.blocks:
		var def: Dictionary = Registry.blocks[id]
		if def.has("sound"):
			check(Registry.sound_sets.has(def.sound), "%s uses a registered sound set (%s)" % [id, def.sound])
