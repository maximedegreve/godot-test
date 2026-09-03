class_name HexTerrainMesher
extends RefCounted

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const EcologyStage = preload("res://src/world3d/generator/ecology_stage.gd")
const EcologyRenderer = preload("res://src/world3d/rendering/hex_ecology_renderer.gd")
const CORNER_SALT := 0x33444352
## Phase 5 only ever derives edge-profile variation from this dedicated salt.
## It never touches a Phase 1-4 random stream or signature.
const PROFILE_SALT := 0x35505246

## Detail levels. `DETAIL_FULL` is the canonical land surface used for
## collision/picking and the detailed continuous surface used for near
## rendering. `DETAIL_REDUCED` keeps every canonical corner but drops the
## interior land fan centre and the mid-wall bench, so chunk borders remain
## identical while submerged water tiles stay on their inexpensive six-face
## fan at either level.
const DETAIL_FULL := 0
const DETAIL_REDUCED := 1

const PALETTE_STANDARD := &"standard"
const PALETTE_HIGH_CONTRAST := &"high_contrast"

## Beach shelf inside a coastal tile. Both values stay strictly inside the
## logical hex, so the tile footprint and every canonical corner are unchanged.
const BEACH_RING_RADIUS := 0.62
const BEACH_RING_HEIGHT_BIAS := 0.84
## Cliff bench inset toward the tile centre, as a fraction of `hex_size`.
const CLIFF_BENCH_INSET := 0.085
const CLIFF_BENCH_HEIGHT := 0.56
const SHORE_SKIRT_INSET := 0.035
const SHORE_SKIRT_HEIGHT := 0.42
## Render-only bathymetry. Logical water elevation remains level zero for
## generation, simulation, saves, and signatures; only the continuous visual
## surface descends below the water plane.
const SEABED_SHALLOW_DEPTH := 0.24
const SEABED_DEPTH_STEP := 0.38
const SEABED_DEPTH_RINGS := 4
const COASTLINE_SUBMERGE_DEPTH := 0.035
const OCEAN_PLANE_PADDING_HEXES := 24.0
const OCEAN_FLOOR_CLEARANCE := 0.015

## Shader channel ids written into UV.y by `build_chunk_surface`.
const SURFACE_KIND_TOP := 0.0
const SURFACE_KIND_SEABED := -0.5
const SURFACE_KIND_SHORE := 0.55
const SURFACE_KIND_CLIFF := 1.0

const TERRAIN_COLORS := {
	&"coast": Color("#c6b478"),
	&"lowland": Color("#678552"),
	&"highland": Color("#75805a"),
	&"mountain": Color("#8c8981"),
}
const ELEVATION_COLORS := [
	Color("#204d6b"),
	Color("#d4bd7b"),
	Color("#79a85b"),
	Color("#a68455"),
	Color("#e2e0d9"),
]
const BIOME_COLORS := {
	&"water": Color("#245f7a"),
	&"coast": Color("#b89b55"),
	&"snow": Color("#d9e5e8"),
	&"tundra": Color("#758478"),
	&"bare_rock": Color("#5f5b59"),
	&"desert": Color("#b4813c"),
	&"grassland": Color("#5f843c"),
	&"shrubland": Color("#7d683d"),
	&"taiga": Color("#315844"),
	&"temperate_forest": Color("#245b31"),
	&"tropical_forest": Color("#16532e"),
}
## Canonical biome-floor material response, 0 fully organic (moss, loam, leaf
## litter) rising to 1 fully mineral (bare rock, sand, dry clay). This is the
## only per-biome input the textured floor material uses beyond `BIOME_COLORS`:
## it selects and blends the compact original material-pattern continuum in
## `hex_terrain.gdshader` instead of authoring one texture per biome. It is
## written into `COLOR.a` for the `biome` view only — every other mode keeps
## `COLOR.a` at the implicit opaque 1.0 default, so diagnostics stay flat.
const BIOME_MATERIAL_RESPONSE := {
	&"coast": 0.82,
	&"snow": 0.92,
	&"tundra": 0.55,
	&"bare_rock": 1.0,
	&"desert": 0.74,
	&"grassland": 0.16,
	&"shrubland": 0.32,
	&"taiga": 0.22,
	&"temperate_forest": 0.12,
	&"tropical_forest": 0.06,
}
## Fallback for a biome absent from the table (there is none today); keeps the
## helper total rather than silently defaulting to either material extreme.
const DEFAULT_MATERIAL_RESPONSE := 0.5
## Flat continuous-ramp anchors for the `material_response` diagnostic view
## (see `_material_response_color`). This is an independent categorical
## palette, distinct from every biome/terrain colour above; changing it never
## alters `BIOME_COLORS`, `TERRAIN_COLORS`, or any other authored palette.
const MATERIAL_RESPONSE_ORGANIC_COLOR := Color("#1b5e3a")
const MATERIAL_RESPONSE_MINERAL_COLOR := Color("#c9a15a")
const ECOLOGY_FEATURE_COLORS := {
	EcologyStage.FEATURE_SPARSE: Color("#8a9455"),
	EcologyStage.FEATURE_WOODLAND: Color("#4f7c3a"),
	EcologyStage.FEATURE_FOREST: Color("#2d6330"),
	EcologyStage.FEATURE_DENSE_FOREST: Color("#174a23"),
}
const ECOLOGY_BARE_COLOR := Color("#3c4438")
const DIAGNOSTIC_WATER_COLOR := Color("#173447")
const DIAGNOSTIC_LAND_COLOR := Color("#2f3941")
const EXCLUSION_COLORS := {
	EcologyStage.EXCLUSION_WATER: Color("#1d3a4a"),
	EcologyStage.EXCLUSION_CLIFF: Color("#c05a3c"),
	EcologyStage.EXCLUSION_SETTLEMENT: Color("#e0b73c"),
	EcologyStage.EXCLUSION_FEATURE: Color("#a563cf"),
	EcologyStage.EXCLUSION_BANK: Color("#2fb8c6"),
	EcologyStage.EXCLUSION_SHORE: Color("#3f6fbd"),
}
## Exclusion display precedence, strongest reservation first.
const EXCLUSION_DISPLAY_ORDER := [
	EcologyStage.EXCLUSION_WATER,
	EcologyStage.EXCLUSION_CLIFF,
	EcologyStage.EXCLUSION_SETTLEMENT,
	EcologyStage.EXCLUSION_FEATURE,
	EcologyStage.EXCLUSION_BANK,
	EcologyStage.EXCLUSION_SHORE,
]
const UNEXCLUDED_COLOR := Color("#35513c")

