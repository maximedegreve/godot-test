class_name HexHydrologyStage
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")

const DRAINAGE_SALT := 0x33484452
const DEPRESSION_SALT := 0x33484450
const WATERSHED_SALT := 0x33485753
const SOURCE_SALT := 0x33485352
const MEANDER_SALT := 0x33484d52
const RAW_SCALE := 1000
const HEADWATER_MIN_SPACING := 4
const WET_INTERIOR_MOISTURE := 0.58
const WET_INTERIOR_WATER_DISTANCE := 3

## Discrete gameplay-relief tiers eligible for post-priority flatland
## meandering. Ocean (0), highland (3), and mountain (4) tiers keep the
## unmodified priority-flood parent; only coast and lowland flatland ever
## reroutes.
const FLATLAND_ELEVATION_LEVELS := [1, 2]
## Narrow raw-height tolerance (in `_raw_height` units) allowed alongside an
## equal-or-lower gameplay-relief destination. Always kept well below the
## smallest possible one-tier raw-height step so a reroute can never cross a
## discrete relief tier even at the lowest configured elevation step height.
const FLATLAND_RAW_RELIEF_TOLERANCE := 96
## A reroute only ever chooses among destinations within this many
## effective-elevation units of the locally lowest safe candidate, keeping
## flatland meandering "near-lowest" rather than a long lateral wander.
const FLATLAND_NEAR_LOWEST_TOLERANCE := 3
## Soft threshold (in edges) above which continuing the same logical hex
## direction accrues an escalating penalty, discouraging long straight
## flatland runs without ever forbidding one when it is the only safe path.
const FLATLAND_MAX_STRAIGHT_RUN := 2
const FLATLAND_STRAIGHT_RUN_PENALTY := 140.0
const FLATLAND_ALIGNMENT_WEIGHT := 70.0
const FLATLAND_CONVERGENCE_BONUS := 45.0
const FLATLAND_PARALLEL_PENALTY := 95.0
const FLATLAND_ELEVATION_WEIGHT := 6.0
const FLATLAND_SHARP_TURN_PENALTY := 100000.0
const FLATLAND_MEANDER_FREQUENCY_A := 0.047
const FLATLAND_MEANDER_FREQUENCY_B := 0.031
const FLATLAND_MEANDER_FREQUENCY_C := 0.063


static func apply(world: HexWorldData, settings: WorldGenerationSettings) -> void:
	_reset(world)
	var ocean := _mark_ocean(world)
	var order := _priority_drainage(world, ocean)
	var mandatory_lakes := _mark_enclosed_water_lakes(world, ocean)
	var retained_depressions := _retain_depressions(world, settings, order)
	var reroute_result := _reroute_flatland_drainage(world)
	_rebuild_effective_elevation(world, ocean)
	order = _downstream_order(world, ocean)
	_assign_runoff_and_accumulation(world, order)
	_assign_watersheds(world, ocean)
	var river_result := _select_rivers(world, settings)
	var diagnostics := _hydrology_diagnostics(
		world,
		river_result["heads"],
		HEADWATER_MIN_SPACING
	)
	var meander_diagnostics := _flatland_logical_meander_diagnostics(
		world,
		reroute_result
	)
	var lake_count := mandatory_lakes + retained_depressions
	world.metadata["hydrology_signature"] = world.hydrology_signature()
	world.metadata["lake_count"] = lake_count
	world.metadata["mandatory_lake_count"] = mandatory_lakes
	world.metadata["retained_depression_count"] = retained_depressions
	world.metadata["river_count"] = river_result["headwater_count"]
	world.metadata["river_edge_count"] = river_result["edge_count"]
	world.metadata["river_flow_threshold"] = river_result["threshold"]
	world.metadata["maximum_flow_accumulation"] = _maximum_accumulation(world)
	world.metadata["watershed_count"] = _watershed_count(world)
	for key in meander_diagnostics:
		world.metadata[key] = meander_diagnostics[key]
	for key in diagnostics:
		world.metadata[key] = diagnostics[key]


static func _reset(world: HexWorldData) -> void:
	for tile in world.tiles:
		tile.is_ocean = false
		tile.effective_elevation = 0
		tile.flow_direction = -1
		tile.runoff = 0
		tile.flow_accumulation = 0
		tile.watershed_id = -1
		tile.lake_id = -1
		tile.lake_outlet_direction = -1
		tile.river_connections = PackedByteArray([0, 0, 0, 0, 0, 0])
		tile.river_selected_connections = PackedByteArray([0, 0, 0, 0, 0, 0])
		tile.river_flow = PackedInt32Array([0, 0, 0, 0, 0, 0])


static func _mark_ocean(world: HexWorldData) -> Dictionary:
	var ocean: Dictionary = {}
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
	for coordinate in ocean:
		world.tile_at(coordinate).is_ocean = true
	return ocean


static func _priority_drainage(world: HexWorldData, ocean: Dictionary) -> Array[HexTileData]:
	var heap: Array = []
	var visited: Dictionary = {}
	var order: Array[HexTileData] = []
	for tile in world.tiles:
		if not ocean.has(tile.coordinate):
			continue
		tile.effective_elevation = 0
		visited[tile.coordinate] = true
		_heap_push(
			heap,
			[
				0,
				_hash_int(world.seed, DRAINAGE_SALT, tile.coordinate),
				_tile_index(world, tile),
				tile,
			]
		)
	while not heap.is_empty():
		var entry: Array = _heap_pop(heap)
		var source: HexTileData = entry[3]
		order.append(source)
		for direction in range(6):
			var neighbor := world.tile_at(
				HexCoordinatesScript.neighbor(source.coordinate, direction)
			)
			if neighbor == null or visited.has(neighbor.coordinate):
				continue
			visited[neighbor.coordinate] = true
			var raw_height := _raw_height(neighbor)
			neighbor.effective_elevation = maxi(
				raw_height,
				source.effective_elevation + 1
			)
			neighbor.flow_direction = posmod(direction + 3, 6)
			_heap_push(
				heap,
				[
					neighbor.effective_elevation,
					_hash_int(world.seed, DRAINAGE_SALT, neighbor.coordinate),
					_tile_index(world, neighbor),
					neighbor,
				]
			)
	return order


