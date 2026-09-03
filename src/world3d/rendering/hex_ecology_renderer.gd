class_name HexEcologyRenderer
extends RefCounted

## Phase 4 batched ecology rendering.
##
## Every terrain chunk produces at most one `MultiMeshInstance3D` per feature
## class. Vegetation and resource markers never create per-feature nodes, and
## the shared class meshes and materials are allocated once for the whole
## world rather than per chunk or per tile.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const EcologyStage = preload("res://src/world3d/generator/ecology_stage.gd")

const PLACEMENT_SALT := 0x34504c43
const RESOURCE_CLASS := &"resource"
const FEATURE_CLASS_IDS := [
	EcologyStage.VEGETATION_CLASS_BROADLEAF,
	EcologyStage.VEGETATION_CLASS_CONIFER,
	EcologyStage.VEGETATION_CLASS_SCRUB,
	RESOURCE_CLASS,
]
## Instances contributed by one tile at full detail, by vegetation feature.
const FEATURE_INSTANCE_COUNTS := {
	EcologyStage.FEATURE_SPARSE: 1,
	EcologyStage.FEATURE_WOODLAND: 2,
	EcologyStage.FEATURE_FOREST: 4,
	EcologyStage.FEATURE_DENSE_FOREST: 6,
}
const MAXIMUM_TILE_INSTANCES := 6
## In-hex placement radius as a fraction of `hex_size`. Together with the
## maximum vegetation mesh radius and scale, this stays inside the pointy-top
## inradius so a complete prop never crosses a tile edge or chunk border.
const PLACEMENT_RADIUS := 0.38
const MAXIMUM_VEGETATION_MESH_RADIUS := 0.26
const MAXIMUM_VEGETATION_SCALE := 1.43
const POINTY_HEX_INRADIUS := 0.8660254
const TILE_EDGE_CLEARANCE := 0.01
## Distance-based density reduction. This runs before any model LOD: the
## instance buffer is ordered so that the first pass over every tile comes
## first, and reducing `visible_instance_count` therefore thins extra props
## while keeping one prop on every vegetated tile.
const FULL_DETAIL_CAMERA_HEIGHT := 45.0
const MINIMUM_DETAIL_CAMERA_HEIGHT := 150.0
const MINIMUM_DETAIL_FACTOR := 0.25
## Documented Ultra prototype budget, enforced by the Phase 4 tests and
## reported by the runtime preview. See `docs/HEX_WORLD_PHASE4.md`.
const ULTRA_INSTANCE_BUDGET := 8000
const ULTRA_INSTANCE_BUFFER_BYTES_BUDGET := 512 * 1024
const ULTRA_SCENE_DRAW_CALL_BUDGET := 220
const VEGETATION_COLORS := {
	EcologyStage.VEGETATION_CLASS_BROADLEAF: Color("#2f6b32"),
	EcologyStage.VEGETATION_CLASS_CONIFER: Color("#26543f"),
	EcologyStage.VEGETATION_CLASS_SCRUB: Color("#6f7a41"),
}
## Saturated marker colors that no biome terrain or vegetation tone uses.
const RESOURCE_MARKER_COLORS := {
	&"timber": Color("#f0b429"),
	&"grain": Color("#ffe066"),
	&"horses": Color("#e07a3f"),
	&"iron": Color("#c9d1d9"),
	&"stone": Color("#9aa5b1"),
	&"furs": Color("#c46bd6"),
	&"fish": Color("#3fd0e0"),
	&"salt": Color("#f2f5f7"),
	&"gold": Color("#ffd21f"),
	&"wine": Color("#c62f57"),
}
const RESOURCE_MARKER_FALLBACK_COLOR := Color("#ff5fa2")
const PALETTE_STANDARD := &"standard"
const PALETTE_HIGH_CONTRAST := &"high_contrast"
## Phase 5 accessibility review: every standard marker colour already clears a
## 3.0 figure/ground ratio against the neutral diagnostic land and water tones
## except `wine`, which measured 2.21. The accessible palette lightens only that
## entry and leaves the approved Phase 4 colours untouched.
const RESOURCE_MARKER_HIGH_CONTRAST_COLORS := {
	&"timber": Color("#f0b429"),
	&"grain": Color("#ffe066"),
	&"horses": Color("#e07a3f"),
	&"iron": Color("#c9d1d9"),
	&"stone": Color("#9aa5b1"),
	&"furs": Color("#c46bd6"),
	&"fish": Color("#3fd0e0"),
	&"salt": Color("#f2f5f7"),
	&"gold": Color("#ffd21f"),
	&"wine": Color("#f3557f"),
}

