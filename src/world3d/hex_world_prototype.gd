class_name HexWorldPrototype
extends Node3D

signal world_regenerated(world: HexWorldData)
signal terrain_view_changed(view_id: String)
signal ecology_detail_changed(detail_factor: float)
signal tile_selected(tile: HexTileData)
signal generation_progress(stage: String, progress: float)
signal chunks_rebuilt(chunk_count: int, reason: String)
signal device_benchmark_finished(document: Dictionary)

const Generator = preload("res://src/world3d/generator/hex_world_generator.gd")
const GenerationJob = preload("res://src/world3d/generator/hex_world_generation_job.gd")
const Mesher = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")
const TerrainMaterial = preload("res://src/world3d/rendering/hex_terrain_material.gd")
const HydrologyMesher = preload("res://src/world3d/rendering/hex_hydrology_mesher.gd")
const EcologyRenderer = preload("res://src/world3d/rendering/hex_ecology_renderer.gd")
const UnderwaterEcologyRenderer = preload(
	"res://src/world3d/rendering/hex_underwater_ecology_renderer.gd"
)
const EcologyStage = preload("res://src/world3d/generator/ecology_stage.gd")
const ChunkIndex = preload("res://src/world3d/hex/hex_chunk_index.gd")
const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const Picker = preload("res://src/world3d/interaction/hex_picker.gd")
const Serializer = preload("res://src/world3d/data/hex_world_serializer.gd")
const Budget = preload("res://src/world3d/rendering/hex_world_budget.gd")
const DeviceBenchmark = preload("res://src/world3d/rendering/hex_world_device_benchmark.gd")
const DeviceEvidence = preload("res://src/world3d/rendering/hex_world_device_evidence.gd")

## Terrain views in which batched vegetation props remain visible. Other
## diagnostics hide vegetation so the tile colors stay readable.
const VEGETATION_VISIBLE_VIEWS := ["biome", "ecology"]
## Resource markers stay visible in the resource diagnostic as well.
const RESOURCE_VISIBLE_VIEWS := ["biome", "ecology", "resources"]
const TERRAIN_VIEW_IDS := [
	"biome",
	"elevation",
	"temperature",
	"moisture",
	"flow_direction",
	"watershed",
	"accumulation",
	"lakes",
	"river_edges",
	"ecology",
	"resources",
	"density",
	"exclusion",
	"material_response",
]
## Detail switch distance and the scrub feature-LOD distance, both expressed as
## multiples of the framed camera height so every tier behaves the same.
const TERRAIN_LOD_FRAME_FACTOR := 1.25
const SCRUB_VISIBILITY_FRAME_FACTOR := 1.15
const DEFAULT_SAVE_PATH := "user://hex_world_prototype.tlchex"
## Where a device benchmark writes its evidence document inside the sandbox.
const DEFAULT_DEVICE_EVIDENCE_PATH := "user://hex_world_device_evidence.json"
## The packaged benchmark build declares this custom feature, which is what
## routes it to the prototype scene and starts an unattended capture. A normal
## build never has it, so the production 2D campaign is untouched.
const BENCHMARK_FEATURE := "hexbench"
## Console fences so an unattended handset capture can be recovered from the
## device log alone, without file sharing or a debugger attached.
const EVIDENCE_CONSOLE_BEGIN := "----- BEGIN HEX WORLD DEVICE EVIDENCE -----"
const EVIDENCE_CONSOLE_END := "----- END HEX WORLD DEVICE EVIDENCE -----"

@export_category("Generation")
@export var settings: WorldGenerationSettings
@export var generate_on_ready := true
@export var parse_command_line_on_ready := true
@export var show_test_panel := true
## Runs logical generation on a worker thread. The worker only builds plain
## data; every scene-tree and mesh operation stays on the main thread.
@export var use_worker_thread_generation := true
@export var regenerate_in_editor := false:
	set(value):
		regenerate_in_editor = false
		if value and is_inside_tree():
			call_deferred("regenerate")

@export_category("Debug")
@export_enum(
	"Biome:biome",
	"Elevation:elevation",
	"Temperature:temperature",
	"Moisture:moisture",
	"Flow direction:flow_direction",
	"Watershed:watershed",
	"Accumulation:accumulation",
	"Lakes:lakes",
	"River edges:river_edges",
	"Ecology:ecology",
	"Resources:resources",
	"Vegetation density:density",
	"Exclusion zones:exclusion",
	"Material response:material_response"
)
var terrain_view := "biome":
	set(value):
		var hydrology_mode_changed := (
			(terrain_view == "river_edges") != (value == "river_edges")
		)
		terrain_view = value
		if is_inside_tree() and world_data != null:
			_rebuild_terrain()
			if hydrology_mode_changed:
				_rebuild_hydrology()
			_update_ecology_visibility()
			_update_terrain_material()
			terrain_view_changed.emit(terrain_view)
@export var debug_elevation := false:
	set(value):
		debug_elevation = value
		if value and terrain_view != "elevation":
			terrain_view = "elevation"
		elif not value and terrain_view == "elevation":
			terrain_view = "biome"
@export var show_hex_boundaries := false:
	set(value):
		show_hex_boundaries = value
		if is_inside_tree():
			_update_debug_visibility()
@export var show_chunk_boundaries := false:
	set(value):
		show_chunk_boundaries = value
		if is_inside_tree():
			_update_debug_visibility()

@export_category("Phase 5")
@export var enable_terrain_lod := true:
	set(value):
		enable_terrain_lod = value
		if is_inside_tree():
			_apply_terrain_lod()
@export var enable_collision := true
@export var high_contrast_palette := false:
	set(value):
		if high_contrast_palette == value:
			return
		high_contrast_palette = value
		if is_inside_tree() and world_data != null:
			_rebuild_terrain()
			_rebuild_ecology()
			_update_terrain_material()

