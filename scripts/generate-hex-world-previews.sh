#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="$("$ROOT/scripts/find-godot.sh")"

"$GODOT_BIN" --headless --editor --path "$ROOT" --quit-after 600 --quiet

HEADLESS_CAPTURE=0
for argument in "$@"; do
	if [[ "$argument" == "--topology-only" || "$argument" == "--counts-only" ]]; then
		HEADLESS_CAPTURE=1
		break
	fi
done

if [[ "$HEADLESS_CAPTURE" -eq 1 ]]; then
	"$GODOT_BIN" \
		--headless \
		--path "$ROOT" \
		--script res://tools/hex_world_preview_capture.gd \
		-- \
		"$@"
else
	"$GODOT_BIN" \
		--path "$ROOT" \
		--script res://tools/hex_world_preview_capture.gd \
		-- \
		"$@"
fi
