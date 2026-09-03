#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="$("$ROOT/scripts/find-godot.sh")"

exec "$GODOT_BIN" --path "$ROOT" "$@"
