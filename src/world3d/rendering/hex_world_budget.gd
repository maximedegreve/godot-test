class_name HexWorldBudget
extends RefCounted

## Phase 5 explicit generation, frame, and memory budgets for the isolated 3D
## hex prototype, plus the honest target-device measurement hook.
##
## Two ceilings are declared for every tier and they must not be conflated:
##
## * `DESKTOP_*` is a reproducible prototype ceiling measured on the development
##   machine with the Forward Mobile renderer. Desktop Forward Mobile is *not*
##   device proof; it only guards against regressions in this repository.
## * `TARGET_DEVICE_*` is the agreed mobile budget. It stays **open** until the
##   same runtime scene is measured on real target hardware through
##   `capture_device_sample`, which is why `target_device_validated` is false.

const DEFAULT_DEVICE_REPORT_PATH := "user://hex_world_device_budget.json"

## Measured desktop logical generation time is roughly 0.30 s Small, 0.71 s
## Medium, 1.81 s Large, and 3.36 s Ultra. The ceilings below keep about 40%
## headroom so ordinary machine noise does not fail a run.
const DESKTOP_GENERATION_MS := {
	&"small": 700,
	&"medium": 1400,
	&"large": 3200,
	&"ultra": 5600,
}
## Terrain, submerged bathymetry, hydrology, ecology meshing plus filtered
## land-only collider construction, main thread. Measured after the continuous
## seabed pass at roughly 0.97 / 1.98 / 4.06 / 6.72 seconds; these ceilings
## retain about 40% headroom for ordinary machine noise.
const DESKTOP_BUILD_MS := {
	&"small": 1400,
	&"medium": 2800,
	&"large": 5700,
	&"ultra": 9500,
}
const DESKTOP_FRAME_MS := 16.7
const DESKTOP_DRAW_CALLS := {
	&"small": 140,
	&"medium": 170,
	&"large": 200,
	&"ultra": 240,
}
## Terrain vertex buffers plus batched ecology instance buffers plus the
## picking/collision triangle soup, in bytes.
const DESKTOP_GEOMETRY_BYTES := {
	&"small": 12 * 1024 * 1024,
	&"medium": 22 * 1024 * 1024,
	&"large": 40 * 1024 * 1024,
	&"ultra": 68 * 1024 * 1024,
}

## Agreed mobile targets. 33.3 ms is the 30 fps strategy-view frame target.
const TARGET_DEVICE_GENERATION_MS := {
	&"small": 2500,
	&"medium": 5000,
	&"large": 11000,
	&"ultra": 19000,
}
const TARGET_DEVICE_FRAME_MS := 33.3
## No single sampled frame may exceed two 30 fps intervals. A steady p95 with a
## 400 ms stall is not a shippable strategy view, so pacing and hitching are
## separate criteria rather than one averaged number.
const TARGET_DEVICE_HITCH_MS := 66.6
const TARGET_DEVICE_GEOMETRY_BYTES := {
	&"small": 12 * 1024 * 1024,
	&"medium": 22 * 1024 * 1024,
	&"large": 40 * 1024 * 1024,
	&"ultra": 68 * 1024 * 1024,
}
## Main-thread scene assembly on the handset. Meshing is CPU work that scales
## with the same tile count as generation, so the ceiling is the generation
## ceiling plus 10%, rounded to a readable value.
const TARGET_DEVICE_BUILD_MS := {
	&"small": 2800,
	&"medium": 5500,
	&"large": 12000,
	&"ultra": 21000,
}
## Resident footprint ceilings. Two numbers, because the two halves behave
## completely differently and conflating them would hide both.
##
## `TARGET_DEVICE_STATIC_MEMORY_BYTES` bounds Godot's own allocator, which is
## where the logical world, the chunk meshes, the collision soup, and the
## batched instance buffers live. It is the half that scales with the tier, and
## it is the half the prototype controls. Measured on the development machine
## through the same protocol: 64.5 / 71.3 / 84.3 / 102.5 MiB. The ceilings keep
## roughly 2x headroom for a handset's larger allocator overhead.
const TARGET_DEVICE_STATIC_MEMORY_BYTES := {
	&"small": 128 * 1024 * 1024,
	&"medium": 160 * 1024 * 1024,
	&"large": 192 * 1024 * 1024,
	&"ultra": 256 * 1024 * 1024,
}
## `TARGET_DEVICE_MEMORY_BYTES` bounds static plus reported video memory, the
## whole footprint the platform has to keep alive. Video memory is dominated by
## a fixed, resolution-dependent renderer allocation the prototype does not
## control: the same measurement reads 440.9 MiB at Small and 458.8 MiB at
## Ultra, so only ~18 MiB of it is the world. The ceilings therefore sit well
## above the measured desktop total (505 / 522 / 539 / 561 MiB) while staying
## far below any mobile low-memory limit, so a breach means something real
## changed rather than that the window got bigger.
const TARGET_DEVICE_MEMORY_BYTES := {
	&"small": 768 * 1024 * 1024,
	&"medium": 832 * 1024 * 1024,
	&"large": 896 * 1024 * 1024,
	&"ultra": 1024 * 1024 * 1024,
}
## Phase 5 does not claim the mobile criterion. This constant is gated: the
## suite asserts it equals `HexWorldDeviceEvidence.repository_verdict()`, so it
## can only become true when committed handset evidence clears every declared
## criterion, and it cannot stay false once such evidence exists.
const TARGET_DEVICE_VALIDATED := false


