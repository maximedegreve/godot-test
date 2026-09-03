extends SceneTree

const Content = preload("res://src/data/game_content.gd")
const Settings = preload("res://src/world3d/resources/world_generation_settings.gd")
const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")
const Generator = preload("res://src/world3d/generator/hex_world_generator.gd")
const Mesher = preload("res://src/world3d/rendering/hex_terrain_mesher.gd")
const EcologyRenderer = preload("res://src/world3d/rendering/hex_ecology_renderer.gd")
const UnderwaterEcologyRenderer = preload(
	"res://src/world3d/rendering/hex_underwater_ecology_renderer.gd"
)
const Serializer = preload("res://src/world3d/data/hex_world_serializer.gd")
const ChunkIndexScript = preload("res://src/world3d/hex/hex_chunk_index.gd")
const EcologyStageScript = preload("res://src/world3d/generator/ecology_stage.gd")
const BiomeFieldScript = preload("res://src/world3d/rendering/hex_terrain_biome_field.gd")
const RUNTIME_SCENE = preload("res://scenes/hex_world_development.tscn")

const DEFAULT_SEEDS := [10, 1, 5, 6, 46]
const IMAGE_SIZE := Vector2i(1152, 648)
const CONTACT_COLUMNS := 2
const RUNTIME_VIEW_IDS := [
	"terrain",
	"elevation",
	"temperature",
	"moisture",
	"biome",
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
	"lod",
	"accessibility",
	"closeup",
	"underwater_closeup",
	"transition_closeup",
]
## Frames measured per world for the Ultra frame-time budget.
const FRAME_BUDGET_SAMPLES := 30


