class_name HexEcologyStage
extends RefCounted

## Phase 4 ecology and resources.
##
## Runs after climate finalization so vegetation can react to the freshwater
## moisture published by Phase 3. It only writes Phase 4 fields
## (`vegetation_density`, `freshwater_access`, `feature_type`, `resource_type`,
## `exclusion_flags`) and never mutates Phase 1 geography, Phase 2 prepared
## climate, or Phase 3 hydrology state.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const Content = preload("res://src/data/game_content.gd")

# Dedicated Phase 4 salts. They follow the existing phase-tagged ASCII
# convention and are never shared with the Phase 1/2/3 streams.
const VEGETATION_SALT := 0x34564744
const FEATURE_SALT := 0x34465452
const RESOURCE_SALT := 0x3452534f
const RESOURCE_CLASS_SALT := 0x3452434c
const SETTLEMENT_SALT := 0x34535454

const FEATURE_NONE := &""
const FEATURE_SPARSE := &"sparse_vegetation"
const FEATURE_WOODLAND := &"woodland"
const FEATURE_FOREST := &"forest"
const FEATURE_DENSE_FOREST := &"dense_forest"
const FEATURE_IDS := [
	FEATURE_SPARSE,
	FEATURE_WOODLAND,
	FEATURE_FOREST,
	FEATURE_DENSE_FOREST,
]
## Density thresholds, highest class first.
const FEATURE_DENSITY_THRESHOLDS := [
	[FEATURE_DENSE_FOREST, 0.60],
	[FEATURE_FOREST, 0.40],
	[FEATURE_WOODLAND, 0.24],
	[FEATURE_SPARSE, 0.14],
]
## Vegetation classes rendered as separate batched feature classes.
const VEGETATION_CLASS_BROADLEAF := &"broadleaf"
const VEGETATION_CLASS_CONIFER := &"conifer"
const VEGETATION_CLASS_SCRUB := &"scrub"
const VEGETATION_CLASS_IDS := [
	VEGETATION_CLASS_BROADLEAF,
	VEGETATION_CLASS_CONIFER,
	VEGETATION_CLASS_SCRUB,
]
const BIOME_VEGETATION_CLASS := {
	&"tropical_forest": VEGETATION_CLASS_BROADLEAF,
	&"temperate_forest": VEGETATION_CLASS_BROADLEAF,
	&"grassland": VEGETATION_CLASS_BROADLEAF,
	&"coast": VEGETATION_CLASS_BROADLEAF,
	&"taiga": VEGETATION_CLASS_CONIFER,
	&"tundra": VEGETATION_CLASS_CONIFER,
	&"snow": VEGETATION_CLASS_CONIFER,
	&"shrubland": VEGETATION_CLASS_SCRUB,
	&"desert": VEGETATION_CLASS_SCRUB,
	&"bare_rock": VEGETATION_CLASS_SCRUB,
}
const BIOME_VEGETATION_BASE := {
	&"tropical_forest": 0.95,
	&"temperate_forest": 0.88,
	&"taiga": 0.72,
	&"grassland": 0.34,
	&"shrubland": 0.26,
	&"coast": 0.22,
	&"tundra": 0.12,
	&"desert": 0.05,
	&"bare_rock": 0.03,
	&"snow": 0.0,
	&"water": 0.0,
}
## Ocean, coast/lowland, highland, and mountain vegetation capability.
const ELEVATION_VEGETATION_SCALE := [0.0, 1.0, 1.0, 0.62, 0.16]
const FRESHWATER_ACCESS_REACH := 3
const FRESHWATER_VEGETATION_BONUS := 0.22
const COLD_VEGETATION_LIMIT := 0.10
const COLD_VEGETATION_SCALE := 0.25
## Coherent vegetation variation. A salted value-noise lattice produces
## groves and clearings instead of per-tile salt-and-pepper noise, while a
## small white-noise term keeps individual tiles from looking stamped.
const VEGETATION_NOISE_CELLS := 5.0
const VEGETATION_COHERENT_WEIGHT := 1.6
const VEGETATION_LOCAL_WEIGHT := 0.5

