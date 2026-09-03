class_name HexWorldLabPanel
extends PanelContainer

const Content = preload("res://src/data/game_content.gd")
const Accessibility = preload("res://src/world3d/ui/hex_world_accessibility.gd")
const Benchmark = preload("res://src/world3d/rendering/hex_world_device_benchmark.gd")
const Evidence = preload("res://src/world3d/rendering/hex_world_device_evidence.gd")

const STYLE_OPTIONS := [
	["Varied", "varied"],
	["Continents and Islands", "continents_and_islands"],
	["Pangea and Islands", "pangea_and_islands"],
	["Archipelago", "archipelago"],
	["Fractured", "fractured"],
]
const SLIDER_DEFINITIONS := [
	["ocean_percentage", "Ocean coverage", 0.35, 0.90, 0.01],
	["continent_size_variation", "Continent size variation", 0.0, 1.0, 0.01],
	["continent_separation", "Continent separation", 0.0, 1.0, 0.01],
	["coast_complexity", "Coast complexity", 0.0, 1.0, 0.01],
	["island_frequency", "Island frequency", 0.0, 1.0, 0.01],
	["terrain_roughness", "Terrain roughness", 0.0, 1.0, 0.01],
	["mountain_frequency", "Mountain frequency", 0.0, 1.0, 0.01],
	["mountain_length", "Mountain length", 0.1, 1.0, 0.01],
	["temperature_variation", "Temperature variation", 0.0, 1.0, 0.01],
	["moisture_variation", "Moisture variation", 0.0, 1.0, 0.01],
	["equator_position", "Equator position", 0.25, 0.75, 0.01],
	["prevailing_wind_strength", "Prevailing wind", 0.0, 1.0, 0.01],
	["rain_shadow_strength", "Rain shadows", 0.0, 1.0, 0.01],
	["biome_boundary_softness", "Biome softness", 0.0, 1.0, 0.01],
	["river_count", "River target", 0, 128, 1],
	["lake_count", "Depression retention", 0, 64, 1],
	["minimum_river_length", "Minimum river length", 1, 32, 1],
	["river_meander_strength", "River meander", 0.0, 1.0, 0.01],
	["freshwater_moisture_reach", "Freshwater reach", 0, 8, 1],
	["forest_density", "Forest density", 0.0, 2.0, 0.01],
	["vegetation_variation", "Vegetation variation", 0.0, 1.0, 0.01],
	["resource_density", "Resource density", 0.0, 2.0, 0.01],
	["resource_minimum_spacing", "Resource spacing", 1, 8, 1],
	["settlement_reserve_radius", "Settlement reserve", 0, 3, 1],
]
const INTEGER_SLIDERS := {
	&"river_count": true,
	&"lake_count": true,
	&"minimum_river_length": true,
	&"freshwater_moisture_reach": true,
	&"resource_minimum_spacing": true,
	&"settlement_reserve_radius": true,
}
const DESKTOP_CONTROL_HEIGHT := 28.0
const DESKTOP_CAMERA_BUTTON_SIZE := 30.0
const DESKTOP_FONT_SIZE := 10

var prototype: HexWorldPrototype
var strategy_camera: StrategyCamera3D
var size_option: OptionButton
var style_option: OptionButton
var seed_input: LineEdit
var status_label: Label
var histogram_label: Label
var ecology_label: Label
var selection_label: Label
var performance_label: Label
var device_label: Label
var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _view_buttons: Dictionary = {}
var _camera_buttons: Dictionary = {}
var _phase_five_controls: Dictionary = {}
var _view_button_group := ButtonGroup.new()
var camera_overlay: PanelContainer


func _ready() -> void:
	prototype = get_parent().get_parent() as HexWorldPrototype
	if prototype == null or not prototype.show_test_panel:
		hide()
		return
	strategy_camera = prototype.get_node("%StrategyCamera") as StrategyCamera3D
	if strategy_camera == null:
		push_error("World Generation Lab requires the strategy camera.")
		hide()
		return
	_build_interface()
	strategy_camera.add_pointer_input_exclusion(self)
	strategy_camera.add_pointer_input_exclusion(camera_overlay)
	prototype.world_regenerated.connect(_on_world_regenerated)
	prototype.terrain_view_changed.connect(_on_terrain_view_changed)
	prototype.ecology_detail_changed.connect(_on_ecology_detail_changed)
	prototype.tile_selected.connect(_on_tile_selected)
	prototype.chunks_rebuilt.connect(_on_chunks_rebuilt)
	_sync_from_settings()