var world_data: HexWorldData
var last_generation_ms := 0
var last_build_ms := 0
var last_rebuilt_chunk_count := 0
var ecology_detail_factor := 1.0
## Pins batched vegetation density so a measurement can hold the declared worst
## case — the framed strategy view at full ecology — instead of only sampling
## whatever the distance rule happens to choose. `-1.0` restores the normal
## distance-driven behaviour and is the only value the game ever runs with.
var ecology_detail_override := -1.0:
	set(value):
		ecology_detail_override = value
		if is_inside_tree() and world_data != null:
			_last_detail_camera_height = -1.0
			update_ecology_detail()
var selected_tile: HexTileData

var _last_detail_camera_height := -1.0
var _terrain_material: ShaderMaterial
## Result of the last `TerrainMaterial.bind_biome_field()` call (`ok`,
## `error`, `width`, `height`, `byte_count`, ...); surfaced by
## `runtime_report()` so the field's dimensions/memory impact is part of the
## same accounting every other geometry/memory figure goes through.
var _biome_field_info: Dictionary = {}
var _chunk_records: Dictionary = {}
var _pick_index: Dictionary = {}
var _dirty_chunks: Dictionary = {}
## World-scoped `HexTerrainMesher._tile_top_normal()` memoisation, keyed by
## axial tile coordinate. It is a pure function of `(world_data, tile,
## resolved_settings)`, so sharing it across every near/far/collision surface
## built for the whole current `world_data` removes redundant recomputation
## without changing a computed normal. The same dictionary stores render-only
## bathymetry heights, which are also pure world-data derivatives. The cache is
## cleared whenever the world changes or before any dirty rebuild. Terrain
## mutation is rare and bounded to explicitly rebuilt chunks, so full
## invalidation is both cheap and safer than trying to maintain a second
## dependency graph beside `HexChunkIndex`.
var _tile_normal_cache: Dictionary = {}
var _generation_job: GenerationJob
var _worker_ran_off_main_thread := false
var _suspended_camera_state: Dictionary = {}
var _lod_distance := 0.0
var _resolved_settings: WorldGenerationSettings
var _run_benchmark_on_ready := false
var _run_device_protocol_on_ready := false
var _device_benchmark: DeviceBenchmark

@onready var terrain_chunks: Node3D = %TerrainChunks
@onready var terrain_chunks_far: Node3D = %TerrainChunksFar
@onready var terrain_colliders: Node3D = %TerrainColliders
@onready var hydrology_chunks: Node3D = %HydrologyChunks
@onready var ecology_chunks: Node3D = %EcologyChunks
@onready var underwater_ecology_chunks: Node3D = %UnderwaterEcologyChunks
@onready var ocean_floor: MeshInstance3D = %OceanFloor
@onready var ocean: MeshInstance3D = %Ocean
@onready var hex_debug: MeshInstance3D = %HexDebug
@onready var chunk_debug: MeshInstance3D = %ChunkDebug
@onready var strategy_camera: StrategyCamera3D = %StrategyCamera
@onready var test_panel: Control = %TestPanel
@onready var loading_overlay: HexWorldLoadingOverlay = %LoadingOverlay


func _ready() -> void:
	if settings == null:
		settings = WorldGenerationSettings.new()
	var tapped_callback := Callable(self, "_on_camera_tapped")
	if strategy_camera != null and not strategy_camera.is_connected(&"tapped", tapped_callback):
		strategy_camera.connect(&"tapped", tapped_callback)
	if not Engine.is_editor_hint() and parse_command_line_on_ready:
		var options := parse_arguments(OS.get_cmdline_user_args())
		if not bool(options["ok"]):
			var message := String(options["error"])
			push_error(message)
			get_window().title = "Godot Test - invalid 3D hex-world arguments"
			if DisplayServer.get_name() == "headless":
				get_tree().quit(2)
			return
		if OS.has_feature(BENCHMARK_FEATURE) and OS.get_cmdline_user_args().is_empty():
			# The packaged benchmark build receives no arguments, so it boots
			# directly into the protocol's declared starting world instead of a
			# random default. Only that build carries the feature.
			options["seed"] = DeviceBenchmark.DEFAULT_SEED
			options["size"] = String(DeviceEvidence.REQUIRED_PROFILE_IDS[0])
			options["style"] = DeviceBenchmark.DEFAULT_STYLE
		settings.seed = int(options["seed"])
		settings.map_size_profile = String(options["size"])
		settings.landform_style = String(options["style"])
		_run_benchmark_on_ready = bool(options["benchmark"])
		_run_device_protocol_on_ready = bool(options["device_benchmark"])
	if generate_on_ready:
		regenerate()
		if _run_benchmark_on_ready:
			call_deferred("write_device_benchmark")
		if _run_device_protocol_on_ready:
			call_deferred("_start_unattended_device_benchmark")


func _exit_tree() -> void:
	if _device_benchmark != null:
		_device_benchmark.cancel()
	_finish_generation_job()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_poll_generation_job()
	if world_data == null or strategy_camera == null:
		return
	update_ecology_detail()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			if strategy_camera != null:
				_suspended_camera_state = strategy_camera.capture_state()
		NOTIFICATION_APPLICATION_RESUMED:
			if strategy_camera != null and not _suspended_camera_state.is_empty():
				strategy_camera.restore_state(_suspended_camera_state)
		NOTIFICATION_WM_SIZE_CHANGED:
			if strategy_camera != null and world_data != null:
				strategy_camera.restore_state(strategy_camera.capture_state())


func _unhandled_key_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			regenerate()
		KEY_F1:
			set_terrain_view("biome" if terrain_view == "elevation" else "elevation")
		KEY_F2:
			show_hex_boundaries = not show_hex_boundaries
		KEY_F3:
			show_chunk_boundaries = not show_chunk_boundaries
		KEY_F4:
			set_terrain_view("temperature")
		KEY_F5:
			set_terrain_view("moisture")
		KEY_F6:
			set_terrain_view("biome")
		KEY_F7:
			set_terrain_view("ecology")
		KEY_F8:
			set_terrain_view("resources")
		KEY_F9:
			high_contrast_palette = not high_contrast_palette
		KEY_TAB:
			if test_panel != null:
				test_panel.visible = not test_panel.visible


