#!/usr/bin/env bash

set -euo pipefail

readonly MIN_GODOT_VERSION="4.7.2"
readonly MIN_GODOT_SCORE=$((4 * 1000000 + 7 * 1000 + 2))

best_bin=""
best_score=-1

consider_godot() {
	local candidate="$1"
	local version
	local score

	if [[ ! -x "$candidate" ]]; then
		return
	fi

	version="$("$candidate" --version 2>/dev/null)" || return 0
	if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.stable(\.|$) ]]; then
		return
	fi

	score=$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]}))
	if ((score >= MIN_GODOT_SCORE && score > best_score)); then
		best_bin="$candidate"
		best_score="$score"
	fi
}

if [[ -n "${GODOT_BIN:-}" ]]; then
	if resolved_bin="$(command -v -- "$GODOT_BIN" 2>/dev/null)"; then
		consider_godot "$resolved_bin"
	else
		consider_godot "$GODOT_BIN"
	fi
else
	for command_name in godot godot4; do
		if resolved_bin="$(command -v "$command_name" 2>/dev/null)"; then
			consider_godot "$resolved_bin"
		fi
	done

	for app_bundle in "$HOME"/Applications/Godot*.app /Applications/Godot*.app; do
		consider_godot "$app_bundle/Contents/MacOS/Godot"
	done
fi

if [[ -z "$best_bin" ]]; then
	printf 'Godot %s stable or newer was not found. Set GODOT_BIN to a compatible executable or install the current stable release.\n' "$MIN_GODOT_VERSION" >&2
	exit 1
fi

printf '%s\n' "$best_bin"
