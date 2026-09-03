class_name HexUnderwaterEcologyRenderer
extends RefCounted

## Deterministic batched seaweed for the continuous submerged terrain.
##
## Placement is derived from the campaign seed, tile coordinate, and dedicated
## render-only salts. It never consumes a generation RNG stream or changes
## logical water data. One MultiMesh per populated chunk keeps the decorative
## layer bounded on every map tier.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const TerrainMesher = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")
const SeaweedShader = preload("res://src/world3d/rendering/hex_seaweed.gdshader")
const SeaweedSourceMesh = preload("res://assets/world3d/seaweed/Seaweed.obj")
const SeaweedAlbedoTexture = preload("res://assets/world3d/seaweed/Seaweed_B.png")
const SeaweedNormalTexture = preload("res://assets/world3d/seaweed/Seaweed_N.png")
const SeaweedRoughnessTexture = preload("res://assets/world3d/seaweed/Seaweed_R.png")

const PLACEMENT_SALT := 0x5357504c
const SCALE_SALT := 0x53575343
const ROTATION_SALT := 0x53575254
const TINT_SALT := 0x5357544e
const PHASE_SALT := 0x53575048
const PATCH_SALT := 0x53575042
const PATCH_DETAIL_SALT := 0x53575044
const SUBSTRATE_SALT := 0x53575342
const EXPOSURE_SALT := 0x53574558
const DISTURBANCE_SALT := 0x53574449
const RECRUITMENT_SALT := 0x53575243
const PIONEER_SALT := 0x53575049

const MINIMUM_WATER_DEPTH := 0.40
const MAXIMUM_WATER_DEPTH := 1.20
const CANDIDATES_PER_TILE := 96
const PLACEMENT_RADIUS := 0.82
const SOURCE_MESH_HEIGHT := 2.80
const SOURCE_MESH_RADIUS := 1.05
const MINIMUM_RENDERED_HEIGHT := 0.30
const MAXIMUM_RENDERED_HEIGHT := 0.92
const MAXIMUM_RENDERED_RADIUS := 0.38

static var _mesh: ArrayMesh
static var _material: ShaderMaterial


static func build_chunk_instances(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i
) -> Array:
	var instances: Array = []
	if settings.seaweed_density <= 0.0:
		return instances
	var start_column := chunk_coordinate.x * settings.chunk_size
	var start_row := chunk_coordinate.y * settings.chunk_size
	var end_column := mini(start_column + settings.chunk_size, world.width)
	var end_row := mini(start_row + settings.chunk_size, world.height)
	var surface_height_cache: Dictionary = {}
	var surface_profile_cache: Dictionary = {}
	var coastal_affinity_cache: Dictionary = {}
	var tile_habitat_cache: Dictionary = {}
	var colony_tiles: Array = []
	var pioneer_tiles: Array = []
	for row in range(start_row, end_row):
		for column in range(start_column, end_column):
			var tile := world.tile_at_offset(column, row)
			if tile == null or not tile.is_ocean:
				continue
			var water_depth := TerrainMesher.water_depth_at_tile(
				world,
				tile,
				settings,
				surface_height_cache
			)
			if not is_eligible_depth(water_depth):
				continue
			var coastal_affinity := _coastal_affinity(
				world,
				tile,
				coastal_affinity_cache
			)
			var habitat_profile := _tile_habitat_profile(
				world.seed,
				tile,
				settings.hex_size,
				water_depth,
				coastal_affinity,
				tile_habitat_cache
			)
			var surface_profile := _submerged_surface_profile(
				world,
				tile,
				settings,
				surface_height_cache,
				surface_profile_cache
			)
			if _profile_supports_colony(habitat_profile):
				colony_tiles.append({
					"tile": tile,
					"water_depth": water_depth,
					"habitat_profile": habitat_profile,
					"surface_profile": surface_profile,
				})
				continue
			var pioneer_clump := _pioneer_clump(
				world.seed,
				tile,
				settings,
				water_depth,
				coastal_affinity
			)
			if not pioneer_clump.is_empty():
				pioneer_clump["tile"] = tile
				pioneer_clump["water_depth"] = water_depth
				pioneer_clump["surface_profile"] = surface_profile
				pioneer_tiles.append(pioneer_clump)
	for pass_index in range(CANDIDATES_PER_TILE):
		for colony_tile_value in colony_tiles:
			var colony_tile: Dictionary = colony_tile_value
			var instance := _candidate_instance_data_for_habitat(
				world,
				colony_tile["tile"] as HexTileData,
				settings,
				pass_index,
				float(colony_tile["water_depth"]),
				colony_tile["habitat_profile"] as PackedFloat32Array,
				colony_tile["surface_profile"] as PackedVector3Array
			)
			if not instance.is_empty():
				instances.append(instance)
	for pioneer_tile_value in pioneer_tiles:
		var pioneer_tile: Dictionary = pioneer_tile_value
		for member_index in range(int(pioneer_tile["count"])):
			instances.append(_pioneer_instance_data(
				world,
				pioneer_tile["tile"] as HexTileData,
				settings,
				member_index,
				float(pioneer_tile["strength"]),
				float(pioneer_tile["water_depth"]),
				pioneer_tile["surface_profile"] as PackedVector3Array
			))
	return instances