## Phase 5 accessibility palette for the categorical diagnostics. Each palette
## is a luminance ladder measured on the *displayed* colour — the terrain
## material consumes authored diagnostic colours as linear values, so the
## authored hex below is deliberately dark and the on-screen result is what
## clears `HexWorldAccessibility.MINIMUM_ADJACENT_CONTRAST` for every pair.
const HIGH_CONTRAST_OVERRIDES := {
	&"exclusion": {
		EcologyStage.EXCLUSION_WATER: Color("#000103"),
		&"none": Color("#020c01"),
		EcologyStage.EXCLUSION_FEATURE: Color("#32055a"),
		EcologyStage.EXCLUSION_SHORE: Color("#06269e"),
		EcologyStage.EXCLUSION_CLIFF: Color("#e41b05"),
		EcologyStage.EXCLUSION_BANK: Color("#0a8d8d"),
		EcologyStage.EXCLUSION_SETTLEMENT: Color("#d2b665"),
	},
	&"lakes": {
		&"none": Color("#010405"),
		&"lake": Color("#1ebde0"),
	},
	&"flow_direction": {
		&"none": Color("#000102"),
		2: Color("#240202"),
		3: Color("#33055f"),
		4: Color("#052a78"),
		1: Color("#b62904"),
		5: Color("#089353"),
		0: Color("#f6b508"),
	},
	&"ecology": {
		&"water": Color("#000102"),
		EcologyStage.FEATURE_DENSE_FOREST: Color("#010d03"),
		EcologyStage.FEATURE_FOREST: Color("#022102"),
		EcologyStage.FEATURE_WOODLAND: Color("#113e04"),
		EcologyStage.FEATURE_SPARSE: Color("#625b07"),
		&"bare": Color("#c6915f"),
	},
}
## Sparse markers are read against the ground around them, so the accessible
## resource diagnostic darkens the ground rather than distorting the ten
## approved marker hues. Only `wine` needed a marker-side change.
const HIGH_CONTRAST_DIAGNOSTIC_LAND_COLOR := Color("#0a0f13")
const HIGH_CONTRAST_DIAGNOSTIC_WATER_COLOR := Color("#05090d")


class ChunkSurface extends RefCounted:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	## Two entries per triangle: the axial q and r of the logical hex that owns
	## the triangle. Picking and collision use this to map a hit face back to a
	## tile across smooth joins, cliffs, and chunk borders.
	var face_tiles := PackedInt32Array()

	func triangle_count() -> int:
		return face_tiles.size() / 2

	func tile_coordinate_for_face(face_index: int) -> Vector2i:
		if face_index < 0 or face_index * 2 + 1 >= face_tiles.size():
			return Vector2i(2147483647, 2147483647)
		return Vector2i(face_tiles[face_index * 2], face_tiles[face_index * 2 + 1])

	func is_empty() -> bool:
		return vertices.is_empty()

	func build_mesh() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		if vertices.is_empty():
			return mesh
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh

	func collision_faces() -> PackedVector3Array:
		var faces := PackedVector3Array()
		faces.resize(indices.size())
		for index in range(indices.size()):
			faces[index] = vertices[indices[index]]
		return faces

	func bounds() -> AABB:
		if vertices.is_empty():
			return AABB()
		var minimum := vertices[0]
		var maximum := vertices[0]
		for vertex in vertices:
			minimum = Vector3(
				minf(minimum.x, vertex.x),
				minf(minimum.y, vertex.y),
				minf(minimum.z, vertex.z)
			)
			maximum = Vector3(
				maxf(maximum.x, vertex.x),
				maxf(maximum.y, vertex.y),
				maxf(maximum.z, vertex.z)
			)
		return AABB(minimum, maximum - minimum)


static func build_chunk(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i,
	debug_mode: Variant = &"biome",
	detail_level := DETAIL_FULL,
	palette: StringName = PALETTE_STANDARD,
	tile_normal_cache: Variant = null
) -> ArrayMesh:
	return build_chunk_surface(
		world,
		settings,
		chunk_coordinate,
		debug_mode,
		detail_level,
		palette,
		tile_normal_cache
	).build_mesh()


## Collision geometry for one chunk plus the face-to-tile table used by
## picking. Collision always uses `DETAIL_FULL` so a reduced-detail render can
## never change which logical hex a tap resolves to.
static func build_chunk_collision(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i,
	tile_normal_cache: Variant = null
) -> Dictionary:
	var surface := build_chunk_surface(
		world,
		settings,
		chunk_coordinate,
		&"biome",
		DETAIL_FULL,
		PALETTE_STANDARD,
		tile_normal_cache
	)
	return {
		"faces": surface.collision_faces(),
		"face_tiles": surface.face_tiles,
		"triangle_count": surface.triangle_count(),
		"bounds": surface.bounds(),
	}


## `tile_normal_cache` memoises `_tile_top_normal()` results keyed by axial
## tile coordinate and the render-only submerged mode; the same dictionary also
## memoises render-only seabed heights. Both are pure functions of
## `(world, tile, settings)`, so
## sharing one cache Dictionary across every near/far/collision surface built
## for the same `world` is a performance optimisation only, never a
## correctness or cross-chunk-continuity requirement: passing a fresh empty
## Dictionary (the default) reproduces the exact prior per-call behaviour, and
## passing a Dictionary already populated by another chunk (even across the
## whole world) always returns the same values a fresh cache would compute,
## because two tiles that border the same corner always agree on that tile's
## own top normal. Callers that mutate terrain after populating a shared cache
## must invalidate it before rebuilding; `HexWorldPrototype.mark_tiles_dirty`
## clears its world-scoped cache while `HexChunkIndex` still limits the actual
## mesh rebuild to the geometrically dependent chunks.
static func build_chunk_surface(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i,
	debug_mode: Variant = &"biome",
	detail_level := DETAIL_FULL,
	palette: StringName = PALETTE_STANDARD,
	tile_normal_cache: Variant = null,
	include_submerged_terrain := false
) -> ChunkSurface:
	var surface := ChunkSurface.new()
	var normal_cache: Dictionary = (
		tile_normal_cache as Dictionary
		if tile_normal_cache is Dictionary
		else {}
	)
	var start_column := chunk_coordinate.x * settings.chunk_size
	var start_row := chunk_coordinate.y * settings.chunk_size
	var end_column := mini(start_column + settings.chunk_size, world.width)
	var end_row := mini(start_row + settings.chunk_size, world.height)
	var elevation_span := maxf(settings.elevation_step_height * 4.0, 0.001)
	for row in range(start_row, end_row):
		for column in range(start_column, end_column):
			var tile := world.tile_at_offset(column, row)
			if tile == null or (tile.is_water and not include_submerged_terrain):
				continue
			var center := tile.position + Vector3.UP * _surface_height(
				world,
				tile,
				settings,
				include_submerged_terrain,
				normal_cache
			)
			var tile_color := _tile_color(tile, debug_mode, palette)
			var center_relief := Vector2(
				clampf(tile.elevation / elevation_span, 0.0, 1.0),
				_tile_rock_factor(tile)
			)
			var center_coast := _tile_coast_factor(world, tile)
			var center_normal := _tile_top_normal(
				world,
				tile,
				settings,
				normal_cache,
				include_submerged_terrain
			)
			var corners: Array[Vector3] = []
			var corner_colors: Array[Color] = []
			var corner_coast: Array[float] = []
			var corner_relief: Array[Vector2] = []
			var corner_normals: Array[Vector3] = []
			for corner_index in range(6):
				corners.append(
					_corner_position(
						world,
						tile,
						corner_index,
						settings,
						include_submerged_terrain,
						normal_cache
					)
				)
				corner_colors.append(
					_corner_color(world, tile, corner_index, debug_mode, palette)
				)
				corner_coast.append(_corner_coast_factor(world, tile, corner_index))
				corner_relief.append(
					_corner_relief(world, tile, corner_index, elevation_span)
				)
				corner_normals.append(
					_corner_top_normal(
						world,
						tile,
						corner_index,
						settings,
						normal_cache,
						include_submerged_terrain
					)
				)
			if detail_level == DETAIL_FULL and not tile.is_water:
				_append_tile_top(
					world,
					tile,
					surface,
					center,
					tile_color,
					center_coast,
					center_relief,
					center_normal,
					corners,
					corner_colors,
					corner_coast,
					corner_relief,
					corner_normals
				)
			else:
				_append_plain_tile_top(
					surface,
					tile,
					center,
					tile_color,
					center_coast,
					center_relief,
					center_normal,
					corners,
					corner_colors,
					corner_coast,
					corner_relief,
					corner_normals,
					SURFACE_KIND_SEABED if tile.is_water else SURFACE_KIND_TOP
				)
			if not tile.is_water:
				_append_edge_skirts(
					world,
					tile,
					settings,
					surface,
					tile_color,
					corner_coast,
					center_relief,
					detail_level,
					include_submerged_terrain
				)
	return surface