func _build_interface() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_font_size_override("font_size", DESKTOP_FONT_SIZE)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("#161d23eb")
	panel_style.border_color = Color("#caa85a")
	panel_style.set_border_width_all(1)
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	add_theme_stylebox_override("panel", panel_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.gui_input.connect(_on_lab_scroll_input)
	margin.add_child(scroll)

	var layout := VBoxContainer.new()
	# Leave room for the vertical scrollbar inside the 304 px desktop panel.
	layout.custom_minimum_size.x = 244
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 5)
	scroll.add_child(layout)

	var title := Label.new()
	title.text = "WORLD GENERATION LAB"
	title.add_theme_color_override("font_color", Color("#f2dfaa"))
	_apply_desktop_label(title)
	layout.add_child(title)

	var hint := Label.new()
	hint.text = "Tune, then generate. Drag to pan; scroll or pinch to zoom. Tab hides the Lab."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color("#b8c5cc"))
	_apply_desktop_label(hint)
	layout.add_child(hint)

	_add_section_label(layout, "MAP")
	size_option = _add_option_row(layout, "Size")
	for profile_id in Content.map_size_profile_ids():
		var profile := Content.map_size_profile(profile_id)
		size_option.add_item(String(profile["label"]))
		size_option.set_item_metadata(size_option.item_count - 1, profile_id)
	size_option.item_selected.connect(_on_size_selected)

	style_option = _add_option_row(layout, "Map family")
	for style_data in STYLE_OPTIONS:
		style_option.add_item(String(style_data[0]))
		style_option.set_item_metadata(style_option.item_count - 1, style_data[1])
	style_option.item_selected.connect(_on_style_selected)

	var seed_row := GridContainer.new()
	seed_row.columns = 2
	seed_row.add_theme_constant_override("h_separation", 6)
	seed_row.add_theme_constant_override("v_separation", 4)
	layout.add_child(seed_row)
	var seed_label := Label.new()
	seed_label.text = "Seed"
	seed_label.custom_minimum_size.x = 92
	_apply_desktop_label(seed_label)
	seed_row.add_child(seed_label)
	seed_input = LineEdit.new()
	seed_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_input.placeholder_text = "-12345"
	_apply_desktop_control(seed_input, "Seed", "Signed integer campaign seed")
	seed_input.text_submitted.connect(func(_value: String) -> void: generate())
	seed_row.add_child(seed_input)
	var random_spacer := Control.new()
	random_spacer.custom_minimum_size.x = 92
	random_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seed_row.add_child(random_spacer)
	var random_button := Button.new()
	random_button.text = "Random"
	random_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	random_button.tooltip_text = "Choose a new signed seed and generate it immediately"
	random_button.pressed.connect(_randomize_seed)
	_apply_desktop_control(
		random_button,
		"Randomize",
		"Choose a new signed seed and generate it"
	)
	seed_row.add_child(random_button)

	_add_section_label(layout, "LAND AND COAST")
	for definition in SLIDER_DEFINITIONS.slice(0, 5):
		_add_slider_row(layout, definition)

	_add_section_label(layout, "RELIEF")
	for definition in SLIDER_DEFINITIONS.slice(5, 8):
		_add_slider_row(layout, definition)

	_add_section_label(layout, "CLIMATE")
	for definition in SLIDER_DEFINITIONS.slice(8, 14):
		_add_slider_row(layout, definition)

	_add_section_label(layout, "HYDROLOGY")
	for definition in SLIDER_DEFINITIONS.slice(14, 19):
		_add_slider_row(layout, definition)

	_add_section_label(layout, "ECOLOGY AND RESOURCES")
	for definition in SLIDER_DEFINITIONS.slice(19):
		_add_slider_row(layout, definition)

	_add_section_label(layout, "DIAGNOSTICS")
	var debug_row := FlowContainer.new()
	debug_row.add_theme_constant_override("separation", 4)
	layout.add_child(debug_row)
	_add_debug_view_button(debug_row, "Biome", "biome")
	_add_debug_view_button(debug_row, "Elevation", "elevation")
	_add_debug_view_button(debug_row, "Temperature", "temperature")
	_add_debug_view_button(debug_row, "Moisture", "moisture")
	_add_debug_view_button(debug_row, "Flow", "flow_direction")
	_add_debug_view_button(debug_row, "Watersheds", "watershed")
	_add_debug_view_button(debug_row, "Accumulation", "accumulation")
	_add_debug_view_button(debug_row, "Lakes", "lakes")
	_add_debug_view_button(debug_row, "River edges", "river_edges")
	_add_debug_view_button(debug_row, "Ecology", "ecology")
	_add_debug_view_button(debug_row, "Resources", "resources")
	_add_debug_view_button(debug_row, "Density", "density")
	_add_debug_view_button(debug_row, "Exclusions", "exclusion")
	_add_debug_view_button(debug_row, "Material response", "material_response")
	_add_debug_toggle(debug_row, "Hexes", "show_hex_boundaries")
	_add_debug_toggle(debug_row, "Chunks", "show_chunk_boundaries")

	_add_section_label(layout, "INTERACTION AND PERFORMANCE")
	var interaction_row := FlowContainer.new()
	interaction_row.add_theme_constant_override("separation", 4)
	layout.add_child(interaction_row)
	_add_phase_five_button(
		interaction_row,
		"Pick centre",
		"Resolve the hex under the middle of the view",
		pick_centre_tile
	)
	_add_phase_five_button(
		interaction_row,
		"Focus selection",
		"Move the camera to the selected hex",
		prototype.focus_on_selected_tile
	)
	_add_phase_five_button(
		interaction_row,
		"Raise tile",
		"Raise the selected hex and rebuild only the dependent chunks",
		raise_selected_tile.bind(1)
	)
	_add_phase_five_button(
		interaction_row,
		"Lower tile",
		"Lower the selected hex and rebuild only the dependent chunks",
		raise_selected_tile.bind(-1)
	)

	var toggle_row := FlowContainer.new()
	toggle_row.add_theme_constant_override("separation", 4)
	layout.add_child(toggle_row)
	_add_phase_five_toggle(
		toggle_row,
		"Terrain LOD",
		"Switch distant chunks to the reduced-detail mesh",
		&"enable_terrain_lod"
	)
	_add_phase_five_toggle(
		toggle_row,
		"Worker thread",
		"Run logical generation off the main thread",
		&"use_worker_thread_generation"
	)
	_add_phase_five_toggle(
		toggle_row,
		"High contrast",
		"Use the accessible diagnostic palettes",
		&"high_contrast_palette"
	)

	var persistence_row := FlowContainer.new()
	persistence_row.add_theme_constant_override("separation", 4)
	layout.add_child(persistence_row)
	_add_phase_five_button(
		persistence_row,
		"Save world",
		"Write the logical world with the versioned schema",
		save_world
	)
	_add_phase_five_button(
		persistence_row,
		"Load world",
		"Restore the saved logical world and verify its signatures",
		load_world
	)
	_add_phase_five_button(
		persistence_row,
		"Device sample",
		"Capture a target-device budget sample from the live scene",
		write_device_sample
	)

	var benchmark_row := FlowContainer.new()
	benchmark_row.add_theme_constant_override("separation", 4)
	layout.add_child(benchmark_row)
	_add_phase_five_button(
		benchmark_row,
		"Device benchmark",
		(
			"Run the full repeatable target-device protocol. Pressing this "
			+ "declares the device started from an idle thermal state."
		),
		run_device_benchmark
	)
	_add_phase_five_button(
		benchmark_row,
		"Quick benchmark",
		"Run a short protocol pass over the current tier only, for a smoke check",
		run_quick_device_benchmark
	)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	layout.add_child(action_row)
	var generate_button := Button.new()
	generate_button.text = "Generate"
	generate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	generate_button.pressed.connect(generate)
	_apply_desktop_control(
		generate_button,
		"Generate",
		"Regenerate the world with the current parameters"
	)
	action_row.add_child(generate_button)

	var reset_button := Button.new()
	reset_button.text = "Reset parameters"
	reset_button.pressed.connect(_reset_parameters)
	_apply_desktop_control(
		reset_button,
		"Reset generation parameters",
		"Restore every slider to its default"
	)
	layout.add_child(reset_button)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color("#d8e0e3"))
	_apply_desktop_label(status_label)
	layout.add_child(status_label)

	histogram_label = Label.new()
	histogram_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	histogram_label.add_theme_color_override("font_color", Color("#9fb1b8"))
	_apply_desktop_label(histogram_label)
	layout.add_child(histogram_label)

	ecology_label = Label.new()
	ecology_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ecology_label.add_theme_color_override("font_color", Color("#9fb1b8"))
	_apply_desktop_label(ecology_label)
	layout.add_child(ecology_label)

	selection_label = Label.new()
	selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	selection_label.add_theme_color_override("font_color", Color("#e6d3a3"))
	selection_label.text = "Selection: tap the map to pick a hex."
	_apply_desktop_label(selection_label)
	layout.add_child(selection_label)

	performance_label = Label.new()
	performance_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	performance_label.add_theme_color_override("font_color", Color("#9fb1b8"))
	_apply_desktop_label(performance_label)
	layout.add_child(performance_label)

	device_label = Label.new()
	device_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	device_label.add_theme_color_override("font_color", Color("#c9b6d8"))
	_apply_desktop_label(device_label)
	layout.add_child(device_label)
	_build_camera_overlay()
	_update_device_gate()