## Exclusion-zone bit flags stored on every tile and rendered by the exclusion
## diagnostic.
##
## * `WATER` is the water tile itself.
## * `SHORE` is ocean-adjacent land reserved for future harbors and coastal
##   treatment; only shore-compatible resources may sit there.
## * `BANK` is a freshwater bank carrying river geometry or touching a lake.
##   It reserves the same resource space and additionally caps vegetation so
##   the batched river ribbons and lake surfaces stay readable.
## * `CLIFF` is a tile with a real cliff wall edge.
## * `SETTLEMENT` is a reserved future settlement site and its ring.
## * `FEATURE` is the spacing reservation around a placed resource marker.
const EXCLUSION_WATER := 1
const EXCLUSION_SHORE := 2
const EXCLUSION_CLIFF := 4
const EXCLUSION_SETTLEMENT := 8
const EXCLUSION_FEATURE := 16
const EXCLUSION_BANK := 32
const EXCLUSION_FLAG_IDS := [
	[EXCLUSION_WATER, &"water"],
	[EXCLUSION_SHORE, &"shore"],
	[EXCLUSION_BANK, &"bank"],
	[EXCLUSION_CLIFF, &"cliff"],
	[EXCLUSION_SETTLEMENT, &"settlement"],
	[EXCLUSION_FEATURE, &"feature"],
]
## Tiles excluded from every placement because a cliff wall, water, or a
## reserved settlement site occupies their usable surface.
const HARD_EXCLUSIONS := EXCLUSION_WATER | EXCLUSION_CLIFF | EXCLUSION_SETTLEMENT
## Reservations that only shore-compatible resources may occupy.
const WATER_EDGE_EXCLUSIONS := EXCLUSION_SHORE | EXCLUSION_BANK
## A tile with at least this many cliff edges carries a real vertical wall, so
## nothing is placed on it. Cliff edges are rare, so this stays a precise
## geometric reservation rather than a broad terrain filter.
const CLIFF_EDGE_EXCLUSION_COUNT := 1
## Freshwater banks keep river ribbons and lake surfaces readable, so
## vegetation there never exceeds this class.
const BANK_MAXIMUM_FEATURE := FEATURE_WOODLAND
## One reserved future settlement site per this many tier provinces.
const SETTLEMENT_PROVINCES_PER_SITE := 6.0
const SETTLEMENT_SITE_SPACING := 4
const SETTLEMENT_BIOMES := {
	&"grassland": 1.0,
	&"coast": 0.92,
	&"temperate_forest": 0.85,
	&"shrubland": 0.6,
	&"taiga": 0.5,
	&"tropical_forest": 0.45,
	&"tundra": 0.2,
}
## Fraction of land tiles that carry a strategic resource at neutral density.
const RESOURCE_LAND_RATE := 0.045
## Additional same-resource spacing above the configured cross-resource
## minimum, keeping one deposit type from clustering in a single region.
const SAME_RESOURCE_EXTRA_SPACING := 3

## Deterministic biome-weighted strategic-resource rules. `share` is the
## nominal allocation weight; every rule with at least one eligible candidate
## also receives a guaranteed minimum of one placement.
const RESOURCE_RULES := [
	{
		"id": &"timber",
		"biomes": {
			&"temperate_forest": 1.0,
			&"taiga": 0.85,
			&"tropical_forest": 0.7,
		},
		"minimum_elevation": 1,
		"maximum_elevation": 3,
		"minimum_vegetation": 0.40,
		"share": 0.16,
	},
	{
		"id": &"grain",
		"biomes": {&"grassland": 1.0, &"coast": 0.6},
		"minimum_elevation": 1,
		"maximum_elevation": 2,
		"minimum_moisture": 0.32,
		"freshwater_weight": 0.6,
		"share": 0.16,
	},
	{
		"id": &"horses",
		"biomes": {&"grassland": 1.0, &"shrubland": 0.8, &"tundra": 0.3},
		"minimum_elevation": 1,
		"maximum_elevation": 2,
		"maximum_vegetation": 0.55,
		"share": 0.12,
	},
	{
		"id": &"iron",
		"biomes": {
			&"bare_rock": 1.0,
			&"tundra": 0.5,
			&"snow": 0.45,
			&"taiga": 0.4,
			&"shrubland": 0.4,
			&"temperate_forest": 0.35,
			&"grassland": 0.3,
		},
		"minimum_elevation": 3,
		"maximum_elevation": 4,
		"share": 0.12,
	},
	{
		"id": &"stone",
		"biomes": {
			&"bare_rock": 1.0,
			&"snow": 0.55,
			&"shrubland": 0.45,
			&"tundra": 0.4,
			&"desert": 0.35,
		},
		"minimum_elevation": 2,
		"maximum_elevation": 4,
		"share": 0.10,
	},
	{
		"id": &"furs",
		"biomes": {&"taiga": 1.0, &"tundra": 0.8, &"snow": 0.5, &"temperate_forest": 0.4},
		"minimum_elevation": 1,
		"maximum_elevation": 3,
		"minimum_vegetation": 0.14,
		"share": 0.10,
	},
	{
		"id": &"fish",
		"biomes": {&"coast": 1.0, &"grassland": 0.5, &"tundra": 0.35, &"taiga": 0.3},
		"minimum_elevation": 1,
		"maximum_elevation": 2,
		"requires_ocean_adjacency": true,
		"shore_compatible": true,
		"share": 0.10,
	},
	{
		"id": &"salt",
		"biomes": {&"desert": 1.0, &"shrubland": 0.6, &"coast": 0.5},
		"minimum_elevation": 1,
		"maximum_elevation": 3,
		"shore_compatible": true,
		"share": 0.08,
	},
	{
		"id": &"gold",
		"biomes": {
			&"bare_rock": 1.0,
			&"snow": 0.6,
			&"desert": 0.45,
			&"tundra": 0.35,
			&"shrubland": 0.3,
		},
		"minimum_elevation": 3,
		"maximum_elevation": 4,
		"share": 0.06,
	},
	{
		"id": &"wine",
		"biomes": {&"shrubland": 1.0, &"grassland": 0.55, &"temperate_forest": 0.4},
		"minimum_elevation": 1,
		"maximum_elevation": 3,
		"minimum_temperature": 0.52,
		"maximum_vegetation": 0.72,
		"share": 0.10,
	},
]