static func runtime_view_ids() -> Array[String]:
	var result: Array[String] = []
	result.assign(RUNTIME_VIEW_IDS)
	return result


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := parse_arguments(OS.get_cmdline_user_args())
	if not bool(options["ok"]):
		push_error(String(options["error"]))
		quit(2)
		return
	if bool(options["counts_only"]):
		var counts := {}
		for profile_value in options["sizes"]:
			var profile_id: String = profile_value
			for style_value in options["styles"]:
				var style_id: String = style_value
				var minimum_land_ratio := INF
				var maximum_land_ratio := -INF
				var minimum_major_components := 999999
				var maximum_major_components := 0
				var worlds_without_mountains := 0
				var signatures: Dictionary = {}
				var climate_signatures: Dictionary = {}
				var hydrology_signatures: Dictionary = {}
				var ecology_signatures: Dictionary = {}
				var biome_presence: Dictionary = {}
				var resource_presence: Dictionary = {}
				var minimum_rivers := 999999
				var maximum_rivers := 0
				var minimum_lakes := 999999
				var maximum_lakes := 0
				var metric_ranges := {}
				for seed_value in options["seeds"]:
					var world := _generate_world(int(seed_value), profile_id, style_id)
					var metadata := _metadata(world)
					minimum_land_ratio = minf(minimum_land_ratio, float(metadata["land_ratio"]))
					maximum_land_ratio = maxf(maximum_land_ratio, float(metadata["land_ratio"]))
					minimum_major_components = mini(
						minimum_major_components,
						int(metadata["major_land_component_count"])
					)
					maximum_major_components = maxi(
						maximum_major_components,
						int(metadata["major_land_component_count"])
					)
					var histogram: Dictionary = metadata["elevation_histogram"]
					if int(histogram.get(4, 0)) == 0:
						worlds_without_mountains += 1
					signatures[metadata["deterministic_signature"]] = true
					climate_signatures[metadata["climate_signature"]] = true
					hydrology_signatures[metadata["hydrology_signature"]] = true
					ecology_signatures[metadata["ecology_signature"]] = true
					for resource_id in (metadata["resource_histogram"] as Dictionary):
						resource_presence[resource_id] = true
					minimum_rivers = mini(minimum_rivers, int(metadata["river_count"]))
					maximum_rivers = maxi(maximum_rivers, int(metadata["river_count"]))
					minimum_lakes = mini(minimum_lakes, int(metadata["lake_count"]))
					maximum_lakes = maxi(maximum_lakes, int(metadata["lake_count"]))
					for metric in [
						"source_elevated_qualification_count",
						"source_mountain_qualification_count",
						"source_highland_qualification_count",
						"source_wet_interior_qualification_count",
						"source_unqualified_count",
						"mean_source_elevation_level",
						"mean_source_ocean_moisture",
						"close_headwater_violation_count",
						"parallel_river_violation_count",
						"sharp_river_turn_count",
						"river_confluence_count",
						"river_system_count",
						"downstream_uphill_violation_count",
						"mean_lowland_river_lateral_deviation",
						"maximum_lowland_river_lateral_deviation",
						"mean_highland_river_lateral_deviation",
						"straight_flatland_reach_count",
						"lowland_river_reach_count",
						"highland_river_reach_count",
						"straight_flatland_deviation_threshold",
						"flatland_reroute_eligible_count",
						"flatland_reroute_total_count",
						"flatland_reroute_selected_edge_count",
						"flatland_straight_river_run_count",
						"flatland_max_straight_river_run_length",
						"flatland_gentle_bend_count",
						"flatland_zigzag_reversal_count",
						"resource_placed_count",
						"resource_target_count",
						"resource_types_present",
						"vegetated_tile_count",
						"forested_tile_count",
						"mean_land_vegetation_density",
						"excluded_tile_count",
						"settlement_reservation_count",
						"minimum_resource_spacing_observed",
						"minimum_same_resource_spacing_observed",
						"resource_rule_violation_count",
						"resource_spacing_violation_count",
						"feature_exclusion_violation_count",
						"ecology_instance_count",
						"ecology_multimesh_node_count",
					]:
						var value := float(metadata[metric])
						if not metric_ranges.has(metric):
							metric_ranges[metric] = {"minimum": value, "maximum": value}
						else:
							metric_ranges[metric]["minimum"] = minf(
								float(metric_ranges[metric]["minimum"]),
								value
							)
							metric_ranges[metric]["maximum"] = maxf(
								float(metric_ranges[metric]["maximum"]),
								value
							)
					for biome in (metadata["biome_histogram"] as Dictionary):
						biome_presence[biome] = true
				counts["%s/%s" % [profile_id, style_id]] = {
					"seeds_scanned": options["seeds"].size(),
					"minimum_land_ratio": minimum_land_ratio,
					"maximum_land_ratio": maximum_land_ratio,
					"minimum_major_land_components": minimum_major_components,
					"maximum_major_land_components": maximum_major_components,
					"worlds_without_mountains": worlds_without_mountains,
					"unique_signatures": signatures.size(),
					"unique_climate_signatures": climate_signatures.size(),
					"unique_hydrology_signatures": hydrology_signatures.size(),
					"unique_ecology_signatures": ecology_signatures.size(),
					"minimum_river_count": minimum_rivers,
					"maximum_river_count": maximum_rivers,
					"minimum_lake_count": minimum_lakes,
					"maximum_lake_count": maximum_lakes,
					"hydrology_metric_ranges": metric_ranges,
					"ecology_metric_ranges": _selected_metric_ranges(
						metric_ranges,
						[
							"resource_placed_count",
							"resource_target_count",
							"resource_types_present",
							"vegetated_tile_count",
							"forested_tile_count",
							"mean_land_vegetation_density",
							"excluded_tile_count",
							"settlement_reservation_count",
							"minimum_resource_spacing_observed",
							"minimum_same_resource_spacing_observed",
							"resource_rule_violation_count",
							"resource_spacing_violation_count",
							"feature_exclusion_violation_count",
							"ecology_instance_count",
							"ecology_multimesh_node_count",
						]
					),
					"biomes_present": biome_presence.keys(),
					"resources_present": resource_presence.keys(),
				}
		print(JSON.stringify(counts, "\t"))
		quit()
		return

	var output_directory := _resolve_output_directory(String(options["output"]))
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		push_error("Could not create 3D hex preview directory %s." % output_directory)
		quit(2)
		return
	var terrain_images: Array[Image] = []
	var elevation_images: Array[Image] = []
	var temperature_images: Array[Image] = []
	var moisture_images: Array[Image] = []
	var biome_images: Array[Image] = []
	var flow_direction_images: Array[Image] = []
	var watershed_images: Array[Image] = []
	var accumulation_images: Array[Image] = []
	var lake_images: Array[Image] = []
	var river_edge_images: Array[Image] = []
	var ecology_images: Array[Image] = []
	var resource_images: Array[Image] = []
	var density_images: Array[Image] = []
	var exclusion_images: Array[Image] = []
	var material_response_images: Array[Image] = []
	var lod_images: Array[Image] = []
	var accessibility_images: Array[Image] = []
	var closeup_images: Array[Image] = []
	var underwater_closeup_images: Array[Image] = []
	var transition_closeup_images: Array[Image] = []
	var topology_images: Array[Image] = []
	var manifest_entries: Array[Dictionary] = []
	var write_errors: Array[String] = []
	for profile_value in options["sizes"]:
		var profile_id: String = profile_value
		for style_value in options["styles"]:
			var style_id: String = style_value
			for seed_value in options["seeds"]:
				var seed: int = seed_value
				var started := Time.get_ticks_msec()
				var stem := "%s_%s_seed_%d" % [profile_id, style_id, seed]
				var world: HexWorldData
				var generation_ms := 0
				var runtime_metrics: Dictionary = {}
				if bool(options["topology_only"]):
					world = _generate_world(seed, profile_id, style_id)
					generation_ms = Time.get_ticks_msec() - started
					var topology := _render_topology_mesh(world)
					_record_png_result(
						topology,
						output_directory.path_join("%s_topology.png" % stem),
						write_errors
					)
					topology_images.append(topology)
				else:
					var capture: Dictionary = await _capture_runtime_world(
						seed,
						profile_id,
						style_id
					)
					if not bool(capture.get("ok", false)):
						write_errors.append(
							"Could not capture %s %s seed %d from the runtime scene."
							% [profile_id, style_id, seed]
						)
						continue
					world = capture["world"]
					generation_ms = int(capture["generation_ms"])
					runtime_metrics = capture["runtime_metrics"]
					var terrain: Image = capture["terrain"]
					var elevation: Image = capture["elevation"]
					var temperature: Image = capture["temperature"]
					var moisture: Image = capture["moisture"]
					var biome: Image = capture["biome"]
					var flow_direction: Image = capture["flow_direction"]
					var watershed: Image = capture["watershed"]
					var accumulation: Image = capture["accumulation"]
					var lakes: Image = capture["lakes"]
					var river_edges: Image = capture["river_edges"]
					var ecology: Image = capture["ecology"]
					var resources: Image = capture["resources"]
					var density: Image = capture["density"]
					var exclusion: Image = capture["exclusion"]
					var material_response: Image = capture["material_response"]
					_record_png_result(
						terrain,
						output_directory.path_join("%s_terrain.png" % stem),
						write_errors
					)
					_record_png_result(
						elevation,
						output_directory.path_join("%s_elevation.png" % stem),
						write_errors
					)
					_record_png_result(
						temperature,
						output_directory.path_join("%s_temperature.png" % stem),
						write_errors
					)
					_record_png_result(
						moisture,
						output_directory.path_join("%s_moisture.png" % stem),
						write_errors
					)
					_record_png_result(
						biome,
						output_directory.path_join("%s_biome.png" % stem),
						write_errors
					)
					_record_png_result(
						flow_direction,
						output_directory.path_join("%s_flow_direction.png" % stem),
						write_errors
					)
					_record_png_result(
						watershed,
						output_directory.path_join("%s_watershed.png" % stem),
						write_errors
					)
					_record_png_result(
						accumulation,
						output_directory.path_join("%s_accumulation.png" % stem),
						write_errors
					)
					_record_png_result(
						lakes,
						output_directory.path_join("%s_lakes.png" % stem),
						write_errors
					)
					_record_png_result(
						river_edges,
						output_directory.path_join("%s_river_edges.png" % stem),
						write_errors
					)
					_record_png_result(
						ecology,
						output_directory.path_join("%s_ecology.png" % stem),
						write_errors
					)
					_record_png_result(
						resources,
						output_directory.path_join("%s_resources.png" % stem),
						write_errors
					)
					_record_png_result(
						density,
						output_directory.path_join("%s_density.png" % stem),
						write_errors
					)
					_record_png_result(
						exclusion,
						output_directory.path_join("%s_exclusion.png" % stem),
						write_errors
					)
					_record_png_result(
						material_response,
						output_directory.path_join("%s_material_response.png" % stem),
						write_errors
					)
					_record_png_result(
						capture["lod"],
						output_directory.path_join("%s_lod.png" % stem),
						write_errors
					)
					_record_png_result(
						capture["accessibility"],
						output_directory.path_join("%s_accessibility.png" % stem),
						write_errors
					)
					_record_png_result(
						capture["closeup"],
						output_directory.path_join("%s_closeup.png" % stem),
						write_errors
					)
					_record_png_result(
						capture["underwater_closeup"],
						output_directory.path_join("%s_underwater_closeup.png" % stem),
						write_errors
					)
					_record_png_result(
						capture["transition_closeup"],
						output_directory.path_join("%s_transition_closeup.png" % stem),
						write_errors
					)
					terrain_images.append(terrain)
					elevation_images.append(elevation)
					temperature_images.append(temperature)
					moisture_images.append(moisture)
					biome_images.append(biome)
					flow_direction_images.append(flow_direction)
					watershed_images.append(watershed)
					accumulation_images.append(accumulation)
					lake_images.append(lakes)
					river_edge_images.append(river_edges)
					ecology_images.append(ecology)
					resource_images.append(resources)
					density_images.append(density)
					exclusion_images.append(exclusion)
					material_response_images.append(material_response)
					lod_images.append(capture["lod"])
					accessibility_images.append(capture["accessibility"])
					closeup_images.append(capture["closeup"])
					underwater_closeup_images.append(capture["underwater_closeup"])
					transition_closeup_images.append(capture["transition_closeup"])
				var capture_ms := Time.get_ticks_msec() - started
				var entry := _metadata(world)
				entry["generation_ms"] = generation_ms
				for runtime_key in runtime_metrics:
					entry[runtime_key] = runtime_metrics[runtime_key]
				entry["capture_ms"] = capture_ms
				if bool(options["topology_only"]):
					entry["topology_file"] = "%s_topology.png" % stem
				else:
					entry["terrain_file"] = "%s_terrain.png" % stem
					entry["elevation_file"] = "%s_elevation.png" % stem
					entry["temperature_file"] = "%s_temperature.png" % stem
					entry["moisture_file"] = "%s_moisture.png" % stem
					entry["biome_file"] = "%s_biome.png" % stem
					entry["flow_direction_file"] = "%s_flow_direction.png" % stem
					entry["watershed_file"] = "%s_watershed.png" % stem
					entry["accumulation_file"] = "%s_accumulation.png" % stem
					entry["lakes_file"] = "%s_lakes.png" % stem
					entry["river_edges_file"] = "%s_river_edges.png" % stem
					entry["ecology_file"] = "%s_ecology.png" % stem
					entry["resources_file"] = "%s_resources.png" % stem
					entry["density_file"] = "%s_density.png" % stem
					entry["exclusion_file"] = "%s_exclusion.png" % stem
					entry["material_response_file"] = "%s_material_response.png" % stem
					entry["lod_file"] = "%s_lod.png" % stem
					entry["accessibility_file"] = "%s_accessibility.png" % stem
					entry["closeup_file"] = "%s_closeup.png" % stem
					entry["underwater_closeup_file"] = "%s_underwater_closeup.png" % stem
					entry["transition_closeup_file"] = "%s_transition_closeup.png" % stem
				manifest_entries.append(entry)
				_record_json_result(
					entry,
					output_directory.path_join("%s.json" % stem),
					write_errors
				)
				print(
					"Captured %s 3D hex %s %s seed %d: %d tiles, %.1f%% land, %d ms"
					% [
						"CPU topology diagnostic" if bool(options["topology_only"]) else "runtime",
						profile_id,
						String(world.metadata["resolved_landform_style"]),
						seed,
						world.tiles.size(),
						float(world.land_tile_count()) / float(world.tiles.size()) * 100.0,
						generation_ms,
					]
				)
	if bool(options["topology_only"]):
		_record_png_result(
			_build_contact_sheet(topology_images),
			output_directory.path_join("topology_contact_sheet.png"),
			write_errors
		)
	else:
		_record_png_result(
			_build_contact_sheet(terrain_images),
			output_directory.path_join("terrain_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(elevation_images),
			output_directory.path_join("elevation_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(temperature_images),
			output_directory.path_join("temperature_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(moisture_images),
			output_directory.path_join("moisture_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(biome_images),
			output_directory.path_join("biome_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(flow_direction_images),
			output_directory.path_join("flow_direction_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(watershed_images),
			output_directory.path_join("watershed_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(accumulation_images),
			output_directory.path_join("accumulation_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(lake_images),
			output_directory.path_join("lakes_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(river_edge_images),
			output_directory.path_join("river_edges_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(ecology_images),
			output_directory.path_join("ecology_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(resource_images),
			output_directory.path_join("resources_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(density_images),
			output_directory.path_join("density_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(exclusion_images),
			output_directory.path_join("exclusion_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(material_response_images),
			output_directory.path_join("material_response_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(lod_images),
			output_directory.path_join("lod_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(accessibility_images),
			output_directory.path_join("accessibility_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(closeup_images),
			output_directory.path_join("closeup_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(underwater_closeup_images),
			output_directory.path_join("underwater_closeup_contact_sheet.png"),
			write_errors
		)
		_record_png_result(
			_build_contact_sheet(transition_closeup_images),
			output_directory.path_join("transition_closeup_contact_sheet.png"),
			write_errors
		)
	_record_json_result({
		"generated_at_utc": Time.get_datetime_string_from_system(true),
		"sizes": options["sizes"],
		"styles": options["styles"],
		"seeds": options["seeds"],
		"maps": manifest_entries,
		"preview_kind": (
			"deterministic CPU mesh topology diagnostic (not a runtime visual)"
			if bool(options["topology_only"])
			else "runtime SubViewport Phase 5 textured terrain, interaction, and scale capture"
		),
		"runtime_scene": RUNTIME_SCENE.resource_path,
	}, output_directory.path_join("manifest.json"), write_errors)
	if not write_errors.is_empty():
		for message in write_errors:
			push_error(message)
		push_error(
			"3D hex preview batch failed with %d capture/write error(s); no success was published."
			% write_errors.size()
		)
		quit(2)
		return
	print(
		"%s 3D hex preview batch written to %s"
		% [
			"CPU topology diagnostic" if bool(options["topology_only"]) else "Runtime-rendered",
			output_directory,
		]
	)
	quit()


static func parse_arguments(arguments: PackedStringArray) -> Dictionary:
	var seeds: Array[int] = []
	var sizes: Array[String] = []
	var styles: Array[String] = []
	var output := "builds/hex-world-previews"
	var counts_only := false
	var topology_only := false
	for argument in arguments:
		if argument == "--counts-only":
			counts_only = true
		elif argument == "--topology-only":
			topology_only = true
		elif argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
			if output.is_empty():
				return {"ok": false, "error": "--output requires a directory."}
		elif argument.begins_with("--size="):
			var profile_id := argument.trim_prefix("--size=").to_lower()
			if not Content.is_valid_map_size_profile(profile_id):
				return {"ok": false, "error": "Invalid map size '%s'." % profile_id}
			sizes.append(profile_id)
		elif argument.begins_with("--sizes="):
			for value in argument.trim_prefix("--sizes=").split(",", false):
				var profile_id := value.strip_edges().to_lower()
				if not Content.is_valid_map_size_profile(profile_id):
					return {"ok": false, "error": "Invalid map size '%s'." % profile_id}
				sizes.append(profile_id)
		elif argument.begins_with("--style="):
			var style_id := argument.trim_prefix("--style=").to_lower()
			if not Settings.is_valid_landform_style(style_id):
				return {"ok": false, "error": "Invalid landform style '%s'." % style_id}
			styles.append(style_id)
		elif argument.begins_with("--styles="):
			for value in argument.trim_prefix("--styles=").split(",", false):
				var style_id := value.strip_edges().to_lower()
				if not Settings.is_valid_landform_style(style_id):
					return {"ok": false, "error": "Invalid landform style '%s'." % style_id}
				styles.append(style_id)
		elif argument.begins_with("--seed="):
			var value := argument.trim_prefix("--seed=")
			if not value.is_valid_int():
				return {"ok": false, "error": "Invalid seed '%s'." % value}
			seeds.append(value.to_int())
		elif argument.begins_with("--seeds="):
			for value in argument.trim_prefix("--seeds=").split(",", false):
				var stripped := value.strip_edges()
				if not stripped.is_valid_int():
					return {"ok": false, "error": "Invalid seed '%s'." % stripped}
				seeds.append(stripped.to_int())
		elif argument.begins_with("--range="):
			var bounds := argument.trim_prefix("--range=").split(":", false)
			if (
				bounds.size() != 2
				or not bounds[0].is_valid_int()
				or not bounds[1].is_valid_int()
			):
				return {"ok": false, "error": "--range must use integer START:END."}
			var start := bounds[0].to_int()
			var finish := bounds[1].to_int()
			if finish < start or finish - start > 999:
				return {"ok": false, "error": "--range must be ascending and contain at most 1,000 seeds."}
			for seed in range(start, finish + 1):
				seeds.append(seed)
		else:
			return {"ok": false, "error": "Unknown 3D hex preview argument: %s" % argument}
	if seeds.is_empty():
		seeds.assign(DEFAULT_SEEDS)
	if sizes.is_empty():
		sizes.append(Content.DEFAULT_MAP_SIZE_PROFILE)
	if styles.is_empty():
		styles.append("varied")
	return {
		"ok": true,
		"seeds": _unique_ints(seeds),
		"sizes": _unique_strings(sizes),
		"styles": _unique_strings(styles),
		"output": output,
		"counts_only": counts_only,
		"topology_only": topology_only,
	}


func _capture_runtime_world(seed: int, profile_id: String, style_id: String) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = "HexWorldPreviewViewport"
	viewport.size = IMAGE_SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.transparent_bg = false
	root.add_child(viewport)

	var prototype := instantiate_runtime_world(seed, profile_id, style_id)
	viewport.add_child(prototype)
	prototype.regenerate()
	await process_frame
	await process_frame
	RenderingServer.force_draw(false)
	await process_frame
	var terrain := viewport.get_texture().get_image()
	if terrain != null and not terrain.is_empty():
		terrain.convert(Image.FORMAT_RGBA8)

	prototype.set_terrain_view("elevation")
	prototype.show_hex_boundaries = true
	prototype.show_chunk_boundaries = true
	var elevation := await _capture_viewport_image(viewport)

	prototype.show_hex_boundaries = false
	prototype.show_chunk_boundaries = false
	prototype.set_terrain_view("temperature")
	var temperature := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("moisture")
	var moisture := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("biome")
	prototype.show_hex_boundaries = true
	var biome := await _capture_viewport_image(viewport)

	prototype.show_hex_boundaries = false
	prototype.set_terrain_view("flow_direction")
	var flow_direction := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("watershed")
	var watershed := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("accumulation")
	var accumulation := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("lakes")
	var lakes := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("river_edges")
	var river_edges := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("ecology")
	var ecology := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("resources")
	var resources := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("density")
	var density := await _capture_viewport_image(viewport)

	prototype.set_terrain_view("exclusion")
	var exclusion := await _capture_viewport_image(viewport)

	# Floor-material response diagnostic: the canonical organic(0)-mineral(1)
	# continuum per biome, flat and independent of decorative texture, normal,
	# roughness, AO, or seed-derived pattern phase (see
	# `HexTerrainMesher._material_response_color`).
	prototype.set_terrain_view("material_response")
	var material_response := await _capture_viewport_image(viewport)

	# Phase 5 reduced-detail terrain, for a direct side-by-side with the full
	# detail terrain capture.
	prototype.set_terrain_view("biome")
	prototype.preview_force_far_detail(true)
	var lod := await _capture_viewport_image(viewport)
	prototype.preview_force_far_detail(false)

	# Phase 5 accessible diagnostic palette on the densest categorical view.
	prototype.high_contrast_palette = true
	prototype.set_terrain_view("exclusion")
	var accessibility := await _capture_viewport_image(viewport)
	prototype.high_contrast_palette = false

	# Phase 5 close-up. The framed capture cannot resolve the textured surface,
	# the beach shelf, or the cliff bench, so a deterministic close view is
	# captured on the most informative coastal cliff tile of each world.
	prototype.set_terrain_view("biome")
	var camera := prototype.get_node("%StrategyCamera") as StrategyCamera3D
	var closeup_tile := _closeup_tile(prototype.world_data)
	if closeup_tile != null:
		camera.focus_on(
			_coast_closeup_position(prototype.world_data, prototype.settings, closeup_tile),
			camera.minimum_height * 1.35,
			false
		)
		prototype.update_ecology_detail()
	var closeup := await _capture_viewport_image(viewport)
	camera.reset_view()
	prototype.update_ecology_detail()

	# Underwater-material close-up: a deterministic ocean tile that actually
	# owns at least one seaweed instance. The subject is selected from the same
	# render-only placement hashes as the runtime MultiMesh, so the capture can
	# never frame an empty patch while seaweed exists elsewhere.
	var underwater_tile := prototype.deterministic_underwater_tile()
	var underwater_closeup: Image
	if underwater_tile != null:
		camera.focus_on(
			underwater_tile.position,
			camera.minimum_height * 1.12,
			false
		)
		prototype.update_ecology_detail()
		underwater_closeup = await _capture_viewport_image(viewport)
		camera.reset_view()
		prototype.update_ecology_detail()
	else:
		underwater_closeup = biome

	# Biome-transition close-up: a deterministic close view over the
	# highest-scoring shared boundary between two different implemented land
	# biomes (see `HexWorldPrototype.select_deterministic_transition_subject`).
	# Distinct subject from `closeup` above, which is always the coastal
	# cliff join; this exercises an inland (or incidental) biome seam instead
	# and never depends on shoreline or cliff exclusion flags.
	var transition_subject := _transition_subject(prototype.world_data)
	var transition_closeup: Image
	if not transition_subject.is_empty():
		camera.focus_on(
			transition_subject["subject_position"],
			camera.minimum_height * 1.7,
			false
		)
		prototype.update_ecology_detail()
		transition_closeup = await _capture_viewport_image(viewport)
		camera.reset_view()
		prototype.update_ecology_detail()
	else:
		# No two implemented land biomes touch in this world (possible only
		# on a tiny or degenerate single-biome map); fall back to the framed
		# biome capture so the contact sheet and manifest stay well-formed
		# rather than omitting an entry.
		transition_closeup = biome

	# The frame budget is measured on the default terrain view, which is the
	# heaviest configuration: terrain, ocean, batched hydrology, and every
	# visible batched ecology and resource instance.
	prototype.set_terrain_view("biome")
	var frame_metrics := await _measure_frame_budget(viewport, prototype)

	var images: Array[Image] = [
		terrain,
		elevation,
		temperature,
		moisture,
		biome,
		flow_direction,
		watershed,
		accumulation,
		lakes,
		river_edges,
		ecology,
		resources,
		density,
		exclusion,
		material_response,
		lod,
		accessibility,
		closeup,
		underwater_closeup,
		transition_closeup,
	]
	for image in images:
		if image == null or image.is_empty():
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			root.remove_child(viewport)
			viewport.queue_free()
			return {"ok": false}
	var world: HexWorldData = prototype.world_data
	var runtime_metrics := _runtime_ecology_metrics(prototype)
	for frame_key in frame_metrics:
		runtime_metrics[frame_key] = frame_metrics[frame_key]
	var phase_five_metrics := _runtime_phase_five_metrics(prototype)
	for phase_five_key in phase_five_metrics:
		runtime_metrics[phase_five_key] = phase_five_metrics[phase_five_key]
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.remove_child(viewport)
	viewport.queue_free()
	return {
		"ok": true,
		"world": world,
		"terrain": terrain,
		"elevation": elevation,
		"temperature": temperature,
		"moisture": moisture,
		"biome": biome,
		"flow_direction": flow_direction,
		"watershed": watershed,
		"accumulation": accumulation,
		"lakes": lakes,
		"river_edges": river_edges,
		"ecology": ecology,
		"resources": resources,
		"density": density,
		"exclusion": exclusion,
		"material_response": material_response,
		"lod": lod,
		"accessibility": accessibility,
		"closeup": closeup,
		"underwater_closeup": underwater_closeup,
		"transition_closeup": transition_closeup,
		"diagnostic": elevation,
		"generation_ms": prototype.last_generation_ms,
		"runtime_metrics": runtime_metrics,
	}


## Measures the actual runtime frame cost of the prototype scene in the
## offscreen viewport. Vertical sync is disabled during measurement so the
## samples report real work rather than presentation pacing. Values include
## SubViewport draw submission, so they are a prototype budget on this
## machine rather than a device benchmark.
func _measure_frame_budget(
	viewport: SubViewport,
	prototype: HexWorldPrototype
) -> Dictionary:
	var headless := DisplayServer.get_name() == "headless"
	var previous_vsync := DisplayServer.VSYNC_ENABLED
	if not headless:
		previous_vsync = DisplayServer.window_get_vsync_mode()
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var runtime_detail := await _sample_frame_times(viewport)
	var ecology_chunks := prototype.get_node("%EcologyChunks") as Node3D
	var runtime_detail_factor := prototype.ecology_detail_factor
	prototype.ecology_detail_factor = 1.0
	prototype._apply_ecology_detail_factor()
	var full_detail := await _sample_frame_times(viewport)
	prototype.ecology_detail_factor = runtime_detail_factor
	prototype._apply_ecology_detail_factor()
	ecology_chunks.visible = false
	var without_ecology := await _sample_frame_times(viewport)
	ecology_chunks.visible = true
	if not headless:
		DisplayServer.window_set_vsync_mode(previous_vsync)
	return {
		"frame_samples": FRAME_BUDGET_SAMPLES,
		"frame_vsync_disabled": not headless,
		"mean_frame_ms": runtime_detail["mean_ms"],
		"maximum_frame_ms": runtime_detail["maximum_ms"],
		"frame_draw_calls": runtime_detail["draw_calls"],
		"frame_primitives": runtime_detail["primitives"],
		"frame_objects": runtime_detail["objects"],
		"mean_frame_ms_full_ecology_detail": full_detail["mean_ms"],
		"maximum_frame_ms_full_ecology_detail": full_detail["maximum_ms"],
		"frame_primitives_full_ecology_detail": full_detail["primitives"],
		"mean_frame_ms_without_ecology": without_ecology["mean_ms"],
		"frame_primitives_without_ecology": without_ecology["primitives"],
		"viewport_size": [viewport.size.x, viewport.size.y],
	}


## Samples the cost of drawing the world itself. The main loop is paced by
## the host display, so only the forced draw is timed; the surrounding
## `process_frame` wait is deliberately excluded.
func _sample_frame_times(viewport: SubViewport) -> Dictionary:
	await process_frame
	RenderingServer.force_draw(false)
	var total_usec := 0
	var maximum_usec := 0
	for _sample in range(FRAME_BUDGET_SAMPLES):
		await process_frame
		var started := Time.get_ticks_usec()
		RenderingServer.force_draw(false)
		var elapsed := Time.get_ticks_usec() - started
		total_usec += elapsed
		maximum_usec = maxi(maximum_usec, elapsed)
	return {
		"mean_ms": float(total_usec) / float(FRAME_BUDGET_SAMPLES) / 1000.0,
		"maximum_ms": float(maximum_usec) / 1000.0,
		"draw_calls": viewport.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME
		),
		"primitives": viewport.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME
		),
		"objects": viewport.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_OBJECTS_IN_FRAME
		),
	}


func _runtime_ecology_metrics(prototype: HexWorldPrototype) -> Dictionary:
	var ecology_chunks := prototype.get_node("%EcologyChunks") as Node3D
	var node_count := 0
	var instance_total := 0
	var visible_total := 0
	var nested_children := 0
	for child in ecology_chunks.get_children():
		var instance := child as MultiMeshInstance3D
		if instance == null or instance.multimesh == null:
			continue
		node_count += 1
		nested_children += instance.get_child_count()
		instance_total += instance.multimesh.instance_count
		visible_total += instance.multimesh.visible_instance_count
	return {
		"runtime_ecology_multimesh_node_count": node_count,
		"runtime_ecology_instance_count": instance_total,
		"runtime_ecology_visible_instance_count": visible_total,
		"runtime_ecology_child_node_count": nested_children,
		"runtime_ecology_detail_factor": prototype.ecology_detail_factor,
		"runtime_ecology_instance_buffer_bytes": instance_total * 64,
		"runtime_terrain_chunk_node_count": (
			(prototype.get_node("%TerrainChunks") as Node3D).get_child_count()
		),
		"runtime_camera_height": (
			(prototype.get_node("%StrategyCamera") as StrategyCamera3D).camera_height()
		),
	}


## Phase 5 runtime evidence: picking correctness, selective-rebuild scope,
## collision size, explicit budgets, and a save/load signature round-trip, all
## measured on the same live scene the renders come from.
## Deterministic close-up subject: the first land tile, in generation order,
## with the highest combined score for elevation, shoreline contact, and a real
## cliff edge. That is the tile where the Phase 5 terrain treatment is most
## visible, and the choice never depends on iteration order or randomness. The
## rule lives on `HexWorldPrototype` so the capture close-up and the device
## benchmark's close camera state always frame the same tile.
func _closeup_tile(world: HexWorldData) -> HexTileData:
	if world == null:
		return null
	var best: HexTileData = null
	var best_score := -1
	for tile in world.tiles:
		if tile.is_water:
			continue
		var map_edge_margin := mini(
			mini(tile.offset_coordinate.x, world.width - 1 - tile.offset_coordinate.x),
			mini(tile.offset_coordinate.y, world.height - 1 - tile.offset_coordinate.y)
		)
		if map_edge_margin < 3:
			continue
		var ocean_edges := 0
		var touches_map_edge := false
		for neighbor_coordinate in HexCoordinatesScript.neighbors(tile.coordinate):
			var neighbor := world.tile_at(neighbor_coordinate)
			if neighbor == null:
				touches_map_edge = true
			elif neighbor.is_ocean:
				ocean_edges += 1
		if ocean_edges == 0 or touches_map_edge:
			continue
		var score := tile.elevation_level * 2 + ocean_edges
		if tile.exclusion_flags & EcologyStageScript.EXCLUSION_CLIFF != 0:
			score += 4
		if score > best_score:
			best_score = score
			best = tile
	return (
		best
		if best != null
		else HexWorldPrototype.select_deterministic_focus_tile(world)
	)


## Centres the capture on the selected tile's first deterministic water edge,
## rather than on the tile centre, so the continuous land/seabed intersection
## and depth-aware water band occupy the middle of the review image.
func _coast_closeup_position(
	world: HexWorldData,
	settings: WorldGenerationSettings,
	tile: HexTileData
) -> Vector3:
	if world == null or settings == null or tile == null:
		return Vector3.ZERO
	for direction in range(6):
		var neighbor := world.tile_at(
			HexCoordinatesScript.neighbor(tile.coordinate, direction)
		)
		if neighbor != null and neighbor.is_ocean:
			return Mesher.canonical_edge_midpoint(world, tile, direction, settings)
	return tile.position


## Deterministic biome-transition subject for `transition_closeup`, resolved
## purely from logical world data (see
## `HexWorldPrototype.select_deterministic_transition_subject`). Returns an
## empty Dictionary when the world has no two touching implemented land
## biomes.
func _transition_subject(world: HexWorldData) -> Dictionary:
	return HexWorldPrototype.select_deterministic_transition_subject(world)


func _runtime_phase_five_metrics(prototype: HexWorldPrototype) -> Dictionary:
	var report := prototype.runtime_report()
	var audit := prototype.picking_audit()
	var world: HexWorldData = prototype.world_data
	var chunk_size := int(report["chunk_size"])
	var interior_tile: HexTileData = null
	var border_tile: HexTileData = null
	for tile in world.tiles:
		if tile.is_water:
			continue
		var chunk := ChunkIndexScript.chunk_for_axial(tile.coordinate, chunk_size)
		var crosses := false
		var inside := true
		for neighbor_coordinate in HexCoordinatesScript.neighbors(tile.coordinate):
			if not world.has_coordinate(neighbor_coordinate):
				inside = false
				continue
			if ChunkIndexScript.chunk_for_axial(neighbor_coordinate, chunk_size) != chunk:
				crosses = true
		if crosses and border_tile == null:
			border_tile = tile
		elif inside and not crosses and interior_tile == null:
			interior_tile = tile
		if interior_tile != null and border_tile != null:
			break
	var interior_chunks := (
		ChunkIndexScript.dependent_chunks(world, interior_tile.coordinate, chunk_size).size()
		if interior_tile != null
		else 0
	)
	var border_chunks := (
		ChunkIndexScript.dependent_chunks(world, border_tile.coordinate, chunk_size).size()
		if border_tile != null
		else 0
	)
	var payload := Serializer.serialize(world)
	var restored := Serializer.deserialize(payload)
	var restored_world: HexWorldData = restored["world"] if bool(restored["ok"]) else null
	var budget: Dictionary = report["budget"]
	return {
		"phase5_chunk_count": report["chunk_count"],
		"phase5_terrain_triangle_count": report["terrain_triangle_count"],
		"phase5_terrain_far_triangle_count": report["terrain_far_triangle_count"],
		"phase5_terrain_geometry_bytes": report["terrain_geometry_bytes"],
		"phase5_collision_triangle_count": report["collision_triangle_count"],
		"phase5_collision_geometry_bytes": report["collision_geometry_bytes"],
		"phase5_geometry_bytes": report["geometry_bytes"],
		"phase5_build_ms": report["build_ms"],
		"phase5_terrain_lod_enabled": report["terrain_lod_enabled"],
		"phase5_terrain_lod_distance": report["terrain_lod_distance"],
		"phase5_picking_sample_count": audit["sample_count"],
		"phase5_picking_correct_count": audit["correct_count"],
		"phase5_picking_cliff_sample_count": audit["cliff_sample_count"],
		"phase5_picking_chunk_border_sample_count": audit["chunk_border_sample_count"],
		"phase5_picking_failures": audit["failures"],
		"phase5_interior_tile_dependent_chunks": interior_chunks,
		"phase5_chunk_border_tile_dependent_chunks": border_chunks,
		"phase5_serialized_bytes": (payload["tiles"] as PackedByteArray).size(),
		"phase5_schema_version": payload["schema_version"],
		"phase5_save_load_round_trip_ok": bool(restored["ok"]),
		"phase5_save_load_error": String(restored.get("error", "")),
		"phase5_round_trip_deterministic_signature_matches": (
			restored_world != null
			and restored_world.deterministic_signature() == world.deterministic_signature()
		),
		"phase5_round_trip_climate_signature_matches": (
			restored_world != null
			and restored_world.climate_signature() == world.climate_signature()
		),
		"phase5_round_trip_hydrology_signature_matches": (
			restored_world != null
			and restored_world.hydrology_signature() == world.hydrology_signature()
		),
		"phase5_round_trip_ecology_signature_matches": (
			restored_world != null
			and restored_world.ecology_signature() == world.ecology_signature()
		),
		"phase5_within_desktop_budget": budget["within_desktop_budget"],
		"phase5_desktop_budget_breaches": budget["desktop_budget_breaches"],
		"phase5_desktop_budget": budget["desktop_budget"],
		"phase5_target_device_budget": budget["target_device_budget"],
		"phase5_target_device_validated": budget["target_device_validated"],
		"phase5_biome_field_ok": bool(report.get("biome_field_ok", false)),
		"phase5_biome_field_width": int(report.get("biome_field_width", 0)),
		"phase5_biome_field_height": int(report.get("biome_field_height", 0)),
		"phase5_biome_field_bytes": int(report.get("biome_field_bytes", 0)),
	}


func _capture_viewport_image(viewport: SubViewport) -> Image:
	await process_frame
	await process_frame
	RenderingServer.force_draw(false)
	await process_frame
	var image := viewport.get_texture().get_image()
	if image != null and not image.is_empty():
		image.convert(Image.FORMAT_RGBA8)
	return image


static func instantiate_runtime_world(
	seed: int,
	profile_id: String,
	style_id := "varied"
) -> HexWorldPrototype:
	var prototype := RUNTIME_SCENE.instantiate() as HexWorldPrototype
	prototype.generate_on_ready = false
	prototype.parse_command_line_on_ready = false
	prototype.show_test_panel = false
	var settings := Settings.new()
	settings.seed = seed
	settings.apply_map_size_profile(profile_id)
	settings.landform_style = style_id
	prototype.settings = settings
	return prototype


func _generate_world(seed: int, profile_id: String, style_id := "varied") -> HexWorldData:
	var settings := Settings.new()
	settings.seed = seed
	settings.apply_map_size_profile(profile_id)
	settings.landform_style = style_id
	return Generator.generate(settings)


func _render_topology_mesh(world: HexWorldData) -> Image:
	var settings := Settings.new()
	settings.seed = world.seed
	settings.apply_map_size_profile(String(world.profile_id))
	var bounds := _topology_projected_bounds(world)
	var padding := 24.0
	var scale := minf(
		(float(IMAGE_SIZE.x) - padding * 2.0) / maxf(bounds.size.x, 1.0),
		(float(IMAGE_SIZE.y) - padding * 2.0) / maxf(bounds.size.y, 1.0)
	)
	var triangles: Array[Dictionary] = []
	var chunk_columns := ceili(float(world.width) / float(settings.chunk_size))
	var chunk_rows := ceili(float(world.height) / float(settings.chunk_size))
	for chunk_y in range(chunk_rows):
		for chunk_x in range(chunk_columns):
			var mesh := Mesher.build_chunk(
				world,
				settings,
				Vector2i(chunk_x, chunk_y),
				true
			)
			if mesh.get_surface_count() == 0:
				continue
			var arrays := mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in range(0, indices.size(), 3):
				var a := vertices[indices[index]]
				var b := vertices[indices[index + 1]]
				var c := vertices[indices[index + 2]]
				triangles.append({
					"a": a,
					"b": b,
					"c": c,
					"color": colors[indices[index]],
					"depth": (a.z + b.z + c.z) / 3.0 + (a.y + b.y + c.y) * 0.22,
				})
	triangles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["depth"]) < float(b["depth"])
	)
	var svg := PackedStringArray()
	svg.append(
		"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">"
		% [IMAGE_SIZE.x, IMAGE_SIZE.y, IMAGE_SIZE.x, IMAGE_SIZE.y]
	)
	svg.append("<rect width=\"100%%\" height=\"100%%\" fill=\"#16242e\"/>")
	for triangle in triangles:
		var points := PackedStringArray()
		for vertex_key in ["a", "b", "c"]:
			var vertex: Vector3 = triangle[vertex_key]
			var projected := _topology_project_point(vertex)
			var pixel := (projected - bounds.position) * scale + Vector2(padding, padding)
			points.append("%.2f,%.2f" % [pixel.x, pixel.y])
		var color: Color = triangle["color"]
		svg.append(
			"<polygon points=\"%s\" fill=\"#%s\" stroke=\"#27343b\" stroke-width=\"0.16\"/>"
			% [" ".join(points), color.to_html(false)]
		)
	svg.append("</svg>")
	var image := Image.new()
	var error := image.load_svg_from_string("".join(svg))
	if error != OK:
		push_error("Could not rasterize Phase 1 topology diagnostic: %s" % error_string(error))
		return Image.create(IMAGE_SIZE.x, IMAGE_SIZE.y, false, Image.FORMAT_RGBA8)
	return image


func _topology_projected_bounds(world: HexWorldData) -> Rect2:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for tile in world.tiles:
		var projected := _topology_project_point(
			tile.position + Vector3.UP * tile.elevation
		)
		minimum.x = minf(minimum.x, projected.x - world.hex_size)
		minimum.y = minf(minimum.y, projected.y - world.hex_size)
		maximum.x = maxf(maximum.x, projected.x + world.hex_size)
		maximum.y = maxf(maximum.y, projected.y + world.hex_size)
	return Rect2(minimum, maximum - minimum)


func _topology_project_point(position: Vector3) -> Vector2:
	return Vector2(position.x, position.z * 0.62 - position.y * 1.9)


func _metadata(world: HexWorldData) -> Dictionary:
	var component_sizes := world.land_component_sizes()
	var major_component_count := 0
	var major_threshold := maxi(8, ceili(float(world.land_tile_count()) * 0.04))
	for component_size in component_sizes:
		if component_size >= major_threshold:
			major_component_count += 1
	var chunk_size := int(world.metadata["chunk_size"])
	var budget_settings := Settings.new()
	budget_settings.seed = world.seed
	budget_settings.apply_map_size_profile(String(world.profile_id))
	var ecology_budget := EcologyRenderer.instance_budget_report(
		world,
		budget_settings
	)
	var underwater_budget := UnderwaterEcologyRenderer.instance_budget_report(
		world,
		budget_settings.validated_copy()
	)
	var result := {
		"seed": world.seed,
		"map_size_profile": String(world.profile_id),
		"requested_landform_style": String(world.metadata["requested_landform_style"]),
		"resolved_landform_style": String(world.metadata["resolved_landform_style"]),
		"grid_size": [world.width, world.height],
		"tile_count": world.tiles.size(),
		"land_tile_count": world.land_tile_count(),
		"land_ratio": float(world.land_tile_count()) / float(world.tiles.size()),
		"land_component_count": component_sizes.size(),
		"major_land_component_count": major_component_count,
		"land_component_sizes": component_sizes,
		"elevation_histogram": world.metadata["elevation_histogram"],
		"deterministic_signature": world.deterministic_signature(),
		"climate_signature": world.climate_signature(),
		"hydrology_signature": world.hydrology_signature(),
		"biome_histogram": world.metadata["biome_histogram"],
		"mean_land_temperature": world.metadata["mean_land_temperature"],
		"mean_land_moisture": world.metadata["mean_land_moisture"],
		"climate_diagnostics": world.metadata["climate_diagnostics"],
		"river_count": world.metadata["river_count"],
		"river_edge_count": world.metadata["river_edge_count"],
		"river_flow_threshold": world.metadata["river_flow_threshold"],
		"lake_count": world.metadata["lake_count"],
		"mandatory_lake_count": world.metadata["mandatory_lake_count"],
		"retained_depression_count": world.metadata["retained_depression_count"],
		"watershed_count": world.metadata["watershed_count"],
		"maximum_flow_accumulation": world.metadata["maximum_flow_accumulation"],
		"source_elevated_qualification_count": world.metadata[
			"source_elevated_qualification_count"
		],
		"source_mountain_qualification_count": world.metadata[
			"source_mountain_qualification_count"
		],
		"source_highland_qualification_count": world.metadata[
			"source_highland_qualification_count"
		],
		"source_wet_interior_qualification_count": world.metadata[
			"source_wet_interior_qualification_count"
		],
		"source_unqualified_count": world.metadata["source_unqualified_count"],
		"mean_source_elevation_level": world.metadata[
			"mean_source_elevation_level"
		],
		"mean_source_ocean_moisture": world.metadata[
			"mean_source_ocean_moisture"
		],
		"close_headwater_violation_count": world.metadata[
			"close_headwater_violation_count"
		],
		"parallel_river_violation_count": world.metadata[
			"parallel_river_violation_count"
		],
		"sharp_river_turn_count": world.metadata["sharp_river_turn_count"],
		"river_confluence_count": world.metadata["river_confluence_count"],
		"river_system_count": world.metadata["river_system_count"],
		"downstream_uphill_violation_count": world.metadata[
			"downstream_uphill_violation_count"
		],
		"mean_lowland_river_lateral_deviation": world.metadata[
			"mean_lowland_river_lateral_deviation"
		],
		"maximum_lowland_river_lateral_deviation": world.metadata[
			"maximum_lowland_river_lateral_deviation"
		],
		"mean_highland_river_lateral_deviation": world.metadata[
			"mean_highland_river_lateral_deviation"
		],
		"straight_flatland_reach_count": world.metadata[
			"straight_flatland_reach_count"
		],
		"lowland_river_reach_count": world.metadata[
			"lowland_river_reach_count"
		],
		"highland_river_reach_count": world.metadata[
			"highland_river_reach_count"
		],
		"straight_flatland_deviation_threshold": world.metadata[
			"straight_flatland_deviation_threshold"
		],
		"flatland_reroute_eligible_count": world.metadata[
			"flatland_reroute_eligible_count"
		],
		"flatland_reroute_total_count": world.metadata[
			"flatland_reroute_total_count"
		],
		"flatland_reroute_selected_edge_count": world.metadata[
			"flatland_reroute_selected_edge_count"
		],
		"flatland_straight_river_run_count": world.metadata[
			"flatland_straight_river_run_count"
		],
		"flatland_max_straight_river_run_length": world.metadata[
			"flatland_max_straight_river_run_length"
		],
		"flatland_gentle_bend_count": world.metadata[
			"flatland_gentle_bend_count"
		],
		"flatland_zigzag_reversal_count": world.metadata[
			"flatland_zigzag_reversal_count"
		],
		"freshwater_influenced_tile_count": world.metadata.get(
			"freshwater_influenced_tile_count",
			0
		),
		"ecology_signature": world.ecology_signature(),
		"feature_histogram": world.metadata["feature_histogram"],
		"exclusion_histogram": world.metadata["exclusion_histogram"],
		"mean_land_vegetation_density": world.metadata[
			"mean_land_vegetation_density"
		],
		"vegetated_tile_count": world.metadata["vegetated_tile_count"],
		"forested_tile_count": world.metadata["forested_tile_count"],
		"excluded_tile_count": world.metadata["excluded_tile_count"],
		"settlement_reservation_count": world.metadata[
			"settlement_reservation_count"
		],
		"resource_histogram": world.metadata["resource_histogram"],
		"resource_candidate_counts": world.metadata["resource_candidate_counts"],
		"resource_quotas": world.metadata["resource_quotas"],
		"resource_target_count": world.metadata["resource_target_count"],
		"resource_placed_count": world.metadata["resource_placed_count"],
		"resource_types_present": world.metadata["resource_types_present"],
		"resource_minimum_spacing": world.metadata["resource_minimum_spacing"],
		"same_resource_minimum_spacing": world.metadata[
			"same_resource_minimum_spacing"
		],
		"minimum_resource_spacing_observed": world.metadata[
			"minimum_resource_spacing_observed"
		],
		"minimum_same_resource_spacing_observed": world.metadata[
			"minimum_same_resource_spacing_observed"
		],
		"resource_rule_violation_count": world.metadata[
			"resource_rule_violation_count"
		],
		"resource_spacing_violation_count": world.metadata[
			"resource_spacing_violation_count"
		],
		"feature_exclusion_violation_count": world.metadata[
			"feature_exclusion_violation_count"
		],
		"chunk_count": (
			ceili(float(world.width) / float(chunk_size))
			* ceili(float(world.height) / float(chunk_size))
		),
	}
	for budget_key in ecology_budget:
		result[budget_key] = ecology_budget[budget_key]
	for budget_key in underwater_budget:
		result[budget_key] = underwater_budget[budget_key]
	# Deterministic transition-closeup subject, recorded so a reviewer can
	# explain which biome seam `transition_closeup`/`transition_closeup_file`
	# frames without re-deriving it from the world (see
	# `HexWorldPrototype.select_deterministic_transition_subject`). Purely
	# logical data; computed the same way whether or not a runtime capture
	# ran, so it is present for both the runtime and `--topology-only` paths.
	var transition_subject := HexWorldPrototype.select_deterministic_transition_subject(world)
	result["transition_subject_available"] = not transition_subject.is_empty()
	if transition_subject.is_empty():
		result["transition_first_coordinate"] = null
		result["transition_first_biome"] = ""
		result["transition_second_coordinate"] = null
		result["transition_second_biome"] = ""
		result["transition_contrast_score"] = 0.0
	else:
		var first_coordinate: Vector2i = transition_subject["first_coordinate"]
		var second_coordinate: Vector2i = transition_subject["second_coordinate"]
		result["transition_first_coordinate"] = [first_coordinate.x, first_coordinate.y]
		result["transition_first_biome"] = String(transition_subject["first_biome"])
		result["transition_second_coordinate"] = [second_coordinate.x, second_coordinate.y]
		result["transition_second_biome"] = String(transition_subject["second_biome"])
		result["transition_contrast_score"] = float(transition_subject["score"])
	# Continuous biome-floor blend field (`HexTerrainBiomeField`): computed
	# the same pure way whether or not a runtime capture ran, so its
	# dimensions/memory impact are present for both the runtime and
	# `--topology-only` paths, matching the transition-subject fields above.
	var biome_field := BiomeFieldScript.build(world)
	result["biome_field_ok"] = bool(biome_field.get("ok", false))
	result["biome_field_width"] = int(biome_field.get("width", 0))
	result["biome_field_height"] = int(biome_field.get("height", 0))
	result["biome_field_bytes"] = int(biome_field.get("byte_count", 0))
	return result


func _build_contact_sheet(images: Array[Image]) -> Image:
	if images.is_empty():
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var rows := ceili(float(images.size()) / float(CONTACT_COLUMNS))
	var sheet := Image.create(
		IMAGE_SIZE.x * CONTACT_COLUMNS,
		IMAGE_SIZE.y * rows,
		false,
		Image.FORMAT_RGBA8
	)
	sheet.fill(Color("#101820"))
	for index in range(images.size()):
		sheet.blit_rect(
			images[index],
			Rect2i(Vector2i.ZERO, IMAGE_SIZE),
			Vector2i(index % CONTACT_COLUMNS, index / CONTACT_COLUMNS) * IMAGE_SIZE
		)
	return sheet


func _record_png_result(image: Image, path: String, errors: Array[String]) -> void:
	var error := image.save_png(path)
	if error != OK:
		errors.append("Could not save preview %s: %s" % [path, error_string(error)])


func _record_json_result(data: Variant, path: String, errors: Array[String]) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		errors.append("Could not save preview metadata %s." % path)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		errors.append("Could not finish preview metadata %s: %s" % [path, error_string(error)])


func _selected_metric_ranges(metric_ranges: Dictionary, metric_names: Array) -> Dictionary:
	var selected: Dictionary = {}
	for metric_name in metric_names:
		if metric_ranges.has(metric_name):
			selected[metric_name] = metric_ranges[metric_name]
	return selected


func _resolve_output_directory(value: String) -> String:
	if value.is_absolute_path():
		return value.simplify_path()
	return ProjectSettings.globalize_path("res://%s" % value).simplify_path()


static func _unique_ints(values: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		if not result.has(value):
			result.append(value)
	return result


static func _unique_strings(values: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		if not result.has(value):
			result.append(value)
	return result
