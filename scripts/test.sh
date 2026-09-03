#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="$("$ROOT/scripts/find-godot.sh")"

"$GODOT_BIN" --headless --editor --path "$ROOT" --quit-after 600 --quiet
exec "$GODOT_BIN" --headless --path "$ROOT" --script res://tests/smoke_test.gd
