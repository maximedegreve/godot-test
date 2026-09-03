class_name HexHydrologyMesher
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const TerrainMesher = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")
const OceanShader = preload("res://src/world3d/rendering/hex_ocean.gdshader")
const WaterUvTexture = preload("res://assets/world3d/water/Water_UV.png")
const WaterNormalATexture = preload("res://assets/world3d/water/Water_N_A.png")
const WaterNormalBTexture = preload("res://assets/world3d/water/Water_N_B.png")
const WaterFoamTexture = preload("res://assets/world3d/water/Foam.png")
const WaterCausticTexture = preload("res://assets/world3d/water/Caustic.png")
const MEANDER_SALT := 0x33484d45
const FLATLAND_RAW_SLOPE_MAXIMUM := 0.20
const FLATLAND_EFFECTIVE_SLOPE_MAXIMUM := 0.20
const STRAIGHT_FLATLAND_DEVIATION_THRESHOLD := 0.055
const MAXIMUM_MEANDER_CONTROL_OFFSET := 0.24
const MAXIMUM_JUNCTION_OFFSET := 0.28
const MAXIMUM_EDGE_CROSSING_OFFSET := 0.30
const MEANDER_PHASE_STEP := 0.32
const DIAGNOSTIC_EDGE_COLOR := Color("#30b8e7")
const DIAGNOSTIC_ERROR_COLOR := Color("#ff365f")
const DIAGNOSTIC_SOURCE_COLOR := Color("#ffe168")
const DIAGNOSTIC_CONFLUENCE_COLOR := Color("#6ef0a8")
const DIAGNOSTIC_DIRECTION_COLOR := Color("#d9f8ff")
const DIAGNOSTIC_SHARP_TURN_COLOR := Color("#ff9a4a")
const LAKE_HEIGHT_CACHE_KEY := "_hydrology_lake_height_cache"
const RIVER_HEIGHT_CACHE_KEY := "_hydrology_river_height_cache"
const HEIGHT_CACHE_SIGNATURE_KEY := "_hydrology_height_cache_signature"


static func build_chunk(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i
) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var start_column := chunk_coordinate.x * settings.chunk_size
	var start_row := chunk_coordinate.y * settings.chunk_size
	var end_column := mini(start_column + settings.chunk_size, world.width)
	var end_row := mini(start_row + settings.chunk_size, world.height)
	var lake_vertices := PackedVector3Array()
	var lake_normals := PackedVector3Array()
	var lake_uvs := PackedVector2Array()
	var lake_indices := PackedInt32Array()
	var river_vertices := PackedVector3Array()
	var river_normals := PackedVector3Array()
	var river_indices := PackedInt32Array()
	var lake_heights := _lake_surface_heights(world, settings)
	var river_heights := _river_visual_heights(world, settings, lake_heights)
	for row in range(start_row, end_row):
		for column in range(start_column, end_column):
			var tile := world.tile_at_offset(column, row)
			if tile == null:
				continue
			if tile.lake_id >= 0:
				_append_lake_tile(
					world,
					tile,
					settings,
					lake_heights,
					lake_vertices,
					lake_normals,
					lake_uvs,
					lake_indices
				)
			if tile.flow_direction >= 0 and tile.river_connections[tile.flow_direction] != 0:
				var destination := world.tile_at(
					HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
				)
				if destination != null:
					_append_river_edge(
						world,
						tile,
						destination,
						settings,
						lake_heights,
						river_heights,
						river_vertices,
						river_normals,
						river_indices
					)
			var maximum_river_flow := 0
			for direction in range(6):
				if tile.river_connections[direction] != 0:
					maximum_river_flow = maxi(
						maximum_river_flow,
						tile.river_flow[direction]
					)
			if maximum_river_flow > 0:
				var center := _river_junction_anchor(
					world,
					tile,
					settings
				)
				center.y = _river_surface_height(
					tile,
					river_heights,
					_surface_height(world, tile, settings, lake_heights)
				) + 0.001
				var join_width := settings.hex_size * clampf(
					0.045 + log(float(maximum_river_flow) + 1.0) * 0.012,
					0.05,
					0.16
				)
				_append_join(
					river_vertices,
					river_normals,
					river_indices,
					center,
					join_width * 1.12
				)
	if not lake_vertices.is_empty():
		var lake_arrays := []
		lake_arrays.resize(Mesh.ARRAY_MAX)
		lake_arrays[Mesh.ARRAY_VERTEX] = lake_vertices
		lake_arrays[Mesh.ARRAY_NORMAL] = lake_normals
		lake_arrays[Mesh.ARRAY_TEX_UV] = lake_uvs
		lake_arrays[Mesh.ARRAY_INDEX] = lake_indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lake_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _lake_material())
	if not river_vertices.is_empty():
		var river_arrays := []
		river_arrays.resize(Mesh.ARRAY_MAX)
		river_arrays[Mesh.ARRAY_VERTEX] = river_vertices
		river_arrays[Mesh.ARRAY_NORMAL] = river_normals
		river_arrays[Mesh.ARRAY_INDEX] = river_indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, river_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _river_material())
	return mesh