static func build_ocean(world: HexWorldData, settings: WorldGenerationSettings) -> ArrayMesh:
	var bounds := world.world_bounds()
	var padding := settings.hex_size * OCEAN_PLANE_PADDING_HEXES
	var minimum := bounds.position - Vector3(padding, 0.0, padding)
	var maximum := bounds.end + Vector3(padding, 0.0, padding)
	return _build_horizontal_plane(minimum, maximum, settings.ocean_height, false)


static func submerged_surface_height(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	surface_height_cache: Variant = null
) -> float:
	return _surface_height(world, tile, settings, true, surface_height_cache)


static func submerged_corner_position(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings,
	surface_height_cache: Variant = null
) -> Vector3:
	return _corner_position(
		world,
		tile,
		corner_index,
		settings,
		true,
		surface_height_cache
	)


static func water_depth_at_tile(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	surface_height_cache: Variant = null
) -> float:
	if tile == null or not tile.is_water:
		return 0.0
	return maxf(
		settings.ocean_height
			- submerged_surface_height(world, tile, settings, surface_height_cache),
		0.0
	)


## Opaque deep floor beneath the complete ocean extent. Logical terrain still
## supplies the textured seabed inside the map; this lower plane only fills the
## padded area beyond the outermost water hexes so the depth-aware ocean shader
## never reveals their jagged mesh boundary.
static func build_ocean_floor(
	world: HexWorldData,
	settings: WorldGenerationSettings
) -> ArrayMesh:
	var bounds := world.world_bounds()
	var padding := settings.hex_size * OCEAN_PLANE_PADDING_HEXES
	var minimum := bounds.position - Vector3(padding, 0.0, padding)
	var maximum := bounds.end + Vector3(padding, 0.0, padding)
	var deepest_seabed := (
		settings.ocean_height
		- SEABED_SHALLOW_DEPTH
		- float(SEABED_DEPTH_RINGS - 1) * SEABED_DEPTH_STEP
	)
	return _build_horizontal_plane(
		minimum,
		maximum,
		deepest_seabed - OCEAN_FLOOR_CLEARANCE,
		true
	)