## Synchronous generation. Used by tooling, tests, and the editor because it
## finishes inside one call.
func regenerate() -> void:
	var resolved_settings := _resolve_settings()
	_report_progress("Generating logical world", 0.05)
	var generation_started := Time.get_ticks_msec()
	world_data = Generator.generate(resolved_settings)
	last_generation_ms = Time.get_ticks_msec() - generation_started
	_worker_ran_off_main_thread = false
	_install_world(resolved_settings)


## Optional worker-thread generation. Only `HexWorldGenerator.generate` runs off
## the main thread; the scene tree and every mesh resource are touched here,
## after `poll()` reports the worker finished.
func regenerate_async() -> void:
	if _generation_job != null:
		return
	var resolved_settings := _resolve_settings()
	if not use_worker_thread_generation:
		regenerate()
		return
	if loading_overlay != null:
		loading_overlay.begin("Generating world")
	_report_progress("Generating logical world on a worker thread", 0.05)
	_generation_job = GenerationJob.new()
	_generation_job.start(resolved_settings)


func is_generating() -> bool:
	return _generation_job != null


## Marks one logical tile as changed and returns every chunk whose geometry
## depends on it. Nothing is rebuilt until `rebuild_dirty_chunks` runs.
func mark_tile_dirty(coordinate: Vector2i) -> Array[Vector2i]:
	return mark_tiles_dirty([coordinate])


func mark_tiles_dirty(coordinates: Array) -> Array[Vector2i]:
	if world_data == null:
		return []
	_invalidate_tile_normal_cache(coordinates)
	var chunks := ChunkIndex.dependent_chunks_for_tiles(
		world_data,
		coordinates,
		_resolve_settings().chunk_size
	)
	for chunk in chunks:
		_dirty_chunks[chunk] = true
	return chunks


## Invalidates the derived normal cache before terrain data changes. A normal
## depends on canonical corner groups as well as its own tile, and those groups
## can cross a chunk boundary. Clearing the small dictionary avoids stale
## second-order dependencies while the existing dirty-chunk set still limits
## all actual remeshing work.
func _invalidate_tile_normal_cache(_coordinates: Array) -> void:
	_tile_normal_cache.clear()


func dirty_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	result.assign(_dirty_chunks.keys())
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)
	return result


## Rebuilds only the chunks marked dirty, including the geometrically dependent
## neighbours resolved by `HexChunkIndex`.
func rebuild_dirty_chunks() -> int:
	if world_data == null or _dirty_chunks.is_empty():
		last_rebuilt_chunk_count = 0
		return 0
	var chunks := dirty_chunks()
	_dirty_chunks.clear()
	var started := Time.get_ticks_msec()
	for chunk in chunks:
		_rebuild_chunk(chunk, _resolve_settings())
	_apply_ecology_detail_factor()
	_update_ecology_visibility()
	_apply_terrain_lod()
	last_rebuilt_chunk_count = chunks.size()
	last_build_ms = Time.get_ticks_msec() - started
	chunks_rebuilt.emit(chunks.size(), "dirty")
	return chunks.size()


## Resolves a screen position to a logical hex using the canonical full-detail
## triangle soup shared with the chunk colliders.
func pick_tile_at(screen_position: Vector2) -> HexTileData:
	var result := pick_result_at(screen_position)
	return result["tile"] as HexTileData if bool(result["ok"]) else null


func pick_result_at(screen_position: Vector2) -> Dictionary:
	if world_data == null or strategy_camera == null:
		return {"ok": false, "tile": null}
	return Picker.pick_from_camera(
		world_data,
		_resolve_settings(),
		_pick_index,
		strategy_camera,
		screen_position
	)


func select_tile(tile: HexTileData) -> void:
	selected_tile = tile
	tile_selected.emit(tile)


func focus_on_selected_tile() -> void:
	if selected_tile == null or strategy_camera == null:
		return
	strategy_camera.focus_on_tile(selected_tile)


## Diagnostic helper for the preview tooling: renders every chunk with the
## reduced-detail mesh so a reviewer can compare detail levels directly.
func preview_force_far_detail(enabled: bool) -> void:
	for key in _chunk_records:
		var record: Dictionary = _chunk_records[key]
		var near_instance := record.get("near") as MeshInstance3D
		var far_instance := record.get("far") as MeshInstance3D
		if near_instance == null or far_instance == null:
			continue
		if enabled:
			near_instance.visibility_range_begin = 0.0
			near_instance.visibility_range_end = 0.0
			near_instance.visible = false
			far_instance.visibility_range_begin = 0.0
			far_instance.visibility_range_end = 0.0
			far_instance.visible = true
		else:
			near_instance.visible = true
	if not enabled:
		_apply_terrain_lod()


## Verifies picking against a bounded deterministic tile sample by casting a
## ray straight down onto each sampled tile.
func picking_audit(sample_limit := 240) -> Dictionary:
	if world_data == null:
		return {"sample_count": 0, "correct_count": 0, "failures": []}
	var resolved_settings := _resolve_settings()
	var land_tiles: Array[HexTileData] = []
	for tile in world_data.tiles:
		if not tile.is_water:
			land_tiles.append(tile)
	if land_tiles.is_empty():
		return {"sample_count": 0, "correct_count": 0, "failures": []}
	var stride := maxi(1, int(ceil(float(land_tiles.size()) / float(maxi(sample_limit, 1)))))
	var height := world_data.world_bounds().size.y + resolved_settings.elevation_step_height * 8.0 + 40.0
	var sample_count := 0
	var correct_count := 0
	var cliff_samples := 0
	var chunk_border_samples := 0
	var failures: Array = []
	for index in range(0, land_tiles.size(), stride):
		var tile := land_tiles[index]
		sample_count += 1
		var origin := tile.position + Vector3(0.0, height, 0.0)
		var result := Picker.pick(
			world_data,
			resolved_settings,
			_pick_index,
			origin,
			Vector3.DOWN
		)
		var matched: bool = bool(result["ok"]) and result["coordinate"] == tile.coordinate
		if matched:
			correct_count += 1
		elif failures.size() < 12:
			failures.append({
				"expected": [tile.coordinate.x, tile.coordinate.y],
				"actual": [
					(result["coordinate"] as Vector2i).x,
					(result["coordinate"] as Vector2i).y,
				],
			})
		if tile.exclusion_flags & EcologyStage.EXCLUSION_CLIFF != 0:
			cliff_samples += 1
		if _is_chunk_border_tile(tile, resolved_settings.chunk_size):
			chunk_border_samples += 1
	return {
		"sample_count": sample_count,
		"correct_count": correct_count,
		"cliff_sample_count": cliff_samples,
		"chunk_border_sample_count": chunk_border_samples,
		"failures": failures,
	}