func _build_camera_overlay() -> void:
	camera_overlay = PanelContainer.new()
	camera_overlay.name = "CameraControls"
	camera_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	camera_overlay.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	camera_overlay.offset_left = -138.0
	camera_overlay.offset_top = -158.0
	camera_overlay.offset_right = -8.0
	camera_overlay.offset_bottom = -8.0
	var overlay_style := StyleBoxFlat.new()
	overlay_style.bg_color = Color("#161d23e8")
	overlay_style.border_color = Color("#caa85a")
	overlay_style.set_border_width_all(1)
	overlay_style.set_corner_radius_all(8)
	camera_overlay.add_theme_stylebox_override("panel", overlay_style)
	# This panel builds during its parent's scene setup, when adding a sibling
	# synchronously is rejected. Defer only the sibling attachment; the complete
	# control tree is ready before the next frame.
	get_parent().add_child.call_deferred(camera_overlay)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 6)
	camera_overlay.add_child(margin)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 3)
	margin.add_child(layout)
	var hint := Label.new()
	hint.text = "VIEW  •  drag  •  scroll"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color("#f2dfaa"))
	_apply_desktop_label(hint)
	layout.add_child(hint)

	var controls := GridContainer.new()
	controls.columns = 3
	controls.add_theme_constant_override("h_separation", 3)
	controls.add_theme_constant_override("v_separation", 3)
	layout.add_child(controls)
	_add_camera_spacer(controls)
	_add_camera_button(controls, "Up", Vector2.UP, "↑")
	_add_camera_action_button(controls, "Zoom in", strategy_camera.zoom_in, "+")
	_add_camera_button(controls, "Left", Vector2.LEFT, "←")
	_add_camera_action_button(controls, "Reset view", strategy_camera.reset_view, "Fit")
	_add_camera_button(controls, "Right", Vector2.RIGHT, "→")
	_add_camera_spacer(controls)
	_add_camera_button(controls, "Down", Vector2.DOWN, "↓")
	_add_camera_action_button(controls, "Zoom out", strategy_camera.zoom_out, "−")

	camera_overlay.visible = visible
	visibility_changed.connect(_sync_camera_overlay_visibility)


