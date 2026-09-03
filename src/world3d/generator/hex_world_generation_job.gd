class_name HexWorldGenerationJob
extends RefCounted

## Phase 5 optional worker-thread logical generation.
##
## The worker runs `HexWorldGenerator.generate` only. That path builds plain
## `RefCounted` data — it never creates a `Node`, never touches the scene tree,
## and never allocates a mesh, material, or rendering resource. Scene-tree work
## and mesh assignment stay on the main thread in `HexWorldPrototype`, which
## consumes the finished `HexWorldData` after `poll()` reports completion.
##
## When the platform cannot use threads the job degrades to a synchronous run so
## callers keep one code path.

const Generator = preload("res://src/world3d/generator/hex_world_generator.gd")

var _thread: Thread
var _mutex := Mutex.new()
var _settings: WorldGenerationSettings
var _result: Dictionary = {}
var _finished := false
var _threaded := false
var _main_thread_id := 0


func start(settings: WorldGenerationSettings) -> bool:
	if is_running():
		return false
	_settings = settings.validated_copy()
	_result = {}
	_finished = false
	_main_thread_id = OS.get_thread_caller_id()
	if not _threads_available():
		_threaded = false
		_run()
		return true
	_thread = Thread.new()
	var error := _thread.start(_run)
	if error != OK:
		_thread = null
		_threaded = false
		_run()
		return true
	_threaded = true
	return true


func is_threaded() -> bool:
	return _threaded


## Single-threaded web exports have no worker threads; every other supported
## target does. The job still falls back if `Thread.start` reports an error.
static func _threads_available() -> bool:
	return not OS.has_feature("web") or OS.has_feature("threads")


func is_running() -> bool:
	return _thread != null and not _finished


## True once the worker has published a result. Safe to call every frame.
func poll() -> bool:
	_mutex.lock()
	var finished := _finished
	_mutex.unlock()
	return finished


## Joins the worker if needed and returns the result. Must be called from the
## main thread; the returned world is only ever handed to the scene after this.
func take_result() -> Dictionary:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_mutex.lock()
	var result := _result.duplicate()
	_mutex.unlock()
	return result


func settings() -> WorldGenerationSettings:
	return _settings


func _run() -> void:
	var worker_thread_id := OS.get_thread_caller_id()
	var started := Time.get_ticks_msec()
	var world := Generator.generate(_settings)
	var elapsed := Time.get_ticks_msec() - started
	_mutex.lock()
	_result = {
		"ok": world != null,
		"world": world,
		"generation_ms": elapsed,
		"worker_thread_id": worker_thread_id,
		"main_thread_id": _main_thread_id,
		"ran_off_main_thread": worker_thread_id != _main_thread_id,
	}
	_finished = true
	_mutex.unlock()