static func _build_horizontal_plane(
	minimum: Vector3,
	maximum: Vector3,
	height: float,
	seabed_channels: bool
) -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(minimum.x, height, minimum.z),
		Vector3(maximum.x, height, minimum.z),
		Vector3(maximum.x, height, maximum.z),
		Vector3(minimum.x, height, maximum.z),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
	])
	if seabed_channels:
		var seabed_color: Color = BIOME_COLORS[&"water"]
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray([
			seabed_color,
			seabed_color,
			seabed_color,
			seabed_color,
		])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
			Vector2(0.0, SURFACE_KIND_SEABED),
			Vector2(0.0, SURFACE_KIND_SEABED),
			Vector2(0.0, SURFACE_KIND_SEABED),
			Vector2(0.0, SURFACE_KIND_SEABED),
		])
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
			Vector2.ZERO,
			Vector2.ZERO,
			Vector2.ZERO,
			Vector2.ZERO,
		])
	# Godot treats clockwise vertices as front-facing. From above, these two
	# triangles therefore face upward while retaining explicit upward normals.
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func build_boundary_mesh(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunks_only: bool
) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for tile in world.tiles:
		for direction in range(6):
			var neighbor := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, direction))
			if chunks_only and not _is_chunk_boundary(tile, neighbor, settings.chunk_size):
				continue
			if not chunks_only and neighbor != null and _tile_order_after(tile, neighbor):
				continue
			var first_corner := posmod(direction - 1, 6)
			var second_corner := direction
			var first := _corner_horizontal(world, tile, first_corner, settings)
			var second := _corner_horizontal(world, tile, second_corner, settings)
			var line_height := (
				maxf(
					settings.ocean_height,
					maxf(
						tile.elevation,
						neighbor.elevation if neighbor != null else tile.elevation
					)
				)
				+ 0.055
			)
			first.y = line_height
			second.y = line_height
			vertices.append(first)
			vertices.append(second)
			var color := Color(1.0, 0.68, 0.18, 0.95) if chunks_only else Color(0.08, 0.09, 0.08, 0.55)
			colors.append(color)
			colors.append(color)
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Full-detail tile top. A land tile that touches water is built as a centre fan
## plus a complete inner berm ring, which drops quickly from the tile centre and
## then flattens into a shelf toward the water-facing corners. The ring is
## closed rather than per-edge so the radial seams inside the tile stay
## T-junction free, and the outer ring is the untouched canonical corner set, so
## the shoreline reads as a beach without moving a single logical boundary.
static func _append_tile_top(
	world: HexWorldData,
	tile: HexTileData,
	surface: ChunkSurface,
	center: Vector3,
	tile_color: Color,
	center_coast: float,
	center_relief: Vector2,
	center_normal: Vector3,
	corners: Array[Vector3],
	corner_colors: Array[Color],
	corner_coast: Array[float],
	corner_relief: Array[Vector2],
	corner_normals: Array[Vector3]
) -> void:
	if not _touches_water(world, tile):
		_append_plain_tile_top(
			surface,
			tile,
			center,
			tile_color,
			center_coast,
			center_relief,
			center_normal,
			corners,
			corner_colors,
			corner_coast,
			corner_relief,
			corner_normals
		)
		return
	var berm: Array[Vector3] = []
	var berm_colors: Array[Color] = []
	var berm_coast: Array[float] = []
	var berm_relief: Array[Vector2] = []
	var berm_normals: Array[Vector3] = []
	for corner_index in range(6):
		berm.append(_beach_ring_point(center, corners[corner_index]))
		berm_colors.append(tile_color.lerp(corner_colors[corner_index], BEACH_RING_RADIUS))
		berm_coast.append(
			lerpf(center_coast, corner_coast[corner_index], BEACH_RING_RADIUS)
		)
		berm_relief.append(
			center_relief.lerp(corner_relief[corner_index], BEACH_RING_RADIUS)
		)
		var berm_normal := center_normal.lerp(corner_normals[corner_index], BEACH_RING_RADIUS)
		berm_normals.append(
			Vector3.UP if berm_normal.is_zero_approx() else berm_normal.normalized()
		)
	for corner_index in range(6):
		var next_index := (corner_index + 1) % 6
		_append_triangle(
			surface,
			tile,
			center,
			berm[corner_index],
			berm[next_index],
			tile_color,
			berm_colors[corner_index],
			berm_colors[next_index],
			Vector2(center_coast, SURFACE_KIND_TOP),
			Vector2(berm_coast[corner_index], SURFACE_KIND_TOP),
			Vector2(berm_coast[next_index], SURFACE_KIND_TOP),
			center_relief,
			berm_relief[corner_index],
			berm_relief[next_index],
			center_normal,
			berm_normals[corner_index],
			berm_normals[next_index]
		)
		_append_triangle(
			surface,
			tile,
			berm[corner_index],
			corners[corner_index],
			corners[next_index],
			berm_colors[corner_index],
			corner_colors[corner_index],
			corner_colors[next_index],
			Vector2(berm_coast[corner_index], SURFACE_KIND_TOP),
			Vector2(corner_coast[corner_index], SURFACE_KIND_TOP),
			Vector2(corner_coast[next_index], SURFACE_KIND_TOP),
			berm_relief[corner_index],
			corner_relief[corner_index],
			corner_relief[next_index],
			berm_normals[corner_index],
			corner_normals[corner_index],
			corner_normals[next_index]
		)
		_append_triangle(
			surface,
			tile,
			berm[corner_index],
			corners[next_index],
			berm[next_index],
			berm_colors[corner_index],
			corner_colors[next_index],
			berm_colors[next_index],
			Vector2(berm_coast[corner_index], SURFACE_KIND_TOP),
			Vector2(corner_coast[next_index], SURFACE_KIND_TOP),
			Vector2(berm_coast[next_index], SURFACE_KIND_TOP),
			berm_relief[corner_index],
			corner_relief[next_index],
			berm_relief[next_index],
			berm_normals[corner_index],
			corner_normals[next_index],
			berm_normals[next_index]
		)


## Reduced-detail tile top: the canonical six-triangle fan without the coastal
## beach berm. The tile surface, every canonical corner, and the chunk border
## are byte-identical to full detail, so a detail switch can never open a seam;
## only the sub-pixel shoreline shelf is dropped.
static func _append_plain_tile_top(
	surface: ChunkSurface,
	tile: HexTileData,
	center: Vector3,
	tile_color: Color,
	center_coast: float,
	center_relief: Vector2,
	center_normal: Vector3,
	corners: Array[Vector3],
	corner_colors: Array[Color],
	corner_coast: Array[float],
	corner_relief: Array[Vector2],
	corner_normals: Array[Vector3],
	surface_kind := SURFACE_KIND_TOP
) -> void:
	for corner_index in range(6):
		var next_index := (corner_index + 1) % 6
		_append_triangle(
			surface,
			tile,
			center,
			corners[corner_index],
			corners[next_index],
			tile_color,
			corner_colors[corner_index],
			corner_colors[next_index],
			Vector2(center_coast, surface_kind),
			Vector2(corner_coast[corner_index], surface_kind),
			Vector2(corner_coast[next_index], surface_kind),
			center_relief,
			corner_relief[corner_index],
			corner_relief[next_index],
			center_normal,
			corner_normals[corner_index],
			corner_normals[next_index]
		)


## Vertical joins between a tile and its lower neighbours. The top and bottom
## rings stay exactly on the canonical corner positions, so a chunk border never
## cracks. At full detail an intermediate bench is inserted, inset toward the
## tile centre by a deterministic per-edge amount, which gives cliffs a layered
## rock profile and shorelines a shallower wash without changing the footprint.
static func _append_edge_skirts(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	surface: ChunkSurface,
	tile_color: Color,
	corner_coast: Array[float],
	center_relief: Vector2,
	detail_level: int,
	include_submerged_terrain := false
) -> void:
	for direction in range(6):
		var neighbor := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, direction))
		var is_shore := neighbor == null or neighbor.is_water
		# The continuous render surface includes the adjacent seabed triangles,
		# so a land-water edge is already watertight and must not also receive
		# the old vertical shoreline wall. Land-only collision meshes retain the
		# canonical skirt path below.
		if is_shore and include_submerged_terrain:
			continue
		var first_corner := posmod(direction - 1, 6)
		var upper_a := _corner_position(
			world,
			tile,
			first_corner,
			settings,
			include_submerged_terrain
		)
		var upper_b := _corner_position(
			world,
			tile,
			direction,
			settings,
			include_submerged_terrain
		)
		var lower_a: Vector3
		var lower_b: Vector3
		if not is_shore:
			# The opposite edge uses the same two canonical horizontal corners,
			# but the low tile's independently resolved corner heights.
			lower_a = _corner_position(
				world,
				neighbor,
				posmod(direction + 3, 6),
				settings,
				include_submerged_terrain
			)
			lower_b = _corner_position(
				world,
				neighbor,
				posmod(direction + 2, 6),
				settings,
				include_submerged_terrain
			)
		else:
			lower_a = Vector3(upper_a.x, settings.ocean_height, upper_a.z)
			lower_b = Vector3(upper_b.x, settings.ocean_height, upper_b.z)
		var upper_height := (upper_a.y + upper_b.y) * 0.5
		var lower_height := (lower_a.y + lower_b.y) * 0.5
		if upper_height <= lower_height + 0.00001:
			continue
		var surface_kind := SURFACE_KIND_SHORE if is_shore else SURFACE_KIND_CLIFF
		var skirt_color := tile_color.darkened(0.18 if is_shore else 0.28)
		var coast_value := minf(corner_coast[first_corner], corner_coast[direction])
		var upper_uv := Vector2(coast_value, surface_kind)
		var lower_uv := Vector2(0.0 if is_shore else coast_value, surface_kind)
		var relief := Vector2(center_relief.x, maxf(center_relief.y, 0.55))
		if detail_level != DETAIL_FULL:
			_append_wall_quad(
				surface,
				tile,
				upper_a,
				upper_b,
				lower_a,
				lower_b,
				skirt_color,
				skirt_color,
				upper_uv,
				lower_uv,
				relief
			)
			continue
		var inset := settings.hex_size * (
			SHORE_SKIRT_INSET if is_shore else _cliff_bench_inset(world, tile, direction)
		)
		var bench_height := SHORE_SKIRT_HEIGHT if is_shore else CLIFF_BENCH_HEIGHT
		var bench_a := _bench_point(tile, upper_a, lower_a, inset, bench_height)
		var bench_b := _bench_point(tile, upper_b, lower_b, inset, bench_height)
		var bench_color := skirt_color.lerp(tile_color.darkened(0.42), 0.5)
		var bench_uv := upper_uv.lerp(lower_uv, 0.5)
		_append_wall_quad(
			surface,
			tile,
			upper_a,
			upper_b,
			bench_a,
			bench_b,
			skirt_color,
			bench_color,
			upper_uv,
			bench_uv,
			relief
		)
		_append_wall_quad(
			surface,
			tile,
			bench_a,
			bench_b,
			lower_a,
			lower_b,
			bench_color,
			skirt_color.darkened(0.12),
			bench_uv,
			lower_uv,
			relief
		)