static func river_edge_midpoint(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings
) -> Vector3:
	var lake_heights := _lake_surface_heights(world, settings)
	var river_heights := _river_visual_heights(world, settings, lake_heights)
	return _river_edge_midpoint(
		world,
		tile,
		settings,
		lake_heights,
		river_heights
	)


static func river_centerline(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings
) -> Array[Vector3]:
	var lake_heights := _lake_surface_heights(world, settings)
	return _river_centerline(
		world,
		source,
		destination,
		settings,
		lake_heights,
		_river_visual_heights(world, settings, lake_heights)
	)


static func river_meander_amplitude(
	tile: HexTileData,
	flow: int,
	settings: WorldGenerationSettings
) -> float:
	var relief_scale: float = [1.0, 1.0, 0.76, 0.30, 0.16][
		clampi(tile.elevation_level, 0, 4)
	]
	var downstream_scale := clampf(
		0.88 + log(float(maxi(flow, 1)) + 1.0) * 0.12,
		0.92,
		1.55
	)
	return (
		settings.hex_size
		* settings.river_meander_strength
		* 0.58
		* relief_scale
		* downstream_scale
	)


static func river_visual_quality_metrics(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Dictionary:
	var lake_heights := _lake_surface_heights(world, settings)
	var river_heights := _river_visual_heights(world, settings, lake_heights)
	var lowland_total := 0.0
	var lowland_maximum := 0.0
	var lowland_count := 0
	var highland_total := 0.0
	var highland_count := 0
	var straight_flatland_count := 0
	var threshold := settings.hex_size * STRAIGHT_FLATLAND_DEVIATION_THRESHOLD
	for source in world.tiles:
		if (
			source.flow_direction < 0
			or source.river_connections[source.flow_direction] == 0
		):
			continue
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(
				source.coordinate,
				source.flow_direction
			)
		)
		if destination == null:
			continue
		var points := _river_centerline(
			world,
			source,
			destination,
			settings,
			lake_heights,
			river_heights
		)
		var deviation := _maximum_centerline_lateral_deviation(points)
		if _is_flatland_reach(source, destination, settings):
			lowland_total += deviation
			lowland_maximum = maxf(lowland_maximum, deviation)
			lowland_count += 1
			straight_flatland_count += int(deviation < threshold)
		elif source.elevation_level >= 3 or destination.elevation_level >= 3:
			highland_total += deviation
			highland_count += 1
	return {
		"mean_lowland_river_lateral_deviation": (
			lowland_total / float(lowland_count) if lowland_count > 0 else 0.0
		),
		"maximum_lowland_river_lateral_deviation": lowland_maximum,
		"mean_highland_river_lateral_deviation": (
			highland_total / float(highland_count) if highland_count > 0 else 0.0
		),
		"straight_flatland_reach_count": straight_flatland_count,
		"lowland_river_reach_count": lowland_count,
		"highland_river_reach_count": highland_count,
		"straight_flatland_deviation_threshold": threshold,
	}


static func _maximum_centerline_lateral_deviation(
	points: Array[Vector3]
) -> float:
	if points.size() < 2:
		return 0.0
	var start := points[0]
	start.y = 0.0
	var finish := points[-1]
	finish.y = 0.0
	var axis := finish - start
	if axis.is_zero_approx():
		return 0.0
	axis = axis.normalized()
	var maximum := 0.0
	for point_value in points:
		var point := point_value
		point.y = 0.0
		var relative := point - start
		var projected := start + axis * relative.dot(axis)
		maximum = maxf(maximum, point.distance_to(projected))
	return maximum


static func _is_flatland_reach(
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings
) -> bool:
	if source.elevation_level > 2 or destination.elevation_level > 2:
		return false
	var elevation_scale := maxf(settings.elevation_step_height, 0.001)
	var raw_slope := absf(source.elevation - destination.elevation) / elevation_scale
	var effective_slope := (
		absf(
			float(source.effective_elevation - destination.effective_elevation)
		)
		/ 1000.0
	)
	return (
		raw_slope <= FLATLAND_RAW_SLOPE_MAXIMUM
		and effective_slope <= FLATLAND_EFFECTIVE_SLOPE_MAXIMUM
	)


