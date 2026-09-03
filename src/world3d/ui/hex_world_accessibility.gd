class_name HexWorldAccessibility
extends RefCounted

## Phase 5 accessibility support for the isolated 3D hex prototype.
##
## Covers the four review areas: terrain contrast, diagnostic palettes, labels,
## and touch targets. Contrast uses the WCAG relative-luminance formula so the
## numbers reported by the review are comparable with the rest of the product.

## Minimum comfortable touch target on a handset, in logical pixels.
const MINIMUM_TOUCH_TARGET := 44.0
## WCAG AA for normal-size interface text.
const MINIMUM_TEXT_CONTRAST := 4.5
## Two categorical map colours that can sit on neighbouring hexes must be
## separable by luminance, not only by hue. This is the ratio the Phase 5
## high-contrast diagnostic palettes are held to.
const MINIMUM_ADJACENT_CONTRAST := 1.45
## A sparse marker colour is read against the neutral map background around it,
## so it is held to a stronger figure/ground ratio instead.
const MINIMUM_MARKER_BACKGROUND_CONTRAST := 3.0

const PALETTE_STANDARD := &"standard"
const PALETTE_HIGH_CONTRAST := &"high_contrast"


## The prototype terrain material consumes authored diagnostic colours as
## linear values, so what reaches the screen is the sRGB encoding of the
## authored channel. Palettes must therefore be audited on the displayed
## colour, not on the authored hex, or the measured ratio will be optimistic.
static func displayed_color(color: Color) -> Color:
	return color.linear_to_srgb()


static func relative_luminance(color: Color) -> float:
	return (
		0.2126 * _linearize(color.r)
		+ 0.7152 * _linearize(color.g)
		+ 0.0722 * _linearize(color.b)
	)


static func contrast_ratio(first: Color, second: Color) -> float:
	var a := relative_luminance(first)
	var b := relative_luminance(second)
	var lighter := maxf(a, b)
	var darker := minf(a, b)
	return (lighter + 0.05) / (darker + 0.05)


## Reports the weakest pair in a categorical palette. `entries` maps a category
## label to a `Color`.
static func audit_palette(
	entries: Dictionary,
	minimum := MINIMUM_ADJACENT_CONTRAST,
	as_displayed := true
) -> Dictionary:
	var labels: Array = entries.keys()
	var minimum_contrast := INF
	var weakest := PackedStringArray()
	var failing: Array[Dictionary] = []
	for first_index in range(labels.size()):
		for second_index in range(first_index + 1, labels.size()):
			var first_label := str(labels[first_index])
			var second_label := str(labels[second_index])
			var ratio := contrast_ratio(
				_resolve(entries[labels[first_index]], as_displayed),
				_resolve(entries[labels[second_index]], as_displayed)
			)
			if ratio < minimum_contrast:
				minimum_contrast = ratio
				weakest = PackedStringArray([first_label, second_label])
			if ratio < minimum:
				failing.append({
					"first": first_label,
					"second": second_label,
					"contrast": ratio,
				})
	if labels.size() < 2:
		minimum_contrast = INF
	return {
		"entry_count": labels.size(),
		"minimum_contrast": minimum_contrast,
		"weakest_pair": weakest,
		"failing_pairs": failing,
		"passes": failing.is_empty(),
		"minimum_required": minimum,
	}


## Sparse markers are read against the surrounding neutral map colour rather
## than against each other, so they are audited against the backgrounds they
## actually appear on.
static func audit_against_background(
	entries: Dictionary,
	backgrounds: Array,
	minimum := MINIMUM_MARKER_BACKGROUND_CONTRAST,
	as_displayed := true
) -> Dictionary:
	var minimum_contrast := INF
	var weakest := PackedStringArray()
	var failing: Array[Dictionary] = []
	for label in entries:
		for background_value in backgrounds:
			var ratio := contrast_ratio(
				_resolve(entries[label], as_displayed),
				_resolve(background_value as Color, as_displayed)
			)
			if ratio < minimum_contrast:
				minimum_contrast = ratio
				weakest = PackedStringArray([
					str(label),
					(background_value as Color).to_html(false),
				])
			if ratio < minimum:
				failing.append({
					"entry": str(label),
					"background": (background_value as Color).to_html(false),
					"contrast": ratio,
				})
	if entries.is_empty() or backgrounds.is_empty():
		minimum_contrast = INF
	return {
		"entry_count": entries.size(),
		"minimum_contrast": minimum_contrast,
		"weakest_pair": weakest,
		"failing_pairs": failing,
		"passes": failing.is_empty(),
		"minimum_required": minimum,
	}


## Enforces the minimum touch target on an interactive control and gives it an
## accessible name and description. Every Phase 5 lab control goes through here.
static func apply_touch_target(
	control: Control,
	accessible_name := "",
	description := ""
) -> void:
	if control == null:
		return
	control.custom_minimum_size = Vector2(
		maxf(control.custom_minimum_size.x, MINIMUM_TOUCH_TARGET),
		maxf(control.custom_minimum_size.y, MINIMUM_TOUCH_TARGET)
	)
	if not accessible_name.is_empty():
		control.tooltip_text = accessible_name if description.is_empty() else (
			"%s — %s" % [accessible_name, description]
		)


static func meets_touch_target(control: Control) -> bool:
	if control == null:
		return false
	var size := control.get_combined_minimum_size()
	return (
		size.x >= MINIMUM_TOUCH_TARGET - 0.01
		and size.y >= MINIMUM_TOUCH_TARGET - 0.01
	)


## Human-readable label for a logical tile, used by the picking readout and by
## screen-reader style tooltips.
static func tile_label(tile: HexTileData) -> String:
	if tile == null:
		return "No tile"
	if tile.is_water:
		return "%s water at %d, %d" % [
			"Lake" if tile.lake_id >= 0 else "Ocean",
			tile.coordinate.x,
			tile.coordinate.y,
		]
	var parts := PackedStringArray()
	parts.append(String(tile.biome).replace("_", " ").capitalize())
	parts.append("elevation %d" % tile.elevation_level)
	if not String(tile.feature_type).is_empty():
		parts.append(String(tile.feature_type).replace("_", " "))
	if not String(tile.resource_type).is_empty():
		parts.append("%s deposit" % String(tile.resource_type))
	if tile.lake_id >= 0:
		parts.append("lakeside")
	return "%s at %d, %d" % [
		", ".join(parts),
		tile.coordinate.x,
		tile.coordinate.y,
	]


static func _resolve(color: Color, as_displayed: bool) -> Color:
	return displayed_color(color) if as_displayed else color


static func _linearize(channel: float) -> float:
	if channel <= 0.03928:
		return channel / 12.92
	return pow((channel + 0.055) / 1.055, 2.4)
