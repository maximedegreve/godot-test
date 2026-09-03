class_name WorldGenerationSettings
extends Resource

const Content = preload("res://src/data/game_content.gd")
const LANDFORM_STYLE_IDS := [
	"varied",
	"continents_and_islands",
	"pangea_and_islands",
	"archipelago",
	"fractured",
]

@export_category("World")
@export var seed := 0
@export_enum("Small:small", "Medium:medium", "Large:large", "Ultra:ultra")
var map_size_profile := "large"
@export_enum(
	"Varied:varied",
	"Continents and Islands:continents_and_islands",
	"Pangea and Islands:pangea_and_islands",
	"Archipelago:archipelago",
	"Fractured:fractured"
)
var landform_style := "varied"
@export var use_custom_profile := false:
	set(value):
		use_custom_profile = value
		notify_property_list_changed()
@export_group("Custom profile", "map_")
@export_range(8, 256, 1) var map_width := 100
@export_range(8, 256, 1) var map_height := 64
@export_group("Custom profile")
@export_range(1, 16, 1) var continent_count := 5
@export_group("")
@export_range(0.35, 0.90, 0.01) var ocean_percentage := 0.58
@export_range(0.0, 1.0, 0.01) var continent_size_variation := 0.32
@export_range(0.0, 1.0, 0.01) var continent_separation := 0.86
@export_range(0.0, 1.0, 0.01) var coast_complexity := 0.42
@export_range(0.0, 1.0, 0.01) var island_frequency := 0.12
@export_range(0.5, 2.0, 0.01) var world_aspect_ratio := 16.0 / 9.0

@export_category("Elevation")
@export_range(0.0, 1.0, 0.01) var terrain_roughness := 0.38
@export_range(0.0, 1.0, 0.01) var mountain_frequency := 0.44
@export_range(0.1, 1.0, 0.01) var mountain_length := 0.58
@export_range(0.25, 4.0, 0.05) var elevation_step_height := 1.4
@export_range(1, 3, 1) var cliff_level_threshold := 2

@export_category("Rendering")
@export_range(0.25, 8.0, 0.05) var hex_size := 1.0
@export_range(4, 64, 1) var chunk_size := 16
@export_range(-2.0, 2.0, 0.05) var ocean_height := 0.45
@export_range(0.0, 0.25, 0.005) var corner_distortion := 0.055

@export_category("Climate")
@export_range(0.0, 1.0, 0.01) var temperature_variation := 0.20
@export_range(0.0, 1.0, 0.01) var moisture_variation := 0.25
@export_range(0.25, 0.75, 0.01) var equator_position := 0.50
@export_range(0.0, 1.0, 0.01) var prevailing_wind_strength := 0.72
@export_range(0.0, 1.0, 0.01) var rain_shadow_strength := 0.68
@export_range(0.0, 1.0, 0.01) var biome_boundary_softness := 0.28

@export_category("Hydrology")
@export_range(0, 128, 1) var river_count := 18
@export_range(0, 64, 1) var lake_count := 8
@export_range(1, 32, 1) var minimum_river_length := 5
@export_range(0.0, 1.0, 0.01) var river_meander_strength := 0.24
@export_range(0, 8, 1) var freshwater_moisture_reach := 3

@export_category("Ecology")
@export_range(0.0, 2.0, 0.01) var forest_density := 0.65
@export_range(0.0, 1.0, 0.01) var vegetation_variation := 0.35
@export_range(0.0, 2.0, 0.01) var seaweed_density := 0.90
@export_range(0.0, 2.0, 0.01) var resource_density := 0.45
@export_range(1, 8, 1) var resource_minimum_spacing := 2
@export_range(0, 3, 1) var settlement_reserve_radius := 1


func apply_map_size_profile(profile_name: String = "") -> void:
	var resolved := profile_name.to_lower()
	if resolved.is_empty():
		resolved = String(map_size_profile)
	if not Content.is_valid_map_size_profile(resolved):
		push_warning("Unknown 3D world map profile '%s'; using Large." % resolved)
		resolved = Content.DEFAULT_MAP_SIZE_PROFILE
	var profile := Content.map_size_profile(resolved)
	map_size_profile = resolved
	use_custom_profile = false
	var grid_size: Vector2i = profile["hex_grid_size"]
	map_width = grid_size.x
	map_height = grid_size.y
	continent_count = int(profile["hex_continent_count"])
	world_aspect_ratio = _grid_world_aspect_ratio(grid_size)


func validated_copy() -> WorldGenerationSettings:
	var result := duplicate(true) as WorldGenerationSettings
	if result == null:
		result = WorldGenerationSettings.new()
	if result.use_custom_profile:
		if not Content.is_valid_map_size_profile(result.map_size_profile):
			result.map_size_profile = Content.DEFAULT_MAP_SIZE_PROFILE
		result.map_width = clampi(result.map_width, 8, 256)
		result.map_height = clampi(result.map_height, 8, 256)
		result.continent_count = clampi(result.continent_count, 1, 16)
	else:
		result.apply_map_size_profile(result.map_size_profile)
	if not result.landform_style in LANDFORM_STYLE_IDS:
		result.landform_style = "varied"
	result.ocean_percentage = clampf(result.ocean_percentage, 0.35, 0.90)
	result.continent_size_variation = clampf(result.continent_size_variation, 0.0, 1.0)
	result.continent_separation = clampf(result.continent_separation, 0.0, 1.0)
	result.temperature_variation = clampf(result.temperature_variation, 0.0, 1.0)
	result.moisture_variation = clampf(result.moisture_variation, 0.0, 1.0)
	result.equator_position = clampf(result.equator_position, 0.25, 0.75)
	result.prevailing_wind_strength = clampf(result.prevailing_wind_strength, 0.0, 1.0)
	result.rain_shadow_strength = clampf(result.rain_shadow_strength, 0.0, 1.0)
	result.biome_boundary_softness = clampf(result.biome_boundary_softness, 0.0, 1.0)
	result.river_count = clampi(result.river_count, 0, 128)
	result.lake_count = clampi(result.lake_count, 0, 64)
	result.minimum_river_length = clampi(result.minimum_river_length, 1, 32)
	result.river_meander_strength = clampf(result.river_meander_strength, 0.0, 1.0)
	result.freshwater_moisture_reach = clampi(result.freshwater_moisture_reach, 0, 8)
	result.forest_density = clampf(result.forest_density, 0.0, 2.0)
	result.vegetation_variation = clampf(result.vegetation_variation, 0.0, 1.0)
	result.seaweed_density = clampf(result.seaweed_density, 0.0, 2.0)
	result.resource_density = clampf(result.resource_density, 0.0, 2.0)
	result.resource_minimum_spacing = clampi(result.resource_minimum_spacing, 1, 8)
	result.settlement_reserve_radius = clampi(result.settlement_reserve_radius, 0, 3)
	result.chunk_size = maxi(4, result.chunk_size)
	result.hex_size = maxf(0.25, result.hex_size)
	return result


static func is_valid_landform_style(style: String) -> bool:
	return style in LANDFORM_STYLE_IDS


static func _grid_world_aspect_ratio(grid_size: Vector2i) -> float:
	var world_width := sqrt(3.0) * (float(grid_size.x) + 0.5)
	var world_height := 1.5 * float(grid_size.y) + 0.5
	return world_width / world_height


func _validate_property(property: Dictionary) -> void:
	if (
		property.name in [&"map_width", &"map_height", &"continent_count"]
		and not use_custom_profile
	):
		property.usage = int(property.usage) | PROPERTY_USAGE_READ_ONLY
