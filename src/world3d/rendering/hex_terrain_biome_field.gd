class_name HexTerrainBiomeField
extends RefCounted

## Continuous biome-floor blend field: one small per-world RGBA8 lookup
## texture the terrain shader samples in fragment-space world position,
## instead of reading the mesh's own per-vertex `COLOR`/`COLOR.a`, for the
## `biome` view only.
##
## Root cause this replaces
## --------------------------
## `HexTerrainMesher` renders every land hex as a six-triangle fan from its
## own centre to its six canonical corners, blending biome colour/response
## only at those triangle vertices (per-triangle Gouraud interpolation).
## Geometry stays watertight (corners are shared and averaged across
## touching tiles), but the *colour gradient inside each triangle* is a
## separate, unrelated linear ramp with no relationship to true hex
## adjacency or to a neighbouring triangle's own gradient. At a sharp biome
## boundary this reads as hard-edged triangular "wedges" fanning out from
## each tile centre, rather than a smooth transition — a discontinuity in
## the colour *gradient*, not the colour value, which is exactly what a
## human eye reads as a false edge.
##
## The fix moves biome colour/response off the vertex fan entirely, for the
## `biome` view only, onto a fragment-space sample of this small global
## field, indexed by continuous fractional axial coordinates
## (`HexCoordinates.world_to_axial_fractional`). Every diagnostic view keeps
## reading the original per-vertex `COLOR`/`COLOR.a`, completely unchanged.
##
## Canonical axial parallelogram
## ------------------------------
## `HexWorldData` stores tiles by *offset* coordinates (`width` columns,
## `height` rows, odd-row shove per `HexCoordinates.offset_to_axial`). Axial
## `q = column - floor(row / 2)`, so as `row` grows the valid `q` window
## slides left by one every two rows. A single small rectangular image can
## still hold every tile with no wasted rows: `q_min = -floor((height - 1)
## / 2)`, field width `= width + floor((height - 1) / 2)`, field height
## `= height`. Pixel `(q - q_min, r)` holds axial tile `(q, r)`. See
## `field_bounds()`.
##
## Filling invalid cells
## ----------------------
## Every field pixel gets a colour: land tiles get their exact biome
## colour/response (`HexTerrainMesher.tile_display_color(tile, &"biome")`,
## the same helper the mesher itself uses). Water tiles and the handful of
## parallelogram pixels with no corresponding offset tile near the map's
## ragged edges are filled by a deterministic multi-source breadth-first
## flood fill seeded from every land tile in fixed row-major order and
## expanded through `HexCoordinates.DIRECTIONS` (also fixed order), so
## bilinear/simplex-adjacent sampling can never read a stray or invalid
## value near a coastline or the map edge, and the fill is exactly
## reproducible (never touches `RandomNumberGenerator`, never depends on
## Dictionary/Array iteration order beyond the fixed structures above).
const HexTerrainMesherScript = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")
const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")

const FORMAT := Image.FORMAT_RGBA8
const BYTES_PER_PIXEL := 4


## Canonical axial-parallelogram bounds for an offset grid of `width` columns
## by `height` rows. Pure integer arithmetic, no world required, so tests can
## validate every map-size tier's dimensions/budget directly.
static func field_bounds(width: int, height: int) -> Dictionary:
	if width <= 0 or height <= 0:
		return {"q_min": 0, "width": 0, "height": 0}
	var q_shift := (height - 1) / 2
	return {"q_min": -q_shift, "width": width + q_shift, "height": height}


## Builds the per-world blend field. Returns the repo's standard
## `{"ok": bool, "error": String, ...}` contract: `ok == false` on any world
## that cannot seed a field (no grid, or no land tile at all) so a caller can
## fail explicitly instead of binding a silently-wrong texture. On success
## also returns `image` (an `Image`, RGB biome colour / A material
## response), `origin_q`, `width`, `height`, and `byte_count` (raw RGBA8
## bytes, before any GPU driver padding/mipmap).
static func build(world: HexWorldData) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "HexTerrainBiomeField.build: world is null.", "image": null}
	var bounds := field_bounds(world.width, world.height)
	var field_width: int = bounds["width"]
	var field_height: int = bounds["height"]
	if field_width <= 0 or field_height <= 0:
		return {
			"ok": false,
			"error": (
				"HexTerrainBiomeField.build: world has no valid grid (%dx%d)."
				% [world.width, world.height]
			),
			"image": null,
		}
	var q_min: int = bounds["q_min"]
	var image := Image.create(field_width, field_height, false, FORMAT)
	var visited := PackedByteArray()
	visited.resize(field_width * field_height)
	var queue: Array[Vector2i] = []
	var land_tile_count := 0
	for row in range(world.height):
		for column in range(world.width):
			var tile := world.tile_at_offset(column, row)
			if tile == null or tile.is_water:
				continue
			var axial := tile.coordinate
			var px := axial.x - q_min
			var py := axial.y
			# Every offset (column, row) tile maps inside the parallelogram by
			# construction (see `field_bounds()`); the guard only keeps a
			# future grid-shape change from ever writing outside the image
			# instead of failing silently.
			if px < 0 or px >= field_width or py < 0 or py >= field_height:
				continue
			var color := HexTerrainMesherScript.tile_display_color(tile, &"biome")
			image.set_pixel(px, py, color)
			var index := py * field_width + px
			if visited[index] == 0:
				visited[index] = 1
				queue.append(Vector2i(px, py))
				land_tile_count += 1
	if land_tile_count == 0:
		return {
			"ok": false,
			"error": "HexTerrainBiomeField.build: world has no land tile to seed the field.",
			"image": null,
		}
	_fill_invalid_cells(image, visited, queue, field_width, field_height)
	return {
		"ok": true,
		"error": "",
		"image": image,
		"origin_q": q_min,
		"width": field_width,
		"height": field_height,
		"byte_count": field_width * field_height * BYTES_PER_PIXEL,
	}


## Deterministic multi-source BFS: `queue` already holds every land pixel, in
## fixed row-major seed order. Expansion uses the six fixed
## `HexCoordinates.DIRECTIONS` in order, so two runs over the same world
## always visit cells in the same order and every filled pixel is a copy of
## a real land pixel — never an average, so no fractional colour is ever
## invented near the coast.
static func _fill_invalid_cells(
	image: Image,
	visited: PackedByteArray,
	queue: Array[Vector2i],
	field_width: int,
	field_height: int
) -> void:
	var directions := HexCoordinatesScript.DIRECTIONS
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var current_color := image.get_pixel(current.x, current.y)
		for direction in directions:
			var neighbor := current + direction
			if (
				neighbor.x < 0
				or neighbor.x >= field_width
				or neighbor.y < 0
				or neighbor.y >= field_height
			):
				continue
			var index := neighbor.y * field_width + neighbor.x
			if visited[index] != 0:
				continue
			visited[index] = 1
			image.set_pixel(neighbor.x, neighbor.y, current_color)
			queue.append(neighbor)