static func resource_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for rule in RESOURCE_RULES:
		result.append(rule["id"])
	return result


static func vegetation_class_for_biome(biome: StringName) -> StringName:
	return BIOME_VEGETATION_CLASS.get(biome, VEGETATION_CLASS_SCRUB)


static func apply(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	_reset(world)
	var freshwater_access := _freshwater_access(world)
	var ocean_adjacent := _ocean_adjacent_coordinates(world)
	_mark_static_exclusions(world, settings, ocean_adjacent)
	var settlement_sites := _reserve_settlement_sites(
		world,
		settings,
		freshwater_access,
		ocean_adjacent
	)
	_assign_vegetation(world, settings, freshwater_access)
	var resource_result := _place_resources(world, settings, ocean_adjacent)
	_apply_feature_exclusions(world, settings)
	world.metadata["settlement_reservation_count"] = settlement_sites.size()
	for key in resource_result:
		world.metadata[key] = resource_result[key]
	var diagnostics := _ecology_diagnostics(world, settings, ocean_adjacent)
	for key in diagnostics:
		world.metadata[key] = diagnostics[key]
	world.metadata["ecology_signature"] = world.ecology_signature()


static func _reset(world: HexWorldData) -> void:
	for tile in world.tiles:
		tile.vegetation_density = 0.0
		tile.freshwater_access = 0.0
		tile.feature_type = FEATURE_NONE
		tile.resource_type = &""
		tile.exclusion_flags = 0


static func _freshwater_access(world: HexWorldData) -> Dictionary:
	var distance: Dictionary = {}
	var queue: Array[Vector2i] = []
	for tile in world.tiles:
		if tile.is_ocean:
			continue
		var freshwater := tile.lake_id >= 0
		if not freshwater:
			for connected in tile.river_connections:
				if connected != 0:
					freshwater = true
					break
		if freshwater:
			distance[tile.coordinate] = 0
			queue.append(tile.coordinate)
	var head := 0
	while head < queue.size():
		var coordinate: Vector2i = queue[head]
		head += 1
		var steps := int(distance[coordinate])
		if steps >= FRESHWATER_ACCESS_REACH:
			continue
		for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
			var neighbor := world.tile_at(neighbor_coordinate)
			if (
				neighbor == null
				or neighbor.is_ocean
				or distance.has(neighbor_coordinate)
			):
				continue
			distance[neighbor_coordinate] = steps + 1
			queue.append(neighbor_coordinate)
	var result: Dictionary = {}
	for coordinate in distance:
		var steps := int(distance[coordinate])
		result[coordinate] = clampf(
			1.0 - float(steps) / float(FRESHWATER_ACCESS_REACH + 1),
			0.0,
			1.0
		)
	return result


static func _ocean_adjacent_coordinates(world: HexWorldData) -> Dictionary:
	var result: Dictionary = {}
	for tile in world.tiles:
		if tile.is_water:
			continue
		for neighbor in world.valid_neighbors(tile.coordinate):
			if neighbor.is_ocean:
				result[tile.coordinate] = true
				break
	return result


static func cliff_edge_count(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings
) -> int:
	var count := 0
	for direction in range(6):
		var neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, direction)
		)
		if neighbor == null:
			continue
		if neighbor.is_water:
			if tile.elevation_level >= settings.cliff_level_threshold:
				count += 1
			continue
		if absi(tile.elevation_level - neighbor.elevation_level) >= settings.cliff_level_threshold:
			count += 1
	return count