static var _class_meshes: Dictionary = {}
static var _class_materials: Dictionary = {}


static func resource_marker_color(
	resource_type: StringName,
	palette: StringName = PALETTE_STANDARD
) -> Color:
	if palette == PALETTE_HIGH_CONTRAST:
		return RESOURCE_MARKER_HIGH_CONTRAST_COLORS.get(
			resource_type,
			RESOURCE_MARKER_FALLBACK_COLOR
		)
	return RESOURCE_MARKER_COLORS.get(resource_type, RESOURCE_MARKER_FALLBACK_COLOR)


static func feature_class_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(FEATURE_CLASS_IDS)
	return result


static func tile_instance_count(tile: HexTileData) -> int:
	if tile == null:
		return 0
	if not String(tile.resource_type).is_empty():
		return 1
	return int(FEATURE_INSTANCE_COUNTS.get(tile.feature_type, 0))


static func tile_feature_class(tile: HexTileData) -> StringName:
	if not String(tile.resource_type).is_empty():
		return RESOURCE_CLASS
	return EcologyStage.vegetation_class_for_biome(tile.biome)


## Builds the ordered instance list for one chunk and feature class. Pass zero
## contains the first prop of every tile, pass one the second, and so on, so a
## reduced visible count always keeps the most important props.
static func build_chunk_instances(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i,
	feature_class: StringName,
	palette: StringName = PALETTE_STANDARD
) -> Array:
	var instances: Array = []
	var start_column := chunk_coordinate.x * settings.chunk_size
	var start_row := chunk_coordinate.y * settings.chunk_size
	var end_column := mini(start_column + settings.chunk_size, world.width)
	var end_row := mini(start_row + settings.chunk_size, world.height)
	for pass_index in range(MAXIMUM_TILE_INSTANCES):
		for row in range(start_row, end_row):
			for column in range(start_column, end_column):
				var tile := world.tile_at_offset(column, row)
				if tile == null or tile_feature_class(tile) != feature_class:
					continue
				if pass_index >= tile_instance_count(tile):
					continue
				instances.append(
					_instance_data(
						world,
						tile,
						settings,
						pass_index,
						feature_class,
						palette
					)
				)
	return instances


static func build_chunk_multimesh(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	chunk_coordinate: Vector2i,
	feature_class: StringName,
	palette: StringName = PALETTE_STANDARD
) -> MultiMesh:
	var instances := build_chunk_instances(
		world,
		settings,
		chunk_coordinate,
		feature_class,
		palette
	)
	if instances.is_empty():
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = class_mesh(feature_class)
	multimesh.instance_count = instances.size()
	var minimum_visible_instances := 0
	for index in range(instances.size()):
		var instance: Dictionary = instances[index]
		multimesh.set_instance_transform(index, instance["transform"])
		multimesh.set_instance_color(index, instance["color"])
		if int(instance["pass_index"]) == 0:
			minimum_visible_instances += 1
	multimesh.set_meta("minimum_visible_instance_count", minimum_visible_instances)
	multimesh.visible_instance_count = instances.size()
	return multimesh


