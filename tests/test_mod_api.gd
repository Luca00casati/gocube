extends "res://tests/test_suite.gd"


func test_core_declares_api_version_and_worldgen() -> void:
	var core: Dictionary = ModLoader.mods.filter(func(m): return m.id == "core")[0]
	check_eq(int(core.get("api_version", 0)), ModLoader.API_VERSION, "core declares the current API version")
	for ore in ["core:coal", "core:iron", "core:gold", "core:crystal"]:
		check(Registry.ores.has(ore), "%s registered from content" % ore)
