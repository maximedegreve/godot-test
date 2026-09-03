class_name HexWorldGenerator
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const ContinentMaskStage = preload("res://src/world3d/generator/continent_mask_stage.gd")
const ElevationStage = preload("res://src/world3d/generator/elevation_stage.gd")
const ClimateStage = preload("res://src/world3d/generator/climate_stage.gd")
const HydrologyStage = preload("res://src/world3d/generator/hydrology_stage.gd")
const EcologyStage = preload("res://src/world3d/generator/ecology_stage.gd")
const HydrologyMesher = preload("res://src/world3d/rendering/hex_hydrology_mesher.gd")


static func generate(input_settings: WorldGenerationSettings) -> HexWorldData:
	var settings := input_settings.validated_copy()
	var world := HexWorldData.new()
	world.seed = settings.seed
	world.profile_id = settings.map_size_profile
	world.width = settings.map_width
	world.height = settings.map_height
	world.hex_size = settings.hex_size
	for row in range(world.height):
		for column in range(world.width):
			var tile := HexTileData.new()
			tile.offset_coordinate = Vector2i(column, row)
			tile.coordinate = HexCoordinatesScript.offset_to_axial(tile.offset_coordinate)
			tile.position = HexCoordinatesScript.axial_to_world(
				tile.coordinate,
				settings.hex_size
			)
			world.add_tile(tile)
	ContinentMaskStage.apply(world, settings)
	ElevationStage.apply(world, settings)
	ClimateStage.prepare(world, settings)
	HydrologyStage.apply(world, settings)
	var river_visual_metrics := HydrologyMesher.river_visual_quality_metrics(
		world,
		settings
	)
	for key in river_visual_metrics:
		world.metadata[key] = river_visual_metrics[key]
	ClimateStage.finalize(world, settings)
	EcologyStage.apply(world, settings)
	world.metadata["seed"] = world.seed
	world.metadata["profile_id"] = String(world.profile_id)
	world.metadata["grid_size"] = Vector2i(world.width, world.height)
	world.metadata["tile_count"] = world.tiles.size()
	world.metadata["chunk_size"] = settings.chunk_size
	return world