func _add_camera_spacer(row: Container) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2.ONE * DESKTOP_CAMERA_BUTTON_SIZE
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)


func _sync_camera_overlay_visibility() -> void:
	if camera_overlay != null:
		camera_overlay.visible = visible


func _on_lab_scroll_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		strategy_camera.suppress_scroll_zoom()
	elif (
		event is InputEventMouseButton
		and event.button_index in [
			MOUSE_BUTTON_WHEEL_UP,
			MOUSE_BUTTON_WHEEL_DOWN,
		]
	):
		strategy_camera.suppress_scroll_zoom()


func _apply_desktop_control(
	control: Control,
	accessible_name := "",
	description := ""
) -> void:
	Accessibility.apply_touch_target(control, accessible_name, description)
	control.custom_minimum_size.y = DESKTOP_CONTROL_HEIGHT
	control.add_theme_font_size_override("font_size", DESKTOP_FONT_SIZE)


func _apply_desktop_label(label: Label) -> void:
	label.add_theme_font_size_override("font_size", DESKTOP_FONT_SIZE)


func _add_section_label(layout: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color("#caa85a"))
	_apply_desktop_label(label)
	layout.add_child(label)


func _add_option_row(layout: VBoxContainer, title: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	layout.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 78
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = title
	_apply_desktop_label(label)
	row.add_child(label)
	var option := OptionButton.new()
	option.fit_to_longest_item = false
	option.clip_text = true
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_desktop_control(option, title)
	row.add_child(option)
	return option


func _add_slider_row(layout: VBoxContainer, definition: Array) -> void:
	var property_name := StringName(definition[0])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	layout.add_child(row)
	var label := Label.new()
	label.text = String(definition[1])
	label.custom_minimum_size.x = 92
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = String(definition[1])
	_apply_desktop_label(label)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = float(definition[2])
	slider.max_value = float(definition[3])
	slider.step = float(definition[4])
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_slider_changed.bind(property_name))
	_apply_desktop_control(slider, String(definition[1]))
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 36
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_apply_desktop_label(value_label)
	row.add_child(value_label)
	_sliders[property_name] = slider
	_value_labels[property_name] = value_label