static func build_river_diagnostic_chunk(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i
) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var lake_heights := _lake_surface_heights(world, settings)
	var start_column := chunk_coordinate.x * settings.chunk_size
	var start_row := chunk_coordinate.y * settings.chunk_size
	var end_column := mini(start_column + settings.chunk_size, world.width)
	var end_row := mini(start_row + settings.chunk_size, world.height)
	for row in range(start_row, end_row):
		for column in range(start_column, end_column):
			var tile := world.tile_at_offset(column, row)
			if tile == null:
				continue
			for direction in range(6):
				if tile.river_connections[direction] == 0:
					continue
				var neighbor := world.tile_at(
					HexCoordinatesScript.neighbor(tile.coordinate, direction)
				)
				var valid := _river_diagnostic_edge_is_valid(
					tile,
					neighbor,
					direction
				)
				var center := tile.position
				center.y = (
					_surface_height(world, tile, settings, lake_heights)
					+ settings.hex_size * 0.035
				)
				var midpoint := TerrainMesher.canonical_edge_midpoint(
					world,
					tile,
					direction,
					settings
				)
				var neighbor_height := (
					_surface_height(world, neighbor, settings, lake_heights)
					if neighbor != null
					else center.y
				)
				midpoint.y = (
					(
						_surface_height(world, tile, settings, lake_heights)
						+ neighbor_height
					) * 0.5
					+ settings.hex_size * 0.035
				)
				_append_diagnostic_segment(
					vertices,
					normals,
					colors,
					indices,
					center,
					midpoint,
					settings.hex_size * (0.034 if valid else 0.052),
					DIAGNOSTIC_EDGE_COLOR if valid else DIAGNOSTIC_ERROR_COLOR
				)
				if tile.flow_direction == direction:
					_append_diagnostic_flow_arrow(
						vertices,
						normals,
						colors,
						indices,
						center.lerp(midpoint, 0.66),
						midpoint - center,
						settings.hex_size * 0.055
					)
				if not valid:
					_append_diagnostic_error_marker(
						vertices,
						normals,
						colors,
						indices,
						center.lerp(midpoint, 0.72),
						midpoint - center,
						settings.hex_size * 0.105
					)
			var incoming_directions: Array[int] = []
			for neighbor in world.valid_neighbors(tile.coordinate):
				if (
					neighbor.flow_direction >= 0
					and neighbor.river_connections[neighbor.flow_direction] != 0
					and world.tile_at(
						HexCoordinatesScript.neighbor(
							neighbor.coordinate,
							neighbor.flow_direction
						)
					) == tile
				):
					incoming_directions.append(neighbor.flow_direction)
			var has_outgoing := (
				tile.flow_direction >= 0
				and tile.river_connections[tile.flow_direction] != 0
			)
			var is_source := _is_realized_river_head(world, tile)
			if is_source or (has_outgoing and incoming_directions.size() >= 2):
				var marker_center := tile.position
				marker_center.y = (
					_surface_height(world, tile, settings, lake_heights)
					+ settings.hex_size * 0.038
				)
				_append_diagnostic_disc(
					vertices,
					normals,
					colors,
					indices,
					marker_center,
					settings.hex_size * (
						0.085 if is_source else 0.105
					),
					(
						DIAGNOSTIC_SOURCE_COLOR
						if is_source
						else DIAGNOSTIC_CONFLUENCE_COLOR
					)
				)
			if has_outgoing:
				for incoming_direction in incoming_directions:
					if _direction_difference(
						incoming_direction,
						tile.flow_direction
					) < 2:
						continue
					var sharp_center := tile.position
					sharp_center.y = (
						_surface_height(world, tile, settings, lake_heights)
						+ settings.hex_size * 0.041
					)
					_append_diagnostic_disc(
						vertices,
						normals,
						colors,
						indices,
						sharp_center,
						settings.hex_size * 0.13,
						DIAGNOSTIC_SHARP_TURN_COLOR
					)
					break
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _diagnostic_material())
	return mesh


static func _river_edge_midpoint(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary,
	river_heights: Dictionary
) -> Vector3:
	var destination := world.tile_at(
		HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
	)
	var midpoint := _river_edge_crossing_anchor(
		world,
		tile,
		destination,
		settings
	)
	var source_height := _river_surface_height(
		tile,
		river_heights,
		_surface_height(world, tile, settings, lake_heights)
	)
	var destination_height := (
		_river_surface_height(
			destination,
			river_heights,
			_surface_height(world, destination, settings, lake_heights)
		)
		if destination != null
		else source_height
	)
	midpoint.y = (source_height + destination_height) * 0.5 + 0.001
	return midpoint


static func _append_lake_tile(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	var height := _surface_height(world, tile, settings, lake_heights)
	var center := tile.position
	center.y = height
	var corners: Array[Vector3] = []
	for corner_index in range(6):
		var corner := TerrainMesher.canonical_corner_horizontal(
			world,
			tile,
			corner_index,
			settings
		)
		corner.y = height
		corners.append(corner)
	for corner_index in range(6):
		var edge_direction := (corner_index + 1) % 6
		var neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, edge_direction)
		)
		var edge_weight := (
			1.0
			if neighbor != null and neighbor.lake_id == tile.lake_id
			else 0.0
		)
		var a := center
		var b := corners[(corner_index + 1) % 6]
		var c := corners[corner_index]
		if (-(b - a).cross(c - a)).dot(Vector3.UP) < 0.0:
			var swap := b
			b = c
			c = swap
		var base := vertices.size()
		vertices.append_array(PackedVector3Array([
			a,
			b,
			c,
		]))
		normals.append_array(PackedVector3Array([
			Vector3.UP,
			Vector3.UP,
			Vector3.UP,
		]))
		uvs.append_array(PackedVector2Array([
			Vector2(1.0, 0.0),
			Vector2(edge_weight, 0.0),
			Vector2(edge_weight, 0.0),
		]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2]))


