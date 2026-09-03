class_name HexWorldDeviceEvidence
extends RefCounted

## Phase 5 target-device evidence schema, validation, and validation gating for
## the isolated 3D hex prototype.
##
## `HexWorldBudget` declares what the target device must achieve.  This script
## declares what counts as *proof* that it did, and it is deliberately strict:
##
## * a document must match the schema and the protocol version it claims;
## * it must come from a real mobile platform, never from desktop Forward
##   Mobile, which is why `is_mobile_platform` is a hard criterion;
## * it must cover every tier and every declared camera state with enough
##   samples that a single lucky frame cannot carry the verdict;
## * it must show that pause/resume and orientation transitions preserved the
##   world and the camera;
## * and every declared criterion must pass before the verdict is `validated`.
##
## `HexWorldBudget.TARGET_DEVICE_VALIDATED` is asserted by the suite to equal
## `repository_verdict()["validated"]`, so the constant cannot be flipped true
## without committed evidence that clears every criterion here, and cannot be
## left false once such evidence exists.

const Budget = preload("res://src/world3d/rendering/hex_world_budget.gd")

const SCHEMA_ID := "the-last-crown.hex-world.device-evidence"
const SCHEMA_VERSION := 1
## Bumped whenever the measurement procedure changes in a way that makes older
## captures non-comparable. Evidence from an older protocol never validates.
const PROTOCOL_VERSION := 1

## Committed review evidence. Absent by default: no handset capture has been
## accepted yet, so the verdict is unvalidated and the budget constant is false.
const REPOSITORY_EVIDENCE_PATH := (
	"res://docs/device-evidence/hex_world_target_device_evidence.json"
)

const REQUIRED_PROFILE_IDS: Array[StringName] = [
	&"small",
	&"medium",
	&"large",
	&"ultra",
]
## The three steady camera states the protocol samples. `framed` is the
## strategy view a player sits in, `mid_zoom` is the transitional read, and
## `close` is the worst case: minimum height over the most detailed terrain
## with ecology at full density.
const REQUIRED_CAMERA_STATES: Array[StringName] = [
	&"framed",
	&"mid_zoom",
	&"close",
]
## A camera state must contribute at least this many sampled frames and this
## much wall-clock time before it may support a verdict.
const MINIMUM_STATE_SAMPLE_FRAMES := 60
const MINIMUM_STATE_SAMPLE_MS := 1000.0
## Frames discarded before each state so shader compilation, buffer upload, and
## the first-frame cost of a camera move never land in the distribution.
const MINIMUM_WARMUP_FRAMES := 20

const CRITERION_SCHEMA := &"schema"
const CRITERION_PROTOCOL := &"protocol_version"
const CRITERION_MOBILE_PLATFORM := &"mobile_platform"
const CRITERION_TIER_COVERAGE := &"tier_coverage"
const CRITERION_SAMPLE_SIZE := &"sample_size"
const CRITERION_GENERATION_TIME := &"generation_time"
const CRITERION_BUILD_TIME := &"build_time"
const CRITERION_GEOMETRY := &"geometry_bytes"
const CRITERION_RESIDENT_MEMORY := &"resident_memory"
const CRITERION_FRAME_PACING := &"frame_pacing"
const CRITERION_FRAME_HITCH := &"frame_hitch"
const CRITERION_LIFECYCLE := &"lifecycle"
const CRITERION_ORIENTATION := &"orientation"
const CRITERION_THERMAL_PRECONDITION := &"thermal_precondition"

const CRITERION_IDS: Array[StringName] = [
	CRITERION_SCHEMA,
	CRITERION_PROTOCOL,
	CRITERION_MOBILE_PLATFORM,
	CRITERION_TIER_COVERAGE,
	CRITERION_SAMPLE_SIZE,
	CRITERION_GENERATION_TIME,
	CRITERION_BUILD_TIME,
	CRITERION_GEOMETRY,
	CRITERION_RESIDENT_MEMORY,
	CRITERION_FRAME_PACING,
	CRITERION_FRAME_HITCH,
	CRITERION_LIFECYCLE,
	CRITERION_ORIENTATION,
	CRITERION_THERMAL_PRECONDITION,
]

## Platforms that count as target mobile hardware. Desktop Forward Mobile is
## deliberately excluded no matter how the renderer is configured.
const MOBILE_OS_NAMES := ["ios", "android"]


static func criterion_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(CRITERION_IDS)
	return result


