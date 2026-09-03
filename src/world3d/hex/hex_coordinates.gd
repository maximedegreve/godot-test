class_name HexCoordinates
extends RefCounted

## Pointy-top axial coordinates. Direction order is clockwise:
## east, south-east, south-west, west, north-west, north-east.
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
	Vector2i(1, -1),
]
const SQRT_THREE := 1.7320508075688772


static func neighbor(coordinate: Vector2i, direction: int) -> Vector2i:
	return coordinate + DIRECTIONS[posmod(direction, DIRECTIONS.size())]


static func neighbors(coordinate: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for direction in DIRECTIONS:
		result.append(coordinate + direction)
	return result


static func distance(a: Vector2i, b: Vector2i) -> int:
	var delta := a - b
	return maxi(abs(delta.x), maxi(abs(delta.y), abs(delta.x + delta.y)))


static func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	if radius < 0:
		return []
	if radius == 0:
		return [center]
	var result: Array[Vector2i] = []
	var current := center + DIRECTIONS[4] * radius
	for direction_index in range(6):
		for step in range(radius):
			result.append(current)
			current += DIRECTIONS[direction_index]
	return result


static func range_coordinates(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if radius < 0:
		return result
	for q_offset in range(-radius, radius + 1):
		var minimum_r := maxi(-radius, -q_offset - radius)
		var maximum_r := mini(radius, -q_offset + radius)
		for r_offset in range(minimum_r, maximum_r + 1):
			result.append(center + Vector2i(q_offset, r_offset))
	return result


static func axial_to_world(coordinate: Vector2i, hex_size: float) -> Vector3:
	return Vector3(
		hex_size * SQRT_THREE * (float(coordinate.x) + float(coordinate.y) * 0.5),
		0.0,
		hex_size * 1.5 * float(coordinate.y)
	)


## Continuous (unrounded) axial coordinates for `world_position`, i.e. the
## exact value `world_to_axial()` rounds to a tile. Exposed so the terrain
## shader's fragment-space biome field sampling
## (`hex_terrain.gdshader`/`HexTerrainBiomeField`) can mirror this exact
## reference formula: `world_to_axial(p, s) ==
## _round_axial(world_to_axial_fractional(p, s).x, world_to_axial_fractional(p, s).y)`
## for every input, which the test suite verifies directly.
static func world_to_axial_fractional(world_position: Vector3, hex_size: float) -> Vector2:
	if hex_size <= 0.0:
		return Vector2.ZERO
	var fractional_q := (
		SQRT_THREE / 3.0 * world_position.x - world_position.z / 3.0
	) / hex_size
	var fractional_r := (2.0 / 3.0 * world_position.z) / hex_size
	return Vector2(fractional_q, fractional_r)


static func world_to_axial(world_position: Vector3, hex_size: float) -> Vector2i:
	if hex_size <= 0.0:
		return Vector2i.ZERO
	var fractional := world_to_axial_fractional(world_position, hex_size)
	return _round_axial(fractional.x, fractional.y)


static func axial_to_offset(coordinate: Vector2i) -> Vector2i:
	return Vector2i(
		coordinate.x + int(floor(float(coordinate.y) * 0.5)),
		coordinate.y
	)


static func offset_to_axial(offset: Vector2i) -> Vector2i:
	return Vector2i(
		offset.x - int(floor(float(offset.y) * 0.5)),
		offset.y
	)


static func _round_axial(q: float, r: float) -> Vector2i:
	var cube_x := q
	var cube_z := r
	var cube_y := -cube_x - cube_z
	var rounded_x := roundi(cube_x)
	var rounded_y := roundi(cube_y)
	var rounded_z := roundi(cube_z)
	var x_difference := absf(float(rounded_x) - cube_x)
	var y_difference := absf(float(rounded_y) - cube_y)
	var z_difference := absf(float(rounded_z) - cube_z)
	if x_difference > y_difference and x_difference > z_difference:
		rounded_x = -rounded_y - rounded_z
	elif y_difference > z_difference:
		rounded_y = -rounded_x - rounded_z
	else:
		rounded_z = -rounded_x - rounded_y
	return Vector2i(rounded_x, rounded_z)
