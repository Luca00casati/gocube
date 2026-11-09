#!/usr/bin/env bash
# Multiplayer smoke test: starts a headless host, then a headless client.
# Usage: tests/mp_smoke.sh [godot-binary]   (run from the project root)
# The host plays a world of its own (_mp_smoke_<pid>), removed afterwards even
# when the test is interrupted, so runs never touch each other's or real worlds.
set -u
GODOT="${1:-godot4}"
LOG="$(mktemp)"
WORLD="_mp_smoke_$$"
WORLD_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/GoCube/worlds/$WORLD"
HOST=""
cleanup() {
	[ -n "$HOST" ] && kill "$HOST" 2>/dev/null && wait "$HOST" 2>/dev/null
	rm -rf "$WORLD_DIR" "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
timeout 120 "$GODOT" --headless res://tests/mp_smoke.tscn -- host "$WORLD" > "$LOG" 2>&1 &
HOST=$!
for _ in $(seq 1 60); do grep -q "HOST ready" "$LOG" && break; sleep 1; done
timeout 90 "$GODOT" --headless res://tests/mp_smoke.tscn -- client 2>&1 | grep -E "^(PASS|FAIL)"
STATUS=${PIPESTATUS[0]}
wait "$HOST" || true
HOST=""
echo "multiplayer smoke test: $([ "$STATUS" -eq 0 ] && echo passed || echo FAILED)"
exit "$STATUS"
