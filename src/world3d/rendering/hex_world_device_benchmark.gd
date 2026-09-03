class_name HexWorldDeviceBenchmark
extends Node

## Phase 5 target-device benchmark protocol for the isolated 3D hex prototype.
##
## This is the repeatable procedure that produces a
## `HexWorldDeviceEvidence` document. It runs identically on desktop and on a
## handset so the two are directly comparable, but only a handset capture is
## device proof.
##
## For every requested tier the protocol:
##
## 1. generates the tier at the declared seed and style and records logical
##    generation and main-thread scene-build time;
## 2. discards `warmup_frames` so shader compilation, buffer upload, and the
##    first-frame cost of a camera move never enter a distribution;
## 3. holds each steady camera state still for a fixed sample window and
##    records the delivered frame-interval distribution, main-thread process
##    time, draw calls, and primitives;
## 4. exercises pause/resume and an orientation/size change and verifies the
##    world signature and the camera survived, sampling the recovery frames;
## 5. records the resident footprint the operating system has to keep alive.
##
## Camera states are held still on purpose. A moving camera measures the input
## and interpolation path, not the steady cost of the view a player reads, and
## it is not reproducible between runs or between devices.
##
## Honest measurement caveat, recorded in every document: on a vsync-locked
## handset the sampled interval is the *delivered* frame interval, quantised to
## the display refresh. It proves the pace target is met; it is not a GPU-cost
## measurement. `process_frame_ms`, `draw_calls`, and `primitives` are recorded
## alongside it because those are not refresh-quantised.

signal progress(stage: String, fraction: float)
signal finished(document: Dictionary)

const Evidence = preload("res://src/world3d/rendering/hex_world_device_evidence.gd")
const Budget = preload("res://src/world3d/rendering/hex_world_budget.gd")

## Protocol defaults. The declared minimums live in `HexWorldDeviceEvidence`;
## these are the values a real capture uses, comfortably above them.
const DEFAULT_WARMUP_FRAMES := 45
const DEFAULT_SAMPLE_FRAMES := 240
## A window closes only when both the frame count and this wall-clock duration
## are satisfied. On a fast host 240 frames arrive in well under a second, which
## is too short a slice of time to describe steady-state pacing or to catch a
## periodic hitch.
const DEFAULT_MINIMUM_SAMPLE_DURATION_MS := 3000.0
## Frames allowed for a camera move to settle before warm-up starts.
const DEFAULT_SETTLE_FRAMES := 12
const DEFAULT_RECOVERY_FRAMES := 90
const DEFAULT_SEED := 6
const DEFAULT_STYLE := "continents_and_islands"
## A reported main-thread process time may legitimately be marginally larger
## than the measured interval because the two counters are read at different
## points in the frame. Anything beyond this multiple is a stale engine counter,
## not a measurement, and is discarded.
const PROCESS_TIME_TOLERANCE := 1.5

## `framed_full_ecology` is the declared worst case: the strategy framing every
## player sits in, with batched vegetation pinned to full density instead of
## thinned by distance. It is what the Phase 4 primitive ceiling was set against.
const CAMERA_STATE_FRAMED := &"framed"
const CAMERA_STATE_FRAMED_FULL_ECOLOGY := &"framed_full_ecology"
const CAMERA_STATE_MID_ZOOM := &"mid_zoom"
const CAMERA_STATE_CLOSE := &"close"
const CAMERA_STATES: Array[StringName] = [
	CAMERA_STATE_FRAMED,
	CAMERA_STATE_FRAMED_FULL_ECOLOGY,
	CAMERA_STATE_MID_ZOOM,
	CAMERA_STATE_CLOSE,
]

var _cancelled := false


