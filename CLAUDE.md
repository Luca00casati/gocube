# GoCube: notes for Claude

## Tests
    godot4 --headless -s res://tests/run_tests.gd [-- filter]

Everything is in GDScript, including `test_mp_processes` (host and client as two
real Godot processes, about 20 s).

## Multiplayer: check the client path before calling a feature done
Single player is the host path; most multiplayer bugs come from the client path
never being run. A feature that changes blocks, items, the player or anything the
host owns (drops, containers, creatures, beds, time) is only done when:

1. A client doing it works: add or extend a step in `tests/test_multiplayer.gd`
   (host and client in one process). Drive the client's player like a person would
   (`tests/mp_play.gd`: aim, then `_place()` / `_break_target()`), not by calling
   Session methods, and check that both worlds match afterwards.
2. The host refusing it works: out of reach, rate-limited, someone standing there,
   or a chunk the host hasn't loaded. Nothing is lost (items come back) and nothing
   is left half done (both halves of a door or bed, or neither).
3. Anything only the host knows (spawn, beds, first night, mode) reaches the
   client, or the client asks the host for it.
4. `test_mp_processes` still passes (two real processes over the network).

In a test, wait for the expected result before comparing worlds: the two worlds
also match before the host has answered.