func _add_debug_view_button(row: Container, title: String, view_id: String) -> void:
	var button := Button.new()
	button.text = title
	button.toggle_mode = true
	button.button_group = _view_button_group
	button.button_pressed = prototype.terrain_view == view_id
	button.toggled.connect(func(value: bool) -> void:
		if value:
			prototype.set_terrain_view(view_id)
	)
	_apply_desktop_control(
		button,
		"%s diagnostic" % title,
		"Recolour the terrain by %s" % title.to_lower()
	)
	row.add_child(button)
	_view_buttons[view_id] = button


func _add_debug_toggle(row: Container, title: String, property_name: StringName) -> void:
	var toggle := CheckBox.new()
	toggle.text = title
	toggle.button_pressed = bool(prototype.get(property_name))
	toggle.toggled.connect(func(value: bool) -> void: prototype.set(property_name, value))
	_apply_desktop_control(toggle, "%s overlay" % title)
	row.add_child(toggle)


func _add_camera_button(
	row: Container,
	title: String,
	direction: Vector2,
	display_text := ""
) -> void:
	var button := Button.new()
	button.text = title if display_text.is_empty() else display_text
	button.pressed.connect(strategy_camera.pan_view.bind(direction))
	_apply_desktop_control(
		button,
		"Pan %s" % title.to_lower(),
		"Move the map view %s" % title.to_lower()
	)
	button.custom_minimum_size = Vector2.ONE * DESKTOP_CAMERA_BUTTON_SIZE
	row.add_child(button)
	_camera_buttons[title] = button


func _add_camera_action_button(
	row: Container,
	title: String,
	action: Callable,
	display_text := ""
) -> void:
	var button := Button.new()
	button.text = title if display_text.is_empty() else display_text
	button.pressed.connect(action)
	var description := ""
	match title:
		"Zoom in":
			description = "Move closer; the mouse-wheel-up alternative zooms toward the pointer"
		"Zoom out":
			description = "Move farther away; the mouse-wheel-down alternative zooms toward the pointer"
		"Reset view":
			description = "Restore the framed whole-world view"
	_apply_desktop_control(button, title, description)
	button.custom_minimum_size = Vector2.ONE * DESKTOP_CAMERA_BUTTON_SIZE
	row.add_child(button)
	_camera_buttons[title] = button


func _sync_from_settings() -> void:
	var settings := prototype.settings
	_select_metadata(size_option, settings.map_size_profile)
	_select_metadata(style_option, settings.landform_style)
	seed_input.text = str(settings.seed)
	for property_name in _sliders:
		var slider: HSlider = _sliders[property_name]
		slider.set_value_no_signal(float(settings.get(property_name)))
		_update_value_label(property_name, slider.value)
	for view_id in _view_buttons:
		var button: Button = _view_buttons[view_id]
		button.set_pressed_no_signal(prototype.terrain_view == view_id)
	_update_status()


