class_name HexTerrainMaterial
extends RefCounted

## Phase 5 terrain material factory.
##
## One `ShaderMaterial` is shared by every terrain chunk, so adding texturing
## does not add a material per chunk or per tile. Diagnostic views set
## `diagnostic_blend` to 1 and render the authored flat palette, which keeps
## every debug view exactly as validated while the default biome view gains
## biome blending, coast treatment, cliff materials, and distance-aware detail.
##
## The two compact original material textures
## (`docs/art-provenance/biome-floor-materials.md`) are bound once here, never
## per chunk. `configure()` additionally derives a render-only
## `pattern_offset`/`pattern_rotation` from the world seed via
## `seed_pattern_transform` so repeated worlds do not share an obvious texture
## phase; this is a pure hash of the seed, not an RNG-stream draw, so it can
## never affect or be affected by world generation.
##
## `bind_biome_field()` is the one function with a *world-scoped* rather than
## configuration-scoped lifecycle: it builds and binds the per-world
## continuous biome-floor blend field (`HexTerrainBiomeField`) that the
## `biome` view samples in the fragment shader instead of interpolating the
## mesh's own per-vertex `COLOR`. Call it only when `world_data` itself
## changes (`HexWorldPrototype._install_world()`/`load_world()`), never from
## `configure()`, which runs on every camera-height/view/palette tick.

const SHADER = preload("res://src/world3d/rendering/hex_terrain.gdshader")
const MATERIAL_PATTERN_TEXTURE := preload("res://assets/terrain/terrain_material_pattern.png")
const MATERIAL_RELIEF_TEXTURE := preload("res://assets/terrain/terrain_material_relief.png")
const SEABED_ALBEDO_TEXTURE := preload("res://assets/world3d/seabed/Ground_B.png")
const SEABED_NORMAL_TEXTURE := preload("res://assets/world3d/seabed/Ground_N.png")
const SEABED_ROUGHNESS_TEXTURE := preload("res://assets/world3d/seabed/Ground_R.png")
const BiomeField = preload("res://src/world3d/rendering/hex_terrain_biome_field.gd")

## The only view that renders the textured surface. Everything else is a
## categorical or continuous diagnostic and must stay flat and readable.
const TEXTURED_VIEWS := ["biome"]

## Dedicated salts for the seed-derived pattern transform. Distinct from every
## Phase 1-4 generator salt (e.g. `ClimateStage`'s) and from the mesher's own
## `CORNER_SALT`/`PROFILE_SALT`, and never read by generation code.
const PATTERN_OFFSET_SALT := 0x50415453
const PATTERN_ROTATION_SALT := 0x50415452
## Offset magnitude, in texture UV units. Any magnitude produces a valid
## phase shift because sampling wraps (`repeat_enable`); kept small purely so
## the derived value stays easy to reason about and log.
const PATTERN_OFFSET_RANGE := 4.0


static func create() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("diagnostic_blend", 0.0)
	material.set_shader_parameter("high_contrast", 0.0)
	material.set_shader_parameter("detail_strength", 1.0)
	material.set_shader_parameter("camera_height", 70.0)
	# Explicit, non-silent binding: a missing/failed texture load surfaces as
	# a null shader parameter that the Phase 5 material-contract test catches,
	# rather than falling back to an implicit engine default silently.
	material.set_shader_parameter("material_pattern_texture", MATERIAL_PATTERN_TEXTURE)
	material.set_shader_parameter("material_relief_texture", MATERIAL_RELIEF_TEXTURE)
	material.set_shader_parameter("seabed_albedo_texture", SEABED_ALBEDO_TEXTURE)
	material.set_shader_parameter("seabed_normal_texture", SEABED_NORMAL_TEXTURE)
	material.set_shader_parameter("seabed_roughness_texture", SEABED_ROUGHNESS_TEXTURE)
	material.set_shader_parameter("pattern_offset", Vector2.ZERO)
	material.set_shader_parameter("pattern_rotation", 0.0)
	# Harmless placeholder until `bind_biome_field()` binds the real per-world
	# field (always done once in `HexWorldPrototype._install_world()` before
	# any chunk becomes visible): a 1x1 neutral-grey, fully opaque texture, so
	# the shader never samples a null sampler2D even in an unusual code path
	# that renders before the first world install.
	material.set_shader_parameter("biome_field_texture", _placeholder_biome_field_texture())
	material.set_shader_parameter("biome_field_origin", Vector2.ZERO)
	material.set_shader_parameter("biome_field_size", Vector2.ONE)
	material.set_shader_parameter("hex_size", 1.0)
	return material