## Ascending-sorted percentile with linear index selection. `quantile` is a
## fraction, so 0.95 returns the p95 sample.
static func percentile(values: PackedFloat64Array, quantile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := int(ceil(clampf(quantile, 0.0, 1.0) * float(sorted.size()))) - 1
	return sorted[clampi(index, 0, sorted.size() - 1)]


static func empty_document() -> Dictionary:
	return {
		"schema": SCHEMA_ID,
		"schema_version": SCHEMA_VERSION,
		"protocol_version": PROTOCOL_VERSION,
		"captured_at_utc": "",
		"device": {},
		"operator": {},
		"runs": [],
	}


## Structural validation. Answers "is this a well-formed evidence document?",
## never "does the hardware pass?".
static func validate_document(document: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	if String(document.get("schema", "")) != SCHEMA_ID:
		errors.append("The document is not a 3D hex-world device evidence schema.")
	var schema_version := int(document.get("schema_version", 0))
	if schema_version != SCHEMA_VERSION:
		errors.append(
			"Unsupported evidence schema version %d; this build reads version %d."
			% [schema_version, SCHEMA_VERSION]
		)
	if not document.has("device") or not (document.get("device") is Dictionary):
		errors.append("The document is missing its device block.")
	if not document.has("runs") or not (document.get("runs") is Array):
		errors.append("The document is missing its per-tier run array.")
	else:
		var runs: Array = document["runs"]
		for index in runs.size():
			if not (runs[index] is Dictionary):
				errors.append("Run %d is not a measurement record." % index)
				continue
			var run: Dictionary = runs[index]
			for key in [
				"profile_id",
				"seed",
				"style",
				"generation_ms",
				"build_ms",
				"geometry_bytes",
				"camera_states",
				"lifecycle",
				"memory",
			]:
				if not run.has(key):
					errors.append(
						"Run %d is missing the required field '%s'." % [index, key]
					)
			if run.has("camera_states") and not (run["camera_states"] is Array):
				errors.append("Run %d does not record camera states as an array." % index)
	return {"ok": errors.is_empty(), "errors": errors}


## Applies every declared criterion. Returns the per-criterion verdicts and the
## single `validated` answer the budget gate consumes.
static func evaluate_document(document: Dictionary) -> Dictionary:
	var results: Array[Dictionary] = []
	var structure := validate_document(document)
	results.append(_criterion(
		CRITERION_SCHEMA,
		bool(structure["ok"]),
		(
			"The evidence document matches schema %s v%d." % [SCHEMA_ID, SCHEMA_VERSION]
			if bool(structure["ok"])
			else "; ".join(structure["errors"])
		)
	))
	if not bool(structure["ok"]):
		return _summarise(results, document)

	var protocol_version := int(document.get("protocol_version", 0))
	results.append(_criterion(
		CRITERION_PROTOCOL,
		protocol_version == PROTOCOL_VERSION,
		"Captured with protocol version %d; this build requires %d."
		% [protocol_version, PROTOCOL_VERSION]
	))

	var device: Dictionary = document.get("device", {})
	var os_name := String(device.get("os_name", "")).to_lower()
	var is_mobile := bool(device.get("is_mobile_platform", false))
	results.append(_criterion(
		CRITERION_MOBILE_PLATFORM,
		is_mobile and MOBILE_OS_NAMES.has(os_name),
		(
			"Captured on %s (%s)." % [device.get("os_name", "?"), device.get("model_name", "?")]
			if is_mobile and MOBILE_OS_NAMES.has(os_name)
			else (
				"Captured on '%s', which is not target mobile hardware. "
				% device.get("os_name", "?")
				+ "Desktop Forward Mobile is not device proof."
			)
		)
	))

	var runs_by_profile := {}
	for entry in document.get("runs", []):
		if entry is Dictionary:
			runs_by_profile[StringName(String(entry.get("profile_id", "")))] = entry
	var missing_profiles := PackedStringArray()
	for profile_id in REQUIRED_PROFILE_IDS:
		if not runs_by_profile.has(profile_id):
			missing_profiles.append(String(profile_id))
	var coverage_detail := "All four tiers were captured."
	var coverage_ok := missing_profiles.is_empty()
	if not coverage_ok:
		coverage_detail = "Missing tiers: %s." % ", ".join(missing_profiles)
	else:
		var missing_states := PackedStringArray()
		for profile_id in REQUIRED_PROFILE_IDS:
			var run: Dictionary = runs_by_profile[profile_id]
			var present := {}
			for state in run.get("camera_states", []):
				if state is Dictionary:
					present[StringName(String(state.get("name", "")))] = true
			for required_state in REQUIRED_CAMERA_STATES:
				if not present.has(required_state):
					missing_states.append("%s/%s" % [profile_id, required_state])
		coverage_ok = missing_states.is_empty()
		if not coverage_ok:
			coverage_detail = "Missing camera states: %s." % ", ".join(missing_states)
	results.append(_criterion(CRITERION_TIER_COVERAGE, coverage_ok, coverage_detail))

	results.append(_evaluate_sample_size(runs_by_profile))
	results.append(_evaluate_scalar_budget(
		runs_by_profile,
		CRITERION_GENERATION_TIME,
		"generation_ms",
		"generation_ms",
		"ms"
	))
	results.append(_evaluate_scalar_budget(
		runs_by_profile,
		CRITERION_BUILD_TIME,
		"build_ms",
		"build_ms",
		"ms"
	))
	results.append(_evaluate_scalar_budget(
		runs_by_profile,
		CRITERION_GEOMETRY,
		"geometry_bytes",
		"geometry_bytes",
		"bytes"
	))
	results.append(_evaluate_resident_memory(runs_by_profile))
	results.append(_evaluate_frame_pacing(runs_by_profile))
	results.append(_evaluate_frame_hitch(runs_by_profile))
	results.append(_evaluate_lifecycle(runs_by_profile, "pause_resume", CRITERION_LIFECYCLE))
	results.append(_evaluate_lifecycle(runs_by_profile, "orientation", CRITERION_ORIENTATION))
	results.append(_evaluate_thermal(document))
	return _summarise(results, document)


static func load_document(path := REPOSITORY_EVIDENCE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {
			"ok": false,
			"document": {},
			"error": "No device evidence is committed at %s." % path,
		}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"ok": false,
			"document": {},
			"error": "Could not read device evidence at %s." % path,
		}
	var text := file.get_as_text()
	file.close()
	# A `JSON` instance reports a malformed document through a return code
	# instead of pushing an engine error, so an invalid file is a verdict rather
	# than log noise.
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {
			"ok": false,
			"document": {},
			"error": "Device evidence at %s is not valid JSON: %s" % [
				path,
				parser.get_error_message(),
			],
		}
	if not (parser.data is Dictionary):
		return {
			"ok": false,
			"document": {},
			"error": "Device evidence at %s is not a JSON object." % path,
		}
	return {"ok": true, "document": parser.data as Dictionary, "error": ""}


static func write_document(document: Dictionary, path: String) -> Dictionary:
	var directory := path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(directory)
	):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Could not write device evidence to %s." % path}
	file.store_string(JSON.stringify(document, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"ok": false, "error": error_string(error)}
	return {"ok": true, "path": path, "error": ""}


## The gate. Reads the committed evidence, applies every criterion, and returns
## the verdict `HexWorldBudget.TARGET_DEVICE_VALIDATED` must agree with.
static func repository_verdict(path := REPOSITORY_EVIDENCE_PATH) -> Dictionary:
	var loaded := load_document(path)
	if not bool(loaded["ok"]):
		return {
			"validated": false,
			"evidence_path": path,
			"evidence_present": false,
			"reason": String(loaded["error"]),
			"criteria": [],
			"failures": PackedStringArray([String(loaded["error"])]),
		}
	var evaluation := evaluate_document(loaded["document"])
	evaluation["evidence_path"] = path
	evaluation["evidence_present"] = true
	return evaluation


static func _summarise(results: Array[Dictionary], document: Dictionary) -> Dictionary:
	var failures := PackedStringArray()
	for result in results:
		if not bool(result["passed"]):
			failures.append("%s: %s" % [result["id"], result["detail"]])
	var evaluated := {}
	for id in CRITERION_IDS:
		evaluated[String(id)] = false
	for result in results:
		evaluated[String(result["id"])] = bool(result["passed"])
	var complete := true
	for id in CRITERION_IDS:
		complete = complete and bool(evaluated[String(id)])
	return {
		"validated": complete and failures.is_empty(),
		"criteria": results,
		"failures": failures,
		"captured_at_utc": String(document.get("captured_at_utc", "")),
		"device": document.get("device", {}),
		"reason": (
			"Every declared target-device criterion passed."
			if complete and failures.is_empty()
			else "; ".join(failures)
		),
	}


static func _criterion(id: StringName, passed: bool, detail: String) -> Dictionary:
	return {"id": String(id), "passed": passed, "detail": detail}


static func _evaluate_sample_size(runs_by_profile: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		if int(run.get("warmup_frames", 0)) < MINIMUM_WARMUP_FRAMES:
			problems.append(
				"%s discarded only %d warm-up frames (minimum %d)"
				% [profile_id, int(run.get("warmup_frames", 0)), MINIMUM_WARMUP_FRAMES]
			)
		for state in run.get("camera_states", []):
			if not (state is Dictionary):
				continue
			var frames := int(state.get("sample_frames", 0))
			var duration := float(state.get("sample_duration_ms", 0.0))
			if frames < MINIMUM_STATE_SAMPLE_FRAMES or duration < MINIMUM_STATE_SAMPLE_MS:
				problems.append(
					"%s/%s sampled %d frames over %.0f ms (minimum %d frames, %.0f ms)"
					% [
						profile_id,
						state.get("name", "?"),
						frames,
						duration,
						MINIMUM_STATE_SAMPLE_FRAMES,
						MINIMUM_STATE_SAMPLE_MS,
					]
				)
	return _criterion(
		CRITERION_SAMPLE_SIZE,
		problems.is_empty(),
		(
			"Every camera state met the minimum warm-up and sample window."
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


static func _evaluate_scalar_budget(
	runs_by_profile: Dictionary,
	criterion_id: StringName,
	measurement_key: String,
	budget_key: String,
	unit: String
) -> Dictionary:
	var problems := PackedStringArray()
	var worst := PackedStringArray()
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		var budget := Budget.target_device_budget(StringName(String(profile_id)))
		if not budget.has(budget_key):
			continue
		var measured := float(run.get(measurement_key, -1.0))
		var ceiling := float(budget[budget_key])
		if measured < 0.0:
			problems.append("%s did not record %s" % [profile_id, measurement_key])
			continue
		if measured > ceiling:
			problems.append(
				"%s measured %.0f %s against a %.0f %s ceiling"
				% [profile_id, measured, unit, ceiling, unit]
			)
		else:
			worst.append("%s %.0f/%.0f" % [profile_id, measured, ceiling])
	return _criterion(
		criterion_id,
		problems.is_empty(),
		(
			"Within the target-device ceiling (%s %s)." % [", ".join(worst), unit]
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


static func _evaluate_resident_memory(runs_by_profile: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	var observed := PackedStringArray()
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		var memory: Dictionary = run.get("memory", {})
		if not memory.has("static_memory_bytes") or not memory.has("video_memory_bytes"):
			problems.append("%s did not record resident memory" % profile_id)
			continue
		var tier := StringName(String(profile_id))
		var static_bytes := float(memory["static_memory_bytes"])
		var static_ceiling := float(Budget.target_device_static_memory_bytes(tier))
		if static_bytes > static_ceiling:
			problems.append(
				"%s allocated %.1f MiB of engine memory against a %.1f MiB ceiling"
				% [profile_id, static_bytes / 1048576.0, static_ceiling / 1048576.0]
			)
		var resident := static_bytes + float(memory["video_memory_bytes"])
		var ceiling := float(Budget.target_device_memory_bytes(tier))
		if resident > ceiling:
			problems.append(
				"%s held %.1f MiB resident against a %.1f MiB ceiling"
				% [profile_id, resident / 1048576.0, ceiling / 1048576.0]
			)
		if problems.is_empty():
			observed.append(
				"%s %.1f static / %.1f total MiB"
				% [profile_id, static_bytes / 1048576.0, resident / 1048576.0]
			)
	return _criterion(
		CRITERION_RESIDENT_MEMORY,
		problems.is_empty(),
		(
			"Engine and total memory stayed inside their ceilings (%s)."
			% ", ".join(observed)
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


static func _evaluate_frame_pacing(runs_by_profile: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	var worst_value := 0.0
	var worst_label := ""
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		for state in run.get("camera_states", []):
			if not (state is Dictionary):
				continue
			var frame_ms: Dictionary = state.get("frame_ms", {})
			var p95 := float(frame_ms.get("p95", -1.0))
			if p95 < 0.0:
				problems.append("%s/%s did not record a p95 frame interval" % [
					profile_id,
					state.get("name", "?"),
				])
				continue
			if p95 > Budget.TARGET_DEVICE_FRAME_MS:
				problems.append(
					"%s/%s held a %.2f ms p95 frame interval against a %.1f ms target"
					% [profile_id, state.get("name", "?"), p95, Budget.TARGET_DEVICE_FRAME_MS]
				)
			elif p95 > worst_value:
				worst_value = p95
				worst_label = "%s/%s" % [profile_id, state.get("name", "?")]
	return _criterion(
		CRITERION_FRAME_PACING,
		problems.is_empty(),
		(
			"Worst sampled p95 frame interval was %.2f ms at %s against a %.1f ms target."
			% [worst_value, worst_label, Budget.TARGET_DEVICE_FRAME_MS]
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


static func _evaluate_frame_hitch(runs_by_profile: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	var worst_value := 0.0
	var worst_label := ""
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		for state in run.get("camera_states", []):
			if not (state is Dictionary):
				continue
			var frame_ms: Dictionary = state.get("frame_ms", {})
			var maximum := float(frame_ms.get("max", -1.0))
			if maximum < 0.0:
				problems.append("%s/%s did not record a worst frame interval" % [
					profile_id,
					state.get("name", "?"),
				])
				continue
			if maximum > Budget.TARGET_DEVICE_HITCH_MS:
				problems.append(
					"%s/%s hitched to %.2f ms against a %.1f ms hitch ceiling"
					% [profile_id, state.get("name", "?"), maximum, Budget.TARGET_DEVICE_HITCH_MS]
				)
			elif maximum > worst_value:
				worst_value = maximum
				worst_label = "%s/%s" % [profile_id, state.get("name", "?")]
	return _criterion(
		CRITERION_FRAME_HITCH,
		problems.is_empty(),
		(
			"Worst sampled frame interval was %.2f ms at %s against a %.1f ms hitch ceiling."
			% [worst_value, worst_label, Budget.TARGET_DEVICE_HITCH_MS]
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


static func _evaluate_lifecycle(
	runs_by_profile: Dictionary,
	transition_key: String,
	criterion_id: StringName
) -> Dictionary:
	var problems := PackedStringArray()
	for profile_id in runs_by_profile:
		var run: Dictionary = runs_by_profile[profile_id]
		var lifecycle: Dictionary = run.get("lifecycle", {})
		if not lifecycle.has(transition_key):
			problems.append("%s did not exercise the %s transition" % [
				profile_id,
				transition_key,
			])
			continue
		var transition: Dictionary = lifecycle[transition_key]
		if not bool(transition.get("camera_state_preserved", false)):
			problems.append("%s lost camera state across %s" % [profile_id, transition_key])
		if not bool(transition.get("world_signature_preserved", false)):
			problems.append(
				"%s changed the world signature across %s" % [profile_id, transition_key]
			)
		var recovery := float(transition.get("recovery_frame_ms_p95", -1.0))
		if recovery < 0.0:
			problems.append("%s did not sample %s recovery frames" % [
				profile_id,
				transition_key,
			])
		elif recovery > Budget.TARGET_DEVICE_HITCH_MS:
			problems.append(
				"%s took %.2f ms p95 to recover from %s against a %.1f ms ceiling"
				% [profile_id, recovery, transition_key, Budget.TARGET_DEVICE_HITCH_MS]
			)
	return _criterion(
		criterion_id,
		problems.is_empty(),
		(
			"Every tier preserved the world and the camera across the %s transition."
			% transition_key
			if problems.is_empty()
			else "; ".join(problems)
		)
	)


## Godot exposes no thermal or battery API, so the operator declares the
## precondition and the document records that declaration explicitly. An
## undeclared capture cannot validate, which keeps the gap visible instead of
## silently assuming a cool device.
static func _evaluate_thermal(document: Dictionary) -> Dictionary:
	var operator: Dictionary = document.get("operator", {})
	var declared := bool(operator.get("thermal_precondition_met", false))
	var battery := int(operator.get("battery_percent", -1))
	var problems := PackedStringArray()
	if not declared:
		problems.append(
			"The operator did not declare that the device started from an idle "
			+ "thermal state on mains-free power"
		)
	if battery < 0:
		problems.append("The capture did not record the battery percentage")
	elif battery < 30:
		problems.append(
			"The device started at %d%% battery; below 30%% iOS and Android may "
			% battery
			+ "throttle and the capture is not representative"
		)
	return _criterion(
		CRITERION_THERMAL_PRECONDITION,
		problems.is_empty(),
		(
			"Operator declared an idle thermal start at %d%% battery." % battery
			if problems.is_empty()
			else "; ".join(problems)
		)
	)
