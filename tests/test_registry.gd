extends "res://tests/test_suite.gd"
## Block id tables: what keeps saved worlds valid when mods change.


func test_default_ids_start_with_air_and_are_sorted() -> void:
	Registry.assign_block_ids()
	check_eq(Registry.block_ids[0], "core:air", "air is id 0")
	var rest := Array(Registry.block_ids).slice(1)
	var sorted_rest := rest.duplicate()
	sorted_rest.sort()
	check_eq(rest, sorted_rest, "other ids sorted")
	check_eq(Registry.block_index(Registry.block_ids[3]), 3, "index lookup")


func test_saved_table_keeps_numbers_and_appends_new_blocks() -> void:
	var saved := PackedStringArray(["core:air", "core:stone", "gone:block", "core:dirt"])
	Registry.assign_block_ids(saved)
	check_eq(Registry.block_index("core:stone"), 1, "saved id kept")
	check_eq(Registry.block_index("core:dirt"), 3, "saved id kept")
	check_eq(Registry.block_index("gone:block"), 2, "missing mod's block keeps its slot")
	check(Registry.block_ids.size() > 4, "new blocks appended")
	check(Registry.block_index("core:grass") >= 4, "new block after the saved ones")
	Registry.assign_block_ids()  # restore defaults for later tests
