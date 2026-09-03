class_name HexChunkIndex
extends RefCounted

## Phase 5 chunk addressing and dirty tracking.
##
## Terrain geometry is canonical per corner: a corner height is resolved from
## the three tiles touching it, and the cliff wall on an edge is emitted by the
## higher of the two tiles sharing that edge. Mutating one tile therefore
## changes geometry in its own chunk and in the chunk of every tile that shares
## a corner or an edge with it, which for a hex grid is exactly its six
## neighbours. `dependent_chunks` returns that closure so a selective rebuild
## never leaves a seam behind.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")


static func chunk_dimensions(world: HexWorldData, chunk_size: int) -> Vector2i:
	var resolved := maxi(chunk_size, 1)
	return Vector2i(
		ceili(float(world.width) / float(resolved)),
		ceili(float(world.height) / float(resolved))
	)


static func chunk_count(world: HexWorldData, chunk_size: int) -> int:
	var dimensions := chunk_dimensions(world, chunk_size)
	return dimensions.x * dimensions.y


static func chunk_for_offset(offset_coordinate: Vector2i, chunk_size: int) -> Vector2i:
	var resolved := maxi(chunk_size, 1)
	return Vector2i(
		int(floor(float(offset_coordinate.x) / float(resolved))),
		int(floor(float(offset_coordinate.y) / float(resolved)))
	)


static func chunk_for_axial(coordinate: Vector2i, chunk_size: int) -> Vector2i:
	return chunk_for_offset(
		HexCoordinatesScript.axial_to_offset(coordinate),
		chunk_size
	)


static func chunk_name(chunk_coordinate: Vector2i) -> String:
	return "%d_%d" % [chunk_coordinate.x, chunk_coordinate.y]


static func is_inside(world: HexWorldData, chunk_coordinate: Vector2i, chunk_size: int) -> bool:
	var dimensions := chunk_dimensions(world, chunk_size)
	return (
		chunk_coordinate.x >= 0
		and chunk_coordinate.y >= 0
		and chunk_coordinate.x < dimensions.x
		and chunk_coordinate.y < dimensions.y
	)


static func all_chunks(world: HexWorldData, chunk_size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var dimensions := chunk_dimensions(world, chunk_size)
	for chunk_y in range(dimensions.y):
		for chunk_x in range(dimensions.x):
			result.append(Vector2i(chunk_x, chunk_y))
	return result


## Every chunk whose built geometry depends on the given tile, sorted in
## deterministic row-major order.
static func dependent_chunks(
	world: HexWorldData,
	coordinate: Vector2i,
	chunk_size: int
) -> Array[Vector2i]:
	var seen: Dictionary = {}
	var candidates: Array[Vector2i] = [coordinate]
	candidates.append_array(HexCoordinatesScript.neighbors(coordinate))
	for candidate in candidates:
		if not world.has_coordinate(candidate):
			continue
		var chunk := chunk_for_axial(candidate, chunk_size)
		if is_inside(world, chunk, chunk_size):
			seen[chunk] = true
	var result: Array[Vector2i] = []
	result.assign(seen.keys())
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)
	return result


## Union of `dependent_chunks` for a batch of mutated tiles.
static func dependent_chunks_for_tiles(
	world: HexWorldData,
	coordinates: Array,
	chunk_size: int
) -> Array[Vector2i]:
	var seen: Dictionary = {}
	for coordinate_value in coordinates:
		for chunk in dependent_chunks(world, coordinate_value as Vector2i, chunk_size):
			seen[chunk] = true
	var result: Array[Vector2i] = []
	result.assign(seen.keys())
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)
	return result