static func _instance_data(
	world: HexWorldData,
	tile: HexTileData,
	settings: WorldGenerationSettings,
	instance_index: int,
	feature_class: StringName,
	palette: StringName = PALETTE_STANDARD
) -> Dictionary:
	var scale_unit := _hash_unit(
		world.seed,
		PLACEMENT_SALT + instance_index * 7919,
		tile.coordinate
	)
	var angle_unit := _hash_unit(
		world.seed,
		PLACEMENT_SALT + instance_index * 104729 + 13,
		tile.coordinate
	)
	var radius_unit := _hash_unit(
		world.seed,
		PLACEMENT_SALT + instance_index * 15485863 + 29,
		tile.coordinate
	)
	var origin := tile.position
	origin.y = tile.elevation - 0.02
	if feature_class == RESOURCE_CLASS:
		var marker_scale := settings.hex_size * 0.34
		var marker_basis := Basis(
			Vector3.UP,
			angle_unit * TAU
		).scaled(Vector3(marker_scale, marker_scale, marker_scale))
		return {
			"transform": Transform3D(marker_basis, origin),
			"color": resource_marker_color(tile.resource_type, palette),
			"pass_index": instance_index,
		}
	var radius := (
		settings.hex_size
		* placement_radius_for_corner_distortion(settings.corner_distortion)
		* sqrt(radius_unit)
	)
	var angle := angle_unit * TAU
	origin.x += cos(angle) * radius
	origin.z += sin(angle) * radius
	var density_scale := 0.62 + tile.vegetation_density * 0.55
	var prop_scale := settings.hex_size * density_scale * (0.72 + scale_unit * 0.5)
	var basis := Basis(Vector3.UP, angle_unit * TAU + float(instance_index)).scaled(
		Vector3(prop_scale, prop_scale * (0.86 + scale_unit * 0.4), prop_scale)
	)
	var base_color: Color = VEGETATION_COLORS.get(feature_class, Color("#3d6b34"))
	var shade := (scale_unit - 0.5) * 0.24
	var color := Color(
		clampf(base_color.r + shade * 0.5, 0.0, 1.0),
		clampf(base_color.g + shade, 0.0, 1.0),
		clampf(base_color.b + shade * 0.4, 0.0, 1.0),
		1.0
	)
	return {
		"transform": Transform3D(basis, origin),
		"color": color,
		"pass_index": instance_index,
	}


static func placement_radius_for_corner_distortion(corner_distortion: float) -> float:
	var distorted_inradius := POINTY_HEX_INRADIUS - clampf(corner_distortion, 0.0, 0.25)
	var silhouette_radius := (
		MAXIMUM_VEGETATION_MESH_RADIUS * MAXIMUM_VEGETATION_SCALE
	)
	return clampf(
		minf(
			PLACEMENT_RADIUS,
			distorted_inradius - silhouette_radius - TILE_EDGE_CLEARANCE
		),
		0.0,
		PLACEMENT_RADIUS
	)


static func detail_factor_for_camera_height(camera_height: float) -> float:
	var span := MINIMUM_DETAIL_CAMERA_HEIGHT - FULL_DETAIL_CAMERA_HEIGHT
	var distance := clampf(
		(camera_height - FULL_DETAIL_CAMERA_HEIGHT) / maxf(span, 0.001),
		0.0,
		1.0
	)
	return lerpf(1.0, MINIMUM_DETAIL_FACTOR, distance)


## Applies distance-based density reduction without rebuilding any buffer.
## Resource markers are strategic information and never thin out.
static func visible_instance_count(
	total_instances: int,
	feature_class: StringName,
	detail_factor: float,
	minimum_visible_instances := 1
) -> int:
	if total_instances <= 0:
		return 0
	if feature_class == RESOURCE_CLASS:
		return total_instances
	return clampi(
		maxi(
			ceili(float(total_instances) * clampf(detail_factor, 0.0, 1.0)),
			minimum_visible_instances
		),
		clampi(minimum_visible_instances, 1, total_instances),
		total_instances
	)