static func _mark_enclosed_water_lakes(
	world: HexWorldData,
	ocean: Dictionary
) -> int:
	var visited: Dictionary = {}
	var lake_id := 0
	for tile in world.tiles:
		if (
			not tile.is_water
			or ocean.has(tile.coordinate)
			or visited.has(tile.coordinate)
		):
			continue
		var component: Array[HexTileData] = []
		var queue: Array[HexTileData] = [tile]
		visited[tile.coordinate] = true
		var head := 0
		while head < queue.size():
			var current := queue[head]
			head += 1
			component.append(current)
			for neighbor in world.valid_neighbors(current.coordinate):
				if (
					not neighbor.is_water
					or ocean.has(neighbor.coordinate)
					or visited.has(neighbor.coordinate)
				):
					continue
				visited[neighbor.coordinate] = true
				queue.append(neighbor)
		_configure_lake_component(world, component, lake_id)
		lake_id += 1
	return lake_id


static func _retain_depressions(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	_priority_order: Array[HexTileData]
) -> int:
	var target := roundi(
		float(settings.lake_count)
		* sqrt(float(world.tiles.size()) / 6400.0)
	)
	if target <= 0:
		return 0
	var candidates: Array[HexTileData] = []
	for tile in world.tiles:
		if tile.is_water or tile.lake_id >= 0:
			continue
		var local_minimum := true
		var has_lower_drain := false
		for neighbor in world.valid_neighbors(tile.coordinate):
			if _raw_height(neighbor) < _raw_height(tile):
				local_minimum = false
			if neighbor.effective_elevation < tile.effective_elevation:
				has_lower_drain = true
		if local_minimum and has_lower_drain and tile.effective_elevation > _raw_height(tile):
			candidates.append(tile)
	candidates.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
		var a_score := _hash_int(world.seed, DEPRESSION_SALT, a.coordinate)
		var b_score := _hash_int(world.seed, DEPRESSION_SALT, b.coordinate)
		if a_score != b_score:
			return a_score < b_score
		return _tile_index(world, a) < _tile_index(world, b)
	)
	var next_lake_id := 0
	for tile in world.tiles:
		next_lake_id = maxi(next_lake_id, tile.lake_id + 1)
	var retained := 0
	var reserved: Dictionary = {}
	for candidate in candidates:
		if retained >= target or reserved.has(candidate.coordinate):
			continue
		var component: Array[HexTileData] = [candidate]
		reserved[candidate.coordinate] = true
		var neighbors := world.valid_neighbors(candidate.coordinate)
		neighbors.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
			if _raw_height(a) != _raw_height(b):
				return _raw_height(a) < _raw_height(b)
			return _tile_index(world, a) < _tile_index(world, b)
		)
		var desired_size := 1 + posmod(
			_hash_int(world.seed, DEPRESSION_SALT + 1, candidate.coordinate),
			3
		)
		for neighbor in neighbors:
			if (
				component.size() >= desired_size
				or neighbor.is_water
				or neighbor.lake_id >= 0
				or reserved.has(neighbor.coordinate)
				or _raw_height(neighbor) > _raw_height(candidate) + RAW_SCALE
			):
				continue
			component.append(neighbor)
			reserved[neighbor.coordinate] = true
		if _configure_lake_component(world, component, next_lake_id):
			next_lake_id += 1
			retained += 1
		else:
			for member in component:
				reserved.erase(member.coordinate)
	return retained


static func _configure_lake_component(
	world: HexWorldData,
	component: Array[HexTileData],
	lake_id: int
) -> bool:
	var members: Dictionary = {}
	for tile in component:
		members[tile.coordinate] = true
	var outlet_tile: HexTileData
	var outlet_direction := -1
	var outlet_destination: HexTileData
	for tile in component:
		if tile.flow_direction < 0:
			continue
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
		)
		if destination == null or members.has(destination.coordinate):
			continue
		if (
			outlet_destination == null
			or destination.effective_elevation < outlet_destination.effective_elevation
			or (
				destination.effective_elevation == outlet_destination.effective_elevation
				and _tile_index(world, tile) < _tile_index(world, outlet_tile)
			)
		):
			outlet_tile = tile
			outlet_direction = tile.flow_direction
			outlet_destination = destination
	if outlet_tile == null:
		return false
	for tile in component:
		tile.lake_id = lake_id
		tile.lake_outlet_direction = -1
	var visited: Dictionary = {outlet_tile.coordinate: true}
	var queue: Array[HexTileData] = [outlet_tile]
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		for direction in range(6):
			var neighbor := world.tile_at(
				HexCoordinatesScript.neighbor(current.coordinate, direction)
			)
			if (
				neighbor == null
				or not members.has(neighbor.coordinate)
				or visited.has(neighbor.coordinate)
			):
				continue
			visited[neighbor.coordinate] = true
			neighbor.flow_direction = posmod(direction + 3, 6)
			queue.append(neighbor)
	outlet_tile.flow_direction = outlet_direction
	outlet_tile.lake_outlet_direction = outlet_direction
	return visited.size() == component.size()


## Deterministic post-priority, pre-accumulation flatland drainage
## rerouting. Runs after lakes are configured (so lake interiors and
## outlets are already fixed and untouched) and before effective elevation
## is rebuilt from the resulting graph, so every later stage (rebuild,
## downstream order, runoff, accumulation, watersheds, river selection)
## simply consumes whatever flow graph this step leaves behind.
##
## Only level-1/2 flatland tiles (coast and lowland) that are not part of a
## lake are eligible. Eligible tiles re-derive their `flow_direction` from
## adjacent candidates that are earlier in the lexicographic
## (pre-reroute effective elevation, deterministic tile order) key captured
## at the start of this pass. Equal-elevation lateral steps are what permit
## real bends across broad flats, while the strictly earlier destination
## still makes cycles impossible. The following effective-elevation rebuild
## restores a strict downhill value on every chosen edge. Highland,
## mountain, ocean, and every lake tile keep the untouched
## priority-flood/lake direction.
static func _reroute_flatland_drainage(world: HexWorldData) -> Dictionary:
	var frozen_elevation: Dictionary = {}
	var original_direction: Dictionary = {}
	var order: Array[HexTileData] = []
	for tile in world.tiles:
		frozen_elevation[tile.coordinate] = tile.effective_elevation
		original_direction[tile.coordinate] = tile.flow_direction
		if not tile.is_ocean:
			order.append(tile)
	# Ascending frozen-elevation and deterministic tile order guarantees every
	# candidate destination has already been finalized. This lets the
	# run-length, incoming-confluence, and sharp-turn bookkeeping below use
	# only already-known downstream state.
	order.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
		var elevation_a := int(frozen_elevation[a.coordinate])
		var elevation_b := int(frozen_elevation[b.coordinate])
		if elevation_a != elevation_b:
			return elevation_a < elevation_b
		return _tile_index(world, a) < _tile_index(world, b)
	)
	var final_direction: Dictionary = {}
	var run_length: Dictionary = {}
	var incoming_count: Dictionary = {}
	var changed: Dictionary = {}
	var eligible_count := 0
	for tile in order:
		var chosen_direction := tile.flow_direction
		if (
			tile.lake_id < 0
			and chosen_direction >= 0
			and FLATLAND_ELEVATION_LEVELS.has(tile.elevation_level)
		):
			eligible_count += 1
			chosen_direction = _choose_flatland_direction(
				world,
				tile,
				chosen_direction,
				frozen_elevation,
				original_direction,
				final_direction,
				run_length,
				incoming_count
			)
		if chosen_direction != tile.flow_direction:
			tile.flow_direction = chosen_direction
		final_direction[tile.coordinate] = chosen_direction
		if chosen_direction != int(original_direction[tile.coordinate]):
			changed[tile.coordinate] = int(original_direction[tile.coordinate])
		if chosen_direction < 0:
			run_length[tile.coordinate] = 0
			continue
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, chosen_direction)
		)
		if destination == null:
			run_length[tile.coordinate] = 1
			continue
		var destination_direction := int(
			final_direction.get(destination.coordinate, -1)
		)
		var continues_straight := destination_direction == chosen_direction
		var destination_run := int(run_length.get(destination.coordinate, 0))
		run_length[tile.coordinate] = (
			1 + destination_run if continues_straight else 1
		)
		incoming_count[destination.coordinate] = (
			int(incoming_count.get(destination.coordinate, 0)) + 1
		)
	return {
		"changed": changed,
		"eligible_count": eligible_count,
		"changed_count": changed.size(),
	}


