extends RefCounted
## Base class for test files: `extends "res://tests/test_suite.gd"`, then write
## `func test_something():` methods (they may `await`). Run them all with
##   godot4 --headless -s res://tests/run_tests.gd [-- name_filter]

var tree: SceneTree
var _failures: PackedStringArray = []
var _cleanup: Array[Node] = []


func check(condition: bool, what: String) -> void:
	if not condition:
		_failures.append(what)


## Errors whose text contains one of these don't fail the test (see expect_error).
var expected_errors: PackedStringArray = []


## The test checks that something is refused with an error mentioning `part`.
func expect_error(part: String) -> void:
	expected_errors.append(part)


func check_eq(actual, expected, what: String) -> void:
	if actual != expected:
		_failures.append("%s: expected %s, got %s" % [what, expected, actual])


func check_near(actual: float, expected: float, tolerance: float, what: String) -> void:
	if absf(actual - expected) > tolerance:
		_failures.append("%s: expected %.3f ± %.3f, got %.3f" % [what, expected, tolerance, actual])


func frames(count: int) -> void:
	for i in count:
		await tree.process_frame


func wait_until(condition: Callable, timeout_s: float = 20.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not condition.call():
		await tree.process_frame
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return false
	return true


## Adds a node to the scene for this test; it is freed after the test.
func add(node: Node) -> Node:
	tree.root.add_child(node)
	_cleanup.append(node)
	return node


## A world on the native engine that saves nothing (unless `world_name` is
## given), loaded around `center`.
func make_world(world_seed: int = 4242, world_name: String = "", view: int = 64,
		center := Vector3(0.5, 20, 0.5)) -> World:
	var w := World.new()
	w.name = "TestWorld"
	add(w)
	w.build(world_name, view, world_seed, world_name != "")
	w.set_viewer(center)
	var area := AABB(center - Vector3(16, 40, 16), Vector3(32, 80, 32))
	check(await wait_until(func(): return w.is_area_meshed(area)), "world loaded around %s" % center)
	return w


func _finish() -> PackedStringArray:
	for node in _cleanup:
		if is_instance_valid(node):
			node.queue_free()
	_cleanup.clear()
	var f := _failures
	_failures = []
	return f
