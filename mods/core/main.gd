extends RefCounted
## Code entry point of the base game. Third-party mods use the same shape:
## a script with init_mod(registry), plus optional JSON content files.

func init_mod(registry) -> void:
	# Content that needs logic can be registered from code instead of JSON.
	registry.register_block("planks", {"hardness": 2.0, "flammable": true, "color": "#b8945f",
		"textures": {"all": "textures/planks.png"}, "sound": "core:wood"})
	registry.register_recipe("planks_to_sticks", {
		"type": "shaped",
		"pattern": ["P", "P"],
		"key": {"P": "core:planks"},
		"output": {"item": "core:stick", "count": 4},
	})