static func _append_river_edge(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary,
	river_heights: Dictionary,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	indices: PackedInt32Array
) -> void:
	var points := _river_centerline(
		world,
		source,
		destination,
		settings,
		lake_heights,
		river_heights
	)
	var flow := maxi(source.river_flow[source.flow_direction], 1)
	var width := settings.hex_size * clampf(
		0.045 + log(float(flow) + 1.0) * 0.012,
		0.05,
		0.16
	)
	_append_polyline_ribbon(vertices, normals, indices, points, width)


static func _river_centerline(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary,
	river_heights: Dictionary
) -> Array[Vector3]:
	var start := _river_junction_anchor(world, source, settings)
	start.y = _river_surface_height(
		source,
		river_heights,
		_surface_height(world, source, settings, lake_heights)
	) + 0.001
	var finish := _river_junction_anchor(world, destination, settings)
	finish.y = _river_surface_height(
		destination,
		river_heights,
		_surface_height(world, destination, settings, lake_heights)
	) + 0.001
	var midpoint := _river_edge_midpoint(
		world,
		source,
		settings,
		lake_heights,
		river_heights
	)
	var edge_tangent := finish - start
	edge_tangent.y = 0.0
	edge_tangent = edge_tangent.normalized()
	var source_tangent := _canonical_tile_tangent(
		world,
		source,
		settings
	)
	var destination_tangent := _canonical_tile_tangent(
		world,
		destination,
		settings
	)
	source_tangent = _edge_oriented_tangent(source_tangent, edge_tangent)
	destination_tangent = _edge_oriented_tangent(
		destination_tangent,
		edge_tangent
	)
	var source_span := start.distance_to(midpoint)
	var destination_span := midpoint.distance_to(finish)
	var bend := _edge_meander_offset(
		world,
		source,
		destination,
		settings
	)
	var edge_side := Vector3(-edge_tangent.z, 0.0, edge_tangent.x)
	var first_controls := [
		start + source_tangent * source_span * 0.34,
		midpoint
			- edge_tangent * source_span * 0.30
			- edge_side * bend,
	]
	var second_controls := [
		midpoint
			+ edge_tangent * destination_span * 0.30
			+ edge_side * bend,
		finish - destination_tangent * destination_span * 0.34,
	]
	first_controls[0].y = lerpf(start.y, midpoint.y, 0.34)
	first_controls[1].y = lerpf(start.y, midpoint.y, 0.70)
	second_controls[0].y = lerpf(midpoint.y, finish.y, 0.30)
	second_controls[1].y = lerpf(midpoint.y, finish.y, 0.66)
	var result: Array[Vector3] = []
	_append_cubic_samples(
		result,
		start,
		first_controls[0],
		first_controls[1],
		midpoint,
		false
	)
	_append_cubic_samples(
		result,
		midpoint,
		second_controls[0],
		second_controls[1],
		finish,
		true
	)
	return result


static func _river_junction_anchor(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings
) -> Vector3:
	var anchor := tile.position
	var maximum_flow := 1
	for flow in tile.river_flow:
		maximum_flow = maxi(maximum_flow, flow)
	var tangent := _canonical_tile_tangent(world, tile, settings)
	tangent.y = 0.0
	if tangent.is_zero_approx():
		return anchor
	tangent = tangent.normalized()
	var side := Vector3(-tangent.z, 0.0, tangent.x)
	var amplitude := river_meander_amplitude(tile, maximum_flow, settings)
	var flat_reach_length := 1
	if tile.flow_direction >= 0:
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(
				tile.coordinate,
				tile.flow_direction
			)
		)
		if (
			destination != null
			and _is_flatland_reach(tile, destination, settings)
		):
			flat_reach_length = _consecutive_flat_reach_length(
				world,
				tile,
				destination,
				settings
			)
			amplitude *= (
				1.20
				+ minf(float(maxi(flat_reach_length - 1, 0)), 8.0) * 0.055
			)
	else:
		amplitude *= 0.45
	var offset := clampf(
		amplitude * _mainstem_meander_phase(world, tile),
		-settings.hex_size * MAXIMUM_JUNCTION_OFFSET,
		settings.hex_size * MAXIMUM_JUNCTION_OFFSET
	)
	return anchor + side * offset


