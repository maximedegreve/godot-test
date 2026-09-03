class_name HexElevationStage
extends RefCounted

const ELEVATION_NOISE_SALT := 0x3344454e
const MOUNTAIN_RANGE_SALT := 0x33444d52


static func apply(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	var coast_distance := _distance_from_water(world)
	var maximum_distance := 1
	for value in coast_distance.values():
		maximum_distance = maxi(maximum_distance, int(value))
	var noise := FastNoiseLite.new()
	noise.seed = int(_derived_seed(world.seed, ELEVATION_NOISE_SALT))
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.055
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.48
	var ranges := _create_mountain_ranges(world, settings)
	for tile in world.tiles:
		if tile.is_water:
			tile.elevation_level = 0
			tile.elevation = 0.0
			tile.terrain_type = &"ocean"
			tile.movement_cost = 1.0
			continue
		var distance_to_water := int(coast_distance.get(tile.coordinate, 1))
		if distance_to_water <= 1:
			tile.elevation_level = 1
			tile.terrain_type = &"coast"
		else:
			var interior := clampf(float(distance_to_water - 1) / float(maximum_distance), 0.0, 1.0)
			var local_detail := (
				noise.get_noise_2d(
					float(tile.offset_coordinate.x),
					float(tile.offset_coordinate.y)
				) * 0.5 + 0.5
			)
			var ridge := _ridge_strength(tile.position, ranges, settings)
			var elevation_score := (
				interior * 0.40
				+ ridge * (0.42 + settings.mountain_frequency * 0.28)
				+ local_detail * settings.terrain_roughness * 0.25
			)
			if elevation_score >= 0.69:
				tile.elevation_level = 4
				tile.terrain_type = &"mountain"
			elif elevation_score >= 0.43:
				tile.elevation_level = 3
				tile.terrain_type = &"highland"
			else:
				tile.elevation_level = 2
				tile.terrain_type = &"lowland"
		tile.elevation = float(tile.elevation_level) * settings.elevation_step_height
		tile.movement_cost = [1.0, 1.0, 1.0, 1.5, 2.5][tile.elevation_level]
	_connect_mountain_chains(world)
	if settings.mountain_frequency > 0.0:
		_ensure_mountain_chain(world, ranges, settings)
	world.metadata["mountain_ranges"] = ranges
	world.metadata["elevation_histogram"] = _elevation_histogram(world)


static func _distance_from_water(world: HexWorldData) -> Dictionary:
	var distances: Dictionary = {}
	var queue: Array[Vector2i] = []
	for tile in world.tiles:
		if tile.is_water:
			distances[tile.coordinate] = 0
			queue.append(tile.coordinate)
	var head := 0
	while head < queue.size():
		var coordinate := queue[head]
		head += 1
		var next_distance := int(distances[coordinate]) + 1
		for neighbor_coordinate in HexCoordinates.neighbors(coordinate):
			if not world.has_coordinate(neighbor_coordinate) or distances.has(neighbor_coordinate):
				continue
			distances[neighbor_coordinate] = next_distance
			queue.append(neighbor_coordinate)
	return distances


static func _create_mountain_ranges(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = _derived_seed(world.seed, MOUNTAIN_RANGE_SALT)
	var ranges: Array[Dictionary] = []
	var macro_seeds: Array = world.metadata.get("continent_macro_seeds", [])
	for macro_seed in macro_seeds:
		if bool(macro_seed.get("is_island", false)):
			continue
		if rng.randf() > 0.45 + settings.mountain_frequency * 0.5:
			continue
		ranges.append(_create_mountain_range(world, settings, rng, macro_seed))
	# A configured non-zero mountain frequency guarantees at least one coherent
	# range. Small tiers otherwise have a meaningful chance to reject every
	# independently sampled range and produce no mountain gameplay tiles.
	if ranges.is_empty() and settings.mountain_frequency > 0.0:
		for macro_seed in macro_seeds:
			if not bool(macro_seed.get("is_island", false)):
				ranges.append(_create_mountain_range(world, settings, rng, macro_seed))
				break
	return ranges


static func _create_mountain_range(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	rng: RandomNumberGenerator,
	macro_seed: Dictionary
) -> Dictionary:
	var normalized_center: Vector2 = macro_seed["position"]
	var center_offset := Vector2i(
		roundi(normalized_center.x * float(world.width - 1)),
		roundi(normalized_center.y * float(world.height - 1))
	)
	var center_coordinate := HexCoordinates.offset_to_axial(center_offset)
	var center := HexCoordinates.axial_to_world(center_coordinate, settings.hex_size)
	var angle := float(macro_seed.get("angle", rng.randf_range(0.0, TAU)))
	var half_length := (
		float(mini(world.width, world.height))
		* settings.hex_size
		* maxf(
			lerpf(0.08, 0.30, settings.mountain_length),
			float(macro_seed.get("span", 0.0)) * 0.72
		)
	)
	var direction := Vector2(cos(angle), sin(angle))
	var perpendicular := Vector2(-direction.y, direction.x)
	var center_2d := Vector2(center.x, center.z)
	var point_count := rng.randi_range(5, 8)
	var points: Array[Vector2] = []
	var widths: Array[float] = []
	var strengths: Array[float] = []
	var bend_phase := rng.randf_range(0.0, TAU)
	var bend_amplitude := half_length * rng.randf_range(0.13, 0.30)
	for point_index in range(point_count):
		var t := float(point_index) / float(point_count - 1)
		var longitudinal := lerpf(-half_length, half_length, t)
		var taper := sin(t * PI)
		var bend := (
			sin(t * PI * rng.randf_range(1.2, 2.4) + bend_phase)
			* bend_amplitude
			* taper
		)
		bend += rng.randf_range(-bend_amplitude * 0.32, bend_amplitude * 0.32) * taper
		points.append(center_2d + direction * longitudinal + perpendicular * bend)
		widths.append(
			settings.hex_size
			* rng.randf_range(1.7, 4.8)
			* lerpf(0.72, 1.0, taper)
		)
		strengths.append(rng.randf_range(0.66, 1.0))
	var segments: Array[Dictionary] = []
	for point_index in range(points.size() - 1):
		segments.append({
			"start": points[point_index],
			"end": points[point_index + 1],
			"width_start": widths[point_index],
			"width_end": widths[point_index + 1],
			"strength_start": strengths[point_index],
			"strength_end": strengths[point_index + 1],
			"kind": "spine",
		})
	var branch_count := rng.randi_range(2, 4)
	for branch_index in range(branch_count):
		var anchor_index := rng.randi_range(1, points.size() - 2)
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var branch_angle := angle + side * rng.randf_range(0.55, 1.15)
		var branch_direction := Vector2(cos(branch_angle), sin(branch_angle))
		var branch_length := half_length * rng.randf_range(0.22, 0.48)
		var branch_mid := (
			points[anchor_index]
			+ branch_direction * branch_length * 0.48
			+ perpendicular * rng.randf_range(-branch_length * 0.12, branch_length * 0.12)
		)
		var branch_end := (
			points[anchor_index]
			+ branch_direction * branch_length
			+ perpendicular * rng.randf_range(-branch_length * 0.20, branch_length * 0.20)
		)
		var branch_width := widths[anchor_index] * rng.randf_range(0.58, 0.86)
		segments.append({
			"start": points[anchor_index],
			"end": branch_mid,
			"width_start": branch_width,
			"width_end": branch_width * rng.randf_range(0.70, 0.92),
			"strength_start": maxf(0.78, strengths[anchor_index] * 0.94),
			"strength_end": rng.randf_range(0.68, 0.90),
			"kind": "branch",
		})
		segments.append({
			"start": branch_mid,
			"end": branch_end,
			"width_start": branch_width * 0.82,
			"width_end": branch_width * rng.randf_range(0.28, 0.52),
			"strength_start": rng.randf_range(0.65, 0.86),
			"strength_end": rng.randf_range(0.42, 0.68),
			"kind": "branch",
		})
	var massif_count := rng.randi_range(2, 3)
	var massifs: Array[Dictionary] = []
	for massif_index in range(massif_count):
		var anchor_index := rng.randi_range(1, points.size() - 2)
		massifs.append({
			"center": points[anchor_index] + Vector2(
				rng.randf_range(-settings.hex_size * 2.0, settings.hex_size * 2.0),
				rng.randf_range(-settings.hex_size * 2.0, settings.hex_size * 2.0)
			),
			"radius": settings.hex_size * rng.randf_range(3.0, 6.2),
			"strength": rng.randf_range(0.78, 1.0),
		})
	return {
		"control_points": points,
		"segments": segments,
		"massifs": massifs,
		"angle": angle,
	}


static func _ridge_strength(
	position: Vector3,
	ranges: Array[Dictionary],
	settings: WorldGenerationSettings
) -> float:
	var result := 0.0
	var point := Vector2(position.x, position.z)
	for mountain_range in ranges:
		for ridge_segment_value in mountain_range["segments"]:
			var ridge_segment: Dictionary = ridge_segment_value
			var start: Vector2 = ridge_segment["start"]
			var end: Vector2 = ridge_segment["end"]
			var segment := end - start
			var denominator := maxf(segment.length_squared(), 0.0001)
			var t := clampf((point - start).dot(segment) / denominator, 0.0, 1.0)
			var distance := point.distance_to(start + segment * t)
			var width := lerpf(
				float(ridge_segment["width_start"]),
				float(ridge_segment["width_end"]),
				t
			)
			var strength := lerpf(
				float(ridge_segment["strength_start"]),
				float(ridge_segment["strength_end"]),
				t
			)
			result = maxf(
				result,
				strength * (1.0 - smoothstep(width * 0.18, width, distance))
			)
		for massif_value in mountain_range["massifs"]:
			var massif: Dictionary = massif_value
			var radius := float(massif["radius"])
			var distance := point.distance_to(Vector2(massif["center"]))
			result = maxf(
				result,
				float(massif["strength"])
				* (1.0 - smoothstep(radius * 0.12, radius, distance))
			)
	return result


static func _connect_mountain_chains(world: HexWorldData) -> void:
	var changes: Dictionary = {}
	for tile in world.tiles:
		if tile.elevation_level != 4:
			continue
		var mountain_neighbors := 0
		var highland_neighbors := 0
		for neighbor in world.valid_neighbors(tile.coordinate):
			if neighbor.elevation_level == 4:
				mountain_neighbors += 1
			elif neighbor.elevation_level == 3:
				highland_neighbors += 1
		if mountain_neighbors == 0 and highland_neighbors < 2:
			changes[tile.coordinate] = 3
	for coordinate in changes:
		var tile := world.tile_at(coordinate)
		tile.elevation_level = 3
		tile.elevation = 3.0 * (
			tile.elevation / 4.0 if tile.elevation > 0.0 else 1.0
		)
		tile.terrain_type = &"highland"
		tile.movement_cost = 1.5


static func _ensure_mountain_chain(
	world: HexWorldData,
	ranges: Array[Dictionary],
	settings: WorldGenerationSettings
) -> void:
	for tile in world.tiles:
		if tile.elevation_level == 4:
			return
	var best_tile: HexTileData
	var best_strength := -1.0
	for tile in world.tiles:
		if tile.is_water or tile.elevation_level <= 1:
			continue
		var strength := _ridge_strength(tile.position, ranges, settings)
		if strength > best_strength:
			best_strength = strength
			best_tile = tile
	if best_tile == null:
		return
	_set_tile_elevation(best_tile, 4, settings)
	var best_neighbor: HexTileData
	var best_neighbor_strength := -1.0
	for neighbor in world.valid_neighbors(best_tile.coordinate):
		if neighbor.is_water or neighbor.elevation_level <= 1:
			continue
		var strength := _ridge_strength(neighbor.position, ranges, settings)
		if strength > best_neighbor_strength:
			best_neighbor_strength = strength
			best_neighbor = neighbor
		if neighbor.elevation_level < 3:
			_set_tile_elevation(neighbor, 3, settings)
	if best_neighbor != null:
		_set_tile_elevation(best_neighbor, 4, settings)


static func _set_tile_elevation(
	tile: HexTileData,
	level: int,
	settings: WorldGenerationSettings
) -> void:
	tile.elevation_level = level
	tile.elevation = float(level) * settings.elevation_step_height
	tile.terrain_type = &"mountain" if level == 4 else &"highland"
	tile.movement_cost = 2.5 if level == 4 else 1.5


static func _elevation_histogram(world: HexWorldData) -> Dictionary:
	var histogram := {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
	for tile in world.tiles:
		histogram[tile.elevation_level] = int(histogram[tile.elevation_level]) + 1
	return histogram


static func _derived_seed(world_seed: int, salt: int) -> int:
	var value := world_seed ^ salt
	value = int((value ^ (value >> 16)) * 0x45d9f3b)
	value = int((value ^ (value >> 16)) * 0x45d9f3b)
	return value ^ (value >> 16)
