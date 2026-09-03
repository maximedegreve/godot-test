class_name StrategyCamera3D
extends Camera3D

## Phase 5 strategy camera.
##
## Bounds, zoom limits, and pan speed are derived from the framed world, so the
## same behaviour is correct at Small and at Ultra without per-tier tuning
## constants. Zoom is anchored: the world point under the cursor or under the
## pinch midpoint stays put, which is what direct manipulation on a touch screen
## should do. A press that does not move is reported as a tap rather than
## swallowed, so picking and camera control share one gesture stream.

signal tapped(screen_position: Vector2)
signal view_changed

## Minimum height as a multiple of `hex_size`, and the absolute floor.
const MINIMUM_HEIGHT_HEX_FACTOR := 7.0
const MINIMUM_HEIGHT_FLOOR := 8.0
## How far past the framed height the player may zoom out.
const MAXIMUM_HEIGHT_FRAME_FACTOR := 1.35
## Framed height as a fraction of the larger world dimension.
const FRAME_HEIGHT_FACTOR := 0.72
## Focus may leave the world by this multiple of `hex_size` so edge tiles can be
## centred, but never far enough to lose the map.
const FOCUS_MARGIN_HEX_FACTOR := 6.0
## A press that moves less than this many pixels is a tap, not a drag.
const TAP_MOVEMENT_TOLERANCE := 12.0
const TAP_DURATION_LIMIT_MS := 450
const GESTURE_SCROLL_ZOOM_SCALE := 0.035
const MAX_GESTURE_ZOOM_STEP := 0.24
const SCROLL_MOMENTUM_SUPPRESSION_MS := 300

@export_range(2.0, 200.0, 0.5) var pan_speed := 34.0
@export_range(0.1, 4.0, 0.05) var zoom_speed := 0.16
@export_range(8.0, 300.0, 1.0) var minimum_height := 18.0
@export_range(10.0, 600.0, 1.0) var maximum_height := 180.0
@export_range(0.0, 2.0, 0.01) var focus_duration := 0.35

var _focus := Vector3.ZERO
var _height := 70.0
var _bounds := AABB()
var _hex_size := 1.0
var _framed_focus := Vector3.ZERO
var _framed_height := 70.0
var _touch_positions: Dictionary = {}
var _pinch_distance := 0.0
var _pinch_midpoint := Vector2.ZERO
var _press_origin := Vector2.ZERO
var _press_started_ms := 0
var _press_moved := false
var _press_active := false
var _mouse_panning := false
var _focus_animating := false
var _focus_from := Vector3.ZERO
var _focus_to := Vector3.ZERO
var _height_from := 0.0
var _height_to := 0.0
var _focus_elapsed := 0.0
var _pointer_input_exclusions: Array[Control] = []
var _scroll_zoom_suppressed_until_ms := 0


func _ready() -> void:
	_update_transform()