## Selects one destination direction for an eligible flatland tile.
##
## Hard constraints (never violated): the destination must be lower in the
## frozen pre-reroute effective elevation or equal and already finalized,
## must not be inside any lake interior, and must have same-or-lower
## discrete gameplay relief (or an equal raw height within the narrow
## flatland tolerance), so a reroute can never cross a ridge or climb.
## Among the safe
## candidates, destinations whose own already-finalized direction would
## keep this edge within a one-step logical turn are strongly preferred
## (the existing zero-sharp-turn invariant is preserved by construction
## whenever a same/near-same-direction safe candidate exists; the wider
## safe pool is only used when every safe candidate would otherwise turn
## sharply). Within that preferred pool, a smooth low-frequency
## seed-derived potential/phase field, a soft penalty against extending a
## long straight run, a bonus for joining an already-converging tile, and a
## penalty against running parallel and adjacent to another already-chosen
## path combine into gentle multi-cell bends and gradual reversals instead
## of per-cell zigzag.
static func _choose_flatland_direction(
	world: HexWorldData,
	tile: HexTileData,
	original_direction: int,
	frozen_elevation: Dictionary,
	original_directions: Dictionary,
	final_direction: Dictionary,
	run_length: Dictionary,
	incoming_count: Dictionary
) -> int:
	var origin_elevation := int(frozen_elevation[tile.coordinate])
	var origin_raw := _raw_height(tile)
	var safe_pool: Array = []
	for direction in range(6):
		var neighbor_tile := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, direction)
		)
		if neighbor_tile == null or neighbor_tile.lake_id >= 0:
			continue
		var neighbor_elevation := int(
			frozen_elevation.get(neighbor_tile.coordinate, origin_elevation)
		)
		if (
			neighbor_elevation > origin_elevation
			or (
				neighbor_elevation == origin_elevation
				and not final_direction.has(neighbor_tile.coordinate)
			)
		):
			continue
		var relief_ok := (
			neighbor_tile.elevation_level <= tile.elevation_level
			or absi(_raw_height(neighbor_tile) - origin_raw)
				<= FLATLAND_RAW_RELIEF_TOLERANCE
		)
		if not relief_ok:
			continue
		var preserves_original_inflows := true
		for upstream_direction in range(6):
			var upstream := world.tile_at(
				HexCoordinatesScript.neighbor(tile.coordinate, upstream_direction)
			)
			if upstream == null:
				continue
			var upstream_flow := int(
				original_directions.get(upstream.coordinate, -1)
			)
			if upstream_flow < 0:
				continue
			var upstream_destination := HexCoordinatesScript.neighbor(
				upstream.coordinate,
				upstream_flow
			)
			if (
				upstream_destination == tile.coordinate
				and _direction_difference(upstream_flow, direction) > 1
			):
				preserves_original_inflows = false
				break
		if not preserves_original_inflows:
			continue
		safe_pool.append({
			"direction": direction,
			"tile": neighbor_tile,
			"elevation": neighbor_elevation,
		})
	if safe_pool.is_empty():
		return tile.flow_direction
	var hard_safe_pool: Array = []
	for candidate in safe_pool:
		var destination: HexTileData = candidate["tile"]
		var destination_direction := int(
			final_direction.get(destination.coordinate, -1)
		)
		if (
			destination_direction < 0
			or _direction_difference(
				int(candidate["direction"]),
				destination_direction
			) <= 1
		):
			hard_safe_pool.append(candidate)
	# Never trade the network-wide zero-sharp-turn invariant for a reroute.
	# The original priority-flood direction remains valid when no candidate
	# can join the already-finalized downstream graph with a gentle bend.
	if hard_safe_pool.is_empty():
		return original_direction
	var active_pool: Array = hard_safe_pool
	var minimum_elevation := int(active_pool[0]["elevation"])
	for candidate in active_pool:
		minimum_elevation = mini(minimum_elevation, int(candidate["elevation"]))
	var near_pool: Array = []
	for candidate in active_pool:
		if (
			int(candidate["elevation"])
				<= minimum_elevation + FLATLAND_NEAR_LOWEST_TOLERANCE
		):
			near_pool.append(candidate)
	var potential := _flatland_meander_potential(world, tile)
	# Treat the smooth field as a lateral bias around the priority-flood
	# downslope. An absolute world-space angle often points uphill and leaves
	# the only safe downhill direction unchanged, recreating ruler-straight
	# plateau rivers.
	var preferred_angle := (
		float(original_direction) * (TAU / 6.0)
		+ (potential - 0.5) * (TAU / 3.0)
	)
	var best_direction := int(near_pool[0]["direction"])
	var best_score := -INF
	for candidate in near_pool:
		var direction := int(candidate["direction"])
		var destination: HexTileData = candidate["tile"]
		var candidate_angle := float(direction) * (TAU / 6.0)
		var alignment := cos(preferred_angle - candidate_angle)
		var destination_direction := int(
			final_direction.get(destination.coordinate, -1)
		)
		var destination_run := int(run_length.get(destination.coordinate, 0))
		var continues_straight := destination_direction == direction
		var predicted_run := 1 + destination_run if continues_straight else 1
		var straight_penalty := 0.0
		if predicted_run > FLATLAND_MAX_STRAIGHT_RUN:
			straight_penalty = (
				float(predicted_run - FLATLAND_MAX_STRAIGHT_RUN)
				* FLATLAND_STRAIGHT_RUN_PENALTY
			)
		var sharp_penalty := 0.0
		if (
			destination_direction >= 0
			and _direction_difference(direction, destination_direction) >= 2
		):
			sharp_penalty = FLATLAND_SHARP_TURN_PENALTY
		var convergence_bonus := (
			float(int(incoming_count.get(destination.coordinate, 0)))
			* FLATLAND_CONVERGENCE_BONUS
		)
		var parallel_penalty := _flatland_parallel_penalty(
			world,
			tile,
			direction,
			destination,
			final_direction
		)
		var score := (
			alignment * FLATLAND_ALIGNMENT_WEIGHT
			- float(int(candidate["elevation"])) * FLATLAND_ELEVATION_WEIGHT
			- straight_penalty
			- sharp_penalty
			+ convergence_bonus
			- parallel_penalty
		)
		if score > best_score:
			best_score = score
			best_direction = direction
	return best_direction


