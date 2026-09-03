class_name HexContinentMaskStage
extends RefCounted

const STYLE_SALT := 0x33445354
const LAYOUT_SALT := 0x33444c59
const ISLAND_SALT := 0x33444953
const COAST_WARP_X_SALT := 0x33445758
const COAST_WARP_Y_SALT := 0x33445759
const COAST_DETAIL_SALT := 0x3344434e
const OWNER_SIZE_SALT := 0x33444f53

const STYLE_CONTINENTS := "continents_and_islands"
const STYLE_PANGEA := "pangea_and_islands"
const STYLE_ARCHIPELAGO := "archipelago"
const STYLE_FRACTURED := "fractured"
const EXPLICIT_STYLES := [
	STYLE_CONTINENTS,
	STYLE_PANGEA,
	STYLE_ARCHIPELAGO,
	STYLE_FRACTURED,
]
const VARIED_STYLE_WEIGHTS := [
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_CONTINENTS,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_PANGEA,
	STYLE_ARCHIPELAGO,
	STYLE_FRACTURED,
]


static func apply(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	var resolved_style := resolve_style(world.seed, settings.landform_style)
	var layout_rng := RandomNumberGenerator.new()
	layout_rng.seed = _derived_seed(world.seed, LAYOUT_SALT)
	var island_rng := RandomNumberGenerator.new()
	island_rng.seed = _derived_seed(world.seed, ISLAND_SALT)
	var layout := _build_layout(resolved_style, layout_rng, island_rng, settings)
	var nodes: Array[Dictionary] = layout["nodes"]
	for tile in world.tiles:
		tile.is_water = true
		tile.continent_id = -1
		tile.terrain_type = &"ocean"
	var target_land_tiles := roundi(
		float(world.tiles.size()) * (1.0 - settings.ocean_percentage)
	)
	var carve_compensation := 0.012
	match resolved_style:
		STYLE_CONTINENTS:
			carve_compensation = 0.014 + settings.continent_separation * 0.012
		STYLE_PANGEA:
			carve_compensation = 0.024
		STYLE_ARCHIPELAGO:
			carve_compensation = 0.034
		STYLE_FRACTURED:
			carve_compensation = 0.030
	var growth_target := mini(
		world.tiles.size(),
		target_land_tiles + roundi(float(world.tiles.size()) * carve_compensation)
	)
	var plate_field := _build_plate_field(world, settings)
	var primary_nodes: Array[Dictionary] = []
	var island_nodes: Array[Dictionary] = []
	for node in nodes:
		if bool(node["is_island"]):
			island_nodes.append(node)
		else:
			primary_nodes.append(node)
	if resolved_style == STYLE_ARCHIPELAGO:
		primary_nodes = nodes
		island_nodes = []
	var principal_owner_count := (layout["mountain_seeds"] as Array).size()
	var reconciliation_owner_count := (
		principal_owner_count if not island_nodes.is_empty() else 0
	)
	var island_share := 0.0
	match resolved_style:
		STYLE_CONTINENTS:
			island_share = 0.06
		STYLE_PANGEA:
			island_share = 0.10
		STYLE_FRACTURED:
			island_share = 0.09
	var island_target := roundi(float(growth_target) * island_share)
	var primary_target := growth_target - island_target
	var coast_noise := _create_noise(world.seed, COAST_DETAIL_SALT, 0.105, 4)
	_grow_from_nodes(
		world,
		primary_nodes,
		primary_target,
		resolved_style,
		plate_field,
		layout.get("water_nodes", []),
		coast_noise,
		settings
	)
	if island_target > 0 and not island_nodes.is_empty():
		_grow_from_nodes(
			world,
			island_nodes,
			island_target,
			STYLE_ARCHIPELAGO,
			plate_field,
			[],
			coast_noise,
			settings
		)
	_fill_remaining_land(
		world,
		growth_target,
		resolved_style,
		plate_field,
		coast_noise,
		settings,
		[],
		false,
		{},
		reconciliation_owner_count
	)
	_smooth_mask(world, target_land_tiles)
	_erode_coast(world, settings)
	if resolved_style in [STYLE_CONTINENTS, STYLE_PANGEA]:
		_apply_water_cuts(world, layout.get("water_nodes", []), settings)
	var corridor_radius := (
		roundi(lerpf(0.0, 4.0, settings.continent_separation))
		if resolved_style == STYLE_CONTINENTS
		else 0
	)
	var protected_owner_corridors := _carve_owner_boundaries(
		world,
		corridor_radius,
		principal_owner_count
	)
	_fill_remaining_land(
		world,
		target_land_tiles,
		resolved_style,
		plate_field,
		coast_noise,
		settings,
		layout.get("water_nodes", []),
		true,
		protected_owner_corridors,
		reconciliation_owner_count
	)
	world.metadata["requested_landform_style"] = settings.landform_style
	world.metadata["resolved_landform_style"] = resolved_style
	world.metadata["continent_macro_seeds"] = layout["mountain_seeds"]
	world.metadata["continent_shape_nodes"] = nodes
	world.metadata["protected_water_cuts"] = layout.get("water_nodes", [])
	world.metadata["tectonic_plates"] = plate_field["plates"]
	world.metadata["tectonic_boundary_tile_count"] = plate_field["boundary_strength"].size()
	world.metadata["target_land_tiles"] = target_land_tiles
	world.metadata["pre_carve_land_target"] = growth_target
	world.metadata["land_tiles"] = world.land_tile_count()


static func resolve_style(world_seed: int, requested_style: String) -> String:
	if requested_style in EXPLICIT_STYLES:
		return requested_style
	var rng := RandomNumberGenerator.new()
	rng.seed = _derived_seed(world_seed, STYLE_SALT)
	return VARIED_STYLE_WEIGHTS[rng.randi_range(0, VARIED_STYLE_WEIGHTS.size() - 1)]


static func _build_layout(
	style: String,
	layout_rng: RandomNumberGenerator,
	island_rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Dictionary:
	match style:
		STYLE_PANGEA:
			return _build_pangea(layout_rng, island_rng, settings)
		STYLE_ARCHIPELAGO:
			return _build_archipelago(layout_rng, island_rng, settings)
		STYLE_FRACTURED:
			return _build_fractured(layout_rng, island_rng, settings)
		_:
			return _build_continents(layout_rng, island_rng, settings)


static func _build_continents(
	rng: RandomNumberGenerator,
	island_rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Dictionary:
	var nodes: Array[Dictionary] = []
	var mountain_seeds: Array[Dictionary] = []
	var water_nodes: Array[Dictionary] = []
	var centers: Array[Vector2] = []
	var minimum_major_count := clampi(roundi(float(settings.continent_count) * 0.55), 2, 4)
	var maximum_major_count := mini(5, minimum_major_count + 1)
	var major_count := rng.randi_range(minimum_major_count, maximum_major_count)
	var target_separation := lerpf(
		0.40,
		0.27,
		float(major_count - 2) / 4.0
	)
	target_separation *= lerpf(0.90, 1.55, settings.continent_separation)
	for continent_id in range(major_count):
		var center := _choose_separated_position(
			rng,
			0.08,
			centers,
			settings,
			target_separation
		)
		centers.append(center)
		var angle := rng.randf_range(0.0, TAU)
		var shape_kind := rng.randi_range(0, 2)
		var span := rng.randf_range(0.075, 0.15)
		var lobes := rng.randi_range(3, 5)
		var curve := rng.randf_range(0.025, 0.075)
		var base_radius := Vector2(0.078, 0.057)
		if shape_kind == 0:
			span = rng.randf_range(0.045, 0.085)
			lobes = rng.randi_range(2, 4)
			curve = rng.randf_range(0.010, 0.045)
			base_radius = Vector2(0.088, 0.070)
		elif shape_kind == 1:
			span = rng.randf_range(0.12, 0.19)
			lobes = rng.randi_range(4, 7)
			curve = rng.randf_range(0.040, 0.090)
			base_radius = Vector2(0.068, 0.047)
		span *= lerpf(
			1.0,
			rng.randf_range(0.68, 1.34),
			settings.continent_size_variation
		)
		var first_node_index := nodes.size()
		_append_spine(
			nodes,
			rng,
			center,
			angle,
			span,
			lobes,
			curve,
			base_radius,
			continent_id,
			false,
			-0.04
		)
		var growth_weight := 1.0
		if shape_kind == 0:
			growth_weight = 0.68
		elif shape_kind == 1:
			growth_weight = 1.18
		for node_index in range(first_node_index, nodes.size()):
			nodes[node_index]["growth_weight"] = growth_weight
		if shape_kind == 2 and rng.randf() < 0.72:
			var first_branch_index := nodes.size()
			var direction := Vector2(cos(angle), sin(angle))
			_append_spine(
				nodes,
				rng,
				center + direction * rng.randf_range(-0.04, 0.04),
				angle + rng.randf_range(0.8, 1.3),
				span * rng.randf_range(0.35, 0.55),
				rng.randi_range(2, 4),
				rng.randf_range(0.015, 0.045),
				Vector2(0.062, 0.046),
				continent_id,
				false,
				-0.035
			)
			for node_index in range(first_branch_index, nodes.size()):
				nodes[node_index]["growth_weight"] = growth_weight
		mountain_seeds.append(_mountain_seed(center, angle, span, continent_id))
		var direction := Vector2(cos(angle), sin(angle))
		var perpendicular := Vector2(-direction.y, direction.x)
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		water_nodes.append(_water_node(
			rng,
			center
				+ direction * rng.randf_range(-0.08, 0.08)
				+ perpendicular * side * rng.randf_range(0.11, 0.18),
			angle + rng.randf_range(-0.45, 0.45),
			rng.randf_range(0.065, 0.11),
			rng.randf_range(0.022, 0.046),
			2.6
		))
	_append_island_chains(
		nodes,
		island_rng,
		settings,
		major_count,
		maxi(9, roundi(8.0 + settings.island_frequency * 18.0)),
		0.011,
		0.030
	)
	return {
		"nodes": nodes,
		"mountain_seeds": mountain_seeds,
		"water_nodes": water_nodes,
	}


static func _build_pangea(
	rng: RandomNumberGenerator,
	island_rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Dictionary:
	var nodes: Array[Dictionary] = []
	var center := Vector2(
		rng.randf_range(0.44, 0.56),
		rng.randf_range(0.43, 0.57)
	)
	var angle := rng.randf_range(0.0, TAU)
	_append_spine(
		nodes, rng, center, angle, 0.33, 9, 0.075,
		Vector2(0.115, 0.088), 0, false, -0.08
	)
	var main_direction := Vector2(cos(angle), sin(angle))
	var branch_origin_a := center + main_direction * rng.randf_range(-0.12, -0.04)
	var branch_origin_b := center + main_direction * rng.randf_range(0.04, 0.14)
	_append_spine(
		nodes, rng, branch_origin_a, angle + rng.randf_range(0.75, 1.25),
		0.18, 5, 0.045, Vector2(0.10, 0.075), 0, false, -0.07
	)
	_append_spine(
		nodes, rng, branch_origin_b, angle - rng.randf_range(0.75, 1.25),
		0.18, 5, 0.045, Vector2(0.10, 0.075), 0, false, -0.07
	)
	_append_island_chains(
		nodes,
		island_rng,
		settings,
		1,
		maxi(7, roundi(6.0 + settings.island_frequency * 16.0)),
		0.017,
		0.044
	)
	var perpendicular := Vector2(-main_direction.y, main_direction.x)
	var water_nodes: Array[Dictionary] = []
	for side in [-1.0, 1.0]:
		var bay_position: Vector2 = (
			center
			+ main_direction * rng.randf_range(-0.16, 0.16)
			+ perpendicular * side * rng.randf_range(0.22, 0.30)
		)
		water_nodes.append(_water_node(
			rng,
			bay_position,
			angle + rng.randf_range(-0.4, 0.4),
			rng.randf_range(0.11, 0.17),
			rng.randf_range(0.045, 0.075),
			3.0
		))
	water_nodes.append(_water_node(
		rng,
		center + main_direction * rng.randf_range(-0.08, 0.08),
		angle + PI * 0.5,
		rng.randf_range(0.08, 0.13),
		rng.randf_range(0.025, 0.045),
		2.2
	))
	return {
		"nodes": nodes,
		"mountain_seeds": [_mountain_seed(center, angle, 0.34, 0)],
		"water_nodes": water_nodes,
	}


static func _build_archipelago(
	rng: RandomNumberGenerator,
	island_rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Dictionary:
	var nodes: Array[Dictionary] = []
	var mountain_seeds: Array[Dictionary] = []
	var centers: Array[Vector2] = []
	var group_count := maxi(8, settings.continent_count * 2)
	for group_id in range(group_count):
		var center := _choose_separated_position(rng, 0.075, centers, settings, 0.10)
		centers.append(center)
		var angle := rng.randf_range(0.0, TAU)
		var span := rng.randf_range(0.035, 0.09)
		_append_spine(
			nodes, rng, center, angle, span, rng.randi_range(2, 4),
			rng.randf_range(0.012, 0.035), Vector2(0.072, 0.052),
			group_id, true, -0.13
		)
		if group_id < settings.continent_count:
			mountain_seeds.append(_mountain_seed(center, angle, span, group_id))
	_append_island_chains(
		nodes,
		island_rng,
		settings,
		group_count,
		maxi(3, roundi(settings.continent_count * settings.island_frequency * 3.0)),
		0.018,
		0.038
	)
	return {"nodes": nodes, "mountain_seeds": mountain_seeds, "water_nodes": []}


static func _build_fractured(
	rng: RandomNumberGenerator,
	island_rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Dictionary:
	var nodes: Array[Dictionary] = []
	var mountain_seeds: Array[Dictionary] = []
	var centers: Array[Vector2] = []
	var major_count := maxi(3, settings.continent_count - 1)
	for continent_id in range(major_count):
		var center := _choose_separated_position(rng, 0.11, centers, settings, 0.32)
		centers.append(center)
		var angle := rng.randf_range(0.0, TAU)
		var span := rng.randf_range(0.12, 0.20)
		_append_spine(
			nodes, rng, center, angle, span, rng.randi_range(4, 6),
			rng.randf_range(0.040, 0.080), Vector2(0.072, 0.046),
			continent_id, false, -0.06
		)
		if rng.randf() < 0.55:
			var direction := Vector2(cos(angle), sin(angle))
			var branch_center := center + direction * rng.randf_range(-0.06, 0.06)
			_append_spine(
				nodes, rng, branch_center, angle + rng.randf_range(0.8, 1.35),
				span * rng.randf_range(0.28, 0.48), rng.randi_range(2, 3),
				0.025, Vector2(0.058, 0.039), continent_id, false, -0.04
			)
		mountain_seeds.append(_mountain_seed(center, angle, span, continent_id))
	_append_island_chains(
		nodes,
		island_rng,
		settings,
		major_count,
		maxi(6, roundi(5.0 + settings.island_frequency * 14.0)),
		0.016,
		0.040
	)
	return {"nodes": nodes, "mountain_seeds": mountain_seeds, "water_nodes": []}


static func _append_spine(
	nodes: Array[Dictionary],
	rng: RandomNumberGenerator,
	center: Vector2,
	angle: float,
	span: float,
	lobe_count: int,
	curve: float,
	base_radius: Vector2,
	continent_id: int,
	is_island: bool,
	bias: float
) -> void:
	var direction := Vector2(cos(angle), sin(angle))
	var perpendicular := Vector2(-direction.y, direction.x)
	for lobe_index in range(lobe_count):
		var t := (
			0.0
			if lobe_count == 1
			else lerpf(-1.0, 1.0, float(lobe_index) / float(lobe_count - 1))
		)
		var position := (
			center
			+ direction * span * t
			+ perpendicular * sin(t * PI) * curve
			+ Vector2(rng.randf_range(-0.012, 0.012), rng.randf_range(-0.012, 0.012))
		)
		position.x = clampf(position.x, 0.055, 0.945)
		position.y = clampf(position.y, 0.055, 0.945)
		nodes.append({
			"position": position,
			"long_radius": base_radius.x * rng.randf_range(0.82, 1.22),
			"short_radius": base_radius.y * rng.randf_range(0.78, 1.18),
			"angle": angle + rng.randf_range(-0.32, 0.32),
			"continent_id": continent_id,
			"is_island": is_island,
			"bias": bias + rng.randf_range(-0.035, 0.035),
		})


static func _append_island_chains(
	nodes: Array[Dictionary],
	rng: RandomNumberGenerator,
	settings: WorldGenerationSettings,
	first_continent_id: int,
	chain_count: int,
	minimum_radius: float,
	maximum_radius: float
) -> void:
	var island_centers: Array[Vector2] = []
	var shape_offset := rng.randi_range(0, 2)
	for chain_index in range(chain_count):
		var center := _choose_offshore_island_position(
			nodes,
			island_centers,
			rng,
			settings
		)
		island_centers.append(center)
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(minimum_radius, maximum_radius)
		var shape_index := (chain_index + shape_offset) % 3
		var span := rng.randf_range(0.025, 0.075)
		var lobe_count := rng.randi_range(3, 5)
		var curve := rng.randf_range(0.008, 0.030)
		var island_kind := "curved_chain"
		var growth_weight := rng.randf_range(0.85, 1.25)
		if shape_index == 0:
			span = 0.0
			lobe_count = 1
			curve = 0.0
			island_kind = "solitary"
			growth_weight = rng.randf_range(0.22, 0.42)
		elif shape_index == 1:
			span = rng.randf_range(0.010, 0.032)
			lobe_count = rng.randi_range(2, 3)
			curve = rng.randf_range(0.0, 0.014)
			island_kind = "compact_group"
			growth_weight = rng.randf_range(0.48, 0.78)
		var first_node_index := nodes.size()
		_append_spine(
			nodes,
			rng,
			center,
			angle,
			span,
			lobe_count,
			curve,
			Vector2(radius * 1.2, radius),
			first_continent_id + chain_index,
			true,
			-0.20 - settings.island_frequency * 0.20
		)
		for node_index in range(first_node_index, nodes.size()):
			nodes[node_index]["growth_weight"] = growth_weight
			nodes[node_index]["island_kind"] = island_kind


static func _choose_offshore_island_position(
	nodes: Array[Dictionary],
	existing_centers: Array[Vector2],
	rng: RandomNumberGenerator,
	settings: WorldGenerationSettings
) -> Vector2:
	var best_position := Vector2(0.5, 0.5)
	var best_score := -INF
	for attempt in range(48):
		var candidate := Vector2(
			rng.randf_range(0.055, 0.945),
			rng.randf_range(0.07, 0.93)
		)
		var nearest_mainland := INF
		for node in nodes:
			if bool(node["is_island"]):
				continue
			nearest_mainland = minf(
				nearest_mainland,
				_node_score(candidate, node, settings.world_aspect_ratio)
			)
		var nearest_island := INF
		for existing_center in existing_centers:
			var delta := candidate - existing_center
			delta.x *= settings.world_aspect_ratio
			nearest_island = minf(nearest_island, delta.length())
		var edge_clearance := minf(
			minf(candidate.x, 1.0 - candidate.x) * settings.world_aspect_ratio,
			minf(candidate.y, 1.0 - candidate.y)
		)
		var score := minf(nearest_mainland * 0.07, nearest_island * 4.0)
		score = minf(score, edge_clearance * 3.0)
		if score > best_score:
			best_score = score
			best_position = candidate
		if nearest_mainland > 1.8 and nearest_island > 0.10 and edge_clearance > 0.075:
			return candidate
	return best_position


static func _mountain_seed(
	position: Vector2,
	angle: float,
	span: float,
	continent_id: int
) -> Dictionary:
	return {
		"position": position,
		"angle": angle,
		"span": span,
		"continent_id": continent_id,
		"is_island": false,
	}


static func _water_node(
	rng: RandomNumberGenerator,
	position: Vector2,
	angle: float,
	long_radius: float,
	short_radius: float,
	strength: float
) -> Dictionary:
	var direction := Vector2(cos(angle), sin(angle))
	var perpendicular := Vector2(-direction.y, direction.x)
	var lobe_count := rng.randi_range(4, 7)
	var lobes: Array[Dictionary] = []
	var bend_phase := rng.randf_range(0.0, TAU)
	for lobe_index in range(lobe_count):
		var t := (
			0.0
			if lobe_count == 1
			else lerpf(-1.0, 1.0, float(lobe_index) / float(lobe_count - 1))
		)
		var taper := sin((float(lobe_index) + 1.0) / float(lobe_count + 1) * PI)
		var bend := (
			sin(t * PI * rng.randf_range(0.8, 1.8) + bend_phase)
			* short_radius
			* rng.randf_range(0.45, 1.15)
		)
		var lobe_position := (
			position
			+ direction * long_radius * t * rng.randf_range(0.72, 1.08)
			+ perpendicular * bend
		)
		lobes.append({
			"position": lobe_position,
			"angle": angle + rng.randf_range(-0.75, 0.75),
			"long_radius": maxf(
				short_radius * 0.65,
				short_radius * rng.randf_range(0.75, 1.55) * taper
			),
			"short_radius": maxf(
				short_radius * 0.48,
				short_radius * rng.randf_range(0.55, 1.25) * taper
			),
			"bias": rng.randf_range(-0.06, 0.08),
		})
	return {
		"position": position,
		"angle": angle,
		"long_radius": long_radius,
		"short_radius": short_radius,
		"bias": 0.0,
		"strength": strength,
		"lobes": lobes,
		"kind": "irregular_basin",
	}


static func _node_score(
	position: Vector2,
	node: Dictionary,
	world_aspect_ratio: float
) -> float:
	if node.has("lobes"):
		var nearest := INF
		for lobe_value in node["lobes"]:
			nearest = minf(
				nearest,
				_ellipse_score(position, lobe_value, world_aspect_ratio)
			)
		return nearest
	return _ellipse_score(position, node, world_aspect_ratio)


static func _ellipse_score(
	position: Vector2,
	node: Dictionary,
	world_aspect_ratio: float
) -> float:
	var delta := position - Vector2(node["position"])
	delta.x *= world_aspect_ratio
	var angle := -float(node["angle"])
	var rotated := Vector2(
		delta.x * cos(angle) - delta.y * sin(angle),
		delta.x * sin(angle) + delta.y * cos(angle)
	)
	var long_radius := maxf(float(node["long_radius"]), 0.001)
	var short_radius := maxf(float(node["short_radius"]), 0.001)
	return Vector2(rotated.x / long_radius, rotated.y / short_radius).length() + float(node["bias"])


static func _choose_separated_position(
	rng: RandomNumberGenerator,
	margin: float,
	existing_positions: Array[Vector2],
	settings: WorldGenerationSettings,
	target_separation: float
) -> Vector2:
	var best_position := Vector2(
		rng.randf_range(margin, 1.0 - margin),
		rng.randf_range(margin, 1.0 - margin)
	)
	if existing_positions.is_empty():
		return best_position
	var best_distance := -1.0
	for attempt in range(36):
		var candidate := Vector2(
			rng.randf_range(margin, 1.0 - margin),
			rng.randf_range(margin, 1.0 - margin)
		)
		var nearest := INF
		for existing in existing_positions:
			var delta := candidate - existing
			delta.x *= settings.world_aspect_ratio
			nearest = minf(nearest, delta.length())
		if nearest > best_distance:
			best_distance = nearest
			best_position = candidate
		if nearest >= target_separation:
			break
	return best_position


static func _create_noise(
	world_seed: int,
	salt: int,
	frequency: float,
	octaves: int
) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = int(_derived_seed(world_seed, salt))
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.52
	noise.fractal_lacunarity = 2.0
	return noise


static func _build_plate_field(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = _derived_seed(world.seed, COAST_WARP_X_SALT)
	var plate_count := clampi(roundi(sqrt(float(world.tiles.size())) / 6.0), 10, 24)
	var plates: Array[Dictionary] = []
	for plate_id in range(plate_count):
		var angle := rng.randf_range(0.0, TAU)
		plates.append({
			"id": plate_id,
			"position": Vector2(rng.randf_range(0.02, 0.98), rng.randf_range(0.02, 0.98)),
			"velocity": Vector2(cos(angle), sin(angle)) * rng.randf_range(0.55, 1.0),
			"rotation": rng.randf_range(-1.0, 1.0),
		})
	var plate_by_coordinate: Dictionary = {}
	for tile in world.tiles:
		var normalized := _normalized_tile_position(tile, world)
		var nearest_plate := 0
		var nearest_distance := INF
		for plate in plates:
			var delta := normalized - Vector2(plate["position"])
			delta.x *= settings.world_aspect_ratio
			var distance := delta.length_squared()
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_plate = int(plate["id"])
		plate_by_coordinate[tile.coordinate] = nearest_plate
	var boundary_strength: Dictionary = {}
	for tile in world.tiles:
		var plate_id := int(plate_by_coordinate[tile.coordinate])
		var plate: Dictionary = plates[plate_id]
		var strongest := 0.0
		for neighbor in world.valid_neighbors(tile.coordinate):
			var neighbor_plate_id := int(plate_by_coordinate[neighbor.coordinate])
			if neighbor_plate_id == plate_id:
				continue
			var neighbor_plate: Dictionary = plates[neighbor_plate_id]
			var sample_position := (
				_normalized_tile_position(tile, world)
				+ _normalized_tile_position(neighbor, world)
			) * 0.5
			var boundary_direction := (
				Vector2(neighbor_plate["position"]) - Vector2(plate["position"])
			).normalized()
			var relative_velocity := relative_plate_velocity(
				plate,
				neighbor_plate,
				sample_position
			)
			strongest = maxf(
				strongest,
				clampf(relative_velocity.dot(boundary_direction) * 0.5 + 0.5, 0.0, 1.0)
			)
		if strongest > 0.0:
			boundary_strength[tile.coordinate] = strongest
	return {
		"plates": plates,
		"plate_by_coordinate": plate_by_coordinate,
		"boundary_strength": boundary_strength,
	}


static func _grow_from_nodes(
	world: HexWorldData,
	nodes: Array[Dictionary],
	target_count: int,
	style: String,
	plate_field: Dictionary,
	water_nodes: Array,
	coast_noise: FastNoiseLite,
	settings: WorldGenerationSettings
) -> void:
	if target_count <= 0 or nodes.is_empty():
		return
	var nodes_by_owner: Dictionary = {}
	for node in nodes:
		var owner := int(node["continent_id"])
		if not nodes_by_owner.has(owner):
			nodes_by_owner[owner] = []
		(nodes_by_owner[owner] as Array).append(node)
	var owners: Array = nodes_by_owner.keys()
	owners.sort()
	var owner_weights: Dictionary = {}
	var total_weight := 0.0
	for owner in owners:
		var owner_rng := RandomNumberGenerator.new()
		owner_rng.seed = _derived_seed(
			world.seed,
			OWNER_SIZE_SALT + int(owner) * 0x1f123bb5
		)
		var size_factor := lerpf(
			1.0,
			owner_rng.randf_range(0.62, 1.38),
			settings.continent_size_variation
		)
		var owner_nodes: Array = nodes_by_owner[owner]
		var growth_weight := 0.0
		for node_value in owner_nodes:
			growth_weight += float((node_value as Dictionary).get("growth_weight", 1.0))
		growth_weight /= float(owner_nodes.size())
		var weight := sqrt(float(owner_nodes.size())) * size_factor * growth_weight
		owner_weights[owner] = weight
		total_weight += weight
	var owner_quotas: Dictionary = {}
	var assigned_quota := 0
	for owner in owners:
		var quota := floori(float(target_count) * float(owner_weights[owner]) / total_weight)
		owner_quotas[owner] = quota
		assigned_quota += quota
	var remainder := target_count - assigned_quota
	for index in range(remainder):
		var owner: int = owners[index % owners.size()]
		owner_quotas[owner] = int(owner_quotas[owner]) + 1

	var heap: Array[Dictionary] = []
	var best_cost: Dictionary = {}
	var require_offshore_seeds := world.land_tile_count() > 0
	for owner in owners:
		for node_value in nodes_by_owner[owner]:
			var node: Dictionary = node_value
			var coordinate := _seed_coordinate(world, Vector2(node["position"]))
			var minimum_land_distance := 3 if require_offshore_seeds else 0
			if not _is_open_seed(world, coordinate, minimum_land_distance):
				coordinate = _nearest_open_seed(world, coordinate, minimum_land_distance)
			if coordinate == Vector2i(999999, 999999):
				continue
			var entry := {
				"coordinate": coordinate,
				"owner": int(owner),
				"cost": maxf(0.0, float(node["bias"]) + 0.2),
				"axis": Vector2(cos(float(node["angle"])), sin(float(node["angle"]))),
			}
			_push_growth_entry(heap, best_cost, entry)
	var owner_counts: Dictionary = {}
	var claimed := 0
	while not heap.is_empty() and claimed < target_count:
		var current := _heap_pop(heap)
		var coordinate: Vector2i = current["coordinate"]
		var owner := int(current["owner"])
		var cost_key := _growth_cost_key(coordinate, owner)
		if float(current["cost"]) > float(best_cost.get(cost_key, INF)) + 0.000001:
			continue
		var tile := world.tile_at(coordinate)
		if tile == null or not tile.is_water:
			continue
		if int(owner_counts.get(owner, 0)) >= int(owner_quotas[owner]):
			continue
		tile.is_water = false
		tile.continent_id = owner
		tile.terrain_type = &"land"
		owner_counts[owner] = int(owner_counts.get(owner, 0)) + 1
		claimed += 1
		var axis: Vector2 = current["axis"]
		for neighbor in world.valid_neighbors(coordinate):
			if not neighbor.is_water:
				continue
			var step_cost := _growth_step_cost(
				world,
				tile,
				neighbor,
				axis,
				style,
				plate_field,
				water_nodes,
				coast_noise,
				settings
			)
			_push_growth_entry(heap, best_cost, {
				"coordinate": neighbor.coordinate,
				"owner": owner,
				"cost": float(current["cost"]) + step_cost,
				"axis": axis,
			})


static func _growth_step_cost(
	world: HexWorldData,
	from_tile: HexTileData,
	to_tile: HexTileData,
	axis: Vector2,
	style: String,
	plate_field: Dictionary,
	water_nodes: Array,
	coast_noise: FastNoiseLite,
	settings: WorldGenerationSettings
) -> float:
	var step_3d := (to_tile.position - from_tile.position).normalized()
	var step := Vector2(step_3d.x, step_3d.z).normalized()
	var directional_strength := 0.30
	if style == STYLE_FRACTURED:
		directional_strength = 0.58
	elif style == STYLE_ARCHIPELAGO:
		directional_strength = 0.25
	elif style == STYLE_PANGEA:
		directional_strength = 0.28
	elif style == STYLE_CONTINENTS:
		directional_strength = 0.42
	var direction_bonus := absf(step.dot(axis.normalized())) * directional_strength
	var convergence := float(
		(plate_field["boundary_strength"] as Dictionary).get(to_tile.coordinate, 0.0)
	)
	var normalized := _normalized_tile_position(to_tile, world)
	var edge_distance := minf(
		minf(normalized.x, 1.0 - normalized.x),
		minf(normalized.y, 1.0 - normalized.y)
	)
	var edge_cost := smoothstep(0.10, 0.0, edge_distance) * 2.4
	var detail := coast_noise.get_noise_2d(
		float(to_tile.offset_coordinate.x),
		float(to_tile.offset_coordinate.y)
	)
	var water_cost := 0.0
	for water_node_value in water_nodes:
		var water_node: Dictionary = water_node_value
		var distance := _node_score(normalized, water_node, settings.world_aspect_ratio)
		if distance < 1.0:
			water_cost = maxf(
				water_cost,
				(1.0 - smoothstep(0.0, 1.0, distance))
				* float(water_node["strength"])
			)
	var noise_cost := detail * settings.coast_complexity * 0.82
	return maxf(
		0.08,
		1.0 - direction_bonus - convergence * 0.34 + edge_cost + water_cost + noise_cost
	)


static func _fill_remaining_land(
	world: HexWorldData,
	target_count: int,
	style: String,
	plate_field: Dictionary,
	coast_noise: FastNoiseLite,
	settings: WorldGenerationSettings,
	protected_water_nodes: Array = [],
	protect_owner_boundaries := false,
	protected_water_coordinates: Dictionary = {},
	maximum_owner_count := 0
) -> void:
	var land_count := world.land_tile_count()
	if land_count >= target_count:
		return
	var heap: Array[Dictionary] = []
	var queued: Dictionary = {}
	for tile in world.tiles:
		if tile.is_water:
			continue
		for neighbor in world.valid_neighbors(tile.coordinate):
			if not neighbor.is_water or queued.has(neighbor.coordinate):
				continue
			if not _can_fill_tile(
				world,
				neighbor,
				tile.continent_id,
				protected_water_nodes,
				protect_owner_boundaries,
				settings,
				protected_water_coordinates,
				maximum_owner_count
			):
				continue
			var cost := _growth_step_cost(
				world,
				tile,
				neighbor,
				Vector2.RIGHT,
				style,
				plate_field,
				[],
				coast_noise,
				settings
			)
			_heap_push(heap, {
				"coordinate": neighbor.coordinate,
				"owner": tile.continent_id,
				"cost": cost,
				"axis": Vector2.RIGHT,
			})
			queued[neighbor.coordinate] = true
	while not heap.is_empty() and land_count < target_count:
		var current := _heap_pop(heap)
		var tile := world.tile_at(current["coordinate"])
		if tile == null or not tile.is_water:
			continue
		if not _can_fill_tile(
			world,
			tile,
			int(current["owner"]),
			protected_water_nodes,
			protect_owner_boundaries,
			settings,
			protected_water_coordinates,
			maximum_owner_count
		):
			continue
		tile.is_water = false
		tile.continent_id = int(current["owner"])
		tile.terrain_type = &"land"
		land_count += 1
		for neighbor in world.valid_neighbors(tile.coordinate):
			if not neighbor.is_water or queued.has(neighbor.coordinate):
				continue
			if not _can_fill_tile(
				world,
				neighbor,
				tile.continent_id,
				protected_water_nodes,
				protect_owner_boundaries,
				settings,
				protected_water_coordinates,
				maximum_owner_count
			):
				continue
			var cost := float(current["cost"]) + _growth_step_cost(
				world,
				tile,
				neighbor,
				Vector2.RIGHT,
				style,
				plate_field,
				[],
				coast_noise,
				settings
			)
			_heap_push(heap, {
				"coordinate": neighbor.coordinate,
				"owner": tile.continent_id,
				"cost": cost,
				"axis": Vector2.RIGHT,
			})
			queued[neighbor.coordinate] = true


static func _can_fill_tile(
	world: HexWorldData,
	tile: HexTileData,
	owner: int,
	protected_water_nodes: Array,
	protect_owner_boundaries: bool,
	settings: WorldGenerationSettings,
	protected_water_coordinates: Dictionary = {},
	maximum_owner_count := 0
) -> bool:
	if maximum_owner_count > 0 and owner >= maximum_owner_count:
		return false
	if protected_water_coordinates.has(tile.coordinate):
		return false
	var normalized := _normalized_tile_position(tile, world)
	for water_node_value in protected_water_nodes:
		var water_node: Dictionary = water_node_value
		if _node_score(normalized, water_node, settings.world_aspect_ratio) < 0.72:
			return false
	if not protect_owner_boundaries:
		return true
	var neighboring_owners: Dictionary = {}
	for neighbor in world.valid_neighbors(tile.coordinate):
		if not neighbor.is_water:
			neighboring_owners[neighbor.continent_id] = true
	return neighboring_owners.size() == 1 and neighboring_owners.has(owner)


static func relative_plate_velocity(
	plate: Dictionary,
	neighbor_plate: Dictionary,
	sample_position: Vector2
) -> Vector2:
	var plate_offset := sample_position - Vector2(plate["position"])
	var neighbor_offset := sample_position - Vector2(neighbor_plate["position"])
	var plate_velocity := (
		Vector2(plate["velocity"])
		+ Vector2(-plate_offset.y, plate_offset.x) * float(plate["rotation"])
	)
	var neighbor_velocity := (
		Vector2(neighbor_plate["velocity"])
		+ Vector2(-neighbor_offset.y, neighbor_offset.x)
			* float(neighbor_plate["rotation"])
	)
	return plate_velocity - neighbor_velocity


static func _seed_coordinate(world: HexWorldData, normalized: Vector2) -> Vector2i:
	var offset := Vector2i(
		clampi(roundi(normalized.x * float(world.width - 1)), 0, world.width - 1),
		clampi(roundi(normalized.y * float(world.height - 1)), 0, world.height - 1)
	)
	return HexCoordinates.offset_to_axial(offset)


static func _nearest_open_seed(
	world: HexWorldData,
	origin: Vector2i,
	minimum_land_distance := 1
) -> Vector2i:
	if _is_open_seed(world, origin, minimum_land_distance):
		return origin
	for radius in range(1, maxi(world.width, world.height)):
		for coordinate in HexCoordinates.ring(origin, radius):
			if _is_open_seed(world, coordinate, minimum_land_distance):
				return coordinate
	return Vector2i(999999, 999999)


static func _is_open_seed(
	world: HexWorldData,
	coordinate: Vector2i,
	minimum_land_distance: int
) -> bool:
	var tile := world.tile_at(coordinate)
	if tile == null or not tile.is_water:
		return false
	if minimum_land_distance <= 0:
		return true
	for nearby in HexCoordinates.range_coordinates(coordinate, minimum_land_distance):
		var nearby_tile := world.tile_at(nearby)
		if nearby_tile != null and not nearby_tile.is_water:
			return false
	return true


static func _normalized_tile_position(tile: HexTileData, world: HexWorldData) -> Vector2:
	return Vector2(
		(float(tile.offset_coordinate.x) + 0.5) / float(world.width),
		(float(tile.offset_coordinate.y) + 0.5) / float(world.height)
	)


static func _push_growth_entry(
	heap: Array[Dictionary],
	best_cost: Dictionary,
	entry: Dictionary
) -> void:
	var key := _growth_cost_key(entry["coordinate"], int(entry["owner"]))
	var cost := float(entry["cost"])
	if cost >= float(best_cost.get(key, INF)):
		return
	best_cost[key] = cost
	_heap_push(heap, entry)


static func _growth_cost_key(coordinate: Vector2i, owner: int) -> String:
	return "%d:%d:%d" % [owner, coordinate.x, coordinate.y]


static func _heap_push(heap: Array[Dictionary], entry: Dictionary) -> void:
	heap.append(entry)
	var index := heap.size() - 1
	while index > 0:
		var parent := floori(float(index - 1) / 2.0)
		if not _growth_entry_before(heap[index], heap[parent]):
			break
		var swap: Dictionary = heap[parent]
		heap[parent] = heap[index]
		heap[index] = swap
		index = parent


static func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty():
		return result
	heap[0] = last
	var index := 0
	while true:
		var left := index * 2 + 1
		var right := left + 1
		var smallest := index
		if left < heap.size() and _growth_entry_before(heap[left], heap[smallest]):
			smallest = left
		if right < heap.size() and _growth_entry_before(heap[right], heap[smallest]):
			smallest = right
		if smallest == index:
			break
		var swap: Dictionary = heap[index]
		heap[index] = heap[smallest]
		heap[smallest] = swap
		index = smallest
	return result


static func _growth_entry_before(a: Dictionary, b: Dictionary) -> bool:
	var cost_a := float(a["cost"])
	var cost_b := float(b["cost"])
	if not is_equal_approx(cost_a, cost_b):
		return cost_a < cost_b
	var coordinate_a: Vector2i = a["coordinate"]
	var coordinate_b: Vector2i = b["coordinate"]
	if coordinate_a.y != coordinate_b.y:
		return coordinate_a.y < coordinate_b.y
	if coordinate_a.x != coordinate_b.x:
		return coordinate_a.x < coordinate_b.x
	return int(a["owner"]) < int(b["owner"])


static func _erode_coast(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	var exposed_land: Array[HexTileData] = []
	var sheltered_water: Array[HexTileData] = []
	for tile in world.tiles:
		var land_neighbors := 0
		for neighbor in world.valid_neighbors(tile.coordinate):
			if not neighbor.is_water:
				land_neighbors += 1
		if not tile.is_water and land_neighbors <= 3:
			exposed_land.append(tile)
		elif tile.is_water and land_neighbors >= 3:
			sheltered_water.append(tile)
	var swap_count := mini(
		mini(exposed_land.size(), sheltered_water.size()),
		roundi(float(world.tiles.size()) * settings.coast_complexity * 0.026)
	)
	if swap_count <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = _derived_seed(world.seed, COAST_WARP_Y_SALT)
	for index in range(exposed_land.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var swap := exposed_land[index]
		exposed_land[index] = exposed_land[swap_index]
		exposed_land[swap_index] = swap
	for index in range(sheltered_water.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var swap := sheltered_water[index]
		sheltered_water[index] = sheltered_water[swap_index]
		sheltered_water[swap_index] = swap
	for index in range(swap_count):
		var removed := exposed_land[index]
		removed.is_water = true
		removed.continent_id = -1
		removed.terrain_type = &"ocean"
		var added := sheltered_water[index]
		added.is_water = false
		added.continent_id = _nearest_land_continent(world, added)
		added.terrain_type = &"land"
	world.metadata["coast_erosion_swaps"] = swap_count


static func _carve_owner_boundaries(
	world: HexWorldData,
	principal_corridor_radius := 0,
	principal_owner_count := 0
) -> Dictionary:
	var carve: Dictionary = {}
	for tile in world.tiles:
		if tile.is_water:
			continue
		for neighbor in world.valid_neighbors(tile.coordinate):
			if neighbor.is_water or neighbor.continent_id == tile.continent_id:
				continue
			var remove_tile := tile
			if (
				neighbor.continent_id > tile.continent_id
				or (
					neighbor.continent_id == tile.continent_id
					and neighbor.coordinate.y > tile.coordinate.y
				)
			):
				remove_tile = neighbor
			var radius := (
				principal_corridor_radius
				if tile.continent_id < principal_owner_count
					and neighbor.continent_id < principal_owner_count
				else 0
			)
			for coordinate in HexCoordinates.range_coordinates(remove_tile.coordinate, radius):
				if world.has_coordinate(coordinate):
					carve[coordinate] = true
	for coordinate in carve:
		var tile := world.tile_at(coordinate)
		tile.is_water = true
		tile.continent_id = -1
		tile.terrain_type = &"ocean"
	world.metadata["carved_boundary_tiles"] = carve.size()
	return carve


static func _apply_water_cuts(
	world: HexWorldData,
	water_nodes: Array,
	settings: WorldGenerationSettings
) -> void:
	var carved := 0
	for tile in world.tiles:
		if tile.is_water:
			continue
		var normalized := _normalized_tile_position(tile, world)
		for water_node_value in water_nodes:
			var water_node: Dictionary = water_node_value
			if _node_score(normalized, water_node, settings.world_aspect_ratio) >= 0.72:
				continue
			tile.is_water = true
			tile.continent_id = -1
			tile.terrain_type = &"ocean"
			carved += 1
			break
	world.metadata["carved_pangea_water_tiles"] = carved


static func _smooth_mask(world: HexWorldData, target_land_tiles: int) -> void:
	var changes: Dictionary = {}
	for tile in world.tiles:
		var land_neighbors := 0
		var valid_neighbors := world.valid_neighbors(tile.coordinate)
		for neighbor in valid_neighbors:
			if not neighbor.is_water:
				land_neighbors += 1
		if not tile.is_water and land_neighbors <= 1:
			changes[tile.coordinate] = true
		elif tile.is_water and valid_neighbors.size() == 6 and land_neighbors >= 5:
			changes[tile.coordinate] = false
	for coordinate in changes:
		var tile := world.tile_at(coordinate)
		tile.is_water = bool(changes[coordinate])
		tile.continent_id = -1 if tile.is_water else _nearest_land_continent(world, tile)
		tile.terrain_type = &"ocean" if tile.is_water else &"land"
	world.metadata["smoothed_land_delta"] = world.land_tile_count() - target_land_tiles


static func _nearest_land_continent(world: HexWorldData, tile: HexTileData) -> int:
	for neighbor in world.valid_neighbors(tile.coordinate):
		if not neighbor.is_water and neighbor.continent_id >= 0:
			return neighbor.continent_id
	return 0


static func _derived_seed(world_seed: int, salt: int) -> int:
	var value := world_seed ^ salt
	value = int((value ^ (value >> 16)) * 0x45d9f3b)
	value = int((value ^ (value >> 16)) * 0x45d9f3b)
	return value ^ (value >> 16)