static func _append_wall_quad(
	surface: ChunkSurface,
	tile: HexTileData,
	upper_a: Vector3,
	upper_b: Vector3,
	lower_a: Vector3,
	lower_b: Vector3,
	upper_color: Color,
	lower_color: Color,
	upper_uv: Vector2,
	lower_uv: Vector2,
	relief: Vector2
) -> void:
	_append_wall_triangle(
		surface, tile,
		upper_a, lower_b, upper_b,
		upper_color, lower_color, upper_color,
		upper_uv, lower_uv, upper_uv,
		relief,
		tile.position
	)
	_append_wall_triangle(
		surface, tile,
		upper_a, lower_a, lower_b,
		upper_color, lower_color, lower_color,
		upper_uv, lower_uv, lower_uv,
		relief,
		tile.position
	)


static func _bench_point(
	tile: HexTileData,
	upper: Vector3,
	lower: Vector3,
	inset: float,
	height_ratio: float
) -> Vector3:
	var point := upper.lerp(lower, 1.0 - height_ratio)
	var inward := Vector3(tile.position.x - upper.x, 0.0, tile.position.z - upper.z)
	if inward.length() > 0.0001:
		point += inward.normalized() * inset
	return point


## Deterministic per-edge bench inset. The edge key is the sorted coordinate
## pair, so both tiles of an edge derive the same value and the result never
## depends on iteration order.
static func _cliff_bench_inset(
	world: HexWorldData,
	tile: HexTileData,
	direction: int
) -> float:
	var first := tile.coordinate
	var second := HexCoordinatesScript.neighbor(tile.coordinate, direction)
	if second.y < first.y or (second.y == first.y and second.x < first.x):
		var swap := first
		first = second
		second = swap
	var value := int(
		hash(
			"%d:%d:%d:%d:%d:%d"
			% [world.seed, PROFILE_SALT, first.x, first.y, second.x, second.y]
		)
	)
	var unit := float(posmod(value, 1000003)) / 1000002.0
	return CLIFF_BENCH_INSET * (0.55 + unit * 0.9)


static func _beach_ring_point(center: Vector3, corner: Vector3) -> Vector3:
	var point := center.lerp(corner, BEACH_RING_RADIUS)
	point.y = lerpf(center.y, corner.y, BEACH_RING_HEIGHT_BIAS)
	return point


static func _append_triangle(
	surface: ChunkSurface,
	tile: HexTileData,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	color_a: Color,
	color_b: Color,
	color_c: Color,
	uv_a: Vector2,
	uv_b: Vector2,
	uv_c: Vector2,
	relief_a: Vector2,
	relief_b: Vector2,
	relief_c: Vector2,
	shading_normal_a := Vector3.ZERO,
	shading_normal_b := Vector3.ZERO,
	shading_normal_c := Vector3.ZERO
) -> void:
	var flat_normal := (b - a).cross(c - a).normalized()
	if flat_normal.y < 0.0:
		var swap := b
		b = c
		c = swap
		var color_swap := color_b
		color_b = color_c
		color_c = color_swap
		var uv_swap := uv_b
		uv_b = uv_c
		uv_c = uv_swap
		var relief_swap := relief_b
		relief_b = relief_c
		relief_c = relief_swap
		var normal_swap := shading_normal_b
		shading_normal_b = shading_normal_c
		shading_normal_c = normal_swap
		flat_normal = -flat_normal
	# Canonical smooth top-face normals (`_tile_top_normal`/`_corner_top_normal`)
	# are passed in per vertex; a triangle that did not receive one (every
	# cliff/skirt caller still on the 13-argument form, and the sentinel
	# `Vector3.ZERO`, which no normalized normal can ever equal) keeps the flat
	# per-triangle normal exactly as before.
	var normal_a := (
		flat_normal if shading_normal_a.is_zero_approx() else shading_normal_a
	)
	var normal_b := (
		flat_normal if shading_normal_b.is_zero_approx() else shading_normal_b
	)
	var normal_c := (
		flat_normal if shading_normal_c.is_zero_approx() else shading_normal_c
	)
	var base := surface.vertices.size()
	# ArrayMesh front faces are clockwise, opposite the cross-product order used
	# above to derive the outward lighting normal.
	surface.vertices.append_array(PackedVector3Array([a, c, b]))
	surface.normals.append_array(PackedVector3Array([normal_a, normal_c, normal_b]))
	surface.colors.append_array(PackedColorArray([color_a, color_c, color_b]))
	surface.uvs.append_array(PackedVector2Array([uv_a, uv_c, uv_b]))
	surface.uv2s.append_array(PackedVector2Array([relief_a, relief_c, relief_b]))
	surface.indices.append_array(PackedInt32Array([base, base + 1, base + 2]))
	surface.face_tiles.append_array(
		PackedInt32Array([tile.coordinate.x, tile.coordinate.y])
	)