static func _mark_static_exclusions(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_adjacent: Dictionary
) -> void:
	for tile in world.tiles:
		if tile.is_water:
			tile.exclusion_flags |= EXCLUSION_WATER
			continue
		if ocean_adjacent.has(tile.coordinate):
			tile.exclusion_flags |= EXCLUSION_SHORE
		var bank := false
		for connected in tile.river_connections:
			if connected != 0:
				bank = true
				break
		if not bank:
			for neighbor in world.valid_neighbors(tile.coordinate):
				if neighbor.lake_id >= 0:
					bank = true
					break
		if bank:
			tile.exclusion_flags |= EXCLUSION_BANK
		if cliff_edge_count(world, tile, settings) >= CLIFF_EDGE_EXCLUSION_COUNT:
			tile.exclusion_flags |= EXCLUSION_CLIFF


static func _reserve_settlement_sites(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	freshwater_access: Dictionary,
	ocean_adjacent: Dictionary
) -> Array[Vector2i]:
	var target := settlement_reservation_target(String(world.profile_id))
	var sites: Array[Vector2i] = []
	if target <= 0:
		return sites
	var candidates: Array = []
	for tile in world.tiles:
		if (
			tile.is_water
			or tile.exclusion_flags & (EXCLUSION_WATER | EXCLUSION_CLIFF) != 0
			or tile.elevation_level < 1
			or tile.elevation_level > 2
			or not SETTLEMENT_BIOMES.has(tile.biome)
		):
			continue
		var score := float(SETTLEMENT_BIOMES[tile.biome])
		score += float(freshwater_access.get(tile.coordinate, 0.0)) * 0.55
		score += 0.35 if ocean_adjacent.has(tile.coordinate) else 0.0
		score += tile.moisture * 0.25
		score += _hash_unit(world.seed, SETTLEMENT_SALT, tile.coordinate) * 0.7
		candidates.append([score, _tile_index(world, tile), tile])
	candidates.sort_custom(func(a: Array, b: Array) -> bool:
		if not is_equal_approx(float(a[0]), float(b[0])):
			return float(a[0]) > float(b[0])
		return int(a[1]) < int(b[1])
	)
	var reserved: Dictionary = {}
	var radius := settings.settlement_reserve_radius
	for candidate in candidates:
		if sites.size() >= target:
			break
		var tile: HexTileData = candidate[2]
		var too_close := false
		for site in sites:
			if HexCoordinatesScript.distance(site, tile.coordinate) < SETTLEMENT_SITE_SPACING:
				too_close = true
				break
		if too_close:
			continue
		sites.append(tile.coordinate)
		for coordinate in HexCoordinatesScript.range_coordinates(tile.coordinate, radius):
			reserved[coordinate] = true
	for coordinate in reserved:
		var reserved_tile := world.tile_at(coordinate)
		if reserved_tile == null or reserved_tile.is_water:
			continue
		reserved_tile.exclusion_flags |= EXCLUSION_SETTLEMENT
	return sites


static func settlement_reservation_target(profile_id: String) -> int:
	if not Content.is_valid_map_size_profile(profile_id):
		profile_id = Content.DEFAULT_MAP_SIZE_PROFILE
	var profile := Content.map_size_profile(profile_id)
	return maxi(
		1,
		roundi(float(profile["province_count"]) / SETTLEMENT_PROVINCES_PER_SITE)
	)


