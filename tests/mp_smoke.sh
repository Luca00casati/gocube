#!/usr/bin/env bash
# Multiplayer smoke test: starts a headless host, then a headless client.
# Usage: tests/mp_smoke.sh [godot-binary]   (run from the project root)
set -u
GODOT="${1:-godot4}"
LOG="$(mktemp)"
rm -rf "$HOME/.local/share/godot/app_userdata/GoCube/worlds/_mp_smoke"
timeout 120 "$GODOT" --headless res://tests/mp_smoke.tscn -- host > "$LOG" 2>&1 &
HOST=$!
for _ in $(seq 1 60); do grep -q "HOST ready" "$LOG" && break; sleep 1; done
timeout 90 "$GODOT" --headless res://tests/mp_smoke.tscn -- client 2>&1 | grep -E "^(PASS|FAIL)"
STATUS=${PIPESTATUS[0]}
wait "$HOST" || true
rm -rf "$HOME/.local/share/godot/app_userdata/GoCube/worlds/_mp_smoke" "$LOG"
echo "multiplayer smoke test: $([ "$STATUS" -eq 0 ] && echo passed || echo FAILED)"
exit "$STATUS"
