extends "res://tests/test_suite.gd"
## Host-side checks of what clients send (Session), without a network.

const Session := preload("res://src/net/session.gd")


func test_player_names_are_cleaned() -> void:
	check_eq(Session.clean_name("  Ann  "), "Ann", "trimmed")
	check_eq(Session.clean_name("A\nB\tC" + String.chr(1) + "D"), "ABCD", "control characters removed")
	check_eq(Session.clean_name("x" + String.chr(0x202E) + "y"), "xy", "no text direction tricks")
	check_eq(Session.clean_name("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnop", "at most 16 characters")
	check_eq(Session.clean_name("\n\n"), "", "nothing left: the host picks a name")


func test_requests_are_rate_limited() -> void:
	var s: Node = Session.new()
	s._peers[7] = {}
	var allowed := 0
	for i in 200:
		if s._allow(7, "edit"):
			allowed += 1
	check_eq(allowed, int(Session.RATES.edit[1]), "a burst, then nothing")
	check(not s._allow(99, "edit"), "unknown peers get nothing")
	s._peers[7].rates.edit[1] -= 1.0  # a second later
	check(s._allow(7, "edit"), "allowed again after a while")
	s.free()


func test_world_migrations() -> void:
	var m := {"format": 1, "seed": 5, "player": {"position": [1, 2, 3]}}
	World.migrate(m)
	check_eq(int(m.format), World.FORMAT_VERSION, "brought up to the current format")
	check(not m.has("player"), "format 1: the old position is dropped (new terrain)")
	check_eq(int(m.seed), 5, "the rest is kept")
