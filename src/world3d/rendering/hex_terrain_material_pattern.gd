class_name HexTerrainMaterialPattern
extends RefCounted

## Deterministic, original generator for the two small seamless terrain-floor
## material textures the Phase 5 shader samples in world space
## (`hex_terrain.gdshader`). Everything here is a closed-form hash/value-noise
## function evaluated on a wrapped lattice: there is no reference image, no
## third-party content, and no engine `RandomNumberGenerator` stream, so
## running `tools/generate_terrain_material_assets.gd` again reproduces the
## committed PNGs byte-for-byte. See
## `docs/art-provenance/biome-floor-materials.md` for the provenance record.
##
## Texture 1, `terrain_material_pattern.png` (RGB8):
##   R - "mineral" break-up (rock, sand, dry clay): higher-frequency, higher-
##       contrast grain.
##   G - "organic" break-up (moss, loam, leaf litter): lower-frequency, softly
##       warped blotches.
##   B - shared fine grain multiplier, sampled at a second UV scale for both
##       materials so one texture carries both the macro and grain bands the
##       shader previously synthesised with raw per-pixel noise.
##
## Texture 2, `terrain_material_relief.png` (RGB8):
##   R, G - tangent-space normal x/y (encoded 0..1) for a subtle relief bump,
##          derived from an independent height field with a wrapped Sobel
##          filter so the normal map stays exactly seamless too.
##   B - the same height field, reused in-shader as a roughness-variance input.
##
## `HexTerrainMesher.biome_material_response` supplies the per-biome blend
## weight between the mineral (R) and organic (G) pattern channels; this file
## only builds the two textures, it does not know about biomes.

const TEXTURE_SIZE := 256
const PATTERN_PATH := "res://assets/terrain/terrain_material_pattern.png"
const RELIEF_PATH := "res://assets/terrain/terrain_material_relief.png"

## Fixed, offline asset-generation salts. These never touch a gameplay random
## stream or a world seed; they exist purely so the mineral, organic, grain,
## warp, and height fields decorrelate from one another.
const MINERAL_SALT := 0x4d494e30
const ORGANIC_SALT := 0x4f524730
const GRAIN_SALT := 0x4752414e
const HEIGHT_SALT := 0x48454947
const WARP_X_SALT := 0x57415258
const WARP_Y_SALT := 0x57415259

const NORMAL_STRENGTH := 2.6

## Base lattice frequency and octave count per channel, tuned to read as
## restrained painterly variation rather than a repeating procedural grid at
## the texture's own resolution. Frequencies stay integers so every octave is
## exactly periodic across the [0, 1) texture domain (see `_value_noise`).
const MINERAL_BASE_FREQUENCY := 5
const MINERAL_OCTAVES := 3
const MINERAL_WARP_FREQUENCY := 3
const MINERAL_WARP_AMOUNT := 0.05

const ORGANIC_BASE_FREQUENCY := 4
const ORGANIC_OCTAVES := 4
const ORGANIC_WARP_FREQUENCY := 2
const ORGANIC_WARP_AMOUNT := 0.12

const GRAIN_BASE_FREQUENCY := 23
const GRAIN_OCTAVES := 2

const HEIGHT_BASE_FREQUENCY := 9
const HEIGHT_OCTAVES := 3
const HEIGHT_WARP_FREQUENCY := 4
const HEIGHT_WARP_AMOUNT := 0.05


## Builds the material-pattern image in memory. Deterministic and pure: the
## same call always returns the same pixels.
static func build_pattern_image() -> Image:
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGB8)
	for y in range(TEXTURE_SIZE):
		var v := (float(y) + 0.5) / float(TEXTURE_SIZE)
		for x in range(TEXTURE_SIZE):
			var u := (float(x) + 0.5) / float(TEXTURE_SIZE)
			var channels := pattern_channels(u, v)
			image.set_pixel(
				x,
				y,
				Color(channels["mineral"], channels["organic"], channels["grain"])
			)
	return image


## Builds the relief image in memory. Deterministic and pure, matching
## `build_pattern_image`.
static func build_relief_image() -> Image:
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGB8)
	for y in range(TEXTURE_SIZE):
		var v := (float(y) + 0.5) / float(TEXTURE_SIZE)
		for x in range(TEXTURE_SIZE):
			var u := (float(x) + 0.5) / float(TEXTURE_SIZE)
			var channels := relief_channels(u, v)
			image.set_pixel(
				x,
				y,
				Color(
					channels["normal_x"] * 0.5 + 0.5,
					channels["normal_y"] * 0.5 + 0.5,
					channels["height"]
				)
			)
	return image