static func _append_wall_triangle(
	surface: ChunkSurface,
	tile: HexTileData,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	color_a: Color,
	color_b: Color,
	color_c: Color,
	uv_a: Vector2,
	uv_b: Vector2,
	uv_c: Vector2,
	relief: Vector2,
	tile_center: Vector3
) -> void:
	var normal := (b - a).cross(c - a).normalized()
	if normal.is_zero_approx():
		return
	var outward := (a + b + c) / 3.0 - tile_center
	outward.y = 0.0
	if normal.dot(outward) < 0.0:
		var swap := b
		b = c
		c = swap
		var color_swap := color_b
		color_b = color_c
		color_c = color_swap
		var uv_swap := uv_b
		uv_b = uv_c
		uv_c = uv_swap
		normal = -normal
	var base := surface.vertices.size()
	surface.vertices.append_array(PackedVector3Array([a, c, b]))
	surface.normals.append_array(PackedVector3Array([normal, normal, normal]))
	surface.colors.append_array(PackedColorArray([color_a, color_c, color_b]))
	surface.uvs.append_array(PackedVector2Array([uv_a, uv_c, uv_b]))
	surface.uv2s.append_array(PackedVector2Array([relief, relief, relief]))
	surface.indices.append_array(PackedInt32Array([base, base + 1, base + 2]))
	surface.face_tiles.append_array(
		PackedInt32Array([tile.coordinate.x, tile.coordinate.y])
	)


## The canonical elevation-band membership at one corner: every tile whose
## elevation level is within `cliff_level_threshold` of the highest tile
## sharing this corner, sorted so any of the (up to 3) touching tiles
## computes exactly the same group regardless of which one asks. Shared by
## corner height blending (`_corner_position`) and corner top-normal
## blending (`_corner_top_normal`) so both stay in lockstep: a true cliff
## (beyond the threshold) keeps a hard edge in height and in lighting alike,
## while every gentler grade blends both together.
static func _corner_smooth_group(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings
) -> Array:
	var touching_tiles: Array[HexTileData] = [tile]
	var first := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, corner_index))
	var second := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, corner_index + 1))
	if first != null:
		touching_tiles.append(first)
	if second != null:
		touching_tiles.append(second)
	# Partition the junction into canonical elevation bands. A transitive
	# 4-3-2 chain must not merge into one band and erase the 4-2 cliff.
	touching_tiles.sort_custom(func(a: HexTileData, b: HexTileData) -> bool:
		if a.elevation_level != b.elevation_level:
			return a.elevation_level > b.elevation_level
		return (
			a.coordinate.y < b.coordinate.y
			or (a.coordinate.y == b.coordinate.y and a.coordinate.x < b.coordinate.x)
		)
	)
	var height_groups: Array = []
	for candidate in touching_tiles:
		var added := false
		for group_value in height_groups:
			var group: Array = group_value
			var highest := group[0] as HexTileData
			if (
				highest.elevation_level - candidate.elevation_level
				< settings.cliff_level_threshold
			):
				group.append(candidate)
				added = true
				break
		if not added:
			height_groups.append([candidate])
	for group_value in height_groups:
		var group: Array = group_value
		for candidate in group:
			if candidate.coordinate == tile.coordinate:
				return group
	return [tile]


static func _corner_position(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings,
	include_submerged_terrain := false,
	surface_height_cache: Variant = null
) -> Vector3:
	var point := _corner_horizontal(world, tile, corner_index, settings)
	var smooth_group := _corner_smooth_group(world, tile, corner_index, settings)
	if include_submerged_terrain:
		var has_land := false
		var has_water := false
		for smooth_tile in smooth_group:
			if (smooth_tile as HexTileData).is_water:
				has_water = true
			else:
				has_land = true
		if has_land and has_water:
			point.y = settings.ocean_height - COASTLINE_SUBMERGE_DEPTH
			return point
	var total_height := 0.0
	for smooth_tile in smooth_group:
		total_height += _surface_height(
			world,
			smooth_tile as HexTileData,
			settings,
			include_submerged_terrain,
			surface_height_cache
		)
	point.y = total_height / float(smooth_group.size())
	return point


## One representative top-face lighting normal per tile: the area-weighted
## (raw cross-product magnitude already carries area) sum of that tile's own
## six centre-to-corner fan triangles, using its *canonical* corners
## (`_corner_position`, before any coastal beach-berm subdivision — the berm
## only adds detail inside the same overall tilt, it never changes it).
## Pure function of `(world, tile, settings)`, so two tiles that both border
## the same corner — even across a chunk boundary — always compute the same
## value; `cache` (keyed by axial coordinate) only memoises repeat lookups. A
## caller may share one cache across every near/far/collision surface built
## for the same `world` (see `build_chunk_surface`'s own doc comment) — doing
## so only skips redundant recomputation, it never changes the result, so it
## is not required for correctness or cross-chunk continuity.
static func _tile_top_normal(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	cache: Dictionary,
	include_submerged_terrain := false
) -> Vector3:
	var cache_key: Variant = (
		Vector3i(tile.coordinate.x, tile.coordinate.y, 1)
		if include_submerged_terrain
		else tile.coordinate
	)
	var cached: Variant = cache.get(cache_key)
	if cached != null:
		return cached
	var center := tile.position + Vector3.UP * _surface_height(
		world,
		tile,
		settings,
		include_submerged_terrain,
		cache
	)
	var corners: Array[Vector3] = []
	for corner_index in range(6):
		corners.append(
			_corner_position(
				world,
				tile,
				corner_index,
				settings,
				include_submerged_terrain,
				cache
			)
		)
	var accumulated := Vector3.ZERO
	for corner_index in range(6):
		var next_index := (corner_index + 1) % 6
		var face_normal := (corners[corner_index] - center).cross(corners[next_index] - center)
		# Match `_append_triangle`'s own winding-flip convention (top-surface
		# normals always point generally upward) before accumulating, so a
		# stray degenerate/inverted triangle can never cancel its neighbours.
		if face_normal.y < 0.0:
			face_normal = -face_normal
		accumulated += face_normal
	var normal := Vector3.UP if accumulated.is_zero_approx() else accumulated.normalized()
	cache[cache_key] = normal
	return normal


## The canonical smooth top-face normal at one corner: the unweighted mean of
## `_tile_top_normal()` over the same `_corner_smooth_group` used for corner
## height blending, so height and lighting agree on exactly which tiles are
## "the same smooth surface" at this junction. A genuine cliff (excluded from
## the smooth group) never contributes here, so the top surface keeps a hard
## lighting edge on each side of a real cliff even though the cliff *wall*
## triangles (`_append_wall_triangle`) are entirely separate and untouched by
## this function either way.
static func _corner_top_normal(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings,
	tile_normal_cache: Dictionary,
	include_submerged_terrain := false
) -> Vector3:
	var smooth_group := _corner_smooth_group(world, tile, corner_index, settings)
	var accumulated := Vector3.ZERO
	for smooth_tile in smooth_group:
		accumulated += _tile_top_normal(
			world,
			smooth_tile,
			settings,
			tile_normal_cache,
			include_submerged_terrain
		)
	return Vector3.UP if accumulated.is_zero_approx() else accumulated.normalized()