static func _river_edge_crossing_anchor(
	world: HexWorldData,
	first_tile: HexTileData,
	second_tile: HexTileData,
	settings: WorldGenerationSettings
) -> Vector3:
	if first_tile == null or second_tile == null:
		return first_tile.position if first_tile != null else Vector3.ZERO
	var canonical_first := first_tile
	var canonical_second := second_tile
	if _tile_sort_index(world, canonical_second) < _tile_sort_index(
		world,
		canonical_first
	):
		canonical_first = second_tile
		canonical_second = first_tile
	var direction := -1
	for candidate_direction in range(6):
		if (
			HexCoordinatesScript.neighbor(
				canonical_first.coordinate,
				candidate_direction
			)
			== canonical_second.coordinate
		):
			direction = candidate_direction
			break
	if direction < 0:
		return (first_tile.position + second_tile.position) * 0.5
	var midpoint := TerrainMesher.canonical_edge_midpoint(
		world,
		canonical_first,
		direction,
		settings
	)
	var center_axis := canonical_second.position - canonical_first.position
	center_axis.y = 0.0
	if center_axis.is_zero_approx():
		return midpoint
	center_axis = center_axis.normalized()
	var edge_axis := Vector3(-center_axis.z, 0.0, center_axis.x)
	var first_anchor := _river_junction_anchor(
		world,
		canonical_first,
		settings
	)
	var second_anchor := _river_junction_anchor(
		world,
		canonical_second,
		settings
	)
	var center_midpoint := (
		canonical_first.position + canonical_second.position
	) * 0.5
	var desired_offset := (
		(first_anchor + second_anchor) * 0.5 - center_midpoint
	).dot(edge_axis)
	desired_offset = clampf(
		desired_offset,
		-settings.hex_size * MAXIMUM_EDGE_CROSSING_OFFSET,
		settings.hex_size * MAXIMUM_EDGE_CROSSING_OFFSET
	)
	return midpoint + edge_axis * desired_offset


static func _edge_oriented_tangent(
	canonical_tangent: Vector3,
	edge_tangent: Vector3
) -> Vector3:
	var tangent := canonical_tangent
	tangent.y = 0.0
	if tangent.is_zero_approx():
		return edge_tangent
	tangent = tangent.normalized()
	if tangent.dot(edge_tangent) <= 0.0:
		return edge_tangent
	const MINIMUM_FORWARD_ALIGNMENT := 0.40
	var alignment := tangent.dot(edge_tangent)
	if alignment < MINIMUM_FORWARD_ALIGNMENT:
		tangent = (
			tangent * alignment
			+ edge_tangent * (MINIMUM_FORWARD_ALIGNMENT - alignment + 0.40)
		).normalized()
	if tangent.dot(edge_tangent) < MINIMUM_FORWARD_ALIGNMENT:
		return edge_tangent
	return tangent


static func _canonical_tile_tangent(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings
) -> Vector3:
	var outgoing := Vector3.ZERO
	if (
		tile.flow_direction >= 0
		and tile.river_connections[tile.flow_direction] != 0
	):
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
		)
		if destination != null:
			outgoing = destination.position - tile.position
			outgoing.y = 0.0
			outgoing = outgoing.normalized()
	var incoming := Vector3.ZERO
	var strongest_incoming_flow := -1
	for neighbor in world.valid_neighbors(tile.coordinate):
		if (
			neighbor.flow_direction < 0
			or neighbor.river_connections[neighbor.flow_direction] == 0
		):
			continue
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(
				neighbor.coordinate,
				neighbor.flow_direction
			)
		)
		if destination != tile:
			continue
		var flow := neighbor.river_flow[neighbor.flow_direction]
		if flow <= strongest_incoming_flow:
			continue
		strongest_incoming_flow = flow
		incoming = tile.position - neighbor.position
		incoming.y = 0.0
		incoming = incoming.normalized()
	var tangent := outgoing
	if not incoming.is_zero_approx() and not outgoing.is_zero_approx():
		tangent = incoming + outgoing
		if tangent.is_zero_approx():
			tangent = outgoing
		else:
			tangent = tangent.normalized()
	elif tangent.is_zero_approx():
		tangent = incoming
	if tangent.is_zero_approx():
		return Vector3.FORWARD
	return tangent


static func _edge_meander_offset(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings
) -> float:
	var flow := maxi(source.river_flow[source.flow_direction], 1)
	var amplitude := (
		river_meander_amplitude(source, flow, settings)
		+ river_meander_amplitude(destination, flow, settings)
	) * 0.5
	var elevation_scale := maxf(settings.elevation_step_height, 0.001)
	var raw_slope := absf(source.elevation - destination.elevation) / elevation_scale
	var effective_slope := (
		absf(
			float(source.effective_elevation - destination.effective_elevation)
		)
		/ 1000.0
	)
	var local_flatness := (
		1.0 - clampf(maxf(raw_slope, effective_slope) / 0.70, 0.0, 1.0)
	)
	amplitude *= lerpf(0.30, 1.0, local_flatness)
	if _is_flatland_reach(source, destination, settings):
		var flat_reach_length := _consecutive_flat_reach_length(
			world,
			source,
			destination,
			settings
		)
		amplitude *= 1.0 + minf(float(maxi(flat_reach_length - 1, 0)), 8.0) * 0.045
	var phase := _mainstem_meander_phase(world, source)
	return clampf(
		amplitude * phase,
		-settings.hex_size * MAXIMUM_MEANDER_CONTROL_OFFSET,
		settings.hex_size * MAXIMUM_MEANDER_CONTROL_OFFSET
	)