func _is_chunk_border_tile(tile: HexTileData, chunk_size: int) -> bool:
	var chunk := ChunkIndex.chunk_for_axial(tile.coordinate, chunk_size)
	for neighbor_coordinate in HexCoordinatesScript.neighbors(tile.coordinate):
		if not world_data.has_coordinate(neighbor_coordinate):
			continue
		if ChunkIndex.chunk_for_axial(neighbor_coordinate, chunk_size) != chunk:
			return true
	return false


func picking_index() -> Dictionary:
	return _pick_index


func save_world(path := DEFAULT_SAVE_PATH) -> Dictionary:
	if world_data == null:
		return {"ok": false, "error": "There is no generated world to save."}
	return Serializer.save_to_file(world_data, path)


func load_world(path := DEFAULT_SAVE_PATH) -> Dictionary:
	var result := Serializer.load_from_file(path)
	if not bool(result["ok"]):
		return result
	world_data = result["world"]
	var resolved_settings := _resolve_settings()
	resolved_settings.seed = world_data.seed
	resolved_settings.apply_map_size_profile(String(world_data.profile_id))
	settings.seed = world_data.seed
	settings.map_size_profile = String(world_data.profile_id)
	last_generation_ms = 0
	_install_world(resolved_settings, "Restoring saved world")
	return result


## Explicit generation, frame, and memory accounting for the current world.
## `biome_field_*` reports the last `TerrainMaterial.bind_biome_field()`
## result (see `_install_world()`): dimensions and raw byte size of the
## per-world continuous biome-floor blend field, so its memory impact is
## part of the same accounting as every other geometry/memory figure here.
func runtime_report() -> Dictionary:
	var resolved_settings := _resolve_settings()
	var terrain_triangles := 0
	var far_triangles := 0
	for key in _chunk_records:
		var record: Dictionary = _chunk_records[key]
		terrain_triangles += int(record.get("near_triangles", 0))
		far_triangles += int(record.get("far_triangles", 0))
	var ecology_instances := 0
	for child in ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance != null and instance.multimesh != null:
			ecology_instances += instance.multimesh.instance_count
	var underwater_instances := 0
	for child in underwater_ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance != null and instance.multimesh != null:
			underwater_instances += instance.multimesh.instance_count
	var collision_bytes := Picker.collision_memory_bytes(_pick_index)
	# Position, normal, colour, UV, and UV2 per vertex, three vertices per face.
	var terrain_bytes := (terrain_triangles + far_triangles) * 3 * (12 + 12 + 16 + 8 + 8)
	var geometry_bytes := (
		terrain_bytes
		+ collision_bytes
		+ ecology_instances * 64
		+ underwater_instances * 64
	)
	var measurements := {
		"generation_ms": last_generation_ms,
		"build_ms": last_build_ms,
		"geometry_bytes": geometry_bytes,
	}
	var profile_id: StringName = (
		world_data.profile_id if world_data != null else &"large"
	)
	return {
		"profile_id": String(profile_id),
		"chunk_count": _chunk_records.size(),
		"terrain_triangle_count": terrain_triangles,
		"terrain_far_triangle_count": far_triangles,
		"terrain_geometry_bytes": terrain_bytes,
		"collision_triangle_count": Picker.triangle_count(_pick_index),
		"collision_geometry_bytes": collision_bytes,
		"ecology_instance_count": ecology_instances,
		"underwater_instance_count": underwater_instances,
		"geometry_bytes": geometry_bytes,
		"generation_ms": last_generation_ms,
		"build_ms": last_build_ms,
		"generated_off_main_thread": _worker_ran_off_main_thread,
		"terrain_lod_enabled": enable_terrain_lod,
		"terrain_lod_distance": _lod_distance,
		"collision_enabled": enable_collision,
		"high_contrast_palette": high_contrast_palette,
		"chunk_size": resolved_settings.chunk_size,
		"budget": Budget.evaluate(profile_id, measurements),
		"biome_field_ok": bool(_biome_field_info.get("ok", false)),
		"biome_field_width": int(_biome_field_info.get("width", 0)),
		"biome_field_height": int(_biome_field_info.get("height", 0)),
		"biome_field_bytes": int(_biome_field_info.get("byte_count", 0)),
	}


## Target-device measurement hook. Runs the same code path on desktop and on a
## handset; only a handset capture is device evidence.
func write_device_benchmark(path := Budget.DEFAULT_DEVICE_REPORT_PATH) -> Dictionary:
	var report := runtime_report()
	var sample := Budget.capture_device_sample(
		StringName(String(report["profile_id"])),
		{
			"generation_ms": report["generation_ms"],
			"build_ms": report["build_ms"],
			"geometry_bytes": report["geometry_bytes"],
			"chunk_count": report["chunk_count"],
			"terrain_triangle_count": report["terrain_triangle_count"],
			"ecology_instance_count": report["ecology_instance_count"],
		}
	)
	var write_result := Budget.write_device_sample(sample, path)
	if bool(write_result["ok"]):
		print("3D hex world device budget sample written to %s" % write_result["path"])
	return write_result