## Height used by the render surface. Water tiles descend in deterministic
## rings away from land, producing a shallow coastal shelf and a deeper open
## seabed without changing any logical elevation or generation signature.
static func _surface_height(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	include_submerged_terrain: bool,
	surface_height_cache: Variant = null
) -> float:
	if not include_submerged_terrain or not tile.is_water:
		return tile.elevation
	var cache: Dictionary = (
		surface_height_cache as Dictionary
		if surface_height_cache is Dictionary
		else {}
	)
	var cache_key := Vector3i(tile.coordinate.x, tile.coordinate.y, 2)
	if cache.has(cache_key):
		return float(cache[cache_key])
	var distance_ring := SEABED_DEPTH_RINGS
	var found_land := false
	for radius in range(1, SEABED_DEPTH_RINGS + 1):
		for coordinate in HexCoordinatesScript.ring(tile.coordinate, radius):
			var candidate := world.tile_at(coordinate)
			if candidate != null and not candidate.is_water:
				distance_ring = radius
				found_land = true
				break
		if found_land:
			break
	var edge_margin := mini(
		mini(tile.offset_coordinate.x, world.width - 1 - tile.offset_coordinate.x),
		mini(tile.offset_coordinate.y, world.height - 1 - tile.offset_coordinate.y)
	)
	var edge_depth_ring := clampi(
		SEABED_DEPTH_RINGS - edge_margin,
		1,
		SEABED_DEPTH_RINGS
	)
	distance_ring = maxi(distance_ring, edge_depth_ring)
	var height := (
		settings.ocean_height
		- SEABED_SHALLOW_DEPTH
		- float(distance_ring - 1) * SEABED_DEPTH_STEP
	)
	cache[cache_key] = height
	return height


static func _corner_horizontal(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings
) -> Vector3:
	var coordinates: Array[Vector2i] = [
		tile.coordinate,
		HexCoordinatesScript.neighbor(tile.coordinate, corner_index),
		HexCoordinatesScript.neighbor(tile.coordinate, corner_index + 1),
	]
	coordinates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)
	var result := Vector3.ZERO
	for coordinate in coordinates:
		result += HexCoordinatesScript.axial_to_world(coordinate, settings.hex_size)
	result /= 3.0
	var hash_value := int(hash("%d:%d" % [world.seed, CORNER_SALT]))
	for coordinate in coordinates:
		hash_value = int(hash_value * 31 + coordinate.x * 92821 + coordinate.y * 68917)
	var angle := float(posmod(hash_value, 3600)) / 3600.0 * TAU
	var displacement := settings.hex_size * settings.corner_distortion
	result.x += cos(angle) * displacement
	result.z += sin(angle) * displacement
	return result


static func canonical_corner_horizontal(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings
) -> Vector3:
	return _corner_horizontal(world, tile, corner_index, settings)


static func canonical_corner_position(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	settings: WorldGenerationSettings
) -> Vector3:
	return _corner_position(world, tile, corner_index, settings)


static func canonical_edge_midpoint(
	world: HexWorldData,
	tile: HexTileData,
	direction: int,
	settings: WorldGenerationSettings
) -> Vector3:
	return (
		_corner_horizontal(world, tile, posmod(direction - 1, 6), settings)
		+ _corner_horizontal(world, tile, direction, settings)
	) * 0.5


## 0 on a tile that touches water, rising to 1 fully inland. Interpolated into
## the shader so the coast treatment fades over the first land ring instead of
## stopping abruptly on a hex edge.
static func _tile_coast_factor(world: HexWorldData, tile: HexTileData) -> float:
	if tile.is_water:
		return 0.0
	return 0.0 if _touches_water(world, tile) else 1.0


static func _touches_water(world: HexWorldData, tile: HexTileData) -> bool:
	for neighbor_coordinate in HexCoordinatesScript.neighbors(tile.coordinate):
		var neighbor := world.tile_at(neighbor_coordinate)
		if neighbor == null or neighbor.is_water:
			return true
	return false


static func _corner_coast_factor(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int
) -> float:
	var total := _tile_coast_factor(world, tile)
	var count := 1
	for offset in [0, 1]:
		var neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, corner_index + offset)
		)
		if neighbor == null or neighbor.is_water:
			continue
		total += _tile_coast_factor(world, neighbor)
		count += 1
	return total / float(count)


## Fraction of exposed rock versus soil and vegetation on a land tile.
static func _tile_rock_factor(tile: HexTileData) -> float:
	if tile.biome == &"bare_rock" or tile.biome == &"snow":
		return 1.0
	if tile.terrain_type == &"mountain":
		return 0.88
	var value := (
		0.16
		+ 0.2 * float(clampi(tile.elevation_level - 1, 0, 3))
		- 0.7 * clampf(tile.vegetation_density, 0.0, 1.0)
	)
	if tile.biome == &"desert":
		value += 0.24
	return clampf(value, 0.0, 1.0)


static func _corner_relief(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	elevation_span: float
) -> Vector2:
	var total := Vector2(
		clampf(tile.elevation / elevation_span, 0.0, 1.0),
		_tile_rock_factor(tile)
	)
	var count := 1
	for offset in [0, 1]:
		var neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, corner_index + offset)
		)
		if neighbor == null or neighbor.is_water:
			continue
		total += Vector2(
			clampf(neighbor.elevation / elevation_span, 0.0, 1.0),
			_tile_rock_factor(neighbor)
		)
		count += 1
	return total / float(count)