static func _mainstem_meander_phase(
	world: HexWorldData,
	tile: HexTileData
) -> float:
	var current := tile
	var root := tile
	var downstream_index := 0
	var visited: Dictionary = {}
	while current != null and downstream_index < 128:
		if visited.has(current.coordinate):
			break
		visited[current.coordinate] = true
		root = current
		var upstream := _strongest_river_upstream(world, current)
		if upstream == null:
			break
		current = upstream
		downstream_index += 1
	var root_phase := _hash_unit(world.seed, MEANDER_SALT, root.coordinate) * TAU
	return sin(root_phase + float(downstream_index) * MEANDER_PHASE_STEP)


static func _consecutive_flat_reach_length(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	settings: WorldGenerationSettings
) -> int:
	var length := 1
	var current := source
	for _step in range(6):
		var upstream := _strongest_river_upstream(world, current)
		if (
			upstream == null
			or not _is_flatland_reach(upstream, current, settings)
		):
			break
		length += 1
		current = upstream
	current = destination
	for _step in range(6):
		if (
			current.flow_direction < 0
			or current.river_connections[current.flow_direction] == 0
		):
			break
		var next := world.tile_at(
			HexCoordinatesScript.neighbor(
				current.coordinate,
				current.flow_direction
			)
		)
		if next == null or not _is_flatland_reach(current, next, settings):
			break
		length += 1
		current = next
	return length


static func _strongest_river_upstream(
	world: HexWorldData,
	tile: HexTileData
) -> HexTileData:
	var result: HexTileData
	var strongest_flow := -1
	for neighbor in world.valid_neighbors(tile.coordinate):
		if (
			neighbor.flow_direction < 0
			or neighbor.river_connections[neighbor.flow_direction] == 0
		):
			continue
		var neighbor_destination := world.tile_at(
			HexCoordinatesScript.neighbor(
				neighbor.coordinate,
				neighbor.flow_direction
			)
		)
		if neighbor_destination != tile:
			continue
		var flow := neighbor.river_flow[neighbor.flow_direction]
		if (
			flow > strongest_flow
			or (
				flow == strongest_flow
				and result != null
				and _tile_sort_index(world, neighbor)
					< _tile_sort_index(world, result)
			)
		):
			result = neighbor
			strongest_flow = flow
	return result


static func _tile_sort_index(world: HexWorldData, tile: HexTileData) -> int:
	return tile.offset_coordinate.y * world.width + tile.offset_coordinate.x


static func _append_cubic_samples(
	points: Array[Vector3],
	start: Vector3,
	control_a: Vector3,
	control_b: Vector3,
	finish: Vector3,
	skip_start: bool
) -> void:
	for index in range(9):
		if skip_start and index == 0:
			continue
		var t := float(index) / 8.0
		var inverse := 1.0 - t
		points.append(
			start * inverse * inverse * inverse
			+ control_a * 3.0 * inverse * inverse * t
			+ control_b * 3.0 * inverse * t * t
			+ finish * t * t * t
		)


static func _append_polyline_ribbon(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	points: Array[Vector3],
	width: float
) -> void:
	var sides: Array[Vector3] = []
	for index in range(points.size()):
		var direction: Vector3
		if index == 0:
			direction = points[1] - points[0]
		elif index == points.size() - 1:
			direction = points[index] - points[index - 1]
		else:
			direction = points[index + 1] - points[index - 1]
		direction.y = 0.0
		sides.append(Vector3(-direction.z, 0.0, direction.x).normalized() * width)
	for index in range(points.size() - 1):
		var center_a := points[index]
		var center_b := points[index + 1]
		var left_a := center_a - sides[index]
		var right_a := center_a + sides[index]
		var left_b := center_b - sides[index + 1]
		var right_b := center_b + sides[index + 1]
		_append_triangle(vertices, normals, indices, left_a, left_b, center_b)
		_append_triangle(vertices, normals, indices, left_a, center_b, center_a)
		_append_triangle(vertices, normals, indices, center_a, center_b, right_b)
		_append_triangle(vertices, normals, indices, center_a, right_b, right_a)


static func _append_join(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	center: Vector3,
	radius: float
) -> void:
	for index in range(6):
		var first_angle := TAU * float(index) / 6.0
		var second_angle := TAU * float(index + 1) / 6.0
		var first := center + Vector3(cos(first_angle), 0.0, sin(first_angle)) * radius
		var second := center + Vector3(cos(second_angle), 0.0, sin(second_angle)) * radius
		_append_triangle(vertices, normals, indices, center, second, first)


static func _append_diagnostic_segment(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	start: Vector3,
	finish: Vector3,
	half_width: float,
	color: Color
) -> void:
	var direction := finish - start
	direction.y = 0.0
	if direction.is_zero_approx():
		return
	var side := Vector3(-direction.z, 0.0, direction.x).normalized() * half_width
	_append_colored_triangle(
		vertices,
		normals,
		colors,
		indices,
		start - side,
		finish - side,
		finish + side,
		color
	)
	_append_colored_triangle(
		vertices,
		normals,
		colors,
		indices,
		start - side,
		finish + side,
		start + side,
		color
	)