static func _assign_vegetation(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	freshwater_access: Dictionary
) -> void:
	for tile in world.tiles:
		tile.freshwater_access = float(freshwater_access.get(tile.coordinate, 0.0))
		if tile.is_water:
			tile.vegetation_density = 0.0
			tile.feature_type = FEATURE_NONE
			continue
		var base := float(BIOME_VEGETATION_BASE.get(tile.biome, 0.0))
		var moisture_term := 0.58 + tile.moisture * 0.72
		var elevation_scale := float(
			ELEVATION_VEGETATION_SCALE[clampi(tile.elevation_level, 0, 4)]
		)
		var density := base * moisture_term * elevation_scale
		density *= 1.0 + FRESHWATER_VEGETATION_BONUS * tile.freshwater_access
		if tile.temperature < COLD_VEGETATION_LIMIT:
			density *= COLD_VEGETATION_SCALE
		var coherent := _coherent_unit(
			world.seed,
			VEGETATION_SALT,
			tile.coordinate,
			VEGETATION_NOISE_CELLS
		)
		var local := _hash_unit(world.seed, FEATURE_SALT, tile.coordinate)
		var variation := settings.vegetation_variation * (
			(coherent - 0.5) * VEGETATION_COHERENT_WEIGHT
			+ (local - 0.5) * VEGETATION_LOCAL_WEIGHT
		)
		density *= 1.0 + variation
		density *= settings.forest_density
		tile.vegetation_density = clampf(density, 0.0, 1.0)
		tile.feature_type = _feature_for_density(tile.vegetation_density)
		if tile.exclusion_flags & HARD_EXCLUSIONS != 0:
			tile.feature_type = FEATURE_NONE
		elif tile.exclusion_flags & EXCLUSION_BANK != 0:
			tile.feature_type = _capped_feature(tile.feature_type, BANK_MAXIMUM_FEATURE)


static func _feature_for_density(density: float) -> StringName:
	for threshold in FEATURE_DENSITY_THRESHOLDS:
		if density >= float(threshold[1]):
			return threshold[0]
	return FEATURE_NONE


static func feature_rank(feature: StringName) -> int:
	return FEATURE_IDS.find(feature) + 1


static func _capped_feature(feature: StringName, maximum: StringName) -> StringName:
	if feature_rank(feature) <= feature_rank(maximum):
		return feature
	return maximum


static func _place_resources(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_adjacent: Dictionary
) -> Dictionary:
	var land_count := world.land_tile_count()
	var target := maxi(
		0,
		roundi(float(land_count) * RESOURCE_LAND_RATE * settings.resource_density)
	)
	var candidate_lists: Array = []
	var candidate_counts: Dictionary = {}
	for rule_index in range(RESOURCE_RULES.size()):
		var rule: Dictionary = RESOURCE_RULES[rule_index]
		var candidates: Array = []
		for tile in world.tiles:
			if not _tile_matches_resource_rule(world, tile, rule, ocean_adjacent):
				continue
			candidates.append([
				_resource_score(world, tile, rule, rule_index),
				_tile_index(world, tile),
				tile,
			])
		candidates.sort_custom(func(a: Array, b: Array) -> bool:
			if not is_equal_approx(float(a[0]), float(b[0])):
				return float(a[0]) > float(b[0])
			return int(a[1]) < int(b[1])
		)
		candidate_lists.append(candidates)
		candidate_counts[String(rule["id"])] = candidates.size()
	var quotas := _resource_quotas(target, candidate_lists)
	var cross_spacing := settings.resource_minimum_spacing
	var same_spacing := cross_spacing + SAME_RESOURCE_EXTRA_SPACING
	var blocked_any: Dictionary = {}
	var blocked_by_type: Dictionary = {}
	var cursors: Array[int] = []
	var placed_counts: Array[int] = []
	for _index in range(RESOURCE_RULES.size()):
		cursors.append(0)
		placed_counts.append(0)
	var histogram: Dictionary = {}
	var placed_total := 0
	# Rarest-eligible resources claim their guaranteed deposit first, so a
	# common resource can never spend the only site a scarce one could use.
	var guarantee_order: Array = []
	for rule_index in range(RESOURCE_RULES.size()):
		if (candidate_lists[rule_index] as Array).is_empty():
			continue
		guarantee_order.append([
			(candidate_lists[rule_index] as Array).size(),
			rule_index,
		])
	guarantee_order.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[0]) != int(b[0]):
			return int(a[0]) < int(b[0])
		return int(a[1]) < int(b[1])
	)
	for entry in guarantee_order:
		var rule_index := int(entry[1])
		if int(quotas[rule_index]) <= 0:
			continue
		_place_next_candidate(
			rule_index,
			candidate_lists,
			cursors,
			placed_counts,
			histogram,
			blocked_any,
			blocked_by_type,
			cross_spacing,
			same_spacing
		)
	for rule_index in range(RESOURCE_RULES.size()):
		placed_total += placed_counts[rule_index]
	var progressing := true
	while progressing:
		progressing = false
		for rule_index in range(RESOURCE_RULES.size()):
			if placed_counts[rule_index] >= int(quotas[rule_index]):
				continue
			if _place_next_candidate(
				rule_index,
				candidate_lists,
				cursors,
				placed_counts,
				histogram,
				blocked_any,
				blocked_by_type,
				cross_spacing,
				same_spacing
			):
				placed_total += 1
				progressing = true
	return {
		"resource_target_count": target,
		"resource_placed_count": placed_total,
		"resource_histogram": histogram,
		"resource_candidate_counts": candidate_counts,
		"resource_quotas": _quota_dictionary(quotas),
		"resource_minimum_spacing": cross_spacing,
		"same_resource_minimum_spacing": same_spacing,
	}