func generate() -> void:
	var stripped_seed := seed_input.text.strip_edges()
	if not stripped_seed.is_valid_int():
		status_label.text = "Seed must be a signed integer."
		status_label.add_theme_color_override("font_color", Color("#ff9b8f"))
		return
	prototype.settings.seed = stripped_seed.to_int()
	prototype.regenerate()


func _on_size_selected(index: int) -> void:
	prototype.settings.apply_map_size_profile(String(size_option.get_item_metadata(index)))


func _on_style_selected(index: int) -> void:
	prototype.settings.landform_style = String(style_option.get_item_metadata(index))


func _on_slider_changed(value: float, property_name: StringName) -> void:
	prototype.settings.set(property_name, value)
	_update_value_label(property_name, value)


func _update_value_label(property_name: StringName, value: float) -> void:
	var label: Label = _value_labels[property_name]
	label.text = (
		str(roundi(value))
		if INTEGER_SLIDERS.has(property_name)
		else "%d%%" % roundi(value * 100.0)
	)


func _randomize_seed() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	seed_input.text = str(rng.randi())
	generate()


func _reset_parameters() -> void:
	var defaults := WorldGenerationSettings.new()
	for property_name in _sliders:
		prototype.settings.set(property_name, defaults.get(property_name))
	_sync_from_settings()


func _on_world_regenerated(_world: HexWorldData) -> void:
	_sync_from_settings()
	_update_performance()


func _on_terrain_view_changed(view_id: String) -> void:
	for candidate in _view_buttons:
		var button: Button = _view_buttons[candidate]
		button.set_pressed_no_signal(candidate == view_id)


func _on_ecology_detail_changed(_detail_factor: float) -> void:
	_update_status()


func _update_status() -> void:
	if prototype.world_data == null:
		status_label.text = "Ready to generate."
		return
	var world := prototype.world_data
	var land_ratio := 100.0 * float(world.land_tile_count()) / float(world.tiles.size())
	status_label.remove_theme_color_override("font_color")
	status_label.text = (
		"%s | %dx%d | %.1f%% land | %d land groups | %d rivers @ %d flow | %d lakes | %d resources | %d ms"
		% [
			String(world.metadata["resolved_landform_style"]).capitalize(),
			world.width,
			world.height,
			land_ratio,
			world.land_component_sizes().size(),
			int(world.metadata.get("river_count", 0)),
			int(world.metadata.get("river_flow_threshold", 0)),
			int(world.metadata.get("lake_count", 0)),
			int(world.metadata.get("resource_placed_count", 0)),
			prototype.last_generation_ms,
		]
	)
	var histogram: Dictionary = world.metadata.get("biome_histogram", {})
	var land_count := maxi(world.land_tile_count(), 1)
	var entries := PackedStringArray()
	for biome_value in histogram:
		var biome := String(biome_value)
		if biome == "water":
			continue
		entries.append(
			"%s %.1f%%"
			% [
				biome.replace("_", " ").capitalize(),
				100.0 * float(histogram[biome_value]) / float(land_count),
			]
		)
	entries.sort()
	histogram_label.text = "Land biomes: %s" % ", ".join(entries)
	var feature_histogram: Dictionary = world.metadata.get("feature_histogram", {})
	var feature_entries := PackedStringArray()
	for feature_value in [
		"dense_forest",
		"forest",
		"woodland",
		"sparse_vegetation",
	]:
		if not feature_histogram.has(feature_value):
			continue
		feature_entries.append(
			"%s %.1f%%"
			% [
				String(feature_value).replace("_", " ").capitalize(),
				100.0 * float(feature_histogram[feature_value]) / float(land_count),
			]
		)
	var resource_histogram: Dictionary = world.metadata.get("resource_histogram", {})
	var resource_entries := PackedStringArray()
	for resource_value in resource_histogram:
		resource_entries.append(
			"%s %d" % [String(resource_value).capitalize(), int(resource_histogram[resource_value])]
		)
	resource_entries.sort()
	ecology_label.text = (
		"Vegetation: %s\nResources: %s\nReserved sites: %d | mean density %.2f | detail %d%%"
		% [
			", ".join(feature_entries) if not feature_entries.is_empty() else "none",
			", ".join(resource_entries) if not resource_entries.is_empty() else "none",
			int(world.metadata.get("settlement_reservation_count", 0)),
			float(world.metadata.get("mean_land_vegetation_density", 0.0)),
			roundi(prototype.ecology_detail_factor * 100.0),
		]
	)