static func default_options() -> Dictionary:
	var profiles: Array[StringName] = []
	profiles.assign(Evidence.REQUIRED_PROFILE_IDS)
	return {
		"profiles": profiles,
		"seed": DEFAULT_SEED,
		"style": DEFAULT_STYLE,
		"warmup_frames": DEFAULT_WARMUP_FRAMES,
		"sample_frames": DEFAULT_SAMPLE_FRAMES,
		"minimum_sample_duration_ms": DEFAULT_MINIMUM_SAMPLE_DURATION_MS,
		"settle_frames": DEFAULT_SETTLE_FRAMES,
		"recovery_frames": DEFAULT_RECOVERY_FRAMES,
		# Godot exposes no thermal or battery API, so these are operator
		# declarations. An undeclared capture cannot validate.
		"thermal_precondition_met": false,
		"battery_percent": -1,
		"operator_note": "",
	}


func cancel() -> void:
	_cancelled = true


## Runs the full protocol and returns the evidence document. The caller keeps
## ownership of `prototype`; the benchmark restores its ecology override, vsync
## mode, and frame cap before returning.
func run(prototype: HexWorldPrototype, options: Dictionary = {}) -> Dictionary:
	_cancelled = false
	var resolved := default_options()
	for key in options:
		resolved[key] = options[key]

	var document := Evidence.empty_document()
	document["captured_at_utc"] = Time.get_datetime_string_from_system(true)
	document["device"] = Budget.device_identity()
	document["operator"] = {
		"thermal_precondition_met": bool(resolved["thermal_precondition_met"]),
		"battery_percent": int(resolved["battery_percent"]),
		"note": String(resolved["operator_note"]),
	}
	document["protocol"] = {
		"seed": int(resolved["seed"]),
		"style": String(resolved["style"]),
		"warmup_frames": int(resolved["warmup_frames"]),
		"sample_frames": int(resolved["sample_frames"]),
		"minimum_sample_duration_ms": float(resolved["minimum_sample_duration_ms"]),
		"settle_frames": int(resolved["settle_frames"]),
		"recovery_frames": int(resolved["recovery_frames"]),
		"camera_states": _state_names(),
		"measurement_caveat": (
			"Sampled intervals are delivered frame intervals. On a vsync-locked "
			+ "handset they are quantised to the display refresh, so they prove "
			+ "the pace target rather than the GPU cost. draw_calls and "
			+ "primitives are not refresh-quantised. process_frame_ms is "
			+ "supplementary: samples reporting more process time than the "
			+ "frame they occurred in are discarded as stale engine counters "
			+ "and counted in process_frame_samples_rejected, so a state whose "
			+ "samples were all rejected carries no process-time evidence."
		),
	}

	var display := _begin_measurement_window()
	document["device"]["screen_refresh_rate"] = display["screen_refresh_rate"]
	document["device"]["vsync_mode_requested"] = display["requested"]
	document["device"]["vsync_mode_effective"] = display["effective"]

	var profiles: Array = resolved["profiles"]
	var runs: Array[Dictionary] = []
	for index in profiles.size():
		if _cancelled:
			break
		var profile_id := StringName(String(profiles[index]))
		var base_fraction := float(index) / float(maxi(profiles.size(), 1))
		var span := 1.0 / float(maxi(profiles.size(), 1))
		var run := await _measure_profile(
			prototype,
			profile_id,
			resolved,
			base_fraction,
			span
		)
		runs.append(run)
	document["runs"] = runs
	_end_measurement_window(display)
	prototype.ecology_detail_override = -1.0

	document["evaluation"] = Evidence.evaluate_document(document)
	progress.emit("Benchmark complete", 1.0)
	finished.emit(document)
	return document


static func _state_names() -> PackedStringArray:
	var names := PackedStringArray()
	for state in CAMERA_STATES:
		names.append(String(state))
	return names