## Accepts the next free candidate for one resource rule, reserving its
## cross-resource and same-resource spacing rings.
static func _place_next_candidate(
	rule_index: int,
	candidate_lists: Array,
	cursors: Array[int],
	placed_counts: Array[int],
	histogram: Dictionary,
	blocked_any: Dictionary,
	blocked_by_type: Dictionary,
	cross_spacing: int,
	same_spacing: int
) -> bool:
	var rule: Dictionary = RESOURCE_RULES[rule_index]
	var resource_id: StringName = rule["id"]
	var candidates: Array = candidate_lists[rule_index]
	var cursor := cursors[rule_index]
	while cursor < candidates.size():
		var tile: HexTileData = candidates[cursor][2]
		cursor += 1
		if blocked_any.has(tile.coordinate):
			continue
		if (
			blocked_by_type.has(resource_id)
			and (blocked_by_type[resource_id] as Dictionary).has(tile.coordinate)
		):
			continue
		tile.resource_type = resource_id
		# A marker tile never also carries decorative vegetation, so the
		# strategic marker stays visually unambiguous.
		tile.feature_type = FEATURE_NONE
		placed_counts[rule_index] += 1
		histogram[String(resource_id)] = int(histogram.get(String(resource_id), 0)) + 1
		for coordinate in HexCoordinatesScript.range_coordinates(
			tile.coordinate,
			maxi(cross_spacing - 1, 0)
		):
			blocked_any[coordinate] = true
		if not blocked_by_type.has(resource_id):
			blocked_by_type[resource_id] = {}
		var type_block: Dictionary = blocked_by_type[resource_id]
		for coordinate in HexCoordinatesScript.range_coordinates(
			tile.coordinate,
			maxi(same_spacing - 1, 0)
		):
			type_block[coordinate] = true
		cursors[rule_index] = cursor
		return true
	cursors[rule_index] = cursor
	return false


static func _quota_dictionary(quotas: Array) -> Dictionary:
	var result: Dictionary = {}
	for rule_index in range(RESOURCE_RULES.size()):
		result[String(RESOURCE_RULES[rule_index]["id"])] = int(quotas[rule_index])
	return result


static func _resource_quotas(target: int, candidate_lists: Array) -> Array:
	var quotas: Array = []
	var shares: Array = []
	var share_total := 0.0
	for rule_index in range(RESOURCE_RULES.size()):
		var available := (candidate_lists[rule_index] as Array).size() > 0
		var share := float(RESOURCE_RULES[rule_index]["share"]) if available else 0.0
		shares.append(share)
		share_total += share
		quotas.append(0)
	if share_total <= 0.0 or target <= 0:
		return quotas
	# Every eligible resource is guaranteed at least one deposit so no
	# strategic resource can vanish from a tier that can support it.
	var guaranteed := 0
	for rule_index in range(RESOURCE_RULES.size()):
		if shares[rule_index] > 0.0:
			quotas[rule_index] = 1
			guaranteed += 1
	var remaining := maxi(target - guaranteed, 0)
	var remainders: Array = []
	var assigned := 0
	for rule_index in range(RESOURCE_RULES.size()):
		if shares[rule_index] <= 0.0:
			remainders.append([0.0, rule_index])
			continue
		var exact := float(remaining) * float(shares[rule_index]) / share_total
		var whole := int(floor(exact))
		quotas[rule_index] = int(quotas[rule_index]) + whole
		assigned += whole
		remainders.append([exact - float(whole), rule_index])
	remainders.sort_custom(func(a: Array, b: Array) -> bool:
		if not is_equal_approx(float(a[0]), float(b[0])):
			return float(a[0]) > float(b[0])
		return int(a[1]) < int(b[1])
	)
	var leftover := remaining - assigned
	var cursor := 0
	while leftover > 0 and cursor < remainders.size() * 4:
		var entry: Array = remainders[cursor % remainders.size()]
		var rule_index := int(entry[1])
		if shares[rule_index] > 0.0:
			quotas[rule_index] = int(quotas[rule_index]) + 1
			leftover -= 1
		cursor += 1
	return quotas