static func _append_diagnostic_error_marker(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	center: Vector3,
	edge_direction: Vector3,
	radius: float
) -> void:
	edge_direction.y = 0.0
	if edge_direction.is_zero_approx():
		return
	var along := edge_direction.normalized() * radius
	var across := Vector3(-along.z, 0.0, along.x)
	center.y += radius * 0.04
	_append_colored_triangle(
		vertices,
		normals,
		colors,
		indices,
		center - along,
		center + across,
		center + along,
		DIAGNOSTIC_ERROR_COLOR
	)
	_append_colored_triangle(
		vertices,
		normals,
		colors,
		indices,
		center - along,
		center + along,
		center - across,
		DIAGNOSTIC_ERROR_COLOR
	)


static func _append_diagnostic_flow_arrow(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	center: Vector3,
	edge_direction: Vector3,
	radius: float
) -> void:
	edge_direction.y = 0.0
	if edge_direction.is_zero_approx():
		return
	var along := edge_direction.normalized() * radius
	var across := Vector3(-along.z, 0.0, along.x) * 0.72
	center.y += radius * 0.03
	_append_colored_triangle(
		vertices,
		normals,
		colors,
		indices,
		center + along,
		center - along + across,
		center - along - across,
		DIAGNOSTIC_DIRECTION_COLOR
	)


static func _append_diagnostic_disc(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	center: Vector3,
	radius: float,
	color: Color
) -> void:
	for index in range(6):
		var first_angle := TAU * float(index) / 6.0
		var second_angle := TAU * float(index + 1) / 6.0
		var first := center + Vector3(
			cos(first_angle),
			0.0,
			sin(first_angle)
		) * radius
		var second := center + Vector3(
			cos(second_angle),
			0.0,
			sin(second_angle)
		) * radius
		_append_colored_triangle(
			vertices,
			normals,
			colors,
			indices,
			center,
			second,
			first,
			color
		)


static func _append_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	indices: PackedInt32Array,
	a: Vector3,
	b: Vector3,
	c: Vector3
) -> void:
	# Godot treats clockwise vertices as front-facing. Its upward-facing front
	# normal is therefore the inverse of the conventional cross product.
	if (-(b - a).cross(c - a)).dot(Vector3.UP) < 0.0:
		var swap := b
		b = c
		c = swap
	var base := vertices.size()
	vertices.append_array(PackedVector3Array([a, b, c]))
	normals.append_array(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP]))
	indices.append_array(PackedInt32Array([base, base + 1, base + 2]))


static func _append_colored_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	color: Color
) -> void:
	if (-(b - a).cross(c - a)).dot(Vector3.UP) < 0.0:
		var swap := b
		b = c
		c = swap
	var base := vertices.size()
	vertices.append_array(PackedVector3Array([a, b, c]))
	normals.append_array(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP]))
	colors.append_array(PackedColorArray([color, color, color]))
	indices.append_array(PackedInt32Array([base, base + 1, base + 2]))


static func _river_diagnostic_edge_is_valid(
	tile: HexTileData,
	neighbor: HexTileData,
	direction: int
) -> bool:
	if neighbor == null:
		return false
	var reverse := posmod(direction + 3, 6)
	var tile_owns_flow := tile.flow_direction == direction
	var neighbor_owns_flow := neighbor.flow_direction == reverse
	return (
		neighbor.river_connections[reverse] != 0
		and tile.river_flow[direction] > 0
		and tile.river_flow[direction] == neighbor.river_flow[reverse]
		and tile_owns_flow != neighbor_owns_flow
	)


static func _is_realized_river_head(
	world: HexWorldData,
	tile: HexTileData
) -> bool:
	if (
		tile.flow_direction < 0
		or tile.river_selected_connections[tile.flow_direction] == 0
	):
		return false
	for neighbor in world.valid_neighbors(tile.coordinate):
		if (
			neighbor.flow_direction >= 0
			and neighbor.river_selected_connections[neighbor.flow_direction] != 0
			and world.tile_at(
				HexCoordinatesScript.neighbor(
					neighbor.coordinate,
					neighbor.flow_direction
				)
			) == tile
		):
			return false
	return true


static func _direction_difference(first: int, second: int) -> int:
	var difference := absi(first - second)
	return mini(difference, 6 - difference)


static func _surface_height(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary
) -> float:
	if tile == null:
		return settings.ocean_height + 0.075
	if tile.lake_id >= 0:
		return float(lake_heights.get(tile.lake_id, settings.ocean_height + 0.075))
	if tile.is_ocean or tile.is_water:
		return settings.ocean_height + 0.075
	return tile.elevation + 0.085


