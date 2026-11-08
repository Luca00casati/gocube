extends "res://tests/test_suite.gd"

const NAME := "_test_save"


func test_edits_and_meta_survive_reload() -> void:
	_delete()
	var w := await make_world(99, NAME)
	var pos := Vector3i(2, w.raycast(Vector3(2.5, 100, 2.5), Vector3.DOWN, 300).position.y + 1, 2)
	w.set_block(pos, Registry.block_index("core:gold_ore"))
	w.meta.time = 0.61
	w.save({"position": [1, 2, 3]})
	w.queue_free()
	await frames(2)
	var again := await make_world(0, NAME)  # seed comes from world.json
	check_eq(int(again.meta.seed), 99, "seed saved")
	check_near(float(again.meta.time), 0.61, 0.0001, "time of day saved")
	check_eq(again.meta.player.position, [1.0, 2.0, 3.0], "player state saved")  # JSON numbers are floats
	check_eq(again.get_block(pos), Registry.block_index("core:gold_ore"), "edited block reloaded from disk")
	again.queue_free()
	await frames(2)
	_delete()


func _delete() -> void:
	var dir := World.WORLDS_DIR.path_join(NAME)
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in ["chunks", ""]:
		var d := dir.path_join(sub)
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
	DirAccess.remove_absolute(dir.path_join("chunks"))
	DirAccess.remove_absolute(dir)