static func _tile_matches_resource_rule(
	world: HexWorldData,
	tile: HexTileData,
	rule: Dictionary,
	ocean_adjacent: Dictionary
) -> bool:
	if tile.is_water:
		return false
	if tile.exclusion_flags & HARD_EXCLUSIONS != 0:
		return false
	if (
		tile.exclusion_flags & WATER_EDGE_EXCLUSIONS != 0
		and not bool(rule.get("shore_compatible", false))
	):
		return false
	var biomes: Dictionary = rule["biomes"]
	if not biomes.has(tile.biome):
		return false
	if tile.elevation_level < int(rule.get("minimum_elevation", 1)):
		return false
	if tile.elevation_level > int(rule.get("maximum_elevation", 4)):
		return false
	if tile.vegetation_density < float(rule.get("minimum_vegetation", 0.0)):
		return false
	if tile.vegetation_density > float(rule.get("maximum_vegetation", 1.0)):
		return false
	if tile.temperature < float(rule.get("minimum_temperature", 0.0)):
		return false
	if tile.moisture < float(rule.get("minimum_moisture", 0.0)):
		return false
	if (
		bool(rule.get("requires_ocean_adjacency", false))
		and not ocean_adjacent.has(tile.coordinate)
	):
		return false
	if tile.freshwater_access < float(rule.get("minimum_freshwater_access", 0.0)):
		return false
	return true


static func _resource_score(
	world: HexWorldData,
	tile: HexTileData,
	rule: Dictionary,
	rule_index: int
) -> float:
	var biomes: Dictionary = rule["biomes"]
	var score := float(biomes.get(tile.biome, 0.0))
	score += tile.freshwater_access * float(rule.get("freshwater_weight", 0.0))
	score += _hash_unit(
		world.seed,
		RESOURCE_SALT + rule_index * RESOURCE_CLASS_SALT,
		tile.coordinate
	) * 0.75
	return score