## Runs the full repeatable target-device protocol and produces a versioned
## evidence document. The document is written into the sandbox *and* fenced on
## the console, because on a packaged handset build the sandbox file is not
## reachable without file sharing but the device log always is.
func run_device_benchmark(
	options: Dictionary = {},
	path := DEFAULT_DEVICE_EVIDENCE_PATH
) -> Dictionary:
	if _device_benchmark != null:
		return {"ok": false, "error": "A device benchmark is already running."}
	_device_benchmark = DeviceBenchmark.new()
	_device_benchmark.name = "DeviceBenchmark"
	add_child(_device_benchmark)
	_device_benchmark.progress.connect(_on_device_benchmark_progress)
	if loading_overlay != null:
		loading_overlay.begin("Device benchmark")
	var document: Dictionary = await _device_benchmark.run(self, options)
	if loading_overlay != null:
		loading_overlay.finish()
	_device_benchmark.queue_free()
	_device_benchmark = null

	var write_result := DeviceEvidence.write_document(document, path)
	print(EVIDENCE_CONSOLE_BEGIN)
	print(JSON.stringify(document, "\t"))
	print(EVIDENCE_CONSOLE_END)
	var evaluation: Dictionary = document.get("evaluation", {})
	print(
		"3D hex world device evidence: %s (%s)"
		% [
			"validated" if bool(evaluation.get("validated", false)) else "not validated",
			evaluation.get("reason", ""),
		]
	)
	device_benchmark_finished.emit(document)
	return {
		"ok": bool(write_result["ok"]),
		"error": String(write_result.get("error", "")),
		"path": path,
		"document": document,
	}


func is_running_device_benchmark() -> bool:
	return _device_benchmark != null


## The committed-evidence gate as the runtime sees it. `HexWorldBudget` declares
## the constant; this reports whether the repository actually holds evidence
## that earns it.
static func target_device_gate() -> Dictionary:
	return DeviceEvidence.repository_verdict()


## Deterministic close-view subject: the first land tile, in generation order,
## with the highest combined score for elevation, shoreline contact, and a real
## cliff edge. That is where the Phase 5 terrain treatment is most visible, and
## the choice never depends on iteration order or randomness. Shared by the
## preview capture close-up and by the device benchmark so both frame the same
## tile for the same world.
func deterministic_focus_tile() -> HexTileData:
	return select_deterministic_focus_tile(world_data)


static func select_deterministic_focus_tile(world: HexWorldData) -> HexTileData:
	if world == null:
		return null
	var best: HexTileData = null
	var best_score := -1
	for tile in world.tiles:
		if tile.is_water:
			continue
		var score := tile.elevation_level * 2
		if tile.exclusion_flags & EcologyStage.EXCLUSION_SHORE != 0:
			score += 5
		if tile.exclusion_flags & EcologyStage.EXCLUSION_CLIFF != 0:
			score += 4
		if score > best_score:
			best_score = score
			best = tile
	return best


## Deterministic biome-transition subject: the first land/land edge, in
## generation order (`world.tiles` order, then ascending neighbor direction),
## whose two tiles resolve to different implemented biomes and which has the
## single highest combined elevation/rock/moisture-contrast score. This is a
## distinct seam from `select_deterministic_focus_tile`'s coastal cliff join
## — it never selects a shoreline or cliff edge on its own, only an inland (or
## incidentally coastal) boundary between two different land biomes — so the
## `transition_closeup` capture and the existing `closeup` capture never
## duplicate the same subject. The score and the tie-break both depend only on
## logical world data already present on `HexTileData`; no `RandomNumberGenerator`
## draw is used, so the same world always frames the same seam. Returns an
## empty Dictionary when the world has no land tiles or no biome boundary
## (e.g. a single-biome world).
func deterministic_transition_subject() -> Dictionary:
	return select_deterministic_transition_subject(world_data)


static func select_deterministic_transition_subject(world: HexWorldData) -> Dictionary:
	if world == null:
		return {}
	var best: Dictionary = {}
	var best_score := -1.0
	for tile in world.tiles:
		if tile.is_water:
			continue
		for direction in range(6):
			var neighbor_coordinate: Vector2i = HexCoordinatesScript.neighbor(
				tile.coordinate,
				direction
			)
			var neighbor := world.tile_at(neighbor_coordinate)
			if neighbor == null or neighbor.is_water or neighbor.biome == tile.biome:
				continue
			var elevation_contrast := (
				absf(float(tile.elevation_level - neighbor.elevation_level)) / 4.0
			)
			var rock_contrast := absf(
				_transition_ground_exposure(tile) - _transition_ground_exposure(neighbor)
			)
			var moisture_contrast := absf(tile.moisture - neighbor.moisture)
			var score := elevation_contrast + rock_contrast + moisture_contrast
			if score > best_score:
				best_score = score
				best = {
					"first_coordinate": tile.coordinate,
					"first_biome": tile.biome,
					"second_coordinate": neighbor.coordinate,
					"second_biome": neighbor.biome,
					"subject_position": (tile.position + neighbor.position) * 0.5,
					"elevation_contrast": elevation_contrast,
					"rock_contrast": rock_contrast,
					"moisture_contrast": moisture_contrast,
					"score": score,
				}
	return best


## Small public exposed-ground proxy used only to score transition-subject
## contrast above. Deliberately a local, independent formula over public
## `HexTileData` fields (elevation level and vegetation density) rather than a
## dependency on `HexTerrainMesher._tile_rock_factor`: that helper is private
## rendering detail owned by the mesher, and this only needs a stable
## relative ordering between two tiles, not the mesher's exact shading value.
static func _transition_ground_exposure(tile: HexTileData) -> float:
	if tile.biome == &"bare_rock" or tile.biome == &"snow":
		return 1.0
	return clampf(
		0.16
			+ 0.2 * float(clampi(tile.elevation_level - 1, 0, 3))
			- 0.7 * clampf(tile.vegetation_density, 0.0, 1.0),
		0.0,
		1.0
	)


func _on_device_benchmark_progress(stage: String, fraction: float) -> void:
	_report_progress(stage, fraction)


func set_terrain_view(value: String) -> void:
	if value not in TERRAIN_VIEW_IDS:
		push_error("Unknown 3D terrain view '%s'." % value)
		return
	terrain_view = value