## Reports the batched-instance budget for one world without building nodes.
static func instance_budget_report(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	detail_factor := 1.0
) -> Dictionary:
	var chunk_columns := ceili(float(world.width) / float(settings.chunk_size))
	var chunk_rows := ceili(float(world.height) / float(settings.chunk_size))
	var per_class: Dictionary = {}
	var visible_per_class: Dictionary = {}
	var node_count := 0
	var total := 0
	var visible_total := 0
	for feature_class in FEATURE_CLASS_IDS:
		per_class[String(feature_class)] = 0
		visible_per_class[String(feature_class)] = 0
	for chunk_y in range(chunk_rows):
		for chunk_x in range(chunk_columns):
			for feature_class in FEATURE_CLASS_IDS:
				var instances := build_chunk_instances(
					world,
					settings,
					Vector2i(chunk_x, chunk_y),
					feature_class
				)
				var count := instances.size()
				if count == 0:
					continue
				var minimum_visible_instances := 0
				for instance in instances:
					if int(instance["pass_index"]) == 0:
						minimum_visible_instances += 1
				node_count += 1
				per_class[String(feature_class)] = int(
					per_class[String(feature_class)]
				) + count
				total += count
				var visible := visible_instance_count(
					count,
					feature_class,
					detail_factor,
					minimum_visible_instances
				)
				visible_per_class[String(feature_class)] = int(
					visible_per_class[String(feature_class)]
				) + visible
				visible_total += visible
	return {
		"ecology_instance_count": total,
		"ecology_visible_instance_count": visible_total,
		"ecology_instance_count_by_class": per_class,
		"ecology_visible_instance_count_by_class": visible_per_class,
		"ecology_multimesh_node_count": node_count,
		"ecology_chunk_count": chunk_columns * chunk_rows,
		"ecology_feature_class_count": FEATURE_CLASS_IDS.size(),
		"ecology_detail_factor": detail_factor,
		# One TRANSFORM_3D entry is 12 floats and one instance color is
		# 4 floats, so a batched instance costs 64 bytes of buffer.
		"ecology_instance_buffer_bytes": total * 64,
	}


static func class_mesh(feature_class: StringName) -> ArrayMesh:
	if _class_meshes.has(feature_class):
		return _class_meshes[feature_class]
	var mesh: ArrayMesh
	match feature_class:
		EcologyStage.VEGETATION_CLASS_CONIFER:
			mesh = _build_conifer_mesh()
		EcologyStage.VEGETATION_CLASS_SCRUB:
			mesh = _build_scrub_mesh()
		RESOURCE_CLASS:
			mesh = _build_resource_marker_mesh()
		_:
			mesh = _build_broadleaf_mesh()
	mesh.surface_set_material(0, class_material(feature_class))
	_class_meshes[feature_class] = mesh
	return mesh


static func class_material(feature_class: StringName) -> StandardMaterial3D:
	if _class_materials.has(feature_class):
		return _class_materials[feature_class]
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.88
	material.cull_mode = BaseMaterial3D.CULL_BACK
	if feature_class == RESOURCE_CLASS:
		# Markers read as authored strategic icons rather than as terrain
		# vegetation: harder shading, a rim of emission, and no roughness.
		material.roughness = 0.24
		material.metallic = 0.15
		material.emission_enabled = true
		material.emission = Color("#ffffff")
		material.emission_energy_multiplier = 0.35
	_class_materials[feature_class] = material
	return material


static func _build_broadleaf_mesh() -> ArrayMesh:
	var builder := _MeshBuilder.new()
	builder.add_prism(0.0, 0.055, 0.30, Color("#4a3421"), 4)
	builder.add_cone(0.30, 0.26, 0.60, Color("#ffffff"), 7)
	builder.add_cone(0.66, 0.17, 0.34, Color("#e6f0e0"), 7)
	return builder.build()


static func _build_conifer_mesh() -> ArrayMesh:
	var builder := _MeshBuilder.new()
	builder.add_prism(0.0, 0.05, 0.22, Color("#3c2c1d"), 4)
	builder.add_cone(0.20, 0.22, 0.52, Color("#ffffff"), 6)
	builder.add_cone(0.56, 0.16, 0.44, Color("#eef5ee"), 6)
	builder.add_cone(0.92, 0.09, 0.30, Color("#dfeadf"), 6)
	return builder.build()