func _add_phase_five_button(
	row: Container,
	title: String,
	description: String,
	action: Callable
) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	_apply_desktop_control(button, title, description)
	row.add_child(button)
	_phase_five_controls[title] = button


func _add_phase_five_toggle(
	row: Container,
	title: String,
	description: String,
	property_name: StringName
) -> void:
	var toggle := CheckBox.new()
	toggle.text = title
	toggle.button_pressed = bool(prototype.get(property_name))
	toggle.toggled.connect(func(value: bool) -> void:
		prototype.set(property_name, value)
		_update_performance()
	)
	_apply_desktop_control(toggle, title, description)
	row.add_child(toggle)
	_phase_five_controls[title] = toggle


func pick_centre_tile() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var centre := viewport.get_visible_rect().size * 0.5
	prototype.select_tile(prototype.pick_tile_at(centre))


## Mutates one logical tile and rebuilds only the chunks whose geometry depends
## on it. This is the interactive proof of Phase 5 dirty tracking.
func raise_selected_tile(delta: int) -> void:
	var tile := prototype.selected_tile
	if tile == null or prototype.world_data == null:
		selection_label.text = "Selection: pick a hex before changing its elevation."
		return
	var settings := prototype.settings.validated_copy()
	tile.elevation_level = clampi(tile.elevation_level + delta, 0, 4)
	tile.is_water = tile.elevation_level == 0
	tile.elevation = float(tile.elevation_level) * settings.elevation_step_height
	var chunks := prototype.mark_tile_dirty(tile.coordinate)
	var rebuilt := prototype.rebuild_dirty_chunks()
	selection_label.text = (
		"Selection: %s\nElevation now %d — %d dependent chunk(s) marked, %d rebuilt in %d ms."
		% [
			Accessibility.tile_label(tile),
			tile.elevation_level,
			chunks.size(),
			rebuilt,
			prototype.last_build_ms,
		]
	)
	_update_performance()


func save_world() -> void:
	var result := prototype.save_world()
	performance_label.text = (
		"Saved %d bytes to %s" % [int(result.get("bytes", 0)), result.get("path", "")]
		if bool(result["ok"])
		else "Save failed: %s" % result["error"]
	)


func load_world() -> void:
	var result := prototype.load_world()
	if not bool(result["ok"]):
		performance_label.text = "Load failed: %s" % result["error"]
		return
	performance_label.text = (
		"Restored schema v%d with matching deterministic, climate, hydrology, and ecology signatures."
		% int(result["schema_version"])
	)


func write_device_sample() -> void:
	var result := prototype.write_device_benchmark()
	performance_label.text = (
		"Device budget sample written to %s (desktop capture is not device proof)."
		% result.get("path", "")
		if bool(result["ok"])
		else "Device sample failed: %s" % result["error"]
	)


## The in-app measurement path. A packaged handset build cannot receive command
## line arguments and cannot hand a sandbox file back, so this button is the
## supported way to capture device evidence: it runs the whole protocol, shows
## the verdict on the handset, and fences the document on the device console.
func run_device_benchmark() -> void:
	await _run_device_benchmark_with({})


func run_quick_device_benchmark() -> void:
	var profiles: Array[StringName] = [
		StringName(prototype.settings.map_size_profile)
	]
	await _run_device_benchmark_with({
		"profiles": profiles,
		"sample_frames": Benchmark.DEFAULT_SAMPLE_FRAMES / 2,
		"warmup_frames": Evidence.MINIMUM_WARMUP_FRAMES,
	})


