class_name HexClimateStage
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")

const TEMPERATURE_SALT := 0x33435450
const MOISTURE_SALT := 0x33434d53
const HEMISPHERE_SALT := 0x3343484d
const BIOME_SALT := 0x3343424d
const BIOME_IDS := [
	&"water",
	&"coast",
	&"snow",
	&"tundra",
	&"bare_rock",
	&"desert",
	&"grassland",
	&"shrubland",
	&"taiga",
	&"temperate_forest",
	&"tropical_forest",
]


static func apply(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	prepare(world, settings)
	finalize(world, settings)


static func prepare(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	var ocean_coordinates := _ocean_coordinates(world)
	var equator := effective_equator(world.seed, settings)
	_compute_temperature(world, settings)
	_propagate_ocean_moisture(world, settings, ocean_coordinates, equator)
	for tile in world.tiles:
		tile.ocean_moisture = tile.moisture
	world.metadata["ocean_tile_count"] = ocean_coordinates.size()
	world.metadata["inland_water_tile_count"] = (
		world.tiles.size() - world.land_tile_count() - ocean_coordinates.size()
	)
	world.metadata["effective_equator_position"] = equator
	world.metadata["climate_prepared"] = true


static func finalize(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	var ocean_coordinates := _ocean_coordinates(world)
	var equator := effective_equator(world.seed, settings)
	for tile in world.tiles:
		tile.moisture = tile.ocean_moisture
	if world.metadata.has("hydrology_signature"):
		_apply_freshwater_moisture(world, settings, ocean_coordinates)
	_classify_biomes(world, settings, ocean_coordinates)
	var biome_histogram := {}
	var temperature_total := 0.0
	var moisture_total := 0.0
	for tile in world.tiles:
		biome_histogram[tile.biome] = int(biome_histogram.get(tile.biome, 0)) + 1
		if not tile.is_water:
			temperature_total += tile.temperature
			moisture_total += tile.moisture
	var land_count := maxi(world.land_tile_count(), 1)
	world.metadata["biome_histogram"] = biome_histogram
	world.metadata["mean_land_temperature"] = temperature_total / float(land_count)
	world.metadata["mean_land_moisture"] = moisture_total / float(land_count)
	world.metadata["climate_diagnostics"] = _climate_diagnostics(
		world,
		settings,
		ocean_coordinates,
		equator
	)
	world.metadata["climate_signature"] = world.climate_signature()


static func _apply_freshwater_moisture(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_coordinates: Dictionary
) -> void:
	var reach := settings.freshwater_moisture_reach
	if reach <= 0:
		world.metadata["freshwater_influenced_tile_count"] = 0
		return
	var distance_by_coordinate: Dictionary = {}
	var queue: Array[Vector2i] = []
	for tile in world.tiles:
		if ocean_coordinates.has(tile.coordinate):
			continue
		var freshwater := tile.lake_id >= 0
		if not freshwater:
			for connected in tile.river_connections:
				if connected != 0:
					freshwater = true
					break
		if freshwater:
			distance_by_coordinate[tile.coordinate] = 0
			queue.append(tile.coordinate)
	var head := 0
	while head < queue.size():
		var coordinate := queue[head]
		head += 1
		var distance := int(distance_by_coordinate[coordinate])
		if distance >= reach:
			continue
		for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
			var neighbor := world.tile_at(neighbor_coordinate)
			if (
				neighbor == null
				or neighbor.is_ocean
				or distance_by_coordinate.has(neighbor_coordinate)
			):
				continue
			distance_by_coordinate[neighbor_coordinate] = distance + 1
			queue.append(neighbor_coordinate)
	var influenced := 0
	for coordinate in distance_by_coordinate:
		var tile := world.tile_at(coordinate)
		if tile == null or tile.is_ocean:
			continue
		var distance := int(distance_by_coordinate[coordinate])
		var freshwater_addition := (
			0.18 * (1.0 - float(distance) / float(reach + 1))
		)
		if freshwater_addition > 0.0:
			tile.moisture = clampf(tile.moisture + freshwater_addition, 0.0, 1.0)
			influenced += 1
	world.metadata["freshwater_influenced_tile_count"] = influenced


static func effective_equator(seed: int, settings: WorldGenerationSettings) -> float:
	var hemisphere_shift := (
		_hash_unit(seed, HEMISPHERE_SALT, 0, 0) - 0.5
	) * 0.07
	return clampf(settings.equator_position + hemisphere_shift, 0.25, 0.75)


static func prevailing_wind_direction(
	normalized_latitude: float,
	equator_position := 0.5
) -> int:
	var latitude_from_equator := (
		(equator_position - normalized_latitude) / maxf(equator_position, 0.01)
		if normalized_latitude < equator_position
		else (normalized_latitude - equator_position)
			/ maxf(1.0 - equator_position, 0.01)
	)
	if latitude_from_equator < 0.34:
		return 3
	if latitude_from_equator < 0.72:
		return 0
	return 3


static func _compute_temperature(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> void:
	var equator := effective_equator(world.seed, settings)
	var north_span := maxf(equator, 0.01)
	var south_span := maxf(1.0 - equator, 0.01)
	for tile in world.tiles:
		var row_fraction := (
			(float(tile.offset_coordinate.y) + 0.5) / float(world.height)
		)
		var pole_distance := (
			(equator - row_fraction) / north_span
			if row_fraction < equator
			else (row_fraction - equator) / south_span
		)
		var latitude_temperature := 1.0 - pow(clampf(pole_distance, 0.0, 1.0), 1.16)
		var variation := (
			_hash_unit(
				world.seed,
				TEMPERATURE_SALT,
				tile.coordinate.x,
				tile.coordinate.y
			) - 0.5
		) * settings.temperature_variation * 0.34
		var altitude_cooling := (
			float(maxi(tile.elevation_level - 1, 0)) * 0.105
			+ maxf(tile.elevation - settings.elevation_step_height, 0.0)
				* 0.018
		)
		tile.temperature = clampf(
			latitude_temperature + variation - altitude_cooling,
			0.0,
			1.0
		)


static func _propagate_ocean_moisture(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_coordinates: Dictionary,
	equator: float
) -> void:
	var queue: Array[HexTileData] = []
	var head := 0
	for tile in world.tiles:
		if ocean_coordinates.has(tile.coordinate):
			tile.moisture = 1.0
			queue.append(tile)
		else:
			tile.moisture = 0.0
	while head < queue.size():
		var source := queue[head]
		head += 1
		var latitude := (
			(float(source.offset_coordinate.y) + 0.5) / float(world.height)
		)
		var wind_direction := prevailing_wind_direction(latitude, equator)
		for direction in range(6):
			var neighbor := world.tile_at(
				HexCoordinatesScript.neighbor(source.coordinate, direction)
			)
			if neighbor == null or neighbor.is_water:
				continue
			var alignment := _direction_alignment(direction, wind_direction)
			var retention := (
				0.82
				+ settings.prevailing_wind_strength * alignment * 0.105
			)
			var elevation_rise := maxi(
				neighbor.elevation_level - source.elevation_level,
				0
			)
			retention -= (
				float(elevation_rise)
				* settings.rain_shadow_strength
				* 0.105
			)
			var candidate := source.moisture * clampf(retention, 0.48, 0.94)
			if candidate > neighbor.moisture + 0.001:
				neighbor.moisture = candidate
				queue.append(neighbor)
	for tile in world.tiles:
		if tile.is_water:
			continue
		var variation := (
			_hash_unit(
				world.seed,
				MOISTURE_SALT,
				tile.coordinate.x,
				tile.coordinate.y
			) - 0.5
		) * settings.moisture_variation * 0.42
		tile.moisture = clampf(tile.moisture + variation, 0.0, 1.0)
		var latitude := (
			(float(tile.offset_coordinate.y) + 0.5) / float(world.height)
		)
		var wind_direction := prevailing_wind_direction(latitude, equator)
		var upwind := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, wind_direction + 3)
		)
		if (
			upwind != null
			and not upwind.is_water
			and upwind.elevation_level >= 3
			and upwind.elevation_level > tile.elevation_level
		):
			var barrier_levels := upwind.elevation_level - tile.elevation_level
			tile.moisture *= clampf(
				1.0
					- float(barrier_levels)
					* settings.rain_shadow_strength
					* 0.24,
				0.36,
				1.0
			)


static func _classify_biomes(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_coordinates: Dictionary
) -> void:
	for tile in world.tiles:
		if tile.is_water:
			tile.biome = &"water"
			continue
		var softness := (
			_hash_unit(
				world.seed,
				BIOME_SALT,
				tile.coordinate.x,
				tile.coordinate.y
			) - 0.5
		) * settings.biome_boundary_softness * 0.18
		var temperature := clampf(tile.temperature + softness, 0.0, 1.0)
		var moisture := clampf(tile.moisture - softness * 0.7, 0.0, 1.0)
		var coastal := false
		for neighbor in world.valid_neighbors(tile.coordinate):
			if ocean_coordinates.has(neighbor.coordinate):
				coastal = true
				break
		if tile.elevation_level >= 4:
			tile.biome = &"snow" if temperature < 0.34 else &"bare_rock"
		elif temperature < 0.16:
			tile.biome = &"snow"
		elif temperature < 0.30:
			tile.biome = &"tundra" if moisture < 0.58 else &"taiga"
		elif coastal and tile.elevation_level <= 1 and moisture >= 0.34:
			tile.biome = &"coast"
		elif temperature > 0.72 and moisture < 0.29:
			tile.biome = &"desert"
		elif temperature > 0.69 and moisture > 0.67:
			tile.biome = &"tropical_forest"
		elif temperature < 0.48 and moisture > 0.61:
			tile.biome = &"taiga"
		elif moisture > 0.64:
			tile.biome = &"temperate_forest"
		elif moisture < 0.31:
			tile.biome = &"shrubland"
		else:
			tile.biome = &"grassland"


static func _direction_alignment(direction: int, wind_direction: int) -> float:
	var difference := mini(
		posmod(direction - wind_direction, 6),
		posmod(wind_direction - direction, 6)
	)
	return [1.0, 0.48, -0.38, -1.0][difference]


static func _climate_diagnostics(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_coordinates: Dictionary,
	equator: float
) -> Dictionary:
	var coastal_total := 0.0
	var coastal_count := 0
	var inland_total := 0.0
	var inland_count := 0
	var windward_total := 0.0
	var windward_count := 0
	var leeward_total := 0.0
	var leeward_count := 0
	for tile in world.tiles:
		if tile.is_water:
			continue
		var coastal := false
		var deep_inland := true
		for coordinate in HexCoordinatesScript.range_coordinates(tile.coordinate, 3):
			var candidate := world.tile_at(coordinate)
			if candidate != null and ocean_coordinates.has(candidate.coordinate):
				deep_inland = false
				if HexCoordinatesScript.distance(tile.coordinate, coordinate) == 1:
					coastal = true
		if coastal:
			coastal_total += tile.moisture
			coastal_count += 1
		if deep_inland:
			inland_total += tile.moisture
			inland_count += 1
		var latitude := (
			(float(tile.offset_coordinate.y) + 0.5) / float(world.height)
		)
		var wind_direction := prevailing_wind_direction(latitude, equator)
		var downwind := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, wind_direction)
		)
		var upwind := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, wind_direction + 3)
		)
		if (
			tile.elevation_level <= 2
			and downwind != null
			and downwind.elevation_level >= 3
		):
			windward_total += tile.moisture
			windward_count += 1
		if (
			tile.elevation_level <= 2
			and upwind != null
			and upwind.elevation_level >= 3
		):
			leeward_total += tile.moisture
			leeward_count += 1
	return {
		"coastal_mean_moisture": (
			coastal_total / float(coastal_count) if coastal_count > 0 else 0.0
		),
		"deep_inland_mean_moisture": (
			inland_total / float(inland_count) if inland_count > 0 else 0.0
		),
		"windward_mean_moisture": (
			windward_total / float(windward_count) if windward_count > 0 else 0.0
		),
		"leeward_mean_moisture": (
			leeward_total / float(leeward_count) if leeward_count > 0 else 0.0
		),
		"coastal_tile_count": coastal_count,
		"deep_inland_tile_count": inland_count,
		"windward_tile_count": windward_count,
		"leeward_tile_count": leeward_count,
	}


static func _ocean_coordinates(world: HexWorldData) -> Dictionary:
	var ocean := {}
	var queue: Array[Vector2i] = []
	for row in range(world.height):
		for column in range(world.width):
			if (
				row != 0
				and row != world.height - 1
				and column != 0
				and column != world.width - 1
			):
				continue
			var tile := world.tile_at_offset(column, row)
			if tile == null or not tile.is_water or ocean.has(tile.coordinate):
				continue
			ocean[tile.coordinate] = true
			queue.append(tile.coordinate)
	var head := 0
	while head < queue.size():
		var coordinate := queue[head]
		head += 1
		for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
			var neighbor := world.tile_at(neighbor_coordinate)
			if (
				neighbor == null
				or not neighbor.is_water
				or ocean.has(neighbor_coordinate)
			):
				continue
			ocean[neighbor_coordinate] = true
			queue.append(neighbor_coordinate)
	return ocean


static func _hash_unit(seed: int, salt: int, x: int, y: int) -> float:
	var value := int(hash("%d:%d:%d:%d" % [seed, salt, x, y]))
	return float(posmod(value, 1000003)) / 1000002.0
