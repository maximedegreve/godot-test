# Godot Test

Standalone reproduction project for the 3D hex map generator extracted
It contains the generator stages, development lab, rendering code, deterministic preview capture, and only the map-size data needed to run them.

## Requirements

- Godot 4.7.2 stable or newer
- macOS or Linux for the included shell scripts

Set `GODOT_BIN` if Godot is not available as `godot`, `godot4`, or an app in the
standard macOS Applications folders.

## Run the map lab

```bash
./scripts/run.sh
```

Useful launch arguments:

```bash
./scripts/run.sh -- --hex-seed=10 --hex-size=large --hex-style=fractured
```

The lab can regenerate maps, change size and landform style, inspect diagnostic
views, save/load generated worlds, and exercise the renderer without loading the
rest of the game.

## Capture deterministic bug evidence

```bash
./scripts/generate-hex-world-previews.sh \
  --size=large \
  --seeds=10,1,5,6,46 \
  --quick \
  --output=builds/map-previews
```

For a fast generator-only scan:

```bash
./scripts/generate-hex-world-previews.sh \
  --size=large \
  --range=0:99 \
  --counts-only
```

Generated files under `builds/` are intentionally ignored. Attach the relevant
PNG and JSON outputs to a bug report together with:

- Godot version and operating system
- seed, map size, and landform style
- exact reproduction steps
- expected and actual behavior

## Smoke test

```bash
./scripts/test.sh
```

The test imports the project, generates the same Small world twice, verifies its
deterministic signature, and instantiates the development scene.

Third-party water textures retain their original license in
`assets/world3d/water/LICENSE.md`.