func _measure_profile(
	prototype: HexWorldPrototype,
	profile_id: StringName,
	resolved: Dictionary,
	base_fraction: float,
	span: float
) -> Dictionary:
	progress.emit("Generating %s" % profile_id, base_fraction)
	prototype.settings.seed = int(resolved["seed"])
	prototype.settings.map_size_profile = String(profile_id)
	prototype.settings.landform_style = String(resolved["style"])
	prototype.ecology_detail_override = -1.0
	prototype.regenerate()
	await _await_frames(1)

	var report := prototype.runtime_report()
	var camera_states: Array[Dictionary] = []
	for state_index in CAMERA_STATES.size():
		if _cancelled:
			break
		var state := CAMERA_STATES[state_index]
		var fraction := base_fraction + span * (
			0.2 + 0.6 * float(state_index) / float(CAMERA_STATES.size())
		)
		progress.emit("Sampling %s / %s" % [profile_id, state], fraction)
		camera_states.append(await _sample_camera_state(prototype, state, resolved))

	progress.emit("Lifecycle %s" % profile_id, base_fraction + span * 0.85)
	var lifecycle := {
		"pause_resume": await _measure_pause_resume(prototype, resolved),
		"orientation": await _measure_orientation(prototype, resolved),
	}

	return {
		"profile_id": String(profile_id),
		"seed": int(resolved["seed"]),
		"style": String(resolved["style"]),
		"generation_ms": int(report["generation_ms"]),
		"build_ms": int(report["build_ms"]),
		"geometry_bytes": int(report["geometry_bytes"]),
		"chunk_count": int(report["chunk_count"]),
		"terrain_triangle_count": int(report["terrain_triangle_count"]),
		"terrain_far_triangle_count": int(report["terrain_far_triangle_count"]),
		"collision_triangle_count": int(report["collision_triangle_count"]),
		"ecology_instance_count": int(report["ecology_instance_count"]),
		"warmup_frames": int(resolved["warmup_frames"]),
		"camera_states": camera_states,
		"lifecycle": lifecycle,
		"memory": _capture_memory(),
		"desktop_evaluation": report["budget"],
	}


## Holds one steady camera state, discards the warm-up, and records the sampled
## distribution. Nothing about the world changes inside the window.
func _sample_camera_state(
	prototype: HexWorldPrototype,
	state: StringName,
	resolved: Dictionary
) -> Dictionary:
	_apply_camera_state(prototype, state)
	await _await_frames(int(resolved["settle_frames"]))
	await _await_frames(int(resolved["warmup_frames"]))

	var frame_ms := PackedFloat64Array()
	var process_ms := PackedFloat64Array()
	var rejected_process_samples := 0
	var draw_calls := 0.0
	var primitives := 0.0
	var target_frames := int(resolved["sample_frames"])
	var minimum_duration_ms := float(resolved["minimum_sample_duration_ms"])
	var window_started := Time.get_ticks_usec()
	var previous := window_started
	# The window closes only when *both* the frame count and the minimum
	# duration are satisfied. A fast host reaches 240 frames in under a second,
	# which is too short a slice of time to describe steady-state pacing.
	while not _cancelled:
		var elapsed_ms := float(Time.get_ticks_usec() - window_started) / 1000.0
		if frame_ms.size() >= target_frames and elapsed_ms >= minimum_duration_ms:
			break
		await _await_frames(1)
		var now := Time.get_ticks_usec()
		var interval_ms := float(now - previous) / 1000.0
		frame_ms.append(interval_ms)
		previous = now
		# `Performance.TIME_PROCESS` is an engine counter that can stay stale
		# after an expensive frame, and a reported process time longer than the
		# frame it happened in is physically impossible. Those samples are
		# dropped and counted rather than silently averaged into the evidence.
		var reported_process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		if reported_process_ms <= interval_ms * PROCESS_TIME_TOLERANCE:
			process_ms.append(reported_process_ms)
		else:
			rejected_process_samples += 1
		draw_calls = maxf(
			draw_calls,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		)
		primitives = maxf(
			primitives,
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		)
	var duration_ms := float(Time.get_ticks_usec() - window_started) / 1000.0

	return {
		"name": String(state),
		"camera_height": prototype.strategy_camera.camera_height(),
		"ecology_detail_factor": prototype.ecology_detail_factor,
		"ecology_detail_pinned": prototype.ecology_detail_override >= 0.0,
		"sample_frames": frame_ms.size(),
		"sample_duration_ms": duration_ms,
		"frame_ms": summarise_samples(frame_ms),
		"process_frame_ms": summarise_samples(process_ms),
		"process_frame_samples": process_ms.size(),
		"process_frame_samples_rejected": rejected_process_samples,
		"draw_calls": int(draw_calls),
		"primitives": int(primitives),
	}