static func _placeholder_biome_field_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(0.5, 0.5, 0.5, 0.5))
	return ImageTexture.create_from_image(image)


## Builds this world's continuous biome-floor blend field
## (`HexTerrainBiomeField`) and binds it to the shared terrain material. Call
## exactly once per world install/load
## (`HexWorldPrototype._install_world()`/`load_world()`) — never per frame
## and never per chunk: the field is genuinely global, one texture per
## world, independent of chunk count, so rebuilding it on every
## `_update_terrain_material()` tick (view/camera changes) would violate the
## "no per-frame CPU work" budget for no visual benefit, since the field
## itself never changes unless `world_data` does.
##
## Returns the `HexTerrainBiomeField.build()` result dictionary (`ok`,
## `error`, `width`, `height`, `byte_count`, ...) unchanged, so the caller can
## fail explicitly and can surface the field's dimensions/memory impact (see
## `HexWorldPrototype.runtime_report()`).
static func bind_biome_field(material: ShaderMaterial, world: HexWorldData) -> Dictionary:
	var result := BiomeField.build(world)
	if material == null:
		return result
	if not bool(result.get("ok", false)):
		return result
	var texture := ImageTexture.create_from_image(result["image"])
	material.set_shader_parameter("biome_field_texture", texture)
	material.set_shader_parameter(
		"biome_field_origin",
		Vector2(float(result["origin_q"]), 0.0)
	)
	material.set_shader_parameter(
		"biome_field_size",
		Vector2(float(result["width"]), float(result["height"]))
	)
	material.set_shader_parameter("hex_size", world.hex_size if world != null else 1.0)
	return result


static func is_textured_view(view_id: String) -> bool:
	return view_id in TEXTURED_VIEWS


## Deterministic, render-only offset/rotation for the packed material
## textures, derived purely from the world seed. Same seed always returns the
## same transform; different seeds are expected (not guaranteed) to differ.
## This never consumes or advances any gameplay `RandomNumberGenerator`
## stream, so it carries no generation signature.
static func seed_pattern_transform(world_seed: int) -> Dictionary:
	var offset := Vector2(
		_hash_unit(world_seed, PATTERN_OFFSET_SALT, 0, 0),
		_hash_unit(world_seed, PATTERN_OFFSET_SALT, 1, 0)
	) * PATTERN_OFFSET_RANGE
	var rotation := _hash_unit(world_seed, PATTERN_ROTATION_SALT, 0, 0) * TAU
	return {"offset": offset, "rotation": rotation}


static func configure(
	material: ShaderMaterial,
	view_id: String,
	camera_height: float,
	high_contrast: bool,
	detail_strength := 1.0,
	world_seed := 0
) -> void:
	if material == null:
		return
	material.set_shader_parameter(
		"diagnostic_blend",
		0.0 if is_textured_view(view_id) else 1.0
	)
	material.set_shader_parameter("high_contrast", 1.0 if high_contrast else 0.0)
	material.set_shader_parameter("camera_height", camera_height)
	material.set_shader_parameter("detail_strength", detail_strength)
	var transform := seed_pattern_transform(world_seed)
	material.set_shader_parameter("pattern_offset", transform["offset"])
	material.set_shader_parameter("pattern_rotation", transform["rotation"])


## Local copy of the generator's hash idiom (see `ClimateStage._hash_unit`).
## Deliberately duplicated rather than imported: rendering must never take a
## dependency on generator code, and this is a three-line pure function.
static func _hash_unit(seed_value: int, salt: int, x: int, y: int) -> float:
	var value := int(hash("%d:%d:%d:%d" % [seed_value, salt, x, y]))
	return float(posmod(value, 1000003)) / 1000002.0