func _process(delta: float) -> void:
	if _focus_animating:
		_advance_focus_animation(delta)
		return
	var movement := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		movement.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		movement.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		movement.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		movement.y += 1.0
	if movement != Vector2.ZERO:
		movement = movement.normalized() * pan_speed * (_height / 70.0) * delta
		_focus.x += movement.x
		_focus.z += movement.y
		_clamp_focus()
		_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	var pointer_input_excluded := (
		event is InputEventMouse
		and pointer_input_is_excluded(event.position)
	) or (
		event is InputEventGesture
		and pointer_input_is_excluded(event.position)
	)
	if pointer_input_excluded:
		if _is_scroll_zoom_event(event):
			suppress_scroll_zoom()
		return
	if handle_touch_event(event):
		get_viewport().set_input_as_handled()
		return
	if handle_mouse_event(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Q:
			_zoom(zoom_speed)
		elif event.keycode == KEY_E:
			_zoom(-zoom_speed)


func add_pointer_input_exclusion(control: Control) -> void:
	if control != null and not _pointer_input_exclusions.has(control):
		_pointer_input_exclusions.append(control)


func suppress_scroll_zoom() -> void:
	_scroll_zoom_suppressed_until_ms = (
		Time.get_ticks_msec() + SCROLL_MOMENTUM_SUPPRESSION_MS
	)


func pointer_input_is_excluded(screen_position: Vector2) -> bool:
	for index in range(_pointer_input_exclusions.size() - 1, -1, -1):
		var control := _pointer_input_exclusions[index]
		if not is_instance_valid(control):
			_pointer_input_exclusions.remove_at(index)
			continue
		if control.visible and control.get_global_rect().has_point(screen_position):
			return true
	return false


## Mouse mirrors the touch behaviour: drag to pan, wheel to zoom toward the
## cursor, click without movement to pick.
func handle_mouse_event(event: InputEvent) -> bool:
	if (
		_is_scroll_zoom_event(event)
		and Time.get_ticks_msec() < _scroll_zoom_suppressed_until_ms
	):
		suppress_scroll_zoom()
		return true
	if event is InputEventPanGesture:
		if absf(event.delta.y) <= 0.001:
			return false
		var zoom_amount := clampf(
			event.delta.y * GESTURE_SCROLL_ZOOM_SCALE,
			-MAX_GESTURE_ZOOM_STEP,
			MAX_GESTURE_ZOOM_STEP
		)
		zoom_at(zoom_amount, event.position)
		return true
	if event is InputEventMagnifyGesture:
		if event.factor <= 0.0 or is_equal_approx(event.factor, 1.0):
			return false
		var zoom_amount := clampf(
			1.0 / event.factor - 1.0,
			-MAX_GESTURE_ZOOM_STEP,
			MAX_GESTURE_ZOOM_STEP
		)
		zoom_at(zoom_amount, event.position)
		return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_at(-zoom_speed, event.position)
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_at(zoom_speed, event.position)
			return true
		if event.button_index != MOUSE_BUTTON_LEFT:
			return false
		if event.pressed:
			_begin_press(event.position)
			_mouse_panning = true
			return true
		var was_panning := _mouse_panning
		_mouse_panning = false
		return _end_press(event.position) or was_panning
	if event is InputEventMouseMotion and _mouse_panning:
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_mouse_panning = false
			_press_active = false
			return false
		_track_press_movement(event.position)
		if _press_moved:
			_pan_screen_delta(event.relative)
		return true
	return false


func _is_scroll_zoom_event(event: InputEvent) -> bool:
	if event is InputEventPanGesture:
		return true
	return (
		event is InputEventMouseButton
		and event.button_index in [
			MOUSE_BUTTON_WHEEL_UP,
			MOUSE_BUTTON_WHEEL_DOWN,
		]
	)


func handle_touch_event(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_positions[event.index] = event.position
			if _touch_positions.size() == 1:
				_begin_press(event.position)
			else:
				_press_active = false
			_reset_pinch_reference()
			return true
		_touch_positions.erase(event.index)
		_reset_pinch_reference()
		_end_press(event.position)
		return true
	if not event is InputEventScreenDrag:
		return false
	if not _touch_positions.has(event.index):
		return false
	_touch_positions[event.index] = event.position
	_track_press_movement(event.position)
	if _touch_positions.size() == 1:
		if _press_moved:
			_pan_screen_delta(event.relative)
		_reset_pinch_reference()
		return true
	if _touch_positions.size() >= 2:
		_press_active = false
		var pair := _first_touch_pair()
		var first: Vector2 = pair[0]
		var second: Vector2 = pair[1]
		var distance := first.distance_to(second)
		var midpoint := (first + second) * 0.5
		if _pinch_distance > 0.001 and distance > 0.001:
			var anchor: Variant = _world_point_at(midpoint)
			_set_height(_height * (_pinch_distance / distance))
			_pan_screen_delta(midpoint - _pinch_midpoint)
			_restore_anchor(anchor, midpoint)
			_update_transform()
		_pinch_distance = distance
		_pinch_midpoint = midpoint
		return true
	return false


func frame_world(bounds: AABB, hex_size := 1.0) -> void:
	_bounds = bounds
	_hex_size = maxf(hex_size, 0.01)
	_focus = bounds.get_center()
	_focus.y = 0.0
	var framed := maxf(bounds.size.x, bounds.size.z) * FRAME_HEIGHT_FACTOR
	minimum_height = maxf(_hex_size * MINIMUM_HEIGHT_HEX_FACTOR, MINIMUM_HEIGHT_FLOOR)
	maximum_height = maxf(
		framed * MAXIMUM_HEIGHT_FRAME_FACTOR,
		minimum_height + 1.0
	)
	_height = clampf(framed, minimum_height, maximum_height)
	_framed_focus = _focus
	_framed_height = _height
	_focus_animating = false
	_update_transform()


## Smoothly centres a world position, optionally changing the zoom level.
func focus_on(position: Vector3, height := -1.0, animated := true) -> void:
	var target := position
	target.y = 0.0
	var target_height := _height if height <= 0.0 else clampf(
		height,
		minimum_height,
		maximum_height
	)
	if not animated or focus_duration <= 0.0:
		_focus = target
		_height = target_height
		_focus_animating = false
		_clamp_focus()
		_update_transform()
		return
	_focus_from = _focus
	_focus_to = target
	_height_from = _height
	_height_to = target_height
	_focus_elapsed = 0.0
	_focus_animating = true


func focus_on_tile(tile: HexTileData, height := -1.0, animated := true) -> void:
	if tile == null:
		return
	focus_on(tile.position, height, animated)


func is_focusing() -> bool:
	return _focus_animating


## Restores the framed view without discarding the configured bounds.
func reset_view() -> void:
	_focus = _framed_focus
	_height = _framed_height
	_focus_animating = false
	_update_transform()


func zoom_in() -> void:
	_zoom(-zoom_speed)


func zoom_out() -> void:
	_zoom(zoom_speed)


func zoom_at(amount: float, screen_position: Vector2) -> void:
	var anchor: Variant = _world_point_at(screen_position)
	_set_height(_height * (1.0 + amount))
	_restore_anchor(anchor, screen_position)
	_update_transform()


func pan_view(direction: Vector2) -> void:
	if direction.is_zero_approx():
		return
	var distance := pan_speed * (_height / 70.0) * 0.35
	var normalized := direction.normalized()
	_focus.x += normalized.x * distance
	_focus.z += normalized.y * distance
	_focus_animating = false
	_clamp_focus()
	_update_transform()


func focus_position() -> Vector3:
	return _focus


func camera_height() -> float:
	return _height


func world_bounds() -> AABB:
	return _bounds


## Normalised zoom, 0 fully zoomed in and 1 fully zoomed out.
func zoom_ratio() -> float:
	var span := maxf(maximum_height - minimum_height, 0.001)
	return clampf((_height - minimum_height) / span, 0.0, 1.0)


## Serialisable camera state for pause/resume and orientation changes.
func capture_state() -> Dictionary:
	return {
		"focus": _focus,
		"height": _height,
		"bounds_position": _bounds.position,
		"bounds_size": _bounds.size,
		"hex_size": _hex_size,
		"framed_focus": _framed_focus,
		"framed_height": _framed_height,
	}


func restore_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	_bounds = AABB(
		state.get("bounds_position", Vector3.ZERO),
		state.get("bounds_size", Vector3.ZERO)
	)
	_hex_size = maxf(float(state.get("hex_size", 1.0)), 0.01)
	if _bounds.size != Vector3.ZERO:
		var framed := maxf(_bounds.size.x, _bounds.size.z) * FRAME_HEIGHT_FACTOR
		minimum_height = maxf(_hex_size * MINIMUM_HEIGHT_HEX_FACTOR, MINIMUM_HEIGHT_FLOOR)
		maximum_height = maxf(framed * MAXIMUM_HEIGHT_FRAME_FACTOR, minimum_height + 1.0)
	_framed_focus = state.get("framed_focus", _framed_focus)
	_framed_height = float(state.get("framed_height", _framed_height))
	_focus = state.get("focus", _focus)
	_height = clampf(float(state.get("height", _height)), minimum_height, maximum_height)
	_focus_animating = false
	_clamp_focus()
	_update_transform()


func _advance_focus_animation(delta: float) -> void:
	_focus_elapsed += delta
	var progress := clampf(_focus_elapsed / maxf(focus_duration, 0.0001), 0.0, 1.0)
	var eased := progress * progress * (3.0 - 2.0 * progress)
	_focus = _focus_from.lerp(_focus_to, eased)
	_height = lerpf(_height_from, _height_to, eased)
	if progress >= 1.0:
		_focus_animating = false
	_clamp_focus()
	_update_transform()


func _zoom(amount: float) -> void:
	_set_height(_height * (1.0 + amount))
	_update_transform()


func _set_height(value: float) -> void:
	_height = clampf(value, minimum_height, maximum_height)
	_focus_animating = false


func _begin_press(position: Vector2) -> void:
	_press_active = true
	_press_moved = false
	_press_origin = position
	_press_started_ms = Time.get_ticks_msec()


func _track_press_movement(position: Vector2) -> void:
	if not _press_active:
		return
	if position.distance_to(_press_origin) > TAP_MOVEMENT_TOLERANCE:
		_press_moved = true


func _end_press(position: Vector2) -> bool:
	if not _press_active:
		return false
	_press_active = false
	if _press_moved:
		return false
	if position.distance_to(_press_origin) > TAP_MOVEMENT_TOLERANCE:
		return false
	if Time.get_ticks_msec() - _press_started_ms > TAP_DURATION_LIMIT_MS:
		return false
	tapped.emit(position)
	return true


func _pan_screen_delta(delta: Vector2) -> void:
	var world_per_pixel := _height / maxf(float(get_viewport().get_visible_rect().size.y), 1.0)
	_focus.x -= delta.x * world_per_pixel
	_focus.z -= delta.y * world_per_pixel
	_focus_animating = false
	_clamp_focus()
	_update_transform()


func _world_point_at(screen_position: Vector2) -> Variant:
	if not is_inside_tree():
		return null
	var origin := project_ray_origin(screen_position)
	var direction := project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return null
	var distance := -origin.y / direction.y
	if distance < 0.0:
		return null
	return origin + direction * distance


func _restore_anchor(anchor: Variant, screen_position: Vector2) -> void:
	if anchor == null:
		return
	_update_transform()
	var current: Variant = _world_point_at(screen_position)
	if current == null:
		return
	var shift: Vector3 = (anchor as Vector3) - (current as Vector3)
	_focus.x += shift.x
	_focus.z += shift.z
	_clamp_focus()


func _first_touch_pair() -> Array[Vector2]:
	var indices: Array = _touch_positions.keys()
	indices.sort()
	return [
		_touch_positions[indices[0]] as Vector2,
		_touch_positions[indices[1]] as Vector2,
	]


func _reset_pinch_reference() -> void:
	_pinch_distance = 0.0
	_pinch_midpoint = Vector2.ZERO
	if _touch_positions.size() < 2:
		return
	var pair := _first_touch_pair()
	_pinch_distance = pair[0].distance_to(pair[1])
	_pinch_midpoint = (pair[0] + pair[1]) * 0.5


func _clamp_focus() -> void:
	if _bounds.size == Vector3.ZERO:
		return
	var margin := _hex_size * FOCUS_MARGIN_HEX_FACTOR
	_focus.x = clampf(_focus.x, _bounds.position.x - margin, _bounds.end.x + margin)
	_focus.z = clampf(_focus.z, _bounds.position.z - margin, _bounds.end.z + margin)


func _update_transform() -> void:
	position = _focus + Vector3(0.0, _height, _height * 0.66)
	look_at(_focus, Vector3.UP)
	view_changed.emit()