static func _build_scrub_mesh() -> ArrayMesh:
	var builder := _MeshBuilder.new()
	builder.add_cone(0.0, 0.22, 0.24, Color("#ffffff"), 6)
	builder.add_cone(0.16, 0.13, 0.16, Color("#e8efd8"), 5)
	return builder.build()


static func _build_resource_marker_mesh() -> ArrayMesh:
	var builder := _MeshBuilder.new()
	# A slim pedestal plus a hard-edged double pyramid. The silhouette is
	# vertical and angular, so a marker never reads as a tree at map zoom.
	builder.add_prism(0.0, 0.075, 0.34, Color("#2a2f36"), 6)
	builder.add_cone(0.34, 0.26, 0.30, Color("#ffffff"), 4)
	builder.add_inverted_cone(0.64, 0.26, 0.34, Color("#e8ecf2"), 4)
	return builder.build()


static func _hash_unit(seed: int, salt: int, coordinate: Vector2i) -> float:
	var value := int(hash("%d:%d:%d:%d" % [seed, salt, coordinate.x, coordinate.y]))
	return float(posmod(value, 1000003)) / 1000002.0


class _MeshBuilder extends RefCounted:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func add_cone(base_y: float, radius: float, height: float, tint: Color, sides: int) -> void:
		var apex := Vector3(0.0, base_y + height, 0.0)
		for side in range(sides):
			var first := _ring_point(base_y, radius, side, sides)
			var second := _ring_point(base_y, radius, side + 1, sides)
			_add_triangle(first, second, apex, tint)
			_add_triangle(second, first, Vector3(0.0, base_y, 0.0), tint.darkened(0.25))

	func add_inverted_cone(
		base_y: float,
		radius: float,
		height: float,
		tint: Color,
		sides: int
	) -> void:
		var tip := Vector3(0.0, base_y - height, 0.0)
		for side in range(sides):
			var first := _ring_point(base_y, radius, side, sides)
			var second := _ring_point(base_y, radius, side + 1, sides)
			_add_triangle(second, first, tip, tint)

	func add_prism(
		base_y: float,
		input_radius: float,
		height: float,
		tint: Color,
		sides: int
	) -> void:
		var radius := maxf(input_radius, 0.03)
		for side in range(sides):
			var lower_first := _ring_point(base_y, radius, side, sides)
			var lower_second := _ring_point(base_y, radius, side + 1, sides)
			var upper_first := lower_first + Vector3(0.0, height, 0.0)
			var upper_second := lower_second + Vector3(0.0, height, 0.0)
			_add_triangle(lower_first, lower_second, upper_second, tint)
			_add_triangle(lower_first, upper_second, upper_first, tint)

	func build() -> ArrayMesh:
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
		return mesh

	func _ring_point(y: float, radius: float, side: int, sides: int) -> Vector3:
		var angle := TAU * float(side) / float(sides)
		return Vector3(cos(angle) * radius, y, sin(angle) * radius)

	func _add_triangle(a: Vector3, b: Vector3, c: Vector3, tint: Color) -> void:
		var normal := (b - a).cross(c - a).normalized()
		if normal.is_zero_approx():
			normal = Vector3.UP
		# Prop meshes are solids of revolution around the local Y axis. The
		# cross-product order of the cone and prism builders points inward, which
		# left every visible prop face lit only by ambient light and reading as a
		# black silhouette at close range. Orient the lighting normal outward.
		var centroid := (a + b + c) / 3.0
		var outward := Vector3(centroid.x, 0.0, centroid.z)
		if outward.length() > 0.001 and normal.dot(outward.normalized()) < 0.0:
			normal = -normal
		var base := vertices.size()
		# ArrayMesh front faces are clockwise, matching the terrain mesher.
		vertices.append_array(PackedVector3Array([a, c, b]))
		normals.append_array(PackedVector3Array([normal, normal, normal]))
		colors.append_array(PackedColorArray([tint, tint, tint]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2]))