static func profile_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(DESKTOP_GENERATION_MS.keys())
	return result


static func desktop_budget(profile_id: StringName) -> Dictionary:
	return {
		"generation_ms": int(DESKTOP_GENERATION_MS.get(profile_id, 5600)),
		"build_ms": int(DESKTOP_BUILD_MS.get(profile_id, 6000)),
		"frame_ms": DESKTOP_FRAME_MS,
		"draw_calls": int(DESKTOP_DRAW_CALLS.get(profile_id, 240)),
		"geometry_bytes": int(DESKTOP_GEOMETRY_BYTES.get(profile_id, 68 * 1024 * 1024)),
	}


static func target_device_budget(profile_id: StringName) -> Dictionary:
	return {
		"generation_ms": int(TARGET_DEVICE_GENERATION_MS.get(profile_id, 19000)),
		"build_ms": int(TARGET_DEVICE_BUILD_MS.get(profile_id, 21000)),
		"frame_ms": TARGET_DEVICE_FRAME_MS,
		"hitch_ms": TARGET_DEVICE_HITCH_MS,
		"geometry_bytes": int(
			TARGET_DEVICE_GEOMETRY_BYTES.get(profile_id, 68 * 1024 * 1024)
		),
		"memory_bytes": target_device_memory_bytes(profile_id),
		"static_memory_bytes": target_device_static_memory_bytes(profile_id),
		"validated": TARGET_DEVICE_VALIDATED,
	}


static func target_device_memory_bytes(profile_id: StringName) -> int:
	return int(TARGET_DEVICE_MEMORY_BYTES.get(profile_id, 1024 * 1024 * 1024))


static func target_device_static_memory_bytes(profile_id: StringName) -> int:
	return int(TARGET_DEVICE_STATIC_MEMORY_BYTES.get(profile_id, 256 * 1024 * 1024))


## Compares one measurement set against the desktop prototype ceilings. The
## target-device verdict is always reported as unvalidated so a green desktop
## run can never be mistaken for device evidence.
static func evaluate(profile_id: StringName, measurements: Dictionary) -> Dictionary:
	var budget := desktop_budget(profile_id)
	var breaches := PackedStringArray()
	for key in ["generation_ms", "build_ms", "draw_calls", "geometry_bytes"]:
		if not measurements.has(key):
			continue
		if float(measurements[key]) > float(budget[key]):
			breaches.append(key)
	if measurements.has("frame_ms") and float(measurements["frame_ms"]) > DESKTOP_FRAME_MS:
		breaches.append("frame_ms")
	return {
		"profile_id": String(profile_id),
		"desktop_budget": budget,
		"target_device_budget": target_device_budget(profile_id),
		"measurements": measurements,
		"within_desktop_budget": breaches.is_empty(),
		"desktop_budget_breaches": breaches,
		"target_device_validated": TARGET_DEVICE_VALIDATED,
		"target_device_note": (
			"Desktop Forward Mobile is not device proof. Run the device "
			+ "benchmark on the target handset (Lab \u2192 Device benchmark, or "
			+ "the hexbench packaged build) and commit the resulting evidence "
			+ "document to close this."
		),
	}


## Target-device measurement hook. Samples the live engine counters on whatever
## hardware the build is running on, so the same code path produces the desktop
## prototype numbers and the eventual on-device numbers.
static func capture_device_sample(
	profile_id: StringName,
	extra: Dictionary = {}
) -> Dictionary:
	var sample := device_identity()
	sample["captured_at_utc"] = Time.get_datetime_string_from_system(true)
	sample["profile_id"] = String(profile_id)
	sample["static_memory_bytes"] = OS.get_static_memory_usage()
	sample["video_memory_bytes"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	sample["texture_memory_bytes"] = Performance.get_monitor(
		Performance.RENDER_TEXTURE_MEM_USED
	)
	sample["buffer_memory_bytes"] = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)
	sample["object_node_count"] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	sample["process_frame_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	sample["frames_per_second"] = Performance.get_monitor(Performance.TIME_FPS)
	for key in extra:
		sample[key] = extra[key]
	sample["evaluation"] = evaluate(profile_id, extra)
	return sample


## Stable hardware and renderer identity shared by the single-shot sample and
## by the full device-benchmark evidence document, so both name the device the
## same way.
static func device_identity() -> Dictionary:
	var memory_info := OS.get_memory_info()
	return {
		"os_name": OS.get_name(),
		"os_version": OS.get_version(),
		"model_name": OS.get_model_name(),
		"processor_name": OS.get_processor_name(),
		"processor_count": OS.get_processor_count(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": String(
			ProjectSettings.get_setting("rendering/renderer/rendering_method", "")
		),
		"display_server": DisplayServer.get_name(),
		"is_mobile_platform": OS.has_feature("mobile"),
		"physical_memory_bytes": int(memory_info.get("physical", 0)),
		"available_memory_bytes": int(memory_info.get("available", 0)),
	}


static func write_device_sample(
	sample: Dictionary,
	path := DEFAULT_DEVICE_REPORT_PATH
) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"error": "Could not write the device budget sample to %s." % path,
		}
	file.store_string(JSON.stringify(sample, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"ok": false, "error": error_string(error)}
	return {"ok": true, "path": path, "error": ""}