static func _apply_feature_exclusions(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> void:
	var radius := maxi(settings.resource_minimum_spacing - 1, 0)
	for tile in world.tiles:
		if String(tile.resource_type).is_empty():
			continue
		tile.exclusion_flags |= EXCLUSION_FEATURE
		for coordinate in HexCoordinatesScript.range_coordinates(tile.coordinate, radius):
			var neighbor := world.tile_at(coordinate)
			if neighbor != null and not neighbor.is_water:
				neighbor.exclusion_flags |= EXCLUSION_FEATURE


static func _ecology_diagnostics(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ocean_adjacent: Dictionary
) -> Dictionary:
	var feature_histogram: Dictionary = {}
	var exclusion_histogram: Dictionary = {}
	for flag in EXCLUSION_FLAG_IDS:
		exclusion_histogram[String(flag[1])] = 0
	var density_total := 0.0
	var vegetated := 0
	var forested := 0
	var excluded := 0
	var rule_violations := 0
	var feature_violations := 0
	var resource_tiles: Array[HexTileData] = []
	var rules_by_id: Dictionary = {}
	for rule in RESOURCE_RULES:
		rules_by_id[rule["id"]] = rule
	for tile in world.tiles:
		var feature_key := (
			"none" if String(tile.feature_type).is_empty() else String(tile.feature_type)
		)
		feature_histogram[feature_key] = int(feature_histogram.get(feature_key, 0)) + 1
		if not tile.is_water:
			density_total += tile.vegetation_density
		if not String(tile.feature_type).is_empty():
			vegetated += 1
			if feature_rank(tile.feature_type) >= feature_rank(FEATURE_FOREST):
				forested += 1
		for flag in EXCLUSION_FLAG_IDS:
			if tile.exclusion_flags & int(flag[0]) != 0:
				exclusion_histogram[String(flag[1])] = int(
					exclusion_histogram[String(flag[1])]
				) + 1
		if tile.exclusion_flags != 0:
			excluded += 1
		if (
			not String(tile.feature_type).is_empty()
			and (
				tile.exclusion_flags & HARD_EXCLUSIONS != 0
				or not String(tile.resource_type).is_empty()
				or (
					tile.exclusion_flags & EXCLUSION_BANK != 0
					and feature_rank(tile.feature_type)
						> feature_rank(BANK_MAXIMUM_FEATURE)
				)
			)
		):
			feature_violations += 1
		if String(tile.resource_type).is_empty():
			continue
		resource_tiles.append(tile)
		var rule: Dictionary = rules_by_id.get(tile.resource_type, {})
		if rule.is_empty():
			rule_violations += 1
			continue
		var checked_flags := tile.exclusion_flags
		# The placement rule check re-runs without the spacing reservation the
		# accepted placement itself created.
		tile.exclusion_flags = checked_flags & ~EXCLUSION_FEATURE
		if not _tile_matches_resource_rule(world, tile, rule, ocean_adjacent):
			rule_violations += 1
		tile.exclusion_flags = checked_flags
	var minimum_spacing := 999999
	var minimum_same_spacing := 999999
	for first_index in range(resource_tiles.size()):
		for second_index in range(first_index + 1, resource_tiles.size()):
			var first := resource_tiles[first_index]
			var second := resource_tiles[second_index]
			var distance := HexCoordinatesScript.distance(
				first.coordinate,
				second.coordinate
			)
			minimum_spacing = mini(minimum_spacing, distance)
			if first.resource_type == second.resource_type:
				minimum_same_spacing = mini(minimum_same_spacing, distance)
	var spacing_violations := 0
	if not resource_tiles.is_empty():
		if minimum_spacing < settings.resource_minimum_spacing:
			spacing_violations += 1
		if (
			minimum_same_spacing
			< settings.resource_minimum_spacing + SAME_RESOURCE_EXTRA_SPACING
			and minimum_same_spacing != 999999
		):
			spacing_violations += 1
	var land_count := maxi(world.land_tile_count(), 1)
	var present_types: Dictionary = {}
	for tile in resource_tiles:
		present_types[tile.resource_type] = true
	return {
		"feature_histogram": feature_histogram,
		"exclusion_histogram": exclusion_histogram,
		"mean_land_vegetation_density": density_total / float(land_count),
		"vegetated_tile_count": vegetated,
		"forested_tile_count": forested,
		"excluded_tile_count": excluded,
		"resource_types_present": present_types.size(),
		"resource_rule_violation_count": rule_violations,
		"resource_spacing_violation_count": spacing_violations,
		"feature_exclusion_violation_count": feature_violations,
		"minimum_resource_spacing_observed": (
			minimum_spacing if minimum_spacing != 999999 else 0
		),
		"minimum_same_resource_spacing_observed": (
			minimum_same_spacing if minimum_same_spacing != 999999 else 0
		),
	}


static func _tile_index(world: HexWorldData, tile: HexTileData) -> int:
	return tile.offset_coordinate.y * world.width + tile.offset_coordinate.x


## Deterministic smoothed value noise over the axial lattice. It uses only the
## world seed and a Phase 4 salt, so it never disturbs an earlier stage.
static func _coherent_unit(
	seed: int,
	salt: int,
	coordinate: Vector2i,
	cell_size: float
) -> float:
	var scaled_x := float(coordinate.x) / cell_size
	var scaled_y := float(coordinate.y) / cell_size
	var cell_x := floori(scaled_x)
	var cell_y := floori(scaled_y)
	var fraction_x := scaled_x - float(cell_x)
	var fraction_y := scaled_y - float(cell_y)
	var smooth_x := fraction_x * fraction_x * (3.0 - 2.0 * fraction_x)
	var smooth_y := fraction_y * fraction_y * (3.0 - 2.0 * fraction_y)
	var corner_00 := _hash_unit(seed, salt, Vector2i(cell_x, cell_y))
	var corner_10 := _hash_unit(seed, salt, Vector2i(cell_x + 1, cell_y))
	var corner_01 := _hash_unit(seed, salt, Vector2i(cell_x, cell_y + 1))
	var corner_11 := _hash_unit(seed, salt, Vector2i(cell_x + 1, cell_y + 1))
	return lerpf(
		lerpf(corner_00, corner_10, smooth_x),
		lerpf(corner_01, corner_11, smooth_x),
		smooth_y
	)


static func _hash_unit(seed: int, salt: int, coordinate: Vector2i) -> float:
	var value := int(hash("%d:%d:%d:%d" % [seed, salt, coordinate.x, coordinate.y]))
	return float(posmod(value, 1000003)) / 1000002.0