static func _lake_surface_heights(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Dictionary:
	var cache_signature := _height_cache_signature(world, settings)
	if (
		String(world.metadata.get(HEIGHT_CACHE_SIGNATURE_KEY, ""))
			== cache_signature
		and world.metadata.get(LAKE_HEIGHT_CACHE_KEY) is Dictionary
	):
		return world.metadata[LAKE_HEIGHT_CACHE_KEY]
	var result: Dictionary = {}
	for tile in world.tiles:
		if tile.lake_id < 0:
			continue
		var candidate := (
			settings.ocean_height + 0.075
			if tile.is_water
			else tile.elevation + 0.085
		)
		result[tile.lake_id] = maxf(
			float(result.get(tile.lake_id, -INF)),
			candidate
		)
	# A lake surface sits at its spillway crest rather than at the provisional
	# level-zero water height. This keeps the visible outlet flat or descending
	# even when its logical downstream parent is a higher discrete land tile.
	for _pass in range(maxi(result.size(), 1)):
		var changed := false
		for tile in world.tiles:
			if tile.lake_id < 0 or tile.lake_outlet_direction < 0:
				continue
			var destination := world.tile_at(
				HexCoordinatesScript.neighbor(
					tile.coordinate,
					tile.lake_outlet_direction
				)
			)
			if destination == null:
				continue
			var spillway_height := (
				float(result.get(destination.lake_id, settings.ocean_height + 0.075))
				if destination.lake_id >= 0
				else _base_surface_height(destination, settings)
			)
			var current_height := float(result.get(tile.lake_id, spillway_height))
			if spillway_height > current_height:
				result[tile.lake_id] = spillway_height
				changed = true
		if not changed:
			break
	world.metadata[HEIGHT_CACHE_SIGNATURE_KEY] = cache_signature
	world.metadata[LAKE_HEIGHT_CACHE_KEY] = result
	world.metadata.erase(RIVER_HEIGHT_CACHE_KEY)
	return result


static func _river_visual_heights(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	lake_heights: Dictionary
) -> Dictionary:
	var cache_signature := _height_cache_signature(world, settings)
	if (
		String(world.metadata.get(HEIGHT_CACHE_SIGNATURE_KEY, ""))
			== cache_signature
		and world.metadata.get(RIVER_HEIGHT_CACHE_KEY) is Dictionary
	):
		return world.metadata[RIVER_HEIGHT_CACHE_KEY]
	var result: Dictionary = {}
	var downstream_sources: Array[HexTileData] = []
	for tile in world.tiles:
		var participates := false
		for direction in range(6):
			if tile.river_connections[direction] != 0:
				participates = true
				break
		if not participates:
			continue
		result[tile.coordinate] = _surface_height(
			world,
			tile,
			settings,
			lake_heights
		)
		if (
			tile.flow_direction >= 0
			and tile.river_connections[tile.flow_direction] != 0
		):
			downstream_sources.append(tile)
	downstream_sources.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
		if a.effective_elevation != b.effective_elevation:
			return a.effective_elevation < b.effective_elevation
		return (
			a.offset_coordinate.y * world.width + a.offset_coordinate.x
			< b.offset_coordinate.y * world.width + b.offset_coordinate.x
		)
	)
	for source in downstream_sources:
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(
				source.coordinate,
				source.flow_direction
			)
		)
		if destination == null:
			continue
		if not result.has(destination.coordinate):
			result[destination.coordinate] = _surface_height(
				world,
				destination,
				settings,
				lake_heights
			)
		result[source.coordinate] = maxf(
			float(result[source.coordinate]),
			float(result[destination.coordinate])
		)
	world.metadata[HEIGHT_CACHE_SIGNATURE_KEY] = cache_signature
	world.metadata[LAKE_HEIGHT_CACHE_KEY] = lake_heights
	world.metadata[RIVER_HEIGHT_CACHE_KEY] = result
	return result


static func _height_cache_signature(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> String:
	return "%s|%.6f" % [
		String(world.metadata.get("hydrology_signature", "")),
		settings.ocean_height,
	]


static func _river_surface_height(
	tile: HexTileData,
	river_heights: Dictionary,
	fallback: float
) -> float:
	if tile == null:
		return fallback
	return float(river_heights.get(tile.coordinate, fallback))


static func _base_surface_height(
	tile: HexTileData,
	settings: WorldGenerationSettings
) -> float:
	if tile == null or tile.is_ocean or tile.is_water:
		return settings.ocean_height + 0.075
	return tile.elevation + 0.085


static func _lake_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = OceanShader
	material.set_shader_parameter("uv_sampler", WaterUvTexture)
	material.set_shader_parameter("normalmap_a_sampler", WaterNormalATexture)
	material.set_shader_parameter("normalmap_b_sampler", WaterNormalBTexture)
	material.set_shader_parameter("foam_sampler", WaterFoamTexture)
	material.set_shader_parameter("caustic_sampler", WaterCausticTexture)
	# The global sea plane already lies beneath enclosed lakes. A slightly
	# lighter alpha keeps the two transparent layers visually equivalent to
	# one water column while retaining each lake's hydrology-derived height.
	material.set_shader_parameter("opacity_scale", 0.72)
	material.set_shader_parameter("edge_fade", 1.0)
	material.render_priority = 1
	return material


static func _river_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#45b8db")
	material.roughness = 0.26
	return material


static func _diagnostic_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material.render_priority = 2
	return material


static func _hash_unit(seed: int, salt: int, coordinate: Vector2i) -> float:
	var value := int(hash("%d:%d:%d:%d" % [
		seed,
		salt,
		coordinate.x,
		coordinate.y,
	]))
	return float(posmod(value, 1000003)) / 1000002.0