## Reduces batched vegetation density with camera distance before any model
## LOD exists. Only `visible_instance_count` changes, so no buffer is rebuilt.
func update_ecology_detail() -> void:
	if strategy_camera == null:
		return
	var height := strategy_camera.camera_height()
	if (
		ecology_detail_override < 0.0
		and absf(height - _last_detail_camera_height) < 0.5
	):
		return
	_last_detail_camera_height = height
	_update_terrain_material()
	var previous_factor := ecology_detail_factor
	var resolved_factor := (
		clampf(ecology_detail_override, 0.0, 1.0)
		if ecology_detail_override >= 0.0
		else EcologyRenderer.detail_factor_for_camera_height(height)
	)
	if is_equal_approx(resolved_factor, previous_factor):
		# The pinned measurement state holds one factor for its whole window;
		# re-walking every batched multimesh each frame would measure the
		# harness instead of the scene.
		return
	ecology_detail_factor = resolved_factor
	_apply_ecology_detail_factor()
	ecology_detail_changed.emit(ecology_detail_factor)


func _resolve_settings() -> WorldGenerationSettings:
	if settings == null:
		settings = WorldGenerationSettings.new()
	var resolved := settings.validated_copy()
	settings.map_size_profile = resolved.map_size_profile
	settings.map_width = resolved.map_width
	settings.map_height = resolved.map_height
	settings.continent_count = resolved.continent_count
	_resolved_settings = resolved
	return resolved


func _poll_generation_job() -> void:
	if _generation_job == null or not _generation_job.poll():
		return
	var result := _generation_job.take_result()
	_generation_job = null
	if not bool(result.get("ok", false)):
		push_error("Worker-thread 3D hex world generation failed.")
		if loading_overlay != null:
			loading_overlay.finish()
		return
	world_data = result["world"]
	last_generation_ms = int(result["generation_ms"])
	_worker_ran_off_main_thread = bool(result["ran_off_main_thread"])
	_install_world(_resolve_settings())


func _finish_generation_job() -> void:
	if _generation_job == null:
		return
	_generation_job.take_result()
	_generation_job = null


## Main-thread scene assembly. Everything that creates a node, a mesh, or a
## material happens here.
func _install_world(resolved_settings: WorldGenerationSettings, title := "Generating world") -> void:
	if loading_overlay != null and not loading_overlay.visible:
		loading_overlay.begin(title)
	var build_started := Time.get_ticks_msec()
	_dirty_chunks.clear()
	_chunk_records.clear()
	_pick_index.clear()
	_tile_normal_cache.clear()
	selected_tile = null
	_clear_children(terrain_chunks)
	_clear_children(terrain_chunks_far)
	_clear_children(terrain_colliders)
	_clear_children(hydrology_chunks)
	_clear_children(ecology_chunks)
	_clear_children(underwater_ecology_chunks)
	# The continuous biome-floor blend field is genuinely global (one texture
	# per world, not per chunk), so it is built/bound exactly once here, when
	# `world_data` itself changes — never inside `_update_terrain_material()`,
	# which runs on every camera-height/view/palette tick.
	_bind_terrain_material_biome_field()
	_report_progress("Building terrain chunks", 0.35)
	var chunks := ChunkIndex.all_chunks(world_data, resolved_settings.chunk_size)
	for chunk in chunks:
		_rebuild_chunk(chunk, resolved_settings)
	_report_progress("Framing the world", 0.85)
	ocean_floor.mesh = Mesher.build_ocean_floor(world_data, resolved_settings)
	ocean_floor.material_override = _ensure_terrain_material()
	ocean.mesh = Mesher.build_ocean(world_data, resolved_settings)
	hex_debug.mesh = (
		Mesher.build_boundary_mesh(world_data, resolved_settings, false)
		if show_hex_boundaries
		else null
	)
	chunk_debug.mesh = (
		Mesher.build_boundary_mesh(world_data, resolved_settings, true)
		if show_chunk_boundaries
		else null
	)
	_update_debug_visibility()
	strategy_camera.frame_world(world_data.world_bounds(), resolved_settings.hex_size)
	_lod_distance = strategy_camera.camera_height() * TERRAIN_LOD_FRAME_FACTOR
	_apply_terrain_lod()
	_last_detail_camera_height = -1.0
	update_ecology_detail()
	_update_ecology_visibility()
	_update_terrain_material()
	last_build_ms = Time.get_ticks_msec() - build_started
	if loading_overlay != null:
		loading_overlay.finish()
	if not Engine.is_editor_hint():
		get_window().title = "Godot Test - 3D Hex World"
	print(
		"3D hex world: %s seed %d, %dx%d tiles, %d land, %d chunks, %d ms logic, %d ms build"
		% [
			world_data.profile_id,
			world_data.seed,
			world_data.width,
			world_data.height,
			world_data.land_tile_count(),
			terrain_chunks.get_child_count(),
			last_generation_ms,
			last_build_ms,
		]
	)
	chunks_rebuilt.emit(chunks.size(), "full")
	world_regenerated.emit(world_data)