static func build_chunk_multimesh(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i
) -> MultiMesh:
	var instances := build_chunk_instances(world, settings, chunk_coordinate)
	if instances.is_empty():
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = seaweed_mesh()
	multimesh.instance_count = instances.size()
	for index in range(instances.size()):
		var instance: Dictionary = instances[index]
		multimesh.set_instance_transform(index, instance["transform"])
		multimesh.set_instance_custom_data(index, instance["custom_data"])
	var minimum_visible_instances := 0
	for instance in instances:
		if int(instance["pass_index"]) == 0:
			minimum_visible_instances += 1
	multimesh.set_meta("minimum_visible_instance_count", minimum_visible_instances)
	multimesh.visible_instance_count = instances.size()
	return multimesh


static func is_eligible_depth(water_depth: float) -> bool:
	return water_depth >= MINIMUM_WATER_DEPTH and water_depth <= MAXIMUM_WATER_DEPTH


static func visible_instance_count(
	total_instances: int,
	detail_factor: float,
	minimum_visible_instances := 1
) -> int:
	if total_instances <= 0:
		return 0
	return clampi(
		maxi(
			ceili(float(total_instances) * clampf(detail_factor, 0.0, 1.0)),
			minimum_visible_instances
		),
		clampi(minimum_visible_instances, 1, total_instances),
		total_instances
	)