static func _tile_color(
	tile: HexTileData,
	debug_mode: Variant,
	palette: StringName = PALETTE_STANDARD
) -> Color:
	var mode: StringName = &"biome"
	if debug_mode is bool:
		mode = &"elevation" if debug_mode else &"biome"
	else:
		mode = debug_mode
	var high_contrast := palette == PALETTE_HIGH_CONTRAST
	if mode == &"elevation":
		return ELEVATION_COLORS[clampi(tile.elevation_level, 0, 4)]
	if mode == &"temperature":
		return _temperature_color(tile.temperature)
	if mode == &"moisture":
		return _moisture_color(tile.moisture)
	if mode == &"material_response":
		if tile.is_water:
			return DIAGNOSTIC_WATER_COLOR
		return _material_response_color(biome_material_response(tile.biome))
	if mode == &"flow_direction":
		var flow_overrides: Dictionary = HIGH_CONTRAST_OVERRIDES[&"flow_direction"]
		if tile.is_ocean or tile.flow_direction < 0:
			return flow_overrides[&"none"] if high_contrast else Color("#173447")
		if high_contrast:
			return flow_overrides[tile.flow_direction]
		var directions := [
			Color("#f2cc5d"),
			Color("#e98b4a"),
			Color("#d95858"),
			Color("#ad65c5"),
			Color("#4f8fd1"),
			Color("#4cb89c"),
		]
		return directions[tile.flow_direction]
	if mode == &"watershed":
		if tile.watershed_id < 0:
			return Color("#173447")
		var hue := float(posmod(tile.watershed_id, 997)) / 997.0
		return Color.from_hsv(
			hue,
			0.72 if high_contrast else 0.58,
			0.88 if high_contrast else 0.76
		)
	if mode == &"accumulation":
		if tile.is_ocean:
			return Color("#173447")
		var accumulation := clampf(
			log(float(tile.flow_accumulation) + 1.0) / log(12000.0),
			0.0,
			1.0
		)
		return Color("#e7d7a1").lerp(Color("#164b87"), accumulation)
	if mode == &"lakes":
		var lake_overrides: Dictionary = HIGH_CONTRAST_OVERRIDES[&"lakes"]
		if high_contrast:
			return lake_overrides[&"lake"] if tile.lake_id >= 0 else lake_overrides[&"none"]
		return Color("#27a8d1") if tile.lake_id >= 0 else Color("#283239")
	if mode == &"river_edges":
		return Color("#283239")
	if mode == &"ecology":
		var ecology_overrides: Dictionary = HIGH_CONTRAST_OVERRIDES[&"ecology"]
		if tile.is_water:
			return ecology_overrides[&"water"] if high_contrast else DIAGNOSTIC_WATER_COLOR
		if high_contrast:
			return ecology_overrides.get(tile.feature_type, ecology_overrides[&"bare"])
		return ECOLOGY_FEATURE_COLORS.get(tile.feature_type, ECOLOGY_BARE_COLOR)
	if mode == &"density":
		if tile.is_water:
			return DIAGNOSTIC_WATER_COLOR
		return Color("#ded4ad").lerp(
			Color("#10401d"),
			clampf(tile.vegetation_density, 0.0, 1.0)
		)
	if mode == &"resources":
		if tile.is_water:
			return (
				HIGH_CONTRAST_DIAGNOSTIC_WATER_COLOR
				if high_contrast
				else DIAGNOSTIC_WATER_COLOR
			)
		if String(tile.resource_type).is_empty():
			return (
				HIGH_CONTRAST_DIAGNOSTIC_LAND_COLOR
				if high_contrast
				else DIAGNOSTIC_LAND_COLOR
			)
		return EcologyRenderer.resource_marker_color(
			tile.resource_type,
			EcologyRenderer.PALETTE_HIGH_CONTRAST if high_contrast else EcologyRenderer.PALETTE_STANDARD
		)
	if mode == &"exclusion":
		var exclusion_overrides: Dictionary = HIGH_CONTRAST_OVERRIDES[&"exclusion"]
		for flag in EXCLUSION_DISPLAY_ORDER:
			if tile.exclusion_flags & int(flag) != 0:
				return exclusion_overrides[flag] if high_contrast else EXCLUSION_COLORS[flag]
		return exclusion_overrides[&"none"] if high_contrast else UNEXCLUDED_COLOR
	var biome_color: Color = BIOME_COLORS.get(
		tile.biome,
		TERRAIN_COLORS.get(tile.terrain_type, Color("#745f42"))
	)
	# The biome view is the only mode reaching this fallback (every other mode
	# returns above), so this is the only place `COLOR.a` carries the material
	# response instead of the implicit opaque 1.0 every hex-literal `Color(...)`
	# above already returns.
	return Color(biome_color.r, biome_color.g, biome_color.b, biome_material_response(tile.biome))


static func tile_display_color(
	tile: HexTileData,
	debug_mode: Variant,
	palette: StringName = PALETTE_STANDARD
) -> Color:
	return _tile_color(tile, debug_mode, palette)


## Canonical organic-to-mineral floor material response for a biome, used to
## blend the compact original material-pattern texture in
## `hex_terrain.gdshader` instead of authoring one texture per biome. Public so
## tools and tests can validate the continuum without constructing a tile.
static func biome_material_response(biome: StringName) -> float:
	return float(BIOME_MATERIAL_RESPONSE.get(biome, DEFAULT_MATERIAL_RESPONSE))


static func _corner_color(
	world: HexWorldData,
	tile: HexTileData,
	corner_index: int,
	debug_mode: Variant,
	palette: StringName = PALETTE_STANDARD
) -> Color:
	var touching_tiles: Array[HexTileData] = [tile]
	var first := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, corner_index))
	var second := world.tile_at(HexCoordinatesScript.neighbor(tile.coordinate, corner_index + 1))
	if first != null and not first.is_water:
		touching_tiles.append(first)
	if second != null and not second.is_water:
		touching_tiles.append(second)
	var color := Color(0.0, 0.0, 0.0, 0.0)
	for touching_tile in touching_tiles:
		color += _tile_color(touching_tile, debug_mode, palette)
	return color / float(touching_tiles.size())


static func _temperature_color(value: float) -> Color:
	var cold := Color("#28529a")
	var cool := Color("#43a8aa")
	var mild := Color("#d4bd42")
	var hot := Color("#b83b2f")
	if value < 0.4:
		return cold.lerp(cool, value / 0.4)
	if value < 0.7:
		return cool.lerp(mild, (value - 0.4) / 0.3)
	return mild.lerp(hot, (value - 0.7) / 0.3)


static func _moisture_color(value: float) -> Color:
	var dry := Color("#8f482f")
	var moderate := Color("#7f9b3f")
	var wet := Color("#176b78")
	if value < 0.5:
		return dry.lerp(moderate, value / 0.5)
	return moderate.lerp(wet, (value - 0.5) / 0.5)


## Explicit terrain diagnostic for the floor-material system's canonical
## organic(0)-to-mineral(1) continuum (`biome_material_response`). Deliberately
## a plain two-colour lerp with no local rock-exposure bump, seed phase, or
## texture sample, so the diagnostic answers exactly one question ("what
## response does this biome resolve to") and stays flat and testable: the
## same biome always renders the same colour regardless of elevation,
## moisture, or world seed. Water keeps the shared `DIAGNOSTIC_WATER_COLOR`
## treatment used by every other non-biome diagnostic.
static func _material_response_color(value: float) -> Color:
	return MATERIAL_RESPONSE_ORGANIC_COLOR.lerp(
		MATERIAL_RESPONSE_MINERAL_COLOR,
		clampf(value, 0.0, 1.0)
	)


static func _is_chunk_boundary(
	tile: HexTileData,
	neighbor: HexTileData,
	chunk_size: int
) -> bool:
	if neighbor == null:
		return true
	var tile_chunk := Vector2i(
		tile.offset_coordinate.x / chunk_size,
		tile.offset_coordinate.y / chunk_size
	)
	var neighbor_chunk := Vector2i(
		neighbor.offset_coordinate.x / chunk_size,
		neighbor.offset_coordinate.y / chunk_size
	)
	if tile_chunk == neighbor_chunk:
		return false
	return not _tile_order_after(tile, neighbor)


static func _tile_order_after(a: HexTileData, b: HexTileData) -> bool:
	return (
		a.offset_coordinate.y > b.offset_coordinate.y
		or (
			a.offset_coordinate.y == b.offset_coordinate.y
			and a.offset_coordinate.x > b.offset_coordinate.x
		)
	)
