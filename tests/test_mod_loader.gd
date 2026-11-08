extends "res://tests/test_suite.gd"


func test_core_mod_loaded_with_content() -> void:
	check(ModLoader.mods.any(func(m): return m.id == "core"), "core mod loaded")
	check_eq(ModLoader.get_mod_path("core"), "res://mods/core", "core path")
	for id in ["core:stone", "core:grass", "core:water", "core:lamp", "core:coal_ore", "core:planks"]:
		check(Registry.blocks.has(id), "%s registered" % id)
	check(Registry.recipes.has("core:planks_to_sticks"), "recipe from the mod's script registered")


func test_registry_is_frozen_after_loading() -> void:
	check(Registry.is_frozen(), "frozen")
