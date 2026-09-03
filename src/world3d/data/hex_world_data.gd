class_name HexWorldData
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")

var seed := 0
var profile_id: StringName = &"large"
var width := 0
var height := 0
var hex_size := 1.0
var tiles: Array[HexTileData] = []
var metadata: Dictionary = {}

var _tiles_by_coordinate: Dictionary = {}


func add_tile(tile: HexTileData) -> void:
	tiles.append(tile)
	_tiles_by_coordinate[tile.coordinate] = tile


func tile_at(coordinate: Vector2i) -> HexTileData:
	return _tiles_by_coordinate.get(coordinate) as HexTileData


func tile_at_offset(column: int, row: int) -> HexTileData:
	if column < 0 or row < 0 or column >= width or row >= height:
		return null
	return tile_at(HexCoordinatesScript.offset_to_axial(Vector2i(column, row)))


func has_coordinate(coordinate: Vector2i) -> bool:
	return _tiles_by_coordinate.has(coordinate)


func valid_neighbors(coordinate: Vector2i) -> Array[HexTileData]:
	var result: Array[HexTileData] = []
	for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
		var candidate := tile_at(neighbor_coordinate)
		if candidate != null:
			result.append(candidate)
	return result


func land_tile_count() -> int:
	var result := 0
	for tile in tiles:
		if not tile.is_water:
			result += 1
	return result


func land_component_sizes() -> Array[int]:
	var visited: Dictionary = {}
	var sizes: Array[int] = []
	for tile in tiles:
		if tile.is_water or visited.has(tile.coordinate):
			continue
		var component_size := 0
		var queue: Array[Vector2i] = [tile.coordinate]
		visited[tile.coordinate] = true
		var head := 0
		while head < queue.size():
			var coordinate := queue[head]
			head += 1
			component_size += 1
			for neighbor_coordinate in HexCoordinatesScript.neighbors(coordinate):
				var neighbor := tile_at(neighbor_coordinate)
				if neighbor == null or neighbor.is_water or visited.has(neighbor_coordinate):
					continue
				visited[neighbor_coordinate] = true
				queue.append(neighbor_coordinate)
		sizes.append(component_size)
	sizes.sort()
	sizes.reverse()
	return sizes


func deterministic_signature() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(("%d:%s:%d:%d|" % [seed, profile_id, width, height]).to_utf8_buffer())
	for tile in tiles:
		context.update((tile.stable_signature() + "|").to_utf8_buffer())
	return context.finish().hex_encode()


func climate_signature() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(("%d:%s:%d:%d|" % [seed, profile_id, width, height]).to_utf8_buffer())
	for tile in tiles:
		context.update((tile.climate_signature() + "|").to_utf8_buffer())
	return context.finish().hex_encode()


func hydrology_signature() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(("%d:%s:%d:%d|" % [seed, profile_id, width, height]).to_utf8_buffer())
	for tile in tiles:
		context.update((tile.hydrology_signature() + "|").to_utf8_buffer())
	return context.finish().hex_encode()


func ecology_signature() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(("%d:%s:%d:%d|" % [seed, profile_id, width, height]).to_utf8_buffer())
	for tile in tiles:
		context.update((tile.ecology_signature() + "|").to_utf8_buffer())
	return context.finish().hex_encode()


func world_bounds() -> AABB:
	if tiles.is_empty():
		return AABB()
	var minimum := tiles[0].position
	var maximum := minimum
	for tile in tiles:
		minimum.x = minf(minimum.x, tile.position.x)
		minimum.z = minf(minimum.z, tile.position.z)
		maximum.x = maxf(maximum.x, tile.position.x)
		maximum.z = maxf(maximum.z, tile.position.z)
	return AABB(
		minimum - Vector3(hex_size, 0.0, hex_size),
		(maximum - minimum) + Vector3(hex_size * 2.0, 0.0, hex_size * 2.0)
	)