## Penalizes a candidate direction that would run immediately adjacent and
## parallel to another already-finalized flatland path, discouraging
## braided/parallel reaches while leaving genuine convergence (handled by
## the confluence bonus above) unpenalized.
static func _flatland_parallel_penalty(
	world: HexWorldData,
	tile: HexTileData,
	direction: int,
	destination: HexTileData,
	final_direction: Dictionary
) -> float:
	var penalty := 0.0
	for other_direction in range(6):
		if other_direction == direction:
			continue
		var other_neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, other_direction)
		)
		if (
			other_neighbor == null
			or other_neighbor.coordinate == destination.coordinate
			or HexCoordinatesScript.distance(
				other_neighbor.coordinate,
				destination.coordinate
			) != 1
		):
			continue
		var other_direction_final := int(
			final_direction.get(other_neighbor.coordinate, -1)
		)
		if other_direction_final < 0:
			continue
		if _direction_difference(other_direction_final, direction) <= 1:
			penalty += FLATLAND_PARALLEL_PENALTY
	return penalty


## Smooth, low-frequency, seed-derived routing potential mapped to a
## preferred logical direction phase. Two slowly varying sine waves at
## different low frequencies and orientations, offset by a dedicated
## per-world phase drawn from `MEANDER_SALT`, combine into a field that
## drifts gently across many tiles rather than oscillating tile to tile,
## which is what lets consecutive reroutes prefer multi-cell gentle bends
## and gradual reversals over per-cell zigzag.
static func _flatland_meander_potential(
	world: HexWorldData,
	tile: HexTileData
) -> float:
	var seed_phase := _hash_unit(world.seed, MEANDER_SALT, Vector2i.ZERO) * TAU
	var x := float(tile.offset_coordinate.x)
	var y := float(tile.offset_coordinate.y)
	var wave := (
		sin(x * FLATLAND_MEANDER_FREQUENCY_A + y * FLATLAND_MEANDER_FREQUENCY_B + seed_phase)
		+ sin(
			x * FLATLAND_MEANDER_FREQUENCY_C
			- y * FLATLAND_MEANDER_FREQUENCY_A
			+ seed_phase * 1.7
		)
	) * 0.25 + 0.5
	return clampf(wave, 0.0, 1.0)


## Diagnostics for the logical (selected-edge) flatland meander, as
## distinct from the runtime rendering spline's cosmetic centerline
## deviation reported by `HexHydrologyMesher.river_visual_quality_metrics`.
## These inspect the actual selected hex-adjacency edges (`flow_direction`
## and `river_selected_connections`), not sampled curve geometry.
static func _flatland_logical_meander_diagnostics(
	world: HexWorldData,
	reroute_result: Dictionary
) -> Dictionary:
	var changed: Dictionary = reroute_result.get("changed", {})
	var selected_reroute_edge_count := 0
	var straight_run_count := 0
	var straight_run_maximum := 0
	var gentle_bend_count := 0
	var zigzag_reversal_count := 0
	for tile in world.tiles:
		if (
			tile.flow_direction < 0
			or tile.river_selected_connections[tile.flow_direction] == 0
			or not FLATLAND_ELEVATION_LEVELS.has(tile.elevation_level)
		):
			continue
		if changed.has(tile.coordinate):
			selected_reroute_edge_count += 1
		if _flatland_selected_run_start(world, tile):
			var length := _flatland_selected_run_length(world, tile)
			if length >= 2:
				straight_run_count += 1
				straight_run_maximum = maxi(straight_run_maximum, length)
		var destination := _flow_destination(world, tile)
		if (
			destination != null
			and FLATLAND_ELEVATION_LEVELS.has(destination.elevation_level)
			and destination.flow_direction >= 0
			and destination.river_selected_connections[destination.flow_direction] != 0
		):
			var difference := _direction_difference(
				tile.flow_direction,
				destination.flow_direction
			)
			if difference == 1:
				gentle_bend_count += 1
			elif difference >= 2:
				zigzag_reversal_count += 1
	return {
		"flatland_reroute_eligible_count": int(
			reroute_result.get("eligible_count", 0)
		),
		"flatland_reroute_total_count": int(
			reroute_result.get("changed_count", 0)
		),
		"flatland_reroute_selected_edge_count": selected_reroute_edge_count,
		"flatland_straight_river_run_count": straight_run_count,
		"flatland_max_straight_river_run_length": straight_run_maximum,
		"flatland_gentle_bend_count": gentle_bend_count,
		"flatland_zigzag_reversal_count": zigzag_reversal_count,
	}


## True when no selected-flatland upstream neighbor continues the same
## logical direction into `tile` — i.e. `tile` is the upstream-most edge of
## its maximal straight run (or a run of length one).
static func _flatland_selected_run_start(
	world: HexWorldData,
	tile: HexTileData
) -> bool:
	for neighbor in world.valid_neighbors(tile.coordinate):
		if (
			neighbor.flow_direction >= 0
			and neighbor.river_selected_connections[neighbor.flow_direction] != 0
			and FLATLAND_ELEVATION_LEVELS.has(neighbor.elevation_level)
			and neighbor.flow_direction == tile.flow_direction
			and _flow_destination(world, neighbor) == tile
		):
			return false
	return true


