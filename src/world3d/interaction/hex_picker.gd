class_name HexPicker
extends RefCounted

## Phase 5 hex picking.
##
## Picking runs against the same canonical full-detail triangle soup that the
## chunk colliders are built from, and every triangle carries the axial
## coordinate of the logical hex that emitted it. A ray therefore resolves the
## correct tile across smooth joins, cliff walls, beach shelves, chunk borders,
## and every tier including Ultra, without depending on which render detail
## level happens to be visible.
##
## Chunks are tested front to back by bounding box, and the search stops as soon
## as the best hit is closer than the next chunk's entry distance, so a tap only
## intersects the handful of chunks the ray actually crosses.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const ChunkIndexScript = preload("res://src/world3d/hex/hex_chunk_index.gd")
const Mesher = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")

const SOURCE_TERRAIN := &"terrain"
const SOURCE_WATER := &"water"
const INVALID_COORDINATE := Vector2i(2147483647, 2147483647)


## Builds the chunk-indexed collision/picking soup for a whole world.
static func build_index(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> Dictionary:
	var index: Dictionary = {}
	for chunk in ChunkIndexScript.all_chunks(world, settings.chunk_size):
		var entry := build_chunk_entry(world, settings, chunk)
		if entry.is_empty():
			continue
		index[chunk] = entry
	return index


static func build_chunk_entry(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i
) -> Dictionary:
	var collision := Mesher.build_chunk_collision(world, settings, chunk_coordinate)
	if int(collision["triangle_count"]) == 0:
		return {}
	return {
		"faces": collision["faces"],
		"face_tiles": collision["face_tiles"],
		"bounds": collision["bounds"],
		"triangle_count": collision["triangle_count"],
	}


static func entry_from_surface(
	surface: HexTerrainMesher.ChunkSurface,
	world: HexWorldData = null,
	land_only := false
) -> Dictionary:
	if surface == null or surface.is_empty():
		return {}
	if land_only:
		if world == null:
			push_error("HexPicker.entry_from_surface requires a world for land-only filtering.")
			return {}
		var faces := PackedVector3Array()
		var face_tiles := PackedInt32Array()
		for face_index in range(surface.triangle_count()):
			var coordinate := surface.tile_coordinate_for_face(face_index)
			var tile := world.tile_at(coordinate)
			if tile == null or tile.is_water:
				continue
			for corner in range(3):
				faces.append(surface.vertices[surface.indices[face_index * 3 + corner]])
			face_tiles.append(coordinate.x)
			face_tiles.append(coordinate.y)
		if faces.is_empty():
			return {}
		return {
			"faces": faces,
			"face_tiles": face_tiles,
			"bounds": surface.bounds(),
			"triangle_count": faces.size() / 3,
		}
	return {
		"faces": surface.collision_faces(),
		"face_tiles": surface.face_tiles,
		"bounds": surface.bounds(),
		"triangle_count": surface.triangle_count(),
	}


static func triangle_count(index: Dictionary) -> int:
	var total := 0
	for key in index:
		total += int((index[key] as Dictionary)["triangle_count"])
	return total


static func collision_memory_bytes(index: Dictionary) -> int:
	# Three Vector3 positions per face plus two axial ints per face.
	var total := 0
	for key in index:
		total += int((index[key] as Dictionary)["triangle_count"]) * (3 * 12 + 2 * 4)
	return total


## Resolves a world-space ray to a logical hex. Terrain is authoritative; when
## the ray misses every land triangle the ocean plane is used so taps on open
## water still return the water hex under the cursor.
static func pick(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	index: Dictionary,
	ray_origin: Vector3,
	ray_direction: Vector3,
	maximum_distance := 100000.0
) -> Dictionary:
	if ray_direction.length_squared() < 0.000001:
		return _miss()
	var direction := ray_direction.normalized()
	var ordered: Array = []
	for key in index:
		var entry: Dictionary = index[key]
		var padded: AABB = (entry["bounds"] as AABB).grow(0.001)
		if padded.has_point(ray_origin):
			ordered.append({"key": key, "distance": 0.0})
			continue
		var contact: Variant = padded.intersects_ray(ray_origin, direction)
		if contact == null:
			continue
		var entry_distance := ((contact as Vector3) - ray_origin).dot(direction)
		if entry_distance < 0.0 or entry_distance > maximum_distance:
			continue
		ordered.append({"key": key, "distance": entry_distance})
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"])
	)
	var best_distance := maximum_distance
	var best_coordinate := INVALID_COORDINATE
	var best_position := Vector3.ZERO
	var best_face := -1
	var best_chunk := Vector2i.ZERO
	var tested_chunks := 0
	for candidate in ordered:
		if float(candidate["distance"]) > best_distance:
			break
		tested_chunks += 1
		var entry: Dictionary = index[candidate["key"]]
		var faces: PackedVector3Array = entry["faces"]
		var face_tiles: PackedInt32Array = entry["face_tiles"]
		for face_index in range(faces.size() / 3):
			var hit: Variant = Geometry3D.ray_intersects_triangle(
				ray_origin,
				direction,
				faces[face_index * 3],
				faces[face_index * 3 + 1],
				faces[face_index * 3 + 2]
			)
			if hit == null:
				continue
			var position: Vector3 = hit
			var distance := (position - ray_origin).dot(direction)
			if distance < 0.0 or distance >= best_distance:
				continue
			best_distance = distance
			best_position = position
			best_face = face_index
			best_chunk = candidate["key"]
			best_coordinate = Vector2i(
				face_tiles[face_index * 2],
				face_tiles[face_index * 2 + 1]
			)
	if best_coordinate != INVALID_COORDINATE:
		return {
			"ok": true,
			"coordinate": best_coordinate,
			"tile": world.tile_at(best_coordinate),
			"position": best_position,
			"distance": best_distance,
			"face_index": best_face,
			"chunk": best_chunk,
			"source": SOURCE_TERRAIN,
			"tested_chunks": tested_chunks,
		}
	return _pick_water(world, settings, ray_origin, direction, maximum_distance, tested_chunks)


static func pick_from_camera(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	index: Dictionary,
	camera: Camera3D,
	screen_position: Vector2
) -> Dictionary:
	if camera == null:
		return _miss()
	return pick(
		world,
		settings,
		index,
		camera.project_ray_origin(screen_position),
		camera.project_ray_normal(screen_position),
		camera.far * 4.0
	)


static func _pick_water(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	ray_origin: Vector3,
	direction: Vector3,
	maximum_distance: float,
	tested_chunks: int
) -> Dictionary:
	if absf(direction.y) < 0.000001:
		return _miss()
	var distance := (settings.ocean_height - ray_origin.y) / direction.y
	if distance < 0.0 or distance > maximum_distance:
		return _miss()
	var position := ray_origin + direction * distance
	var coordinate := HexCoordinatesScript.world_to_axial(position, settings.hex_size)
	var tile := world.tile_at(coordinate)
	if tile == null:
		return _miss()
	return {
		"ok": true,
		"coordinate": coordinate,
		"tile": tile,
		"position": position,
		"distance": distance,
		"face_index": -1,
		"chunk": ChunkIndexScript.chunk_for_axial(coordinate, settings.chunk_size),
		"source": SOURCE_WATER,
		"tested_chunks": tested_chunks,
	}


static func _miss() -> Dictionary:
	return {
		"ok": false,
		"coordinate": INVALID_COORDINATE,
		"tile": null,
		"position": Vector3.ZERO,
		"distance": 0.0,
		"face_index": -1,
		"chunk": Vector2i.ZERO,
		"source": &"",
		"tested_chunks": 0,
	}