func _apply_camera_state(prototype: HexWorldPrototype, state: StringName) -> void:
	var camera := prototype.strategy_camera
	prototype.ecology_detail_override = -1.0
	match state:
		CAMERA_STATE_FRAMED:
			camera.reset_view()
		CAMERA_STATE_FRAMED_FULL_ECOLOGY:
			camera.reset_view()
			prototype.ecology_detail_override = 1.0
		CAMERA_STATE_MID_ZOOM:
			camera.reset_view()
			# The camera sits behind and above its focus, so the focus point has
			# to come from the camera rather than from its world position.
			camera.focus_on(
				camera.focus_position(),
				lerpf(camera.minimum_height, camera.camera_height(), 0.5),
				false
			)
		CAMERA_STATE_CLOSE:
			var tile := prototype.deterministic_focus_tile()
			if tile != null:
				camera.focus_on(tile.position, camera.minimum_height, false)
			else:
				camera.reset_view()
	prototype.update_ecology_detail()


## Pause/resume must preserve the logical world and restore the camera exactly.
## The transition is driven through the same engine notifications the operating
## system sends, so this exercises the shipped code path.
func _measure_pause_resume(
	prototype: HexWorldPrototype,
	resolved: Dictionary
) -> Dictionary:
	_apply_camera_state(prototype, CAMERA_STATE_MID_ZOOM)
	await _await_frames(int(resolved["settle_frames"]))
	var camera_before := prototype.strategy_camera.capture_state()
	var signature_before := _world_signature(prototype)

	prototype.notification(NOTIFICATION_APPLICATION_PAUSED)
	await _await_frames(2)
	prototype.notification(NOTIFICATION_APPLICATION_RESUMED)
	var recovery := await _sample_recovery(int(resolved["recovery_frames"]))

	var camera_after := prototype.strategy_camera.capture_state()
	return {
		"transition": "pause_resume",
		"method": "engine_notification",
		"camera_state_preserved": _camera_states_match(camera_before, camera_after),
		"world_signature_preserved": _world_signature(prototype) == signature_before,
		"recovery_frames": recovery["count"],
		"recovery_frame_ms_p95": recovery["p95"],
		"recovery_frame_ms_max": recovery["max"],
	}


## An orientation change is a viewport size change. Where the display server
## allows a resize the real thing is performed; where the operating system owns
## the window size, as on a handset, the engine notification the prototype
## responds to is dispatched directly and the document records which happened.
func _measure_orientation(
	prototype: HexWorldPrototype,
	resolved: Dictionary
) -> Dictionary:
	_apply_camera_state(prototype, CAMERA_STATE_FRAMED)
	await _await_frames(int(resolved["settle_frames"]))
	var camera_before := prototype.strategy_camera.capture_state()
	var signature_before := _world_signature(prototype)

	var method := "engine_notification"
	var original_size := Vector2i.ZERO
	var resized := false
	# Subwindow support is the practical proxy for "the application owns its
	# window size". A desktop host gets a real resize; a handset, where the
	# operating system owns it, gets the notification the prototype responds to
	# and the document says which happened.
	if DisplayServer.get_name() != "headless" and DisplayServer.has_feature(
		DisplayServer.FEATURE_SUBWINDOWS
	):
		original_size = DisplayServer.window_get_size()
		if original_size.x > 0 and original_size.y > 0:
			DisplayServer.window_set_size(Vector2i(original_size.y, original_size.x))
			method = "window_resize"
			resized = true
	prototype.notification(NOTIFICATION_WM_SIZE_CHANGED)
	await _await_frames(2)
	if resized:
		DisplayServer.window_set_size(original_size)
		prototype.notification(NOTIFICATION_WM_SIZE_CHANGED)
	var recovery := await _sample_recovery(int(resolved["recovery_frames"]))

	var camera_after := prototype.strategy_camera.capture_state()
	return {
		"transition": "orientation",
		"method": method,
		"camera_state_preserved": _camera_states_match(camera_before, camera_after),
		"world_signature_preserved": _world_signature(prototype) == signature_before,
		"recovery_frames": recovery["count"],
		"recovery_frame_ms_p95": recovery["p95"],
		"recovery_frame_ms_max": recovery["max"],
	}