## Length, in edges, of the maximal straight (single logical direction)
## selected-flatland run starting at `start` and walking downstream.
static func _flatland_selected_run_length(
	world: HexWorldData,
	start: HexTileData
) -> int:
	var length := 0
	var current := start
	var direction := start.flow_direction
	var guard := 0
	while (
		current != null
		and current.flow_direction == direction
		and current.flow_direction >= 0
		and current.river_selected_connections[current.flow_direction] != 0
		and FLATLAND_ELEVATION_LEVELS.has(current.elevation_level)
	):
		length += 1
		current = _flow_destination(world, current)
		guard += 1
		if guard > world.tiles.size():
			break
	return length


static func _rebuild_effective_elevation(
	world: HexWorldData,
	ocean: Dictionary
) -> void:
	var children: Dictionary = {}
	for tile in world.tiles:
		if tile.is_ocean or tile.flow_direction < 0:
			continue
		var destination := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
		)
		if destination == null:
			continue
		if not children.has(destination.coordinate):
			children[destination.coordinate] = []
		(children[destination.coordinate] as Array).append(tile)
	var queue: Array[HexTileData] = []
	for coordinate in ocean:
		var root := world.tile_at(coordinate)
		root.effective_elevation = 0
		queue.append(root)
	var head := 0
	var visited: Dictionary = {}
	while head < queue.size():
		var parent := queue[head]
		head += 1
		if visited.has(parent.coordinate):
			continue
		visited[parent.coordinate] = true
		for child_value in children.get(parent.coordinate, []):
			var child := child_value as HexTileData
			child.effective_elevation = maxi(
				_raw_height(child),
				parent.effective_elevation + 1
			)
			queue.append(child)
	assert(visited.size() == world.tiles.size())


static func _downstream_order(
	world: HexWorldData,
	ocean: Dictionary
) -> Array[HexTileData]:
	var children: Dictionary = {}
	for tile in world.tiles:
		if tile.is_ocean:
			continue
		var destination := _flow_destination(world, tile)
		if destination == null:
			continue
		if not children.has(destination.coordinate):
			children[destination.coordinate] = []
		(children[destination.coordinate] as Array).append(tile)
	var order: Array[HexTileData] = []
	var queue: Array[HexTileData] = []
	for coordinate in ocean:
		queue.append(world.tile_at(coordinate))
	var head := 0
	while head < queue.size():
		var tile := queue[head]
		head += 1
		order.append(tile)
		var child_values: Array = children.get(tile.coordinate, [])
		child_values.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
			return _tile_index(world, a) < _tile_index(world, b)
		)
		for child in child_values:
			queue.append(child)
	return order


static func _assign_runoff_and_accumulation(
	world: HexWorldData,
	order: Array[HexTileData]
) -> void:
	for tile in world.tiles:
		if tile.is_ocean:
			tile.runoff = 0
			tile.flow_accumulation = 0
			continue
		tile.runoff = clampi(
			1 + roundi(tile.ocean_moisture * 2.0) + int(tile.elevation_level >= 3),
			1,
			4
		)
		tile.flow_accumulation = tile.runoff
	for index in range(order.size() - 1, -1, -1):
		var tile := order[index]
		if tile.is_ocean:
			continue
		var destination := _flow_destination(world, tile)
		if destination != null:
			destination.flow_accumulation += tile.flow_accumulation


static func _assign_watersheds(world: HexWorldData, ocean: Dictionary) -> void:
	var watershed_by_ocean: Dictionary = {}
	var roots: Array[HexTileData] = []
	for coordinate in ocean:
		var root := world.tile_at(coordinate)
		if root.flow_accumulation <= 0:
			continue
		roots.append(root)
	roots.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
		return _tile_index(world, a) < _tile_index(world, b)
	)
	for index in range(roots.size()):
		var root := roots[index]
		var id := posmod(
			_hash_int(world.seed, WATERSHED_SALT, root.coordinate),
			2147483646
		)
		watershed_by_ocean[root.coordinate] = id
	for tile in world.tiles:
		if tile.is_ocean:
			tile.watershed_id = int(watershed_by_ocean.get(tile.coordinate, -1))
			continue
		var current := tile
		while current != null and not current.is_ocean:
			current = _flow_destination(world, current)
		tile.watershed_id = (
			int(watershed_by_ocean.get(current.coordinate, -1))
			if current != null
			else -1
		)