## Mineral, organic, and fine-grain pattern values at a texture-space
## coordinate. Exposed (not just `build_pattern_image`) so tests can assert
## exact periodicity and reproducibility without decoding the committed PNG.
static func pattern_channels(u: float, v: float) -> Dictionary:
	var point := Vector2(u, v)
	var mineral_point := _warped_point(
		point,
		MINERAL_WARP_FREQUENCY,
		MINERAL_WARP_AMOUNT,
		MINERAL_SALT
	)
	var mineral := _fbm(mineral_point, MINERAL_BASE_FREQUENCY, MINERAL_OCTAVES, MINERAL_SALT)
	mineral = clampf(pow(mineral, 1.35), 0.0, 1.0)
	var organic_point := _warped_point(
		point,
		ORGANIC_WARP_FREQUENCY,
		ORGANIC_WARP_AMOUNT,
		ORGANIC_SALT
	)
	var organic := _fbm(organic_point, ORGANIC_BASE_FREQUENCY, ORGANIC_OCTAVES, ORGANIC_SALT)
	organic = smoothstep(0.08, 0.92, organic)
	var grain := _fbm(point, GRAIN_BASE_FREQUENCY, GRAIN_OCTAVES, GRAIN_SALT)
	return {"mineral": mineral, "organic": organic, "grain": grain}


## Normal x/y and height at a texture-space coordinate, derived from a wrapped
## finite-difference (Sobel-style) height sample so the normal map stays
## exactly seamless at the texture edge.
static func relief_channels(u: float, v: float) -> Dictionary:
	var texel := 1.0 / float(TEXTURE_SIZE)
	var height := _height(u, v)
	var height_right := _height(u + texel, v)
	var height_left := _height(u - texel, v)
	var height_up := _height(u, v + texel)
	var height_down := _height(u, v - texel)
	var dx := (height_right - height_left) * NORMAL_STRENGTH
	var dy := (height_up - height_down) * NORMAL_STRENGTH
	var normal := Vector3(-dx, -dy, 1.0).normalized()
	return {"normal_x": normal.x, "normal_y": normal.y, "height": height}


static func _height(u: float, v: float) -> float:
	var point := _warped_point(
		Vector2(u, v),
		HEIGHT_WARP_FREQUENCY,
		HEIGHT_WARP_AMOUNT,
		HEIGHT_SALT
	)
	return _fbm(point, HEIGHT_BASE_FREQUENCY, HEIGHT_OCTAVES, HEIGHT_SALT)


static func _warped_point(point: Vector2, frequency: int, amount: float, salt: int) -> Vector2:
	if amount <= 0.0:
		return point
	var warp_x := _value_noise(point, frequency, salt + WARP_X_SALT) - 0.5
	var warp_y := _value_noise(point, frequency, salt + WARP_Y_SALT) - 0.5
	return point + Vector2(warp_x, warp_y) * amount


## Multi-octave value noise. `base_frequency` is an integer cycle count across
## the [0, 1) texture domain and every octave doubles it while staying an
## integer, so the whole sum stays exactly periodic (see `_value_noise`).
static func _fbm(point: Vector2, base_frequency: int, octaves: int, salt: int) -> float:
	var total := 0.0
	var amplitude := 0.5
	var amplitude_sum := 0.0
	var frequency := base_frequency
	for octave in range(octaves):
		total += amplitude * _value_noise(point, frequency, salt + octave * 97)
		amplitude_sum += amplitude
		amplitude *= 0.5
		frequency *= 2
	if amplitude_sum <= 0.0:
		return 0.0
	return total / amplitude_sum


## Smooth (Hermite-interpolated) value noise on a lattice wrapped to
## `frequency` cells. Because the lattice wraps exactly at `frequency`,
## `_value_noise(point, frequency, salt)` is bit-identical to
## `_value_noise(point + Vector2(1, 1), frequency, salt)` for any integer
## frequency — the texture tiles seamlessly by construction, not by visual
## tuning.
static func _value_noise(point: Vector2, frequency: int, salt: int) -> float:
	var scaled := point * float(frequency)
	var cell_x := int(floor(scaled.x))
	var cell_y := int(floor(scaled.y))
	var frac_x := scaled.x - float(cell_x)
	var frac_y := scaled.y - float(cell_y)
	var smooth_x := frac_x * frac_x * (3.0 - 2.0 * frac_x)
	var smooth_y := frac_y * frac_y * (3.0 - 2.0 * frac_y)
	var x0 := posmod(cell_x, frequency)
	var x1 := posmod(cell_x + 1, frequency)
	var y0 := posmod(cell_y, frequency)
	var y1 := posmod(cell_y + 1, frequency)
	var corner_00 := _hash01(x0, y0, salt)
	var corner_10 := _hash01(x1, y0, salt)
	var corner_01 := _hash01(x0, y1, salt)
	var corner_11 := _hash01(x1, y1, salt)
	var top := lerpf(corner_00, corner_10, smooth_x)
	var bottom := lerpf(corner_01, corner_11, smooth_x)
	return lerpf(top, bottom, smooth_y)


## Deterministic integer hash, mixed and masked into [0, 1). Pure arithmetic —
## no `RandomNumberGenerator`, no OS entropy, no shared gameplay stream.
static func _hash01(x: int, y: int, salt: int) -> float:
	var value := x * 374761393 + y * 668265263 + salt * 2246822519
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0x7fffffff) / float(0x7fffffff)