func _run_device_benchmark_with(options: Dictionary) -> void:
	if prototype.is_running_device_benchmark():
		device_label.text = "A device benchmark is already running."
		return
	_set_benchmark_controls_enabled(false)
	device_label.text = "Device benchmark starting. Keep the device still and do not switch apps."
	# Pressing the button is the operator's declaration that the device started
	# from an idle thermal state. Battery level has no Godot API, so it is
	# stamped in by the host capture script and stays unset here.
	var resolved := {"thermal_precondition_met": true}
	for key in options:
		resolved[key] = options[key]
	var result: Dictionary = await prototype.run_device_benchmark(resolved)
	_set_benchmark_controls_enabled(true)
	if not bool(result["ok"]):
		device_label.text = "Device benchmark failed: %s" % result["error"]
		return
	var document: Dictionary = result["document"]
	var evaluation: Dictionary = document.get("evaluation", {})
	var failures: PackedStringArray = evaluation.get("failures", PackedStringArray())
	device_label.text = (
		"Device benchmark: %s\n%s\nWritten to %s and fenced on the device console."
		% [
			"every criterion passed" if bool(evaluation.get("validated", false))
				else "%d criterion failure(s)" % failures.size(),
			_summarise_benchmark(document),
			result["path"],
		]
	)


func _summarise_benchmark(document: Dictionary) -> String:
	var lines := PackedStringArray()
	for run in document.get("runs", []):
		if not (run is Dictionary):
			continue
		var worst_p95 := 0.0
		var worst_state := ""
		for state in run.get("camera_states", []):
			var frame_ms: Dictionary = state.get("frame_ms", {})
			if float(frame_ms.get("p95", 0.0)) > worst_p95:
				worst_p95 = float(frame_ms.get("p95", 0.0))
				worst_state = String(state.get("name", ""))
		var memory: Dictionary = run.get("memory", {})
		var resident := (
			float(memory.get("static_memory_bytes", 0.0))
			+ float(memory.get("video_memory_bytes", 0.0))
		)
		lines.append(
			"%s: %d ms logic, %d ms build, %.1f MiB geometry, %.1f MiB resident, worst p95 %.1f ms (%s)"
			% [
				run.get("profile_id", "?"),
				int(run.get("generation_ms", 0)),
				int(run.get("build_ms", 0)),
				float(run.get("geometry_bytes", 0)) / 1048576.0,
				resident / 1048576.0,
				worst_p95,
				worst_state,
			]
		)
	return "\n".join(lines)


func _set_benchmark_controls_enabled(enabled: bool) -> void:
	for control_name in ["Device benchmark", "Quick benchmark"]:
		var control := _phase_five_controls.get(control_name) as Button
		if control != null:
			control.disabled = not enabled


func _update_device_gate() -> void:
	if device_label == null:
		return
	var gate := HexWorldPrototype.target_device_gate()
	device_label.text = (
		"Target-device validation: %s\n%s"
		% [
			"validated by committed evidence" if bool(gate["validated"])
				else "not validated",
			gate.get("reason", ""),
		]
	)


func _on_tile_selected(tile: HexTileData) -> void:
	selection_label.text = "Selection: %s" % Accessibility.tile_label(tile)


func _on_chunks_rebuilt(chunk_count: int, reason: String) -> void:
	if reason == "dirty":
		performance_label.text = (
			"Selective rebuild: %d chunk(s) in %d ms." % [chunk_count, prototype.last_build_ms]
		)
	_update_performance()


func _update_performance() -> void:
	if performance_label == null or prototype.world_data == null:
		return
	var report := prototype.runtime_report()
	var budget: Dictionary = report["budget"]
	performance_label.text = (
		"%d chunks | %d near / %d far triangles | %d collision faces | %.1f MiB geometry\n"
		+ "logic %d ms%s | build %d ms | LOD %s at %.0f | desktop budget %s | target device %s"
	) % [
		int(report["chunk_count"]),
		int(report["terrain_triangle_count"]),
		int(report["terrain_far_triangle_count"]),
		int(report["collision_triangle_count"]),
		float(report["geometry_bytes"]) / 1048576.0,
		int(report["generation_ms"]),
		" (worker)" if bool(report["generated_off_main_thread"]) else "",
		int(report["build_ms"]),
		"on" if bool(report["terrain_lod_enabled"]) else "off",
		float(report["terrain_lod_distance"]),
		"ok" if bool(budget["within_desktop_budget"]) else "exceeded",
		"validated" if bool(budget["target_device_validated"]) else "not yet measured",
	]


func _select_metadata(option: OptionButton, value: String) -> void:
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == value:
			option.select(index)
			return