static func _select_rivers(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Dictionary:
	var target := roundi(
		float(settings.river_count)
		* sqrt(float(world.tiles.size()) / 6400.0)
	)
	var best_threshold := 0
	var best_heads: Array[HexTileData] = []
	if target > 0:
		var water_distance := _distance_from_water(world)
		var best_result := _choose_river_threshold(
			world,
			target,
			settings.minimum_river_length,
			water_distance,
			HEADWATER_MIN_SPACING
		)
		best_threshold = int(best_result["threshold"])
		best_heads.assign(best_result["heads"])
	var selected_edges: Dictionary = {}
	for head in best_heads:
		var current := head
		while current != null and not current.is_ocean and current.lake_id < 0:
			var destination := _flow_destination(world, current)
			if destination == null:
				break
			_encode_river_edge(
				world,
				current,
				destination,
				selected_edges,
				true
			)
			if destination.is_ocean or destination.lake_id >= 0:
				break
			current = destination
	var encoded_edges: Dictionary = selected_edges.duplicate()
	for tile in world.tiles:
		if tile.lake_outlet_direction < 0:
			continue
		var current := tile
		while current != null and not current.is_ocean:
			var destination := _flow_destination(world, current)
			if destination == null:
				break
			if current.lake_id < 0 or current.lake_outlet_direction >= 0:
				_encode_river_edge(
					world,
					current,
					destination,
					encoded_edges,
					false
				)
			current = destination
	var realized_heads := _realized_river_heads(world)
	return {
		"threshold": best_threshold,
		"headwater_count": realized_heads.size(),
		"edge_count": encoded_edges.size(),
		"heads": realized_heads,
	}


static func _river_source_candidates(
	world: HexWorldData,
	threshold: int,
	minimum_length: int,
	water_distance: Dictionary
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for tile in _river_heads(world, threshold, minimum_length):
		var distance := int(water_distance.get(tile.coordinate, 0))
		var wet_interior := (
			tile.ocean_moisture >= WET_INTERIOR_MOISTURE
				and distance >= WET_INTERIOR_WATER_DISTANCE
		)
		var qualified := tile.elevation_level >= 2 or wet_interior
		var route_length := _downstream_length_to_water(world, tile)
		var relief := _upstream_relief(world, tile)
		var score := (
			_source_terrain_score(tile.elevation_level, wet_interior)
				+ log(float(tile.flow_accumulation) + 1.0) * 320.0
				+ float(mini(route_length, 48)) * 18.0
				+ tile.ocean_moisture * 620.0
				+ float(relief) * 360.0
				+ float(mini(distance, 8)) * 75.0
				+ _hash_unit(world.seed, SOURCE_SALT, tile.coordinate) * 96.0
		)
		result.append({
			"tile": tile,
			"qualified": qualified,
			"wet_interior": wet_interior,
			"score": score,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["score"]), float(b["score"])):
			return float(a["score"]) > float(b["score"])
		return (
			_tile_index(world, a["tile"] as HexTileData)
			< _tile_index(world, b["tile"] as HexTileData)
		)
	)
	return result


static func _choose_river_threshold(
	world: HexWorldData,
	target: int,
	minimum_length: int,
	water_distance: Dictionary,
	minimum_spacing: int
) -> Dictionary:
	var best_threshold := 0
	var best_heads: Array[HexTileData] = []
	var best_distance := 2147483647
	var best_qualified_count := -1
	var best_score := -INF
	for threshold in _candidate_flow_thresholds(world):
		var candidates := _river_source_candidates(
			world,
			threshold,
			minimum_length,
			water_distance
		)
		var heads := _choose_river_heads(
			world,
			candidates,
			target,
			minimum_spacing
		)
		var selected_coordinates: Dictionary = {}
		for head in heads:
			selected_coordinates[head.coordinate] = true
		var qualified_count := 0
		var score := 0.0
		for candidate in candidates:
			var tile := candidate["tile"] as HexTileData
			if not selected_coordinates.has(tile.coordinate):
				continue
			qualified_count += int(bool(candidate["qualified"]))
			score += float(candidate["score"])
		var distance := absi(target - heads.size())
		var is_better := (
			distance < best_distance
			or (
				distance == best_distance
				and (
					qualified_count > best_qualified_count
					or (
						qualified_count == best_qualified_count
						and (
							score > best_score
							or (
								is_equal_approx(score, best_score)
								and threshold > best_threshold
							)
						)
					)
				)
			)
		)
		if not is_better:
			continue
		best_threshold = threshold
		best_heads = heads
		best_distance = distance
		best_qualified_count = qualified_count
		best_score = score
	return {
		"threshold": best_threshold,
		"heads": best_heads,
	}


static func _candidate_flow_thresholds(world: HexWorldData) -> Array[int]:
	var values: Array[int] = []
	for tile in world.tiles:
		if not tile.is_ocean and tile.lake_id < 0:
			values.append(tile.flow_accumulation)
	values.sort()
	var thresholds: Array[int] = [2]
	var stride := maxi(1, values.size() / 96)
	for index in range(0, values.size(), stride):
		var value := values[index]
		if value > 1 and not thresholds.has(value):
			thresholds.append(value)
	if not values.is_empty() and not thresholds.has(values[-1]):
		thresholds.append(values[-1])
	return thresholds


static func _choose_river_heads(
	world: HexWorldData,
	candidates: Array[Dictionary],
	target: int,
	minimum_spacing: int
) -> Array[HexTileData]:
	var result: Array[HexTileData] = []
	var selected_network: Dictionary = {}
	var used: Dictionary = {}
	for qualified_only in [true, false]:
		while result.size() < target:
			var best_candidate: Dictionary = {}
			var best_adjusted_score := -INF
			for candidate in candidates:
				var tile := candidate["tile"] as HexTileData
				if (
					used.has(tile.coordinate)
					or (qualified_only and not bool(candidate["qualified"]))
				):
					continue
				var relationship := _source_network_relationship(
					world,
					tile,
					result,
					selected_network,
					minimum_spacing
				)
				if bool(relationship["reject"]):
					continue
				var adjusted_score := float(candidate["score"])
				var join_distance := int(relationship["join_distance"])
				if join_distance > 0:
					adjusted_score += maxf(
						80.0,
						300.0 - float(join_distance) * 14.0
					)
				if adjusted_score > best_adjusted_score:
					best_adjusted_score = adjusted_score
					best_candidate = candidate
				elif (
					is_equal_approx(adjusted_score, best_adjusted_score)
					and not best_candidate.is_empty()
					and _tile_index(world, tile)
						< _tile_index(
							world,
							best_candidate["tile"] as HexTileData
						)
				):
					best_candidate = candidate
			if best_candidate.is_empty():
				break
			var selected := best_candidate["tile"] as HexTileData
			result.append(selected)
			used[selected.coordinate] = true
			_add_downstream_path_to_network(world, selected, selected_network)
		if result.size() >= target:
			break
	return result


static func _realized_river_heads(world: HexWorldData) -> Array[HexTileData]:
	var result: Array[HexTileData] = []
	for tile in world.tiles:
		if (
			tile.flow_direction < 0
			or tile.river_selected_connections[tile.flow_direction] == 0
		):
			continue
		var has_selected_upstream := false
		for neighbor in world.valid_neighbors(tile.coordinate):
			if (
				neighbor.flow_direction >= 0
				and neighbor.river_selected_connections[neighbor.flow_direction] != 0
				and _flow_destination(world, neighbor) == tile
			):
				has_selected_upstream = true
				break
		if not has_selected_upstream:
			result.append(tile)
	return result


static func _source_network_relationship(
	world: HexWorldData,
	candidate: HexTileData,
	selected_heads: Array[HexTileData],
	selected_network: Dictionary,
	minimum_spacing: int
) -> Dictionary:
	if selected_network.has(candidate.coordinate):
		return {"reject": true, "join_distance": 0}
	for head in selected_heads:
		if (
			HexCoordinatesScript.distance(candidate.coordinate, head.coordinate)
				< minimum_spacing
			and not _headwaters_converge_nearby(
				world,
				head,
				candidate,
				minimum_spacing
			)
		):
			return {"reject": true, "join_distance": -1}
		if _headwater_paths_are_close_parallel(world, head, candidate):
			return {"reject": true, "join_distance": -1}
	var current := candidate
	var join_distance := -1
	var steps := 0
	while current != null and not current.is_ocean:
		if selected_network.has(current.coordinate):
			join_distance = steps
			break
		current = _flow_destination(world, current)
		steps += 1
		if steps > world.tiles.size():
			break
	return {"reject": false, "join_distance": join_distance}


static func _add_downstream_path_to_network(
	world: HexWorldData,
	start: HexTileData,
	network: Dictionary
) -> void:
	var current := start
	var steps := 0
	while current != null and not current.is_ocean:
		network[current.coordinate] = true
		if current.lake_id >= 0:
			break
		current = _flow_destination(world, current)
		steps += 1
		if steps > world.tiles.size():
			break


static func _source_terrain_score(
	elevation_level: int,
	wet_interior: bool
) -> float:
	if elevation_level >= 4:
		return 6600.0
	if elevation_level >= 3:
		return 5600.0
	if elevation_level >= 2:
		return 3900.0
	if wet_interior:
		return 2700.0
	return -2200.0


static func _upstream_relief(world: HexWorldData, tile: HexTileData) -> int:
	var upstream_maximum := tile.elevation_level
	for neighbor in world.valid_neighbors(tile.coordinate):
		if _flow_destination(world, neighbor) == tile:
			upstream_maximum = maxi(upstream_maximum, neighbor.elevation_level)
	var downstream_minimum := tile.elevation_level
	var current := tile
	for _step in range(3):
		current = _flow_destination(world, current)
		if current == null:
			break
		downstream_minimum = mini(downstream_minimum, current.elevation_level)
	return maxi(upstream_maximum - downstream_minimum, 0)


static func _river_heads(
	world: HexWorldData,
	threshold: int,
	minimum_length: int
) -> Array[HexTileData]:
	var result: Array[HexTileData] = []
	for tile in world.tiles:
		if (
			tile.is_ocean
			or tile.lake_id >= 0
			or tile.flow_accumulation < threshold
			or _downstream_length_to_water(world, tile) < minimum_length
		):
			continue
		var has_qualifying_upstream := false
		for neighbor in world.valid_neighbors(tile.coordinate):
			if (
				not neighbor.is_ocean
				and _flow_destination(world, neighbor) == tile
				and neighbor.flow_accumulation >= threshold
			):
				has_qualifying_upstream = true
				break
		if not has_qualifying_upstream:
			result.append(tile)
	return result


static func _downstream_length_to_water(world: HexWorldData, start: HexTileData) -> int:
	var length := 0
	var current := start
	while current != null and not current.is_ocean and current.lake_id < 0:
		current = _flow_destination(world, current)
		length += 1
		if length > world.tiles.size():
			return 0
	return length


static func _encode_river_edge(
	world: HexWorldData,
	source: HexTileData,
	destination: HexTileData,
	encoded_edges: Dictionary,
	is_selected: bool
) -> void:
	var direction := source.flow_direction
	if direction < 0:
		return
	var reverse := posmod(direction + 3, 6)
	var edge_key := _edge_key(source, destination)
	var flow := source.flow_accumulation
	source.river_connections[direction] = 1
	destination.river_connections[reverse] = 1
	if is_selected:
		source.river_selected_connections[direction] = 1
		destination.river_selected_connections[reverse] = 1
	source.river_flow[direction] = flow
	destination.river_flow[reverse] = flow
	encoded_edges[edge_key] = true


static func _flow_destination(
	world: HexWorldData,
	tile: HexTileData
) -> HexTileData:
	if tile.flow_direction < 0:
		return null
	return world.tile_at(
		HexCoordinatesScript.neighbor(tile.coordinate, tile.flow_direction)
	)


static func _maximum_accumulation(world: HexWorldData) -> int:
	var maximum := 0
	for tile in world.tiles:
		maximum = maxi(maximum, tile.flow_accumulation)
	return maximum


static func _watershed_count(world: HexWorldData) -> int:
	var ids: Dictionary = {}
	for tile in world.tiles:
		if tile.watershed_id >= 0:
			ids[tile.watershed_id] = true
	return ids.size()


static func _hydrology_diagnostics(
	world: HexWorldData,
	head_values: Array,
	minimum_spacing: int
) -> Dictionary:
	var heads: Array[HexTileData] = []
	for value in head_values:
		heads.append(value as HexTileData)
	var water_distance := _distance_from_water(world)
	var elevated_sources := 0
	var mountain_sources := 0
	var highland_sources := 0
	var wet_interior_sources := 0
	var unqualified_sources := 0
	var elevation_total := 0.0
	var moisture_total := 0.0
	var systems: Dictionary = {}
	for head in heads:
		var distance := int(water_distance.get(head.coordinate, 0))
		var elevated := head.elevation_level >= 2
		var wet_interior := (
			head.ocean_moisture >= WET_INTERIOR_MOISTURE
			and distance >= WET_INTERIOR_WATER_DISTANCE
		)
		elevated_sources += int(elevated)
		mountain_sources += int(
			head.elevation_level == 4 and head.terrain_type == &"mountain"
		)
		highland_sources += int(
			head.elevation_level == 3 and head.terrain_type == &"highland"
		)
		wet_interior_sources += int(not elevated and wet_interior)
		unqualified_sources += int(not elevated and not wet_interior)
		elevation_total += float(head.elevation_level)
		moisture_total += head.ocean_moisture
		systems[head.watershed_id] = true
	var close_headwaters := 0
	for first_index in range(heads.size()):
		for second_index in range(first_index + 1, heads.size()):
			var first := heads[first_index]
			var second := heads[second_index]
			if (
				HexCoordinatesScript.distance(first.coordinate, second.coordinate)
					>= minimum_spacing
				or _headwaters_converge_nearby(
					world,
					first,
					second,
					minimum_spacing
				)
			):
				continue
			close_headwaters += 1
	var confluences := 0
	var sharp_turns := 0
	var uphill_violations := 0
	for tile in world.tiles:
		if (
			tile.flow_direction < 0
			or tile.river_connections[tile.flow_direction] == 0
		):
			continue
		var destination := _flow_destination(world, tile)
		if (
			destination == null
			or tile.effective_elevation <= destination.effective_elevation
		):
			uphill_violations += 1
		var incoming_directions: Array[int] = []
		for neighbor in world.valid_neighbors(tile.coordinate):
			if (
				neighbor.flow_direction >= 0
				and neighbor.river_connections[neighbor.flow_direction] != 0
				and _flow_destination(world, neighbor) == tile
			):
				incoming_directions.append(neighbor.flow_direction)
		if incoming_directions.size() >= 2:
			confluences += 1
		for incoming_direction in incoming_directions:
			if _direction_difference(incoming_direction, tile.flow_direction) >= 2:
				sharp_turns += 1
	return {
		"source_elevated_qualification_count": elevated_sources,
		"source_mountain_qualification_count": mountain_sources,
		"source_highland_qualification_count": highland_sources,
		"source_wet_interior_qualification_count": wet_interior_sources,
		"source_unqualified_count": unqualified_sources,
		"mean_source_elevation_level": (
			elevation_total / float(heads.size()) if not heads.is_empty() else 0.0
		),
		"mean_source_ocean_moisture": (
			moisture_total / float(heads.size()) if not heads.is_empty() else 0.0
		),
		"close_headwater_violation_count": close_headwaters,
		"parallel_river_violation_count": _parallel_headwater_violation_count(
			world,
			heads
		),
		"sharp_river_turn_count": sharp_turns,
		"river_confluence_count": confluences,
		"river_system_count": systems.size(),
		"downstream_uphill_violation_count": uphill_violations,
	}


static func _distance_from_water(world: HexWorldData) -> Dictionary:
	var result: Dictionary = {}
	var queue: Array[Vector2i] = []
	for tile in world.tiles:
		if not tile.is_ocean and tile.lake_id < 0:
			continue
		result[tile.coordinate] = 0
		queue.append(tile.coordinate)
	var head := 0
	while head < queue.size():
		var coordinate := queue[head]
		head += 1
		var distance := int(result[coordinate])
		for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
			if (
				world.tile_at(neighbor_coordinate) == null
				or result.has(neighbor_coordinate)
			):
				continue
			result[neighbor_coordinate] = distance + 1
			queue.append(neighbor_coordinate)
	return result


static func _headwaters_converge_nearby(
	world: HexWorldData,
	first: HexTileData,
	second: HexTileData,
	maximum_steps: int
) -> bool:
	var first_path: Dictionary = {}
	var current := first
	var steps := 0
	while current != null and steps <= world.tiles.size():
		if current == null:
			break
		first_path[current.coordinate] = steps
		current = _flow_destination(world, current)
		steps += 1
	current = second
	for _step in range(maximum_steps + 1):
		if current == null:
			break
		if (
			first_path.has(current.coordinate)
			and int(first_path[current.coordinate]) <= maximum_steps
		):
			return true
		current = _flow_destination(world, current)
	return false


static func _parallel_headwater_violation_count(
	world: HexWorldData,
	heads: Array[HexTileData]
) -> int:
	var violations := 0
	for first_index in range(heads.size()):
		for second_index in range(first_index + 1, heads.size()):
			if _headwater_paths_are_close_parallel(
				world,
				heads[first_index],
				heads[second_index]
			):
				violations += 1
	return violations


static func _headwater_paths_are_close_parallel(
	world: HexWorldData,
	first: HexTileData,
	second: HexTileData
) -> bool:
	if (
		first == null
		or second == null
		or first == second
		or first.watershed_id < 0
		or first.watershed_id != second.watershed_id
	):
		return false
	var canonical_first := first
	var canonical_second := second
	if _tile_index(world, canonical_second) < _tile_index(world, canonical_first):
		canonical_first = second
		canonical_second = first
	var first_path := _downstream_path_coordinates(world, canonical_first)
	var second_path := _downstream_path_coordinates(world, canonical_second)
	var second_steps: Dictionary = {}
	for second_step in range(second_path.size()):
		second_steps[second_path[second_step]] = second_step
	var first_limit := first_path.size()
	var second_limit := second_path.size()
	for first_step in range(first_path.size()):
		var shared_coordinate := first_path[first_step]
		if not second_steps.has(shared_coordinate):
			continue
		first_limit = first_step
		second_limit = int(second_steps[shared_coordinate])
		break
	for first_step in range(first_limit - 1):
		for second_step in range(second_limit - 1):
			if (
				_path_steps_are_close_parallel(
					world,
					first_path[first_step],
					second_path[second_step]
				)
				and _path_steps_are_close_parallel(
					world,
					first_path[first_step + 1],
					second_path[second_step + 1]
				)
			):
				return true
	return false


static func _path_steps_are_close_parallel(
	world: HexWorldData,
	first_coordinate: Vector2i,
	second_coordinate: Vector2i
) -> bool:
	if HexCoordinatesScript.distance(first_coordinate, second_coordinate) != 1:
		return false
	var first := world.tile_at(first_coordinate)
	var second := world.tile_at(second_coordinate)
	return (
		first != null
		and second != null
		and first.watershed_id >= 0
		and first.watershed_id == second.watershed_id
		and first.flow_direction >= 0
		and second.flow_direction >= 0
		and _direction_difference(first.flow_direction, second.flow_direction) <= 1
	)


static func _downstream_path_coordinates(
	world: HexWorldData,
	start: HexTileData
) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var current := start
	while current != null and not current.is_ocean:
		result.append(current.coordinate)
		if current.lake_id >= 0:
			break
		current = _flow_destination(world, current)
		if result.size() > world.tiles.size():
			break
	return result


static func _direction_difference(first: int, second: int) -> int:
	var difference := absi(first - second)
	return mini(difference, 6 - difference)


static func _raw_height(tile: HexTileData) -> int:
	return maxi(0, roundi(tile.elevation * RAW_SCALE))


static func _tile_index(world: HexWorldData, tile: HexTileData) -> int:
	return tile.offset_coordinate.y * world.width + tile.offset_coordinate.x


static func _edge_key(a: HexTileData, b: HexTileData) -> String:
	var first := "%d:%d" % [a.coordinate.x, a.coordinate.y]
	var second := "%d:%d" % [b.coordinate.x, b.coordinate.y]
	return "%s|%s" % [first, second] if first < second else "%s|%s" % [second, first]


static func _hash_int(seed: int, salt: int, coordinate: Vector2i) -> int:
	return int(hash("%d:%d:%d:%d" % [seed, salt, coordinate.x, coordinate.y]))


static func _hash_unit(seed: int, salt: int, coordinate: Vector2i) -> float:
	return float(posmod(_hash_int(seed, salt, coordinate), 1000003)) / 1000002.0


static func _heap_push(heap: Array, entry: Array) -> void:
	heap.append(entry)
	var index := heap.size() - 1
	while index > 0:
		var parent := (index - 1) / 2
		if not _heap_less(entry, heap[parent]):
			break
		heap[index] = heap[parent]
		index = parent
	heap[index] = entry


static func _heap_pop(heap: Array) -> Array:
	var result: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return result
	var index := 0
	while true:
		var left := index * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var child := left
		if right < heap.size() and _heap_less(heap[right], heap[left]):
			child = right
		if not _heap_less(heap[child], last):
			break
		heap[index] = heap[child]
		index = child
	heap[index] = last
	return result


static func _heap_less(a: Array, b: Array) -> bool:
	return int(a[0]) < int(b[0]) or (
		int(a[0]) == int(b[0])
		and (
			int(a[1]) < int(b[1])
			or (int(a[1]) == int(b[1]) and int(a[2]) < int(b[2]))
		)
	)