func _rebuild_chunk(chunk: Vector2i, resolved_settings: WorldGenerationSettings) -> void:
	var palette := (
		Mesher.PALETTE_HIGH_CONTRAST if high_contrast_palette else Mesher.PALETTE_STANDARD
	)
	var near_surface := Mesher.build_chunk_surface(
		world_data,
		resolved_settings,
		chunk,
		terrain_view,
		Mesher.DETAIL_FULL,
		palette,
		_tile_normal_cache,
		true
	)
	var far_surface := Mesher.build_chunk_surface(
		world_data,
		resolved_settings,
		chunk,
		terrain_view,
		Mesher.DETAIL_REDUCED,
		palette,
		_tile_normal_cache,
		true
	)
	var record: Dictionary = _chunk_records.get(chunk, {})
	var near_instance := record.get("near") as MeshInstance3D
	if near_instance == null:
		near_instance = MeshInstance3D.new()
		near_instance.name = "Chunk_%s" % ChunkIndex.chunk_name(chunk)
		near_instance.set_meta("chunk", chunk)
		terrain_chunks.add_child(near_instance)
	near_instance.mesh = near_surface.build_mesh()
	near_instance.material_override = _ensure_terrain_material()
	var far_instance := record.get("far") as MeshInstance3D
	if far_instance == null:
		far_instance = MeshInstance3D.new()
		far_instance.name = "ChunkFar_%s" % ChunkIndex.chunk_name(chunk)
		far_instance.set_meta("chunk", chunk)
		terrain_chunks_far.add_child(far_instance)
	far_instance.mesh = far_surface.build_mesh()
	far_instance.material_override = _ensure_terrain_material()

	var entry := Picker.entry_from_surface(near_surface, world_data, true)
	if entry.is_empty():
		_pick_index.erase(chunk)
	else:
		_pick_index[chunk] = entry
	var body := record.get("body") as StaticBody3D
	if enable_collision and not entry.is_empty():
		if body == null:
			body = StaticBody3D.new()
			body.name = "Collider_%s" % ChunkIndex.chunk_name(chunk)
			body.set_meta("chunk", chunk)
			var shape_node := CollisionShape3D.new()
			shape_node.name = "Shape"
			body.add_child(shape_node)
			terrain_colliders.add_child(body)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(entry["faces"])
		(body.get_node("Shape") as CollisionShape3D).shape = shape
	elif body != null:
		terrain_colliders.remove_child(body)
		body.queue_free()
		body = null

	var hydrology_instance := record.get("hydrology") as MeshInstance3D
	if hydrology_instance == null:
		hydrology_instance = MeshInstance3D.new()
		hydrology_instance.name = "Hydrology_%s" % ChunkIndex.chunk_name(chunk)
		hydrology_instance.set_meta("chunk", chunk)
		hydrology_chunks.add_child(hydrology_instance)
	hydrology_instance.mesh = (
		HydrologyMesher.build_river_diagnostic_chunk(world_data, resolved_settings, chunk)
		if terrain_view == "river_edges"
		else HydrologyMesher.build_chunk(world_data, resolved_settings, chunk)
	)

	for existing in record.get("ecology", []):
		var old_instance := existing as MultiMeshInstance3D
		if old_instance != null and is_instance_valid(old_instance):
			ecology_chunks.remove_child(old_instance)
			old_instance.queue_free()
	for existing in record.get("underwater", []):
		var old_instance := existing as MultiMeshInstance3D
		if old_instance != null and is_instance_valid(old_instance):
			underwater_ecology_chunks.remove_child(old_instance)
			old_instance.queue_free()
	var ecology_instances: Array = []
	var ecology_palette := (
		EcologyRenderer.PALETTE_HIGH_CONTRAST
		if high_contrast_palette
		else EcologyRenderer.PALETTE_STANDARD
	)
	for feature_class in EcologyRenderer.feature_class_ids():
		var multimesh := EcologyRenderer.build_chunk_multimesh(
			world_data,
			resolved_settings,
			chunk,
			feature_class,
			ecology_palette
		)
		if multimesh == null:
			continue
		var instance := MultiMeshInstance3D.new()
		instance.name = "Ecology_%s_%s" % [ChunkIndex.chunk_name(chunk), feature_class]
		instance.multimesh = multimesh
		instance.set_meta("feature_class", feature_class)
		instance.set_meta("chunk", chunk)
		ecology_chunks.add_child(instance)
		ecology_instances.append(instance)
	var underwater_instances: Array = []
	var underwater_multimesh := UnderwaterEcologyRenderer.build_chunk_multimesh(
		world_data,
		resolved_settings,
		chunk
	)
	if underwater_multimesh != null:
		var underwater_instance := MultiMeshInstance3D.new()
		underwater_instance.name = "UnderwaterEcology_%s" % ChunkIndex.chunk_name(chunk)
		underwater_instance.multimesh = underwater_multimesh
		underwater_instance.set_meta("chunk", chunk)
		underwater_ecology_chunks.add_child(underwater_instance)
		underwater_instances.append(underwater_instance)

	_chunk_records[chunk] = {
		"near": near_instance,
		"far": far_instance,
		"body": body,
		"hydrology": hydrology_instance,
		"ecology": ecology_instances,
		"underwater": underwater_instances,
		"near_triangles": near_surface.triangle_count(),
		"far_triangles": far_surface.triangle_count(),
	}


func _rebuild_terrain() -> void:
	if world_data == null:
		return
	var resolved_settings := _resolve_settings()
	for chunk in ChunkIndex.all_chunks(world_data, resolved_settings.chunk_size):
		_rebuild_chunk(chunk, resolved_settings)
	_apply_ecology_detail_factor()
	_apply_terrain_lod()


func _rebuild_hydrology() -> void:
	if world_data == null:
		return
	var resolved_settings := _resolve_settings()
	for key in _chunk_records:
		var record: Dictionary = _chunk_records[key]
		var instance := record.get("hydrology") as MeshInstance3D
		if instance == null:
			continue
		instance.mesh = (
			HydrologyMesher.build_river_diagnostic_chunk(
				world_data,
				resolved_settings,
				key as Vector2i
			)
			if terrain_view == "river_edges"
			else HydrologyMesher.build_chunk(world_data, resolved_settings, key as Vector2i)
		)


func _rebuild_ecology() -> void:
	_rebuild_terrain()
	_update_ecology_visibility()


func _ensure_terrain_material() -> ShaderMaterial:
	if _terrain_material == null:
		_terrain_material = TerrainMaterial.create()
	return _terrain_material


## Builds and binds the current `world_data`'s continuous biome-floor blend
## field to the shared terrain material (see `TerrainMaterial.bind_biome_field`
## / `HexTerrainBiomeField`). Explicit failure, matching the repo's
## `{"ok", "error", ...}` convention: a world with no land tile (or no valid
## grid) cannot seed a field, and that failure is surfaced loudly rather than
## silently binding a stale or placeholder texture.
func _bind_terrain_material_biome_field() -> void:
	_biome_field_info = {}
	if world_data == null:
		return
	var material := _ensure_terrain_material()
	var result := TerrainMaterial.bind_biome_field(material, world_data)
	_biome_field_info = result
	if not bool(result.get("ok", false)):
		push_error(
			"3D hex world: could not build the biome-floor blend field (%s)."
			% String(result.get("error", ""))
		)


func _update_terrain_material() -> void:
	var material := _ensure_terrain_material()
	TerrainMaterial.configure(
		material,
		terrain_view,
		strategy_camera.camera_height() if strategy_camera != null else 70.0,
		high_contrast_palette,
		1.0,
		world_data.seed if world_data != null else 0
	)


