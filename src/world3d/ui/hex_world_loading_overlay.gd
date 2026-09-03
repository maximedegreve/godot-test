class_name HexWorldLoadingOverlay
extends PanelContainer

## Phase 5 loading feedback for the isolated 3D hex prototype.
##
## The overlay reports the current stage and a coarse progress fraction while a
## world is generated or rebuilt. It stays cheap: two labels and a progress bar,
## created once, shown and hidden rather than rebuilt.

var title_label: Label
var stage_label: Label
var progress_bar: ProgressBar

var _stages: PackedStringArray = PackedStringArray()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#0e141aee")
	style.border_color = Color("#caa85a")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	add_theme_stylebox_override("panel", style)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layout)

	title_label = Label.new()
	title_label.text = "Generating world"
	title_label.add_theme_color_override("font_color", Color("#f2dfaa"))
	title_label.add_theme_font_size_override("font_size", 18)
	layout.add_child(title_label)

	stage_label = Label.new()
	stage_label.text = "Preparing"
	stage_label.add_theme_color_override("font_color", Color("#c6d2d8"))
	layout.add_child(stage_label)

	progress_bar = ProgressBar.new()
	progress_bar.min_value = 0.0
	progress_bar.max_value = 1.0
	progress_bar.value = 0.0
	progress_bar.show_percentage = false
	progress_bar.custom_minimum_size = Vector2(280.0, 10.0)
	layout.add_child(progress_bar)

	hide()


func begin(title: String) -> void:
	_stages = PackedStringArray()
	if title_label != null:
		title_label.text = title
	report("Preparing", 0.0)
	show()


func report(stage: String, progress: float) -> void:
	_stages.append(stage)
	if stage_label != null:
		stage_label.text = stage
	if progress_bar != null:
		progress_bar.value = clampf(progress, 0.0, 1.0)


func finish() -> void:
	report("Ready", 1.0)
	hide()


func reported_stages() -> PackedStringArray:
	return _stages