static func select_deterministic_subject(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> HexTileData:
	if world == null or settings == null:
		return null
	if settings.seaweed_density <= 0.0:
		return null
	var surface_height_cache: Dictionary = {}
	var surface_profile_cache: Dictionary = {}
	var coastal_affinity_cache: Dictionary = {}
	var tile_habitat_cache: Dictionary = {}
	var best: HexTileData = null
	var best_score := -INF
	for tile in world.tiles:
		if not tile.is_ocean:
			continue
		var accepted := 0
		var habitat_total := 0.0
		for candidate_index in range(CANDIDATES_PER_TILE):
			var instance := _candidate_instance_data(
				world,
				tile,
				settings,
				candidate_index,
				surface_height_cache,
				coastal_affinity_cache,
				tile_habitat_cache,
				surface_profile_cache
			)
			if instance.is_empty():
				continue
			accepted += 1
			habitat_total += float(instance["habitat_strength"])
		var score := habitat_total + float(accepted) * 0.5
		if accepted > 0 and score > best_score:
			best_score = score
			best = tile
	return best


static func instance_budget_report(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	detail_factor := 1.0
) -> Dictionary:
	var chunk_columns := ceili(float(world.width) / float(settings.chunk_size))
	var chunk_rows := ceili(float(world.height) / float(settings.chunk_size))
	var total := 0
	var visible_total := 0
	var node_count := 0
	var pioneer_total := 0
	var pioneer_clumps: Dictionary = {}
	for chunk_y in range(chunk_rows):
		for chunk_x in range(chunk_columns):
			var instances := build_chunk_instances(
				world,
				settings,
				Vector2i(chunk_x, chunk_y)
			)
			if instances.is_empty():
				continue
			node_count += 1
			total += instances.size()
			var minimum_visible_instances := 0
			for instance in instances:
				if int(instance["pass_index"]) == 0:
					minimum_visible_instances += 1
				if instance.get("placement_kind", &"colony") == &"pioneer":
					pioneer_total += 1
					pioneer_clumps[instance["pioneer_clump_coordinate"]] = true
			visible_total += visible_instance_count(
				instances.size(),
				detail_factor,
				minimum_visible_instances
			)
	return {
		"underwater_instance_count": total,
		"underwater_visible_instance_count": visible_total,
		"underwater_multimesh_node_count": node_count,
		"underwater_instance_buffer_bytes": total * 64,
		"underwater_pioneer_instance_count": pioneer_total,
		"underwater_pioneer_clump_count": pioneer_clumps.size(),
	}


static func seaweed_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	_mesh = SeaweedSourceMesh.duplicate(true) as ArrayMesh
	if _mesh == null:
		push_error("Could not duplicate the imported seaweed mesh.")
		return null
	for surface_index in range(_mesh.get_surface_count()):
		_mesh.surface_set_material(surface_index, seaweed_material())
	return _mesh


static func seaweed_material() -> ShaderMaterial:
	if _material != null:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = SeaweedShader
	_material.set_shader_parameter("albedo_sampler", SeaweedAlbedoTexture)
	_material.set_shader_parameter("normal_sampler", SeaweedNormalTexture)
	_material.set_shader_parameter("roughness_sampler", SeaweedRoughnessTexture)
	return _material


static func _candidate_instance_data(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	instance_index: int,
	surface_height_cache: Dictionary,
	coastal_affinity_cache: Dictionary,
	tile_habitat_cache: Dictionary,
	surface_profile_cache: Dictionary
) -> Dictionary:
	var water_depth := TerrainMesher.water_depth_at_tile(
		world,
		tile,
		settings,
		surface_height_cache
	)
	if not is_eligible_depth(water_depth):
		return {}
	var coastal_affinity := _coastal_affinity(world, tile, coastal_affinity_cache)
	var habitat_profile := _tile_habitat_profile(
		world.seed,
		tile,
		settings.hex_size,
		water_depth,
		coastal_affinity,
		tile_habitat_cache
	)
	if not _profile_supports_colony(habitat_profile):
		return {}
	return _candidate_instance_data_for_habitat(
		world,
		tile,
		settings,
		instance_index,
		water_depth,
		habitat_profile,
		_submerged_surface_profile(
			world,
			tile,
			settings,
			surface_height_cache,
			surface_profile_cache
		)
	)


static func _candidate_instance_data_for_habitat(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	instance_index: int,
	water_depth: float,
	habitat_profile: PackedFloat32Array,
	surface_profile: PackedVector3Array
) -> Dictionary:
	var hash_coordinate := Vector2i(
		tile.coordinate.x * 97 + instance_index * 17,
		tile.coordinate.y * 193 - instance_index * 29
	)
	var radius_unit := _instance_hash_unit(
		world.seed,
		PLACEMENT_SALT,
		hash_coordinate
	)
	var angle_unit := _instance_hash_unit(
		world.seed,
		ROTATION_SALT,
		hash_coordinate
	)
	var angle := angle_unit * TAU
	var radial_distance := settings.hex_size * PLACEMENT_RADIUS * sqrt(radius_unit)
	var origin := Vector3(
		tile.position.x + cos(angle) * radial_distance,
		0.0,
		tile.position.z + sin(angle) * radial_distance
	)
	var habitat_strength := _interpolated_habitat_strength(
		habitat_profile,
		angle_unit,
		sqrt(radius_unit)
	)
	if habitat_strength <= 0.0:
		return {}
	var colony_density := lerpf(
		0.18,
		0.96,
		_smoothstep(0.08, 0.82, habitat_strength)
	)
	var survival_chance := clampf(
		settings.seaweed_density * colony_density,
		0.0,
		0.98
	)
	if (
		_instance_hash_unit(
			world.seed,
			PLACEMENT_SALT + 86028121,
			hash_coordinate
		)
		>= survival_chance
	):
		return {}
	return _rendered_instance_data(
		world,
		tile,
		settings,
		hash_coordinate,
		instance_index,
		origin,
		angle,
		angle + float(instance_index) * 1.7,
		water_depth,
		habitat_strength,
		surface_profile,
		&"colony"
	)


static func _pioneer_instance_data(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	member_index: int,
	habitat_strength: float,
	water_depth: float,
	surface_profile: PackedVector3Array
) -> Dictionary:
	var tile_hash_coordinate := Vector2i(
		tile.coordinate.x * 131,
		tile.coordinate.y * 197
	)
	var center_angle := _instance_hash_unit(
		world.seed,
		PIONEER_SALT,
		tile_hash_coordinate
	) * TAU
	var center_radius := (
		settings.hex_size
		* 0.48
		* sqrt(_instance_hash_unit(
			world.seed,
			PIONEER_SALT + 32452843,
			tile_hash_coordinate
		))
	)
	var member_hash_coordinate := Vector2i(
		tile_hash_coordinate.x + member_index * 43,
		tile_hash_coordinate.y - member_index * 71
	)
	var scatter_angle := _instance_hash_unit(
		world.seed,
		PIONEER_SALT + 49979687,
		member_hash_coordinate
	) * TAU
	var scatter_radius := (
		settings.hex_size
		* 0.16
		* sqrt(_instance_hash_unit(
			world.seed,
			PIONEER_SALT + 67867967,
			member_hash_coordinate
		))
	)
	var offset := Vector2(
		cos(center_angle) * center_radius + cos(scatter_angle) * scatter_radius,
		sin(center_angle) * center_radius + sin(scatter_angle) * scatter_radius
	)
	var maximum_radius := settings.hex_size * PLACEMENT_RADIUS
	if offset.length() > maximum_radius:
		offset = offset.normalized() * maximum_radius
	var origin := Vector3(
		tile.position.x + offset.x,
		0.0,
		tile.position.z + offset.y
	)
	var root_angle := atan2(offset.y, offset.x)
	var orientation := _instance_hash_unit(
		world.seed,
		ROTATION_SALT,
		member_hash_coordinate
	) * TAU
	var instance := _rendered_instance_data(
		world,
		tile,
		settings,
		member_hash_coordinate,
		0,
		origin,
		root_angle,
		orientation,
		water_depth,
		habitat_strength,
		surface_profile,
		&"pioneer"
	)
	instance["pioneer_clump_coordinate"] = tile.coordinate
	return instance


static func _rendered_instance_data(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	hash_coordinate: Vector2i,
	pass_index: int,
	origin: Vector3,
	root_angle: float,
	orientation: float,
	water_depth: float,
	habitat_strength: float,
	surface_profile: PackedVector3Array,
	placement_kind: StringName
) -> Dictionary:
	var scale_unit := _instance_hash_unit(
		world.seed,
		SCALE_SALT,
		hash_coordinate
	)
	var width_unit := _instance_hash_unit(
		world.seed,
		SCALE_SALT + 32452843,
		hash_coordinate
	)
	origin.y = _submerged_height_at_position(
		origin,
		root_angle,
		surface_profile
	) + 0.01
	# Skew toward younger, shorter plants while retaining occasional mature
	# specimens. A separate width draw prevents every tall plant from also
	# becoming proportionally broad.
	var age := pow(scale_unit, 0.88)
	var available_height := water_depth * 0.88
	var minimum_height := minf(
		settings.hex_size * MINIMUM_RENDERED_HEIGHT,
		available_height * 0.62
	)
	var rendered_height := clampf(
		water_depth * lerpf(0.42, 0.86, age),
		minimum_height,
		settings.hex_size * MAXIMUM_RENDERED_HEIGHT
	)
	rendered_height = minf(rendered_height, available_height)
	var vertical_scale := rendered_height / SOURCE_MESH_HEIGHT
	var lateral_scale := minf(
		vertical_scale * lerpf(0.70, 1.35, width_unit),
		settings.hex_size * MAXIMUM_RENDERED_RADIUS / SOURCE_MESH_RADIUS
	)
	var basis := Basis(Vector3.UP, orientation).scaled(
		Vector3(lateral_scale, vertical_scale, lateral_scale)
	)
	var tint_unit := _instance_hash_unit(
		world.seed,
		TINT_SALT,
		hash_coordinate
	)
	var phase := _instance_hash_unit(
		world.seed,
		PHASE_SALT,
		hash_coordinate
	)
	var tint := Color(1.08, 1.18, 0.88).lerp(
		Color(0.78, 1.08, 0.92),
		tint_unit
	)
	return {
		"transform": Transform3D(basis, origin),
		"custom_data": Color(tint.r, tint.g, tint.b, phase),
		"tile_coordinate": tile.coordinate,
		"tile_offset_coordinate": tile.offset_coordinate,
		"water_depth": water_depth,
		"habitat_strength": habitat_strength,
		"pass_index": pass_index,
		"placement_kind": placement_kind,
	}


static func _continuous_habitat_strength(
	seed: int,
	world_position: Vector3,
	hex_size: float,
	water_depth: float,
	coastal_affinity: float
) -> float:
	var point := Vector2(world_position.x, world_position.z) / maxf(hex_size, 0.001)
	var substrate := (
		_value_noise(seed, SUBSTRATE_SALT, point * 0.085) * 0.68
		+ _value_noise(
			seed,
			SUBSTRATE_SALT + 32452843,
			point * 0.24 + Vector2(-31.7, 12.4)
		) * 0.32
	)
	var recruitment := (
		_value_noise(
			seed,
			RECRUITMENT_SALT,
			point * 0.065 + Vector2(17.3, -9.1)
		) * 0.72
		+ _value_noise(
			seed,
			RECRUITMENT_SALT + 49979687,
			point * 0.19 + Vector2(-8.7, 29.6)
		) * 0.28
	)
	var exposure := _value_noise(
		seed,
		EXPOSURE_SALT,
		point * 0.055 + Vector2(8.6, 43.2)
	)
	var disturbance := (
		_value_noise(
			seed,
			DISTURBANCE_SALT,
			point * 0.075 + Vector2(41.2, -18.5)
		) * 0.66
		+ _value_noise(
			seed,
			DISTURBANCE_SALT + 67867967,
			point * 0.22 + Vector2(-22.1, -37.4)
		) * 0.34
	)
	var domain_warp := Vector2(
		_value_noise(
			seed,
			PATCH_SALT + 15485863,
			point * 0.047 + Vector2(6.4, -21.7)
		),
		_value_noise(
			seed,
			PATCH_SALT + 32452843,
			point * 0.047 + Vector2(-33.8, 11.2)
		)
	) - Vector2(0.5, 0.5)
	var warped_point := point + domain_warp * 6.8
	var colony_field := (
		_value_noise(
			seed,
			PATCH_SALT,
			warped_point * 0.105 + Vector2(23.1, -14.7)
		) * 0.68
		+ _value_noise(
			seed,
			PATCH_SALT + 49979687,
			warped_point * 0.27 + Vector2(-7.9, 34.6)
		) * 0.32
	)
	var island_gate := (
		_value_noise(
			seed,
			PATCH_SALT + 67867967,
			warped_point * 0.135 + Vector2(-28.4, -5.3)
		) * 0.74
		+ _value_noise(
			seed,
			PATCH_SALT + 86028121,
			warped_point * 0.34 + Vector2(15.8, 22.9)
		) * 0.26
	)
	var edge_detail := (
		_value_noise(
			seed,
			PATCH_DETAIL_SALT,
			point * 0.31 + Vector2(13.9, 7.2)
		) * 0.62
		+ _value_noise(
			seed,
			PATCH_DETAIL_SALT + 86028121,
			point * 0.57 + Vector2(-19.4, 26.8)
		) * 0.38
	)
	var shelter := clampf(1.0 - absf(exposure - 0.42) * 1.65, 0.0, 1.0)
	var depth_suitability := clampf(
		1.0 - absf(water_depth - 0.68) / 0.72,
		0.0,
		1.0
	)
	var coast_habitat := coastal_affinity * 0.72 + depth_suitability * 0.28
	# Kelp islands form only where attachment habitat and local recruitment
	# overlap. Taking the weaker factor prevents either broad field from
	# turning the full shallow sea into one continuous meadow.
	var ecological_overlap := minf(substrate, recruitment)
	var patch_overlap := minf(colony_field, island_gate)
	var base_habitat := (
		patch_overlap * 0.54
		+ ecological_overlap * 0.22
		+ shelter * 0.08
		+ coast_habitat * 0.16
	)
	var barren_gap := _smoothstep(0.68, 0.82, disturbance)
	var colony_signal := (
		base_habitat
		+ (edge_detail - 0.5) * 0.16
		- barren_gap * 0.52
	)
	var colony_mask := _smoothstep(0.49, 0.57, colony_signal)
	var interior_density := lerpf(
		0.32,
		1.0,
		_smoothstep(0.18, 0.82, edge_detail)
	)
	return colony_mask * interior_density


static func _pioneer_clump(
	seed: int,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	water_depth: float,
	coastal_affinity: float
) -> Dictionary:
	var point := Vector2(tile.position.x, tile.position.z) / maxf(
		settings.hex_size,
		0.001
	)
	var substrate := _value_noise(
		seed,
		SUBSTRATE_SALT + 104729,
		point * 0.11 + Vector2(12.8, -4.7)
	)
	var recruitment := _value_noise(
		seed,
		RECRUITMENT_SALT + 130363,
		point * 0.09 + Vector2(-6.3, 18.1)
	)
	var depth_suitability := clampf(
		1.0 - absf(water_depth - 0.76) / 0.52,
		0.0,
		1.0
	)
	var suitability := (
		substrate * 0.36
		+ recruitment * 0.34
		+ coastal_affinity * 0.20
		+ depth_suitability * 0.10
	)
	var chance := clampf(
		settings.seaweed_density
			* lerpf(0.04, 0.18, _smoothstep(0.30, 0.76, suitability)),
		0.0,
		0.24
	)
	var coordinate := Vector2i(tile.coordinate.x * 149, tile.coordinate.y * 211)
	if _instance_hash_unit(seed, PIONEER_SALT + 86028121, coordinate) >= chance:
		return {}
	var size_unit := _instance_hash_unit(
		seed,
		PIONEER_SALT + 15485863,
		coordinate
	)
	return {
		"count": 2 + mini(floori(size_unit * 3.0), 2),
		"strength": lerpf(0.18, 0.42, suitability),
	}


static func _tile_habitat_profile(
	seed: int,
	tile: HexTileData,
	hex_size: float,
	water_depth: float,
	coastal_affinity: float,
	cache: Dictionary
) -> PackedFloat32Array:
	if cache.has(tile.coordinate):
		return cache[tile.coordinate] as PackedFloat32Array
	var probe_radius := hex_size * PLACEMENT_RADIUS
	var profile := PackedFloat32Array()
	profile.append(_continuous_habitat_strength(
		seed,
		tile.position,
		hex_size,
		water_depth,
		coastal_affinity
	))
	for direction in range(4):
		var angle := TAU * (float(direction) / 4.0 + 0.125)
		var probe_position := tile.position + Vector3(
			cos(angle) * probe_radius,
			0.0,
			sin(angle) * probe_radius
		)
		profile.append(_continuous_habitat_strength(
			seed,
			probe_position,
			hex_size,
			water_depth,
			coastal_affinity
		))
	cache[tile.coordinate] = profile
	return profile


static func _profile_supports_colony(profile: PackedFloat32Array) -> bool:
	for strength in profile:
		if strength > 0.01:
			return true
	return false


static func _interpolated_habitat_strength(
	profile: PackedFloat32Array,
	angle_unit: float,
	radius_unit: float
) -> float:
	if profile.size() < 5:
		return 0.0
	var sector := fposmod(angle_unit - 0.125, 1.0) * 4.0
	var first_direction := floori(sector)
	var second_direction := (first_direction + 1) % 4
	var direction_fraction := sector - float(first_direction)
	direction_fraction = direction_fraction * direction_fraction * (
		3.0 - 2.0 * direction_fraction
	)
	var edge_strength := lerpf(
		profile[first_direction + 1],
		profile[second_direction + 1],
		direction_fraction
	)
	return lerpf(profile[0], edge_strength, clampf(radius_unit, 0.0, 1.0))


static func _submerged_surface_profile(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	surface_height_cache: Dictionary,
	cache: Dictionary
) -> PackedVector3Array:
	if cache.has(tile.coordinate):
		return cache[tile.coordinate] as PackedVector3Array
	var profile := PackedVector3Array()
	profile.append(
		tile.position + Vector3.UP * TerrainMesher.submerged_surface_height(
			world,
			tile,
			settings,
			surface_height_cache
		)
	)
	for corner_index in range(6):
		profile.append(TerrainMesher.submerged_corner_position(
			world,
			tile,
			corner_index,
			settings,
			surface_height_cache
		))
	cache[tile.coordinate] = profile
	return profile


static func _submerged_height_at_position(
	world_position: Vector3,
	angle: float,
	profile: PackedVector3Array
) -> float:
	if profile.size() < 7:
		return world_position.y
	var first_corner := floori(fposmod(angle - PI / 6.0, TAU) / (PI / 3.0))
	var second_corner := (first_corner + 1) % 6
	var center := profile[0]
	var first := profile[first_corner + 1]
	var second := profile[second_corner + 1]
	var point := Vector2(world_position.x, world_position.z)
	var a := Vector2(center.x, center.z)
	var b := Vector2(first.x, first.z)
	var c := Vector2(second.x, second.z)
	var denominator := (
		(b.y - c.y) * (a.x - c.x)
		+ (c.x - b.x) * (a.y - c.y)
	)
	if absf(denominator) <= 0.000001:
		return center.y
	var center_weight := (
		(b.y - c.y) * (point.x - c.x)
		+ (c.x - b.x) * (point.y - c.y)
	) / denominator
	var first_weight := (
		(c.y - a.y) * (point.x - c.x)
		+ (a.x - c.x) * (point.y - c.y)
	) / denominator
	var second_weight := 1.0 - center_weight - first_weight
	return (
		center.y * center_weight
		+ first.y * first_weight
		+ second.y * second_weight
	)


static func _coastal_affinity(
	world: HexWorldData,
	tile: HexTileData,
	cache: Dictionary
) -> float:
	if cache.has(tile.coordinate):
		return float(cache[tile.coordinate])
	var affinity := 0.08
	var affinity_by_distance := [0.0, 0.72, 1.0, 0.76, 0.38]
	for radius in range(1, affinity_by_distance.size()):
		var found_land := false
		for coordinate in HexCoordinatesScript.ring(tile.coordinate, radius):
			var neighbor := world.tile_at(coordinate)
			if neighbor != null and not neighbor.is_water:
				found_land = true
				break
		if found_land:
			affinity = float(affinity_by_distance[radius])
			break
	cache[tile.coordinate] = affinity
	return affinity


static func _value_noise(seed: int, salt: int, point: Vector2) -> float:
	var cell := Vector2i(floori(point.x), floori(point.y))
	var fraction := Vector2(point.x - float(cell.x), point.y - float(cell.y))
	fraction = Vector2(
		fraction.x * fraction.x * (3.0 - 2.0 * fraction.x),
		fraction.y * fraction.y * (3.0 - 2.0 * fraction.y)
	)
	var a := _hash_unit(seed, salt, cell)
	var b := _hash_unit(seed, salt, cell + Vector2i.RIGHT)
	var c := _hash_unit(seed, salt, cell + Vector2i.DOWN)
	var d := _hash_unit(seed, salt, cell + Vector2i.ONE)
	return lerpf(
		lerpf(a, b, fraction.x),
		lerpf(c, d, fraction.x),
		fraction.y
	)


static func _smoothstep(edge_start: float, edge_end: float, value: float) -> float:
	var unit := clampf(
		(value - edge_start) / maxf(edge_end - edge_start, 0.0001),
		0.0,
		1.0
	)
	return unit * unit * (3.0 - 2.0 * unit)


static func _hash_unit(seed: int, salt: int, coordinate: Vector2i) -> float:
	var value := int(hash("%d:%d:%d:%d" % [seed, salt, coordinate.x, coordinate.y]))
	return float(posmod(value, 1000003)) / 1000002.0


static func _instance_hash_unit(
	seed: int,
	salt: int,
	coordinate: Vector2i
) -> float:
	var value := (
		seed
		^ salt
		^ coordinate.x * 374761393
		^ coordinate.y * 668265263
	) & 0x7fffffff
	value = ((value ^ (value >> 16)) * 73244475) & 0x7fffffff
	value = ((value ^ (value >> 16)) * 73244475) & 0x7fffffff
	value = (value ^ (value >> 16)) & 0x7fffffff
	return float(value) / 2147483647.0