## Mesh LOD and occlusion strategy. Each chunk keeps a full-detail and a
## reduced-detail mesh, switched by distance; frustum culling then removes the
## chunks that are off screen entirely, which is the dominant win in a tilted
## top-down strategy view.
func _apply_terrain_lod() -> void:
	if terrain_chunks == null or terrain_chunks_far == null:
		return
	var scrub_distance := _lod_distance / TERRAIN_LOD_FRAME_FACTOR * SCRUB_VISIBILITY_FRAME_FACTOR
	for key in _chunk_records:
		var record: Dictionary = _chunk_records[key]
		var near_instance := record.get("near") as MeshInstance3D
		var far_instance := record.get("far") as MeshInstance3D
		if near_instance == null or far_instance == null:
			continue
		if enable_terrain_lod and _lod_distance > 0.0:
			near_instance.visibility_range_end = _lod_distance
			near_instance.visibility_range_begin = 0.0
			far_instance.visibility_range_begin = _lod_distance
			far_instance.visibility_range_end = 0.0
			far_instance.visible = true
		else:
			near_instance.visibility_range_end = 0.0
			far_instance.visible = false
	for child in ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null:
			continue
		var feature_class := StringName(instance.get_meta("feature_class", &""))
		instance.visibility_range_end = (
			scrub_distance
			if enable_terrain_lod and feature_class == EcologyStage.VEGETATION_CLASS_SCRUB
			else 0.0
		)
	for child in underwater_ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance != null:
			# Beds are already sparse and density-thinned. Keep them visible in
			# the framed strategy view instead of culling the entire underwater
			# layer before its silhouettes can read through the water.
			instance.visibility_range_end = 0.0


func _apply_ecology_detail_factor() -> void:
	if ecology_chunks == null:
		return
	for child in ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		instance.multimesh.visible_instance_count = EcologyRenderer.visible_instance_count(
			instance.multimesh.instance_count,
			StringName(instance.get_meta("feature_class", &"")),
			ecology_detail_factor,
			int(instance.multimesh.get_meta("minimum_visible_instance_count", 1))
		)
	for child in underwater_ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		instance.multimesh.visible_instance_count = (
			UnderwaterEcologyRenderer.visible_instance_count(
				instance.multimesh.instance_count,
				maxf(ecology_detail_factor, 0.50),
				int(
					instance.multimesh.get_meta(
						"minimum_visible_instance_count",
						1
					)
				)
			)
		)


func _update_ecology_visibility() -> void:
	if ecology_chunks == null:
		return
	var vegetation_visible := terrain_view in VEGETATION_VISIBLE_VIEWS
	var resources_visible := terrain_view in RESOURCE_VISIBLE_VIEWS
	for child in ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null:
			continue
		var is_resource := (
			StringName(instance.get_meta("feature_class", &""))
			== EcologyRenderer.RESOURCE_CLASS
		)
		instance.visible = resources_visible if is_resource else vegetation_visible
	for child in underwater_ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance != null:
			instance.visible = vegetation_visible


func deterministic_underwater_tile() -> HexTileData:
	return UnderwaterEcologyRenderer.select_deterministic_subject(
		world_data,
		_resolve_settings()
	)


func _update_debug_visibility() -> void:
	if hex_debug != null:
		if show_hex_boundaries and hex_debug.mesh == null and world_data != null:
			hex_debug.mesh = Mesher.build_boundary_mesh(
				world_data,
				_resolve_settings(),
				false
			)
		hex_debug.visible = show_hex_boundaries
	if chunk_debug != null:
		if show_chunk_boundaries and chunk_debug.mesh == null and world_data != null:
			chunk_debug.mesh = Mesher.build_boundary_mesh(
				world_data,
				_resolve_settings(),
				true
			)
		chunk_debug.visible = show_chunk_boundaries


func _on_camera_tapped(screen_position: Vector2) -> void:
	if world_data == null:
		return
	select_tile(pick_tile_at(screen_position))


func _report_progress(stage: String, progress: float) -> void:
	if loading_overlay != null and loading_overlay.visible:
		loading_overlay.report(stage, progress)
	generation_progress.emit(stage, progress)


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


static func parse_arguments(arguments: PackedStringArray) -> Dictionary:
	var seed := 0
	var size := "large"
	var style := "varied"
	var benchmark := false
	var device_benchmark := false
	for argument in arguments:
		if argument == "--hex-benchmark":
			benchmark = true
		elif argument == "--hex-device-benchmark":
			device_benchmark = true
		elif argument.begins_with("--hex-seed="):
			var value := argument.trim_prefix("--hex-seed=")
			if not value.is_valid_int():
				return {"ok": false, "error": "--hex-seed requires an integer."}
			seed = value.to_int()
		elif argument.begins_with("--hex-size="):
			size = argument.trim_prefix("--hex-size=").to_lower()
			if not GameContent.is_valid_map_size_profile(size):
				return {"ok": false, "error": "Invalid hex-world size '%s'." % size}
		elif argument.begins_with("--hex-style="):
			style = argument.trim_prefix("--hex-style=").to_lower()
			if not WorldGenerationSettings.is_valid_landform_style(style):
				return {"ok": false, "error": "Invalid hex-world style '%s'." % style}
		else:
			return {"ok": false, "error": "Unknown 3D hex-world argument: %s" % argument}
	return {
		"ok": true,
		"seed": seed,
		"size": size,
		"style": style,
		"benchmark": benchmark,
		"device_benchmark": device_benchmark,
	}


## Unattended capture used by the headless desktop reference run and by the
## packaged benchmark build launched from a host. A handset capture normally
## goes through the Lab button instead, because the operator pressing it is what
## declares the thermal precondition.
func _start_unattended_device_benchmark() -> void:
	var result: Dictionary = await run_device_benchmark()
	if not bool(result["ok"]):
		push_error(String(result["error"]))
	# An unattended invocation owns the process. Two frames let the fenced
	# console output flush before the application exits.
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0 if bool(result["ok"]) else 1)