func _sample_recovery(frame_count: int) -> Dictionary:
	var samples := PackedFloat64Array()
	var previous := Time.get_ticks_usec()
	while samples.size() < frame_count and not _cancelled:
		await _await_frames(1)
		var now := Time.get_ticks_usec()
		samples.append(float(now - previous) / 1000.0)
		previous = now
	var summary := summarise_samples(samples)
	return {
		"count": samples.size(),
		"p95": float(summary["p95"]),
		"max": float(summary["max"]),
	}


static func summarise_samples(samples: PackedFloat64Array) -> Dictionary:
	if samples.is_empty():
		return {"min": 0.0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var total := 0.0
	var minimum := samples[0]
	var maximum := samples[0]
	for value in samples:
		total += value
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	return {
		"min": minimum,
		"mean": total / float(samples.size()),
		"p50": Evidence.percentile(samples, 0.5),
		"p95": Evidence.percentile(samples, 0.95),
		"p99": Evidence.percentile(samples, 0.99),
		"max": maximum,
	}


func _capture_memory() -> Dictionary:
	var memory_info := OS.get_memory_info()
	return {
		"static_memory_bytes": OS.get_static_memory_usage(),
		"static_memory_peak_bytes": OS.get_static_memory_peak_usage(),
		"video_memory_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		"texture_memory_bytes": Performance.get_monitor(
			Performance.RENDER_TEXTURE_MEM_USED
		),
		"buffer_memory_bytes": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED),
		"object_node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"available_memory_bytes": int(memory_info.get("available", 0)),
	}


static func _world_signature(prototype: HexWorldPrototype) -> String:
	if prototype.world_data == null:
		return ""
	return "%s|%s|%s|%s" % [
		prototype.world_data.deterministic_signature(),
		prototype.world_data.climate_signature(),
		prototype.world_data.hydrology_signature(),
		prototype.world_data.ecology_signature(),
	]


static func _camera_states_match(first: Dictionary, second: Dictionary) -> bool:
	for key in first:
		if not second.has(key):
			return false
		var a: Variant = first[key]
		var b: Variant = second[key]
		if a is float:
			if not is_equal_approx(float(a), float(b)):
				return false
		elif a is Vector3:
			if not (a as Vector3).is_equal_approx(b as Vector3):
				return false
		elif a != b:
			return false
	return true


## Removes the frame cap and requests vsync off so the sampled interval is the
## pace the device can actually deliver rather than the pace it is throttled to.
## The handset may ignore the request; the effective mode is recorded either way.
func _begin_measurement_window() -> Dictionary:
	var state := {
		"previous_max_fps": Engine.max_fps,
		"previous_vsync": -1,
		"requested": "disabled",
		"effective": "unknown",
		"screen_refresh_rate": 0.0,
	}
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		state["previous_vsync"] = int(DisplayServer.window_get_vsync_mode())
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		state["effective"] = _vsync_name(int(DisplayServer.window_get_vsync_mode()))
		state["screen_refresh_rate"] = DisplayServer.screen_get_refresh_rate()
	return state


func _end_measurement_window(state: Dictionary) -> void:
	Engine.max_fps = int(state.get("previous_max_fps", 0))
	var previous_vsync := int(state.get("previous_vsync", -1))
	if previous_vsync >= 0 and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(previous_vsync as DisplayServer.VSyncMode)


static func _vsync_name(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "disabled"
		DisplayServer.VSYNC_ENABLED:
			return "enabled"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		DisplayServer.VSYNC_MAILBOX:
			return "mailbox"
	return "unknown"


func _await_frames(count: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for _index in maxi(count, 0):
		await tree.process_frame
