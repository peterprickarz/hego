@tool
class_name CopiaStore3D
extends Node3D
## An instancing store: points written into it are kept per cell and set, built into ready-to-draw
## data by the native build, and drawn around its sources through [RenderingServer], with
## colliders through [PhysicsServer3D]. A source is a place streaming happens around: the default
## source ([member target] or the current camera) and every [CopiaSource3D] in the scene tree, for
## games with several views of the same world. Points and cells are in the node's local space;
## ranges and margins are compared on the local XZ plane, so the node is meant to be unscaled.
##
## The node creates no child nodes and nothing it creates is saved with the scene. It reads the
## built cells of [member data_directory] on worker threads and makes every server call on the
## main thread under [member frame_budget_usec]. In the editor it rebuilds what an object change
## or a write made stale; in a running game it only reads. See the design page,
## [code]docs/development/copia_design.md[/code], for the data and the native classes.

## Emitted on the main thread when a group is handed to the drawer or the colliders (its objects
## are then created by later frames under the budget). [param info] holds
## [code]object_path[/code], [code]cell[/code] (the far cell for an impostor group),
## [code]kind[/code] ([code]"draw"[/code], [code]"impostor"[/code] or [code]"collider"[/code]) and
## [code]group[/code] (the id in [method get_drawer] or [method get_colliders]) and
## [code]requested_usec[/code] ([method Time.get_ticks_usec] when its section was requested).
signal group_added(info: Dictionary)
## Emitted on the main thread when a group is removed; [param info] as in [signal group_added].
signal group_removed(info: Dictionary)
## Emitted on the main thread each time the store goes from unsettled to settled: no directory or
## section read in flight, nothing queued for creation or freeing in the drawer or the colliders,
## and no rebuild running (see [method is_settled]). Not emitted every frame. After a camera jump
## without [method load_now], a game that uses SDFGI or other renderer state that is built once
## on arrival should wait for this signal and then refresh that state.
signal streaming_settled()
## Emitted on the main thread when a background build starts: one started by
## [method build_async], or the rebuild an object change schedules.
signal build_started()
## Emitted on the main thread when a background build has finished and its result is applied (the
## loaded cells it rewrote are being refreshed). [param report] is the result of
## [code]CopiaBuild.build_cells[/code] ([code]ok[/code], [code]error[/code], [code]written[/code],
## [code]unchanged[/code], [code]deleted[/code], [code]skipped[/code], [code]cell_count[/code],
## [code]far_count[/code], ...) plus [code]stale[/code] (the stale cells it computed, when it was
## given none) and [code]usec[/code] (its wall time on the build thread).
signal build_finished(report: Dictionary)

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const SourceScript := preload("res://addons/copia/copia_source_3d.gd")
const DebugScript := preload("res://addons/copia/copia_debug.gd")
const EXTENSION := "res://addons/copia/bin/copia.gdextension"
## Seconds between the last build input change of an object and the rebuild it causes.
const REBUILD_DELAY := 0.5
const CELL_EXTENSION := ".copiacell"
## Step budget of [method load_now], in microseconds: effectively unlimited.
const LOAD_NOW_BUDGET_USEC := 100000000
## Section kinds by the streamer's kind index.
const KIND_NAMES: Array[String] = ["draw", "collider", "impostor"]


## Hands worker results to the main thread. Worker tasks touch only their arguments and this
## object, which lives as long as a task holds it, so a task that outlives the node is harmless.
class _Loader extends RefCounted:
	var mutex := Mutex.new()
	var results: Array = []

	func read_section(file: String, object_path: String, section: String, token: int) -> void:
		var data: Dictionary = ClassDB.class_call_static("CopiaCells", "read_section", file, object_path, section)
		mutex.lock()
		results.append([token, data])
		mutex.unlock()

	func read_directory(file: String, token: int) -> void:
		var data: Dictionary = ClassDB.class_call_static("CopiaCells", "read_directory", file)
		mutex.lock()
		results.append([token, data])
		mutex.unlock()

	func take() -> Array:
		mutex.lock()
		var taken := results
		results = []
		mutex.unlock()
		return taken


## One loaded (or loading) section: an object's draw or collider section of a cell, or its
## impostor entry of a far cell.
class _Record extends RefCounted:
	var kind := ""  # "draw", "impostor" or "collider"
	var cell := Vector2i.ZERO  # the far cell for "impostor"
	var path := ""
	var group := 0  # id in the drawer or the colliders; 0 while loading
	var old_group := 0  # the group being replaced, removed once group is ready
	var token := 0  # request in flight
	var revision := 0  # directory revision the group was read from
	var count := 0  # collider bodies of the group
	var batches := {}  # impostor: impostor batch cell -> batch index
	# Draw record of an object whose impostor batch cell is smaller than the cell: the impostor
	# batch cell of each batch (multimesh) or instance, x and z.
	var impostor_cells := PackedInt32Array()
	var failed := false
	var requested_usec := 0  # when the section in use (or in flight) was requested
	var handle := 0  # the record's handle in the streamer
	# What the sources that need it ask for, from the streamer's last evaluation: the largest
	# density and range scale (the creation priority is read from the streamer when needed).
	var density := 1.0
	var range_scale := 1.0


## Directory of the store's data: [code]sets/[/code], [code]cells/[/code] and [code]far/[/code],
## with the index files [code]sets/index.copiaindex[/code] and [code]cells/index.copiaindex[/code].
@export_dir var data_directory := "":
	set(value):
		if data_directory == value: return
		data_directory = value
		_reset_data()
		update_configuration_warnings()
## Edge length in metres of a cell on the local XZ plane. Changing it needs a full rebuild.
@export_range(1.0, 4096.0, 1.0, "or_greater", "suffix:m") var cell_size := 64.0:
	set(value):
		if is_equal_approx(cell_size, value): return
		cell_size = value
		_reset_data()
		update_configuration_warnings()
## Edge length in metres of a far cell, which holds the impostor batches of the cells inside it.
## A multiple of [member cell_size]. A build input of every object with an impostor.
@export_range(1.0, 8192.0, 1.0, "or_greater", "suffix:m") var impostor_cell_size := 128.0:
	set(value):
		if is_equal_approx(impostor_cell_size, value): return
		impostor_cell_size = value
		_reset_data()
		update_configuration_warnings()
## The node of the default source (see [member use_default_source]). Empty: the viewport's
## current [Camera3D] in a running game, the editor's 3D viewport camera in the editor.
@export var target: NodePath
## Stream around the default source: [member target] (or the current camera) with range scale 1,
## the store's [member density], colliders and shadows. Off: only [CopiaSource3D] nodes are
## streamed around, and [method update_streaming] and [method load_now] ignore their position.
@export var use_default_source := true:
	set(value):
		if use_default_source == value: return
		use_default_source = value
		_update_needed = true
## Main-thread time in microseconds given to creating and freeing server objects per frame.
## Colliders take up to half of it first; the drawer gets the rest. The renderer adds work of its
## own in the frame after creation (about five times the step on the reference machine; see the
## design page, "Budget"), so pass about a sixth of the frame time you are willing to lose.
@export_range(1, 100000, 1, "or_greater", "suffix:usec") var frame_budget_usec := 500
## Metres beyond an object's range at which its section is requested.
@export_range(0.0, 1000.0, 0.5, "or_greater", "suffix:m") var load_margin := 16.0:
	set(value):
		load_margin = maxf(value, 0.0)
		_configure_streamer()
		update_configuration_warnings()
## Metres beyond an object's range at which its section is freed. Must exceed [member load_margin].
@export_range(0.0, 1000.0, 0.5, "or_greater", "suffix:m") var unload_margin := 32.0:
	set(value):
		unload_margin = maxf(value, 0.0)
		_configure_streamer()
		update_configuration_warnings()
## Seconds between two streaming updates.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:s") var update_interval := 0.1
## Metres (on the local XZ plane) a source must move from where it was at the last evaluated
## update before an update decides again what to load and free. An update in which no source
## moved further and nothing else changed (no source setting, object, cell, directory, margin or
## loaded section) does nothing. The margins absorb the lag: with the default 16 m
## [member load_margin] a section is still requested at least 15 m before its range is reached,
## and freeing waits for [member unload_margin] (32 m) anyway. 0: every move is evaluated.
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m") var movement_threshold := 1.0:
	set(value):
		movement_threshold = maxf(value, 0.0)
		_configure_streamer()
## Fraction of each batch's instances drawn, by their keep value (see the design page, "Density").
@export_range(0.0, 1.0, 0.01) var density := 1.0:
	set(value):
		density = clampf(value, 0.0, 1.0)
		if _drawer != null:
			_drawer.set_density(density)
## Distance in metres from a source with colliders within which colliders exist, for objects
## whose physics settings give no distance. 0: colliders follow the object's draw range.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var collider_distance := 50.0:
	set(value):
		collider_distance = value
		_push_objects()
## In the editor, stream around the editor camera. Off: the editor draws nothing.
@export var editor_preview := true:
	set(value):
		editor_preview = value
		if not value and Engine.is_editor_hint():
			_unload_all()

@export_group("Debug")
## Viewport debug view of every object of the store, for objects whose render settings'
## [member CopiaRenderSettings.debug_view] is off (theirs wins otherwise); see
## [enum CopiaRenderSettings.DebugView] and the reference page, "Debug views". Applied to the live
## groups at once, like a draw override, with no build. Editor and debug state: shown in the
## inspector but never saved with the scene.
@export var debug_view: RenderScript.DebugView = RenderScript.DebugView.OFF:
	set(value):
		if debug_view == value: return
		debug_view = value
		for path in _objects:
			if _objects[path] != null:
				_apply_draw_params(_objects[path])
		_report_debug_views()

## Rebuild the cells an object change makes stale (debounced, on a background thread), and
## check for stale cells when the node becomes ready. On by default in the editor and off in a
## running game; a tool script can turn it on before adding the node.
var watch_objects := Engine.is_editor_hint()

var _drawer: Object
var _colliders: Object
var _streamer: Object  # CopiaStreamer, the streaming decision; created with the first drawer
var _records := {}  # streamer handle -> _Record
var _loader := _Loader.new()
var _tasks: Array[int] = []
var _token := 0
var _requests := {}  # token -> _Record (sections)
var _dir_requests := {}  # token -> [is_far, cell]
var _cells_known := {}  # Vector2i -> true
var _far_known := {}
var _cell_dirs := {}  # Vector2i -> read_directory result
var _far_dirs := {}
var _previous_dirs := {}  # [is_far, cell] -> the directory before a rebuild, until it is read again
var _cell_dir_pending := {}  # Vector2i -> token
var _far_dir_pending := {}
var _cell_revision := {}  # Vector2i -> int
var _far_revision := {}
var _live := {}  # cell -> {path -> {"draw"|"collider" -> _Record}}
var _far_live := {}  # far cell -> {path -> _Record}
var _replacing := {}  # _Record -> true
var _collider_records := {}  # collider group id -> _Record
var _group_counts := {"draw": 0, "impostor": 0, "collider": 0}
var _objects := {}  # path -> info Dictionary, or null when the path does not resolve
var _set_paths := {}  # path -> true, the object paths of the set files (sets index)
var _set_paths_loaded := false
var _dir_paths := {}  # path -> true, seen in a cached directory
var _ranges_dirty := true
var _max_draw_range := INF
var _max_collider_range := INF
var _max_impostor_range := INF
# The sources of the last update, as parallel arrays (index = source): local XZ point, global
# position, range scale, density, colliders and shadows flags, priority, node (null for the
# default source).
var _source_count := 0
var _source_points := PackedVector2Array()
var _source_globals := PackedVector3Array()
var _source_scales := PackedFloat64Array()
var _source_densities := PackedFloat64Array()
var _source_colliders := PackedByteArray()
var _source_shadows := PackedByteArray()
var _source_priorities := PackedFloat64Array()
var _source_nodes: Array = []
var _shadow_positions := PackedVector3Array()
var _source_revision := -1
var _sources_known := false  # an update has gathered the sources
var _scanned := false
var _last_position := Vector3.ZERO
var _has_position := false
var _timer := 0.0
var _build_thread: Thread
var _rebuild_timer := -1.0
var _last_build := {}
var _default_render := RenderScript.new()
var _last_step_usec := 0
var _update_needed := false  # a directory or a build arrived: update streaming in this frame
var _was_settled := true
var _excluded_rects: Array[Rect2] = []  # run-time state, see set_excluded_rects
var _draw_overrides := {}  # object path -> params merged into its draw params
var _impostor_overrides := {}  # object path -> params merged into its impostor draw params
var _debug_views := {}  # object path -> its debug view, for objects drawn with one


func _init() -> void:
	set_notify_transform(true)


func _validate_property(property: Dictionary) -> void:
	if property.name == "debug_view":
		property.usage = PROPERTY_USAGE_EDITOR  # shown, never saved


func _ready() -> void:
	if watch_objects and not data_directory.is_empty():
		_rebuild_timer = 0.0


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_WORLD:
			_start()
		NOTIFICATION_EXIT_WORLD:
			_stop()
		NOTIFICATION_TRANSFORM_CHANGED:
			if _drawer != null:
				_drawer.set_transform(global_transform)
				_colliders.set_transform(global_transform)
		NOTIFICATION_VISIBILITY_CHANGED:
			if not is_visible_in_tree():
				_unload_all()
			else:
				_update_needed = true  # stream again in this frame
		NOTIFICATION_PREDELETE:
			_stop()
			if _build_thread != null:
				_build_thread.wait_to_finish()
				_build_thread = null
			for path in _objects:
				_disconnect_object(_objects[path])
			_objects.clear()


func _process(delta: float) -> void:
	if _drawer == null:
		_poll_build(delta)  # a background build finishes outside the world too
		return
	_collect_tasks()
	_drain_results()
	_check_replacements()
	_poll_build(delta)
	DebugScript.sync_hidden()
	if SourceScript._revision != _source_revision:
		_update_needed = true  # a source entered, left or changed
	_timer += delta
	if _timer >= update_interval or _update_needed:
		_timer = 0.0
		update_streaming_all()
	var spent := int(_colliders.step(maxi(frame_budget_usec / 2, 1)).usec)
	_last_step_usec = spent + int(_drawer.step(maxi(frame_budget_usec - spent, 1)).usec)
	_update_shadows()
	_update_settled()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if data_directory.is_empty():
		warnings.append("No data directory is set.")
	elif not DirAccess.dir_exists_absolute(data_directory):
		warnings.append("The data directory %s does not exist; write() creates it." % data_directory)
	if unload_margin <= load_margin:
		warnings.append("unload_margin (%.1f m) must exceed load_margin (%.1f m), or sections are freed as soon as they load." % [unload_margin, load_margin])
	var per_far := impostor_cell_size / cell_size
	if per_far < 1.0 or not is_equal_approx(per_far, roundf(per_far)):
		warnings.append("impostor_cell_size (%.1f m) is not a multiple of cell_size (%.1f m)." % [impostor_cell_size, cell_size])
	if not data_directory.is_empty() and not _set_paths_loaded:
		_load_object_paths()
	for path in _all_object_paths():
		var info = _info(path)
		if info == null:
			continue
		var descriptor: Dictionary = info.object.descriptor(impostor_cell_size)
		var batch: float = descriptor.batch_size
		var per_cell := cell_size / batch
		if per_cell < 1.0 or not is_equal_approx(per_cell, roundf(per_cell)):
			warnings.append("%s: batch_size %.2f m does not divide cell_size %.1f m; the build rejects it." % [path, batch, cell_size])
		var impostor_batch: float = descriptor.impostor_batch_size
		if descriptor.impostor and impostor_batch > 0.0:
			var per_impostor := cell_size / impostor_batch
			var per_draw := impostor_batch / batch
			if per_impostor < 1.0 or not is_equal_approx(per_impostor, roundf(per_impostor)):
				warnings.append("%s: impostor_batch_size %.2f m does not divide cell_size %.1f m; the build rejects it." % [path, impostor_batch, cell_size])
			elif descriptor.draw == "multimesh" and (per_draw < 1.0 or not is_equal_approx(per_draw, roundf(per_draw))):
				warnings.append("%s: impostor_batch_size %.2f m is not a multiple of batch_size %.2f m; the build rejects it." % [path, impostor_batch, batch])
	return warnings


# --- Writing and building ---------------------------------------------------------------------


## Applies [param clears] and [param points] with [code]CopiaSets.apply[/code] (the design page's
## "Writing points" describes both), builds the touched cells and refreshes those that are loaded.
## Returns [code]{ok, error, apply, build}[/code] with both native results.
func write(clears: Array, points: Dictionary) -> Dictionary:
	_quiesce()
	var report := {"ok": false, "error": "", "apply": {}, "build": {}}
	if data_directory.is_empty():
		report.error = "no data directory"
		return report
	var applied: Dictionary = _native_static("CopiaSets", "apply", [data_directory, cell_size, clears, points])
	report.apply = applied
	if not applied.get("ok", false):
		report.error = applied.get("error", "apply failed")
		return report
	_load_object_paths()
	var cells: Array = applied.get("cells", [])
	if cells.is_empty():
		report.ok = true
		report.build = _empty_build()
		return report
	report.build = _build_now(cells, false)
	report.ok = report.build.get("ok", false)
	report.error = report.build.get("error", "")
	return report


## Builds [param cells] ([Vector2i] cells or [method stale_cells] entries); empty builds every
## stale cell. [param force] rebuilds cells whose inputs did not change. Loaded cells that change
## are refreshed. Returns the result of [code]CopiaBuild.build_cells[/code].
func build(cells := [], force := false) -> Dictionary:
	_quiesce()
	if cells.is_empty():
		var stale := stale_cells()
		for entry in stale:
			if entry.get("kind") == "error":
				var failed := _empty_build()
				failed.ok = false
				failed.error = entry.get("error", "invalid descriptors")
				return failed
		cells = stale
	if cells.is_empty():
		return _empty_build()
	return _build_now(cells, force)


## Rebuilds every cell that has set files or a built file, and every stale far cell, with
## [code]force[/code].
func rebuild_all() -> Dictionary:
	_quiesce()
	var wanted := rebuild_all_cells()
	if wanted.is_empty():
		return _empty_build()
	return _build_now(wanted, true)


## The cells [method rebuild_all] builds: every cell with set files or a built file, and every
## stale far cell (as [method stale_cells] entries). Read from the index files. Pass it to
## [method build_async] with [code]force[/code] for a rebuild of everything in the background.
func rebuild_all_cells() -> Array:
	if data_directory.is_empty():
		return []
	var cells := {}
	for set_name in list_sets():
		for entry in _native_static("CopiaSets", "list_cells", [data_directory, set_name]):
			cells[entry.cell] = true
	for entry in _list_built():
		if entry.kind == "cell":
			cells[entry.cell] = true
	var wanted: Array = cells.keys()
	for entry in stale_cells():
		if entry.get("kind") == "far":
			wanted.append(entry)
	return wanted


## Starts a build of [param cells] on a background thread, as [method build] does it ([Vector2i]
## cells or [method stale_cells] entries; empty builds every stale cell, found on that thread;
## [param force] rebuilds cells whose inputs did not change). Returns false, and starts nothing,
## when a background build is already running or the node has no data directory. The node keeps
## streaming meanwhile but reads no file until the build is done. [signal build_started] is
## emitted now, [signal build_finished] when the result has been applied, in a later frame; the
## node must be inside the tree for that (its [method Node._process] collects the result), and a
## synchronous call ([method write], [method build], ...) waits for it first.
## [method get_last_build] then returns the same report.
func build_async(cells := [], force := false) -> bool:
	if _build_thread != null or data_directory.is_empty() or not _ensure_native():
		return false
	_start_background_build(cells, force)
	return _build_thread != null


## True while a background build ([method build_async] or an object-change rebuild) runs.
func is_building() -> bool:
	return _build_thread != null


## The cells whose built files differ from their inputs: [code]CopiaBuild.stale_cells[/code] with
## the descriptors of every known object.
func stale_cells() -> Array:
	if data_directory.is_empty():
		return []
	return _native_static("CopiaBuild", "stale_cells", [data_directory, cell_size, _descriptors()])


## The set names with at least one set file.
func list_sets() -> PackedStringArray:
	if data_directory.is_empty():
		return PackedStringArray()
	return _native_static("CopiaSets", "list_sets", [data_directory])


## One entry per set with at least one set file, sorted by name:
## [code]{set, cells, instances}[/code], the number of cells it has points in and its point count.
## Read from the sets index in one call ([code]CopiaSets.cell_points[/code]); no per-cell file is
## opened.
func set_summary() -> Array:
	if data_directory.is_empty():
		return []
	var rows: Dictionary = cell_points()
	var sets: PackedStringArray = rows.get("set", PackedStringArray())
	var counts: PackedInt32Array = rows.get("count", PackedInt32Array())
	var by_set := {}
	for i in sets.size():
		var entry: Dictionary = by_set.get_or_add(sets[i], {"set": sets[i], "cells": 0, "instances": 0})
		entry.cells += 1
		entry.instances += counts[i]
	var names := by_set.keys()
	names.sort()
	var result := []
	for set_name in names:
		result.append(by_set[set_name])
	return result


## Deletes the set [param set_name] and rebuilds the cells it had content in. Returns
## [code]{cells, build}[/code].
func remove_set(set_name: String) -> Dictionary:
	_quiesce()
	var cells: Array = _native_static("CopiaSets", "remove_set", [data_directory, set_name])
	_load_object_paths()
	var result := _empty_build() if cells.is_empty() else _build_now(cells, false)
	return {"cells": cells, "build": result}


## The points whose origin lies in [param rect] (local X and Z), as
## [code]CopiaSets.read_points[/code] returns them. [param sets] empty reads every set.
func read_points(rect: Rect2, sets := PackedStringArray(), exclude := PackedStringArray()) -> Dictionary:
	return _native_static("CopiaSets", "read_points", [data_directory, cell_size, rect, PackedStringArray(sets), PackedStringArray(exclude)])


## One row per cell and set that holds points, as [code]CopiaSets.cell_points[/code] returns them
## (the design page's "Point attributes"). [param rect] empty = every cell.
func cell_points(rect := Rect2(), sets := PackedStringArray(), exclude := PackedStringArray()) -> Dictionary:
	return _native_static("CopiaSets", "cell_points", [data_directory, cell_size, rect, PackedStringArray(sets), PackedStringArray(exclude)])


## The descriptor of every known object path that resolves: the object paths of the set files and
## of the built cells (both from the index files).
func descriptors() -> Dictionary:
	return _descriptors()


## The result of the last background build, or [code]{}[/code].
func get_last_build() -> Dictionary:
	return _last_build


# --- Streaming --------------------------------------------------------------------------------


## Updates what is loaded with the default source at the global [param position] (and every
## [CopiaSource3D] at its current position): requests the directories and sections now in range of
## a source, removes the groups no source needs and applies the quality the remaining sources ask
## for. Tests can call it directly. With [member use_default_source] off, [param position] is
## ignored.
func update_streaming(position: Vector3) -> void:
	_last_position = position
	_has_position = true
	_update()


## Updates what is loaded for every source: the default source at [member target] (or the current
## camera; its last position when there is none) and every [CopiaSource3D] at its current
## position. Called every [member update_interval]; tests can call it directly.
func update_streaming_all() -> void:
	if use_default_source:
		var position = _target_position()
		if position != null:
			_last_position = position
			_has_position = true
	_update()


func _update() -> void:
	_update_needed = false
	_gather_sources()
	if not _streaming():
		return
	if _ranges_dirty:
		_compute_ranges()
	# No reads while a build writes the files: then only the live records are decided.
	var loading := _build_thread == null
	var changes: Dictionary = _streamer.update(_source_points, _source_scales, _source_densities, _source_colliders, _source_priorities, loading)
	if not changes.evaluated:
		return  # nothing moved or changed since the last evaluation
	_apply_records(changes)
	if not loading:
		return
	var directories: PackedInt32Array = changes.directories
	for i in range(0, directories.size(), 3):
		_read_directory(directories[i] != 0, Vector2i(directories[i + 1], directories[i + 2]))
	_apply_requests(changes)


## Loads everything that streaming would load with the default source at the global
## [param position] (and every [CopiaSource3D] where it is), before returning: the directories and the draw, impostor and collider sections in range are read, every
## group is created and ready, and impostors are linked, with no frame budget. It uses the same
## decisions as [method update_streaming] (the same ranges and margins) and waits for the worker
## reads on the main thread. The streaming position becomes [param position], so the next regular
## update does not unload what was loaded (when the node has a [member target], put it there).
## With [member use_default_source] off, [param position] is ignored; see [method load_sources_now].
##
## It stalls the calling frame for as long as the loading takes, so use it for moments a loading
## screen covers: a level start, a respawn, a fast travel, a screenshot tool. A background build
## that is running is waited for first. Works in the editor with [member editor_preview] on.
## Returns [code]{ok, error, groups, objects, instances, bodies, usec, timed_out}[/code]: the live
## groups, the drawer's [RenderingServer] instances ([code]objects[/code]: one per batch or single
## instance, plus shadow twins), the instances they draw at the current density
## ([code]instances[/code]) and the collider bodies of the store afterwards, and the time spent. [code]ok[/code]
## is false, with [code]error[/code] set and nothing created, when the node is not in the world, not
## visible, has no data directory or does not stream; it is also false with [code]timed_out[/code]
## true when [param timeout_sec] ran out first (the loading then goes on in later frames).
func load_now(position: Vector3, timeout_sec := 10.0) -> Dictionary:
	return _load_blocking(update_streaming.bind(position), timeout_sec)


## [method load_now] for every source: blocks until the surroundings of every enabled
## [CopiaSource3D] and of the default source (at [member target] or the current camera, when
## [member use_default_source] is on) exist, with no frame budget. Same result and failures as
## [method load_now]. Use it behind a loading screen, or when a view cuts to another place.
func load_sources_now(timeout_sec := 10.0) -> Dictionary:
	return _load_blocking(update_streaming_all, timeout_sec)


func _load_blocking(update: Callable, timeout_sec: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"ok": false, "error": "", "groups": 0, "objects": 0, "instances": 0, "bodies": 0, "usec": 0, "timed_out": false}
	if _drawer == null:
		result.error = "the node is not in the world"
	elif not is_visible_in_tree():
		result.error = "the node is not visible"
	elif data_directory.is_empty():
		result.error = "no data directory"
	elif not _streaming():
		result.error = "the node does not stream (editor_preview is off)"
	if not result.error.is_empty():
		return result
	_quiesce()
	var deadline := started + int(timeout_sec * 1000000.0)
	update.call()
	_timer = 0.0
	while true:
		_collect_tasks()
		_drain_results()
		_check_replacements()
		if _update_needed:
			update.call()
		_colliders.step(LOAD_NOW_BUDGET_USEC)
		_drawer.step(LOAD_NOW_BUDGET_USEC)
		_check_replacements()
		if is_settled():
			break
		if Time.get_ticks_usec() >= deadline:
			result.timed_out = true
			result.error = "timed out"
			break
		if not _tasks.is_empty():
			WorkerThreadPool.wait_for_task_completion(_tasks.pop_back())
		else:
			OS.delay_usec(200)
	_update_shadows()
	_update_settled()
	result.ok = not result.timed_out
	result.groups = _group_counts.draw + _group_counts.impostor + _group_counts.collider
	result.objects = int(_drawer.get_stats().get("objects", 0))
	result.instances = int(_drawer.get_stats().get("instances", 0))
	result.bodies = int(_colliders.get_stats().get("bodies", 0))
	result.usec = Time.get_ticks_usec() - started
	return result


## True when streaming has caught up: no cell directory or section read in flight, nothing queued
## for creation or freeing in the drawer or the colliders, no group still being replaced and no
## rebuild running. [signal streaming_settled] is emitted when this turns from false to true.
func is_settled() -> bool:
	if _drawer == null:
		return true
	if SourceScript._revision != _source_revision:
		return false  # a source changed and the update that follows has not run
	if _update_needed or _build_thread != null or not _requests.is_empty() or not _dir_requests.is_empty() or not _replacing.is_empty():
		return false
	for stats in [_drawer.get_stats(), _colliders.get_stats()]:
		if int(stats.get("pending_create", 0)) != 0 or int(stats.get("pending_free", 0)) != 0:
			return false
	return true


func _update_settled() -> void:
	var settled := is_settled()
	if settled and not _was_settled:
		_was_settled = true
		streaming_settled.emit()
	else:
		_was_settled = settled


## Store counts: cells known (file names) and cached (directories read), groups live by kind,
## work pending, and the drawer's and colliders' own stats. [code]pending[/code] is 0 when
## nothing is in flight, queued or being built. [code]step_usec[/code] is the main-thread time of
## the last frame's collider and drawer steps.
func get_stats() -> Dictionary:
	var drawer_stats: Dictionary = _drawer.get_stats() if _drawer != null else {}
	var collider_stats: Dictionary = _colliders.get_stats() if _colliders != null else {}
	var building := _build_thread != null
	var pending := _requests.size() + _dir_requests.size() + _replacing.size() + _tasks.size()
	pending += int(building) + int(_rebuild_timer >= 0.0)
	pending += int(drawer_stats.get("pending_create", 0)) + int(drawer_stats.get("pending_free", 0))
	pending += int(collider_stats.get("pending_create", 0)) + int(collider_stats.get("pending_free", 0))
	return {
		"cells_known": _cells_known.size(),
		"far_known": _far_known.size(),
		"cells_cached": _cell_dirs.size(),
		"far_cached": _far_dirs.size(),
		"groups": _group_counts.draw + _group_counts.impostor + _group_counts.collider,
		"groups_by_kind": _group_counts.duplicate(),
		"loading": _requests.size(),
		"directory_reads": _dir_requests.size(),
		"tasks": _tasks.size(),
		"replacing": _replacing.size(),
		"building": building,
		"rebuild_scheduled": _rebuild_timer >= 0.0,
		"pending": pending,
		"step_usec": _last_step_usec,
		"excluded_rects": _excluded_rects.size(),
		"draw_overrides": _draw_overrides.size() + _impostor_overrides.size(),
		"drawer": drawer_stats,
		"colliders": collider_stats,
		"sources": _source_stats(),
	}


# One entry per source of the last update: what it is and how many live groups it needs by kind
# (a group needed by several sources counts for each).
func _source_stats() -> Array:
	var result := []
	for s in _source_count:
		var node: Node = _source_nodes[s]
		result.append({
			"name": "default" if node == null else String(node.name),
			"node": node,
			"position": _source_globals[s],
			"range_scale": _source_scales[s],
			"density": _source_densities[s],
			"colliders": _source_colliders[s] != 0,
			"shadows": _source_shadows[s] != 0,
			"priority": _source_priorities[s],
			"groups": {"draw": 0, "impostor": 0, "collider": 0},
		})
	if _source_count == 0 or _streamer == null:
		return result
	var counts: PackedInt32Array = _streamer.get_source_counts(_source_points, _source_scales, _source_colliders)
	for s in _source_count:
		result[s].groups = {"draw": counts[s * 3], "impostor": counts[s * 3 + 1], "collider": counts[s * 3 + 2]}
	return result


## The live groups, as [code][{object_path, cell, kind, group}][/code], groups being replaced
## included.
func get_loaded_groups() -> Array:
	var result := []
	for cell in _live:
		for path in _live[cell]:
			for kind in _live[cell][path]:
				_append_group_infos(_live[cell][path][kind], result)
	for cell in _far_live:
		for path in _far_live[cell]:
			_append_group_infos(_far_live[cell][path], result)
	return result


## The [code]CopiaDrawer[/code] of the node while it is in the world, else null. Read from it
## (group info and RIDs); groups are the node's to add and remove.
func get_drawer() -> Object:
	return _drawer


## The [code]CopiaColliders[/code] of the node while it is in the world, else null.
func get_colliders() -> Object:
	return _colliders


## The object, cell and instance of a collider body, for a ray hit's [code]rid[/code]:
## [code]{object_path, cell, index}[/code], where [code]index[/code] counts the instances of the
## cell's collider section (those at or above the physics settings' minimum scale). [code]{}[/code]
## when the body is not the store's.
func get_collider_info(body: RID) -> Dictionary:
	if _colliders == null:
		return {}
	var found: Dictionary = _colliders.find_body(body)
	if found.is_empty() or not _collider_records.has(found.group):
		return {}
	var record: _Record = _collider_records[found.group]
	return {"object_path": record.path, "cell": record.cell, "index": found.index}


## Leaves out every cell and far cell whose centre lies in one of [param rects] (local X and Z,
## [method Rect2.has_point]): nothing is read, loaded, drawn or given a collider there, in the
## editor and in a game. Cells that become excluded are unloaded at the next update and cells that
## stop being excluded load again, as streaming decides. Replaces the previous list; an empty list
## excludes nothing. Run-time state: not saved with the scene. [method to_nodes] ignores it.
func set_excluded_rects(rects: Array[Rect2]) -> void:
	var cleaned: Array[Rect2] = []
	for rect in rects:
		cleaned.append(rect.abs())
	if cleaned == _excluded_rects:
		return
	_excluded_rects = cleaned
	if _streamer != null:
		_streamer.set_excluded_rects(_excluded_rects)
	_update_needed = true


## The rectangles given to [method set_excluded_rects].
func get_excluded_rects() -> Array[Rect2]:
	return _excluded_rects.duplicate()


## Merges [param params] into the draw params of the object at [param object_path] (the keys of
## [method CopiaObject._get_draw_params], for example [code]extra_cull_margin[/code]) and
## [param impostor_params] into its impostor draw params, for the live groups now and for every
## group created later, without touching the object or its resources. Only the keys whose value
## changes reach the drawer. Replaces an earlier override of the object. Run-time state: not saved,
## and not applied by [method to_nodes].
func set_draw_override(object_path: String, params: Dictionary, impostor_params := {}) -> void:
	if params.is_empty():
		_draw_overrides.erase(object_path)
	else:
		_draw_overrides[object_path] = params.duplicate()
	if impostor_params.is_empty():
		_impostor_overrides.erase(object_path)
	else:
		_impostor_overrides[object_path] = impostor_params.duplicate()
	var info = _objects.get(object_path)
	if info != null:
		_apply_draw_params(info)


## Removes the override of [param object_path]: its groups take the object's own params again.
func clear_draw_override(object_path: String) -> void:
	set_draw_override(object_path, {}, {})


## The override of [param object_path] as [code]{draw, impostor}[/code], or [code]{}[/code].
func get_draw_override(object_path: String) -> Dictionary:
	if not _draw_overrides.has(object_path) and not _impostor_overrides.has(object_path):
		return {}
	return {"draw": _draw_overrides.get(object_path, {}).duplicate(), "impostor": _impostor_overrides.get(object_path, {}).duplicate()}


## Plain [MultiMeshInstance3D] nodes for the built cells intersecting [param rect] (local X and
## Z): one per batch of a multimesh object, one per object and cell for a single-instance object,
## under a [Node3D] per cell, named [code]<cell>/<object name>_<batch>[/code]. The object name is
## the object's path relative to the longest directory common to all object paths in the result
## (every path that has a built cell in [param rect]), with the extension dropped and slashes
## replaced by [code]_[/code]: [code]a/fern_01.tres[/code] and [code]b/fern_01.tres[/code] give
## [code]a_fern_01[/code] and [code]b_fern_01[/code], so names are unique and stable. Sections are
## read synchronously. The nodes are returned, not added to the tree. Low-LOD shadows become
## plain shadows off; the impostors are not included. A [MultiMeshInstance3D] has no per-surface
## override materials, so an object's per-surface materials come with the mesh: the nodes use
## [method CopiaObject.get_surface_material_mesh], a copy of the mesh carrying them.
func to_nodes(rect: Rect2) -> Node3D:
	var root := Node3D.new()
	root.name = "CopiaNodes"
	rect = rect.abs()
	var entries: Array = []
	var all_paths: Array = []
	for entry in _list_built():
		var cell_rect := Rect2(Vector2(entry.cell) * cell_size, Vector2.ONE * cell_size)
		if entry.kind != "cell" or not cell_rect.intersects(rect):
			continue
		entries.append(entry)
		if entry.get("ok", false):
			for path in entry.objects:
				if not all_paths.has(path):
					all_paths.append(path)
	var common := _common_directory(all_paths)
	for entry in entries:
		var cell: Vector2i = entry.cell
		var file := _cell_file(false, cell)
		var directory: Dictionary = entry
		if not directory.get("ok", false):
			push_warning("CopiaStore3D: %s cannot be read" % file)
			continue
		var cell_node := Node3D.new()
		cell_node.name = _cell_name(cell)
		for path in directory.objects:
			var info = _info(path)
			if info == null or info.object.mesh == null:
				continue
			var section: Dictionary = _native_static("CopiaCells", "read_section", [file, path, "draw"])
			if not section.get("ok", false):
				continue
			var base := _node_name_of(path, common)
			if section.kind == "multimesh":
				for b in section.batch_count:
					var multimesh := MultiMesh.new()
					multimesh.transform_format = MultiMesh.TRANSFORM_3D
					multimesh.use_colors = true
					multimesh.use_custom_data = true
					multimesh.mesh = info.object.get_surface_material_mesh()
					multimesh.instance_count = section.counts[b]
					multimesh.buffer = section.buffers[b]
					multimesh.custom_aabb = section.bounds[b]
					cell_node.add_child(_multimesh_node(multimesh, info, "%s_%d" % [base, b], Transform3D(Basis.IDENTITY, section.origins[b])))
			elif section.count > 0:
				var multimesh := MultiMesh.new()
				multimesh.transform_format = MultiMesh.TRANSFORM_3D
				multimesh.mesh = info.object.get_surface_material_mesh()
				multimesh.instance_count = section.count
				multimesh.buffer = _rows_from_columns(section.transforms)
				cell_node.add_child(_multimesh_node(multimesh, info, "%s_0" % base, Transform3D.IDENTITY))
		if cell_node.get_child_count() > 0:
			root.add_child(cell_node)
			for child in cell_node.get_children():
				child.owner = root
			cell_node.owner = root
		else:
			cell_node.free()
	return root


# The longest directory (with a trailing slash, or empty) that every path is under, compared by
# whole directory names.
func _common_directory(paths: Array) -> String:
	if paths.is_empty():
		return ""
	var common: PackedStringArray = paths[0].get_base_dir().split("/")
	for path in paths:
		var parts: PackedStringArray = path.get_base_dir().split("/")
		var shared := 0
		while shared < mini(common.size(), parts.size()) and common[shared] == parts[shared]:
			shared += 1
		common = common.slice(0, shared)
	return "/".join(common) + "/" if common.size() > 0 else ""


# The object's path below [param common], extension dropped, slashes as underscores.
func _node_name_of(path: String, common: String) -> String:
	var relative := path.trim_prefix(common) if path.begins_with(common) else path
	return relative.get_basename().replace("/", "_").validate_node_name()


# --- Life cycle -------------------------------------------------------------------------------


func _start() -> void:
	if not _ensure_native():
		push_error("CopiaStore3D: the Copia native library is not loaded.")
		return
	_drawer = ClassDB.instantiate("CopiaDrawer")
	_drawer.set_scenario(get_world_3d().scenario)
	_drawer.set_transform(global_transform)
	_drawer.set_density(density)
	_colliders = ClassDB.instantiate("CopiaColliders")
	_colliders.set_space(get_world_3d().space)
	_colliders.set_transform(global_transform)
	if _streamer == null:
		_streamer = ClassDB.instantiate("CopiaStreamer")
		_configure_streamer()
		_push_objects()
	# Sources present now are found by the first regular update; later changes force one.
	_source_revision = SourceScript._revision
	_report_debug_views()
	_scan()


func _stop() -> void:
	_unload_all()
	_wait_tasks()
	_loader.take()
	_requests.clear()
	_dir_requests.clear()
	_cell_dir_pending.clear()
	_far_dir_pending.clear()
	if _streamer != null:
		_streamer.clear_pending()
	# Dropping the native owners frees every server object, created or queued.
	_drawer = null
	_colliders = null
	_update_needed = false
	_was_settled = true
	_sources_known = false
	_report_debug_views()  # nothing drawn: no view in use


static func _ensure_native() -> bool:
	if not ClassDB.class_exists("CopiaDrawer"):
		GDExtensionManager.load_extension(EXTENSION)
	return ClassDB.class_exists("CopiaDrawer")


static func _native_static(native_class: String, method: String, arguments: Array) -> Variant:
	if not _ensure_native():
		push_error("CopiaStore3D: the Copia native library is not loaded.")
		return null
	return Callable(ClassDB, "class_call_static").callv([native_class, method] + arguments)


# Hands the grid, margins and movement threshold to the streamer.
func _configure_streamer() -> void:
	if _streamer == null:
		return
	_streamer.set_grid(cell_size, impostor_cell_size)
	_streamer.set_margins(load_margin, unload_margin)
	_streamer.set_movement_threshold(movement_threshold)
	_streamer.set_excluded_rects(_excluded_rects)


# Hands every resolved object's reach values to the streamer.
func _push_objects() -> void:
	if _streamer == null:
		return
	for path in _objects:
		if _objects[path] != null:
			_push_info(_objects[path])


func _push_info(info: Dictionary) -> void:
	if _streamer != null:
		_streamer.set_object(info.path, true, info.has_mesh, info.draw_reach, info.has_physics, _collider_reach(info), info.has_impostor, info.impostor_reach)


func _streaming() -> bool:
	if _drawer == null or not is_visible_in_tree() or data_directory.is_empty():
		return false
	return editor_preview or not Engine.is_editor_hint()


func _target_position() -> Variant:
	var node: Node3D = null
	if not target.is_empty():
		node = get_node_or_null(target) as Node3D
	elif Engine.is_editor_hint():
		if Engine.has_singleton("EditorInterface"):
			var viewport = Engine.get_singleton("EditorInterface").get_editor_viewport_3d(0)
			if viewport != null:
				node = viewport.get_camera_3d()
	elif get_viewport() != null:
		node = get_viewport().get_camera_3d()
	return node.global_position if node != null else null


# Forgets every cached file and loaded group; used when the data directory or a grid size changes.
func _reset_data() -> void:
	_unload_all()
	_cancel_directory_reads()
	_cells_known.clear()
	_far_known.clear()
	_cell_dirs.clear()
	_far_dirs.clear()
	_dir_paths.clear()
	_set_paths.clear()
	_set_paths_loaded = false
	_scanned = false
	_ranges_dirty = true
	if _streamer != null:
		_configure_streamer()
		_streamer.clear_cells()
	if _drawer != null:
		_scan()


# Knows the built and far cells and their objects from the cells index, and the objects of the
# set files from the sets index; opens no per-cell file.
func _scan() -> void:
	_cells_known.clear()
	_far_known.clear()
	if _streamer != null:
		_streamer.clear_known()
	for entry in _list_built():
		(_far_known if entry.kind == "far" else _cells_known)[entry.cell] = true
		if _streamer != null:
			_streamer.set_known(entry.kind == "far", entry.cell, true)
		for path in entry.objects:
			if not _dir_paths.has(path):
				_dir_paths[path] = true
	_load_object_paths()
	_scanned = true
	_ranges_dirty = true


# Every built and far cell with its object summary (CopiaCells.list_cells).
func _list_built() -> Array:
	if data_directory.is_empty():
		return []
	return _native_static("CopiaCells", "list_cells", [data_directory])


func _cell_file(is_far: bool, cell: Vector2i) -> String:
	return data_directory.path_join("far" if is_far else "cells").path_join(_cell_name(cell) + CELL_EXTENSION)


static func _cell_name(cell: Vector2i) -> String:
	return "%d_%d" % [cell.x, cell.y]


# --- Object index and objects -----------------------------------------------------------------


# The object paths of the set files, from the sets index (CopiaSets.list_objects).
func _load_object_paths() -> void:
	_set_paths_loaded = true
	if data_directory.is_empty():
		return
	var paths := {}
	for path in _native_static("CopiaSets", "list_objects", [data_directory]):
		paths[path] = true
	if paths != _set_paths:
		_set_paths = paths
		_ranges_dirty = true


func _all_object_paths() -> Array:
	# A store asked before it entered the world (stale_cells() from a tool) has not read them yet.
	if not _set_paths_loaded:
		_load_object_paths()
	var paths := _set_paths.duplicate()
	paths.merge(_dir_paths)
	var result := paths.keys()
	result.sort()
	return result


func _descriptors() -> Dictionary:
	var result := {}
	for path in _all_object_paths():
		var info = _info(path)
		if info != null:
			result[path] = info.object.descriptor(impostor_cell_size)
	return result


# What the node keeps per object path: the object and the values streaming reads often. null when
# the path does not resolve.
func _info(path: String) -> Variant:
	if _objects.has(path):
		return _objects[path]
	var object = ObjectScript.resolve(path)
	if object == null:
		_objects[path] = null
		return null
	var info := {"object": object, "path": path, "shapes": null, "shape_refs": [], "signature": null, "has_mesh": false}
	info.on_changed = _on_object_changed.bind(path)
	info.on_build = _on_build_inputs_changed.bind(path)
	object.changed.connect(info.on_changed)
	object.build_inputs_changed.connect(info.on_build)
	# The draw params the live groups were given, so a change passes only what differs.
	info.draw_params = _object_params(object, path, false)
	info.impostor_params = _object_params(object, path, true)
	_refresh_info(info)
	_objects[path] = info
	_ranges_dirty = true
	_report_debug_views()
	return info


func _disconnect_object(info) -> void:
	if info == null:
		return
	if info.object.changed.is_connected(info.on_changed):
		info.object.changed.disconnect(info.on_changed)
	if info.object.build_inputs_changed.is_connected(info.on_build):
		info.object.build_inputs_changed.disconnect(info.on_build)


func _refresh_info(info: Dictionary) -> void:
	var object = info.object
	var render = object.render if object.render != null else _default_render
	info.range_end = render.visibility_range_end
	info.impostor_range_end = render.impostor_range_end
	info.draw_reach = render.visibility_range_end if render.visibility_range_end > 0.0 else INF
	info.impostor_reach = render.impostor_range_end if render.impostor_range_end > 0.0 else INF
	info.has_impostor = object.impostor_mesh != null
	info.impostor_batch_size = render.impostor_batch_size
	info.has_mesh = object.mesh != null
	var physics = object.physics
	info.has_physics = physics != null and physics.has_collider()
	info.physics_distance = physics.distance if physics != null else 0.0
	var signature := []
	if physics != null:
		signature = [physics, physics.kind, physics.shapes.duplicate(), physics.shape_transforms.duplicate(), physics.collision_layer, physics.collision_mask, object.mesh]
	if signature != info.signature:
		info.signature = signature
		info.shapes = null
	_push_info(info)


func _collider_reach(info: Dictionary) -> float:
	if info.physics_distance > 0.0:
		return info.physics_distance
	if collider_distance > 0.0:
		return collider_distance
	return info.draw_reach


# The shapes of an object's collider as CopiaColliders takes them; the Shape3D resources are kept
# alive by the info.
func _shapes(info: Dictionary) -> Array:
	if info.shapes == null:
		var refs: Array = info.object.physics.resolve_shapes(info.object.mesh) if info.has_physics else []
		var shapes := []
		for entry in refs:
			shapes.append({"shape": entry.shape.get_rid(), "transform": entry.transform})
		info.shape_refs = refs
		info.shapes = shapes
	return info.shapes


func _compute_ranges() -> void:
	_max_draw_range = 0.0
	_max_collider_range = 0.0
	_max_impostor_range = 0.0
	var any := false
	for path in _all_object_paths():
		var info = _info(path)
		if info == null:
			continue
		any = true
		_max_draw_range = maxf(_max_draw_range, info.draw_reach)
		if info.has_physics:
			_max_collider_range = maxf(_max_collider_range, _collider_reach(info))
		if info.has_impostor:
			_max_impostor_range = maxf(_max_impostor_range, info.impostor_reach)
	if not any:
		# No object known (the indexes list none that resolves): every directory is read.
		_max_draw_range = INF
		_max_collider_range = INF
		_max_impostor_range = INF
	_ranges_dirty = false
	if _streamer != null:
		_streamer.set_max_ranges(_max_draw_range, _max_collider_range, _max_impostor_range)


# Any change: the load-time values that changed go to the live groups at once; no build. Only the
# keys whose value differs from the object's previous draw params are passed, so a game that
# changes one setting (a cull margin that follows the wind) does not re-apply the others.
func _on_object_changed(path: String) -> void:
	var info = _objects.get(path)
	if info == null:
		return
	var old_signature = info.signature
	_refresh_info(info)
	_ranges_dirty = true
	_apply_draw_params(info, info.signature != old_signature)
	update_configuration_warnings()


# The object's draw params (or impostor draw params) with the run-time override merged in, then
# its debug view applied: after the hooks and the override, so a game's own material_override is
# replaced too, and only the material (and for the LOD view the mesh) changes.
func _object_params(object, path: String, impostor: bool) -> Dictionary:
	var params: Dictionary = object._get_impostor_draw_params() if impostor else object._get_draw_params()
	var override: Dictionary = (_impostor_overrides if impostor else _draw_overrides).get(path, {})
	if not override.is_empty():
		params = params.duplicate()
		params.merge(override, true)
	var view := DebugScript.effective_view(object, debug_view)
	if view == RenderScript.DebugView.OFF:
		_debug_views.erase(path)
		return params
	_debug_views[path] = view
	var batch_size := 0.0
	var store_inverse := Transform3D.IDENTITY
	if view == RenderScript.DebugView.BATCHES or view == RenderScript.DebugView.SHADOW_RANGE:
		var descriptor: Dictionary = object.descriptor(impostor_cell_size)
		if impostor:
			batch_size = descriptor.impostor_batch_size if descriptor.impostor_batch_size > 0.0 else cell_size
		elif descriptor.draw == "multimesh":
			batch_size = descriptor.batch_size
		if is_inside_tree():
			store_inverse = global_transform.affine_inverse()
	return DebugScript.apply(params, object, impostor, view, batch_size, store_inverse, path.hash() & 0x7fffffff)


# Tells the debug views which views this store draws with, so caches no store uses are released.
# Called after the drawer has the new params; nothing is in use while the node is out of the world.
func _report_debug_views() -> void:
	var views := {}
	if _drawer != null:
		for path in _debug_views:
			views[_debug_views[path]] = true
	DebugScript.set_store_views(get_instance_id(), views)


# Passes the draw params that changed since the live groups were given theirs (an object change
# or an override) to those groups, and reloads the colliders when [param physics_changed].
func _apply_draw_params(info: Dictionary, physics_changed := false) -> void:
	var path: String = info.path
	var draw_now := _object_params(info.object, path, false)
	var impostor_now := _object_params(info.object, path, true)
	var draw_diff := _params_diff(info.draw_params, draw_now)
	var impostor_diff := _params_diff(info.impostor_params, impostor_now)
	info.draw_params = draw_now
	info.impostor_params = impostor_now
	var relink: bool = draw_diff.has("visibility_end")
	# Group ids by range scale, so groups that take the same values get them in one call.
	var draw_ids := {}
	var impostor_ids := {}
	for cell in _live:
		var records: Dictionary = _live[cell].get(path, {})
		if records.has("draw"):
			var record: _Record = records.draw
			if not draw_diff.is_empty():
				for id in [record.group, record.old_group]:
					if id != 0:
						draw_ids.get_or_add(record.range_scale, PackedInt64Array()).append(id)
		if records.has("collider") and physics_changed:
			records.collider.revision = -1  # reloaded with the new shapes by the next update
			_sync_stale(records.collider)
	if not impostor_diff.is_empty():
		for cell in _far_live:
			if _far_live[cell].has(path):
				var record: _Record = _far_live[cell][path]
				for id in [record.group, record.old_group]:
					if id != 0:
						impostor_ids.get_or_add(record.range_scale, PackedInt64Array()).append(id)
	for scale in draw_ids:
		_drawer.set_groups_params(draw_ids[scale], _scaled(draw_diff, scale))
	for scale in impostor_ids:
		_drawer.set_groups_params(impostor_ids[scale], _scaled(impostor_diff, scale))
	if relink:
		for cell in _live:
			var record: _Record = _live[cell].get(path, {}).get("draw")
			if record != null and record.group != 0:
				_link_child(record)  # the swap distance follows the range end
	_report_debug_views()


# The keys of [param now] whose value differs from [param before] (every key when there was none).
static func _params_diff(before: Variant, now: Dictionary) -> Dictionary:
	if before == null:
		return now.duplicate()
	var diff := {}
	for key in now:
		if not before.has(key) or typeof(before[key]) != typeof(now[key]) or before[key] != now[key]:
			diff[key] = now[key]
	return diff


# A params change as a group needed at [param scale] takes it: a range end scaled as in _draw_params.
static func _scaled(params: Dictionary, scale: float) -> Dictionary:
	if scale == 1.0 or not params.has("visibility_end") or params.visibility_end <= 0.0:
		return params
	var scaled := params.duplicate()
	scaled.visibility_end = params.visibility_end * scale
	return scaled


func _on_build_inputs_changed(_path: String) -> void:
	if watch_objects and not data_directory.is_empty():
		_rebuild_timer = REBUILD_DELAY


# --- Builds -----------------------------------------------------------------------------------


# Brings the directory to one writer and no reader: finishes a background build and waits for
# the worker reads in flight.
func _quiesce() -> void:
	if _build_thread != null:
		var result: Dictionary = _build_thread.wait_to_finish()
		_build_thread = null
		_finish_build(result)
	_settle_reads()


# Waits for every worker read, including those that handling a result starts.
func _settle_reads() -> void:
	while true:
		_wait_tasks()
		_drain_results()
		if _tasks.is_empty():
			return


func _build_now(cells: Array, force: bool) -> Dictionary:
	var result: Dictionary = _native_static("CopiaBuild", "build_cells", [data_directory, cell_size, cells, _descriptors(), force])
	_apply_build_result(result)
	return result


func _empty_build() -> Dictionary:
	return {"ok": true, "error": "", "written": PackedStringArray(), "unchanged": PackedStringArray(), "deleted": PackedStringArray(), "skipped": PackedStringArray(), "defaulted": PackedStringArray()}


func _poll_build(delta: float) -> void:
	if _build_thread != null:
		if _build_thread.is_alive():
			return
		var result: Dictionary = _build_thread.wait_to_finish()
		_build_thread = null
		_finish_build(result)
	if _rebuild_timer >= 0.0:
		_rebuild_timer -= delta
		if _rebuild_timer < 0.0:
			_start_background_build()


# Starts a build on the build thread: the stale cells (cells empty) or the given ones. A debounced
# object-change rebuild that was scheduled is covered by it when it builds the stale cells.
func _start_background_build(cells := [], force := false) -> void:
	if cells.is_empty() and not force:
		_rebuild_timer = -1.0
	if data_directory.is_empty() or not _ensure_native():
		return
	if cells.is_empty() and not DirAccess.dir_exists_absolute(data_directory):
		return
	# Readers finish before the build writes; new reads wait until it is done.
	_settle_reads()
	_build_thread = Thread.new()
	_build_thread.start(_build_job.bind(data_directory, cell_size, _descriptors(), cells.duplicate(), force))
	build_started.emit()


# Runs on the build thread: touches only its arguments.
static func _build_job(directory: String, size: float, objects: Dictionary, cells: Array, force: bool) -> Dictionary:
	var started := Time.get_ticks_usec()
	var stale := []
	if cells.is_empty():
		stale = ClassDB.class_call_static("CopiaBuild", "stale_cells", directory, size, objects)
		for entry in stale:
			if entry.get("kind") == "error":
				return {"ok": false, "error": entry.get("error", "invalid descriptors"), "stale": stale, "usec": Time.get_ticks_usec() - started}
		cells = stale
	var result: Dictionary
	if cells.is_empty():
		result = {"ok": true, "error": "", "written": PackedStringArray(), "unchanged": PackedStringArray(), "deleted": PackedStringArray(),
				"skipped": PackedStringArray(), "defaulted": PackedStringArray(), "cell_count": 0, "far_count": 0}
	else:
		result = ClassDB.class_call_static("CopiaBuild", "build_cells", directory, size, cells, objects, force)
	result.stale = stale
	result.usec = Time.get_ticks_usec() - started
	return result


func _finish_build(result: Dictionary) -> void:
	_update_needed = true
	_last_build = result
	if not result.get("ok", false):
		push_warning("CopiaStore3D: background build failed: %s" % result.get("error"))
	_apply_build_result(result)
	build_finished.emit(result)


# Refreshes the files a build wrote or deleted: known cells, cached directories, loaded groups.
func _apply_build_result(result: Dictionary) -> void:
	if result == null:
		return
	for list_name in ["written", "deleted"]:
		var deleted: bool = list_name == "deleted"
		for relative in result.get(list_name, PackedStringArray()):
			var is_far: bool = relative.begins_with("far/")
			if not is_far and not relative.begins_with("cells/"):
				continue
			var parts: PackedStringArray = relative.get_file().trim_suffix(CELL_EXTENSION).split("_")
			if parts.size() != 2:
				continue
			var cell := Vector2i(parts[0].to_int(), parts[1].to_int())
			var known := _far_known if is_far else _cells_known
			if deleted:
				known.erase(cell)
			else:
				known[cell] = true
			if _streamer != null:
				_streamer.set_known(is_far, cell, not deleted)
			_invalidate(is_far, cell, deleted)


func _invalidate(is_far: bool, cell: Vector2i, deleted: bool) -> void:
	var dirs := _far_dirs if is_far else _cell_dirs
	var pending := _far_dir_pending if is_far else _cell_dir_pending
	if pending.has(cell):
		_dir_requests.erase(pending[cell])
		pending.erase(cell)
	var had := dirs.has(cell)
	if had:
		_previous_dirs[[is_far, cell]] = dirs[cell]
	dirs.erase(cell)
	if _streamer != null:
		_streamer.set_directory_pending(is_far, cell, false)
		_streamer.erase_directory(is_far, cell)
	var live := _far_live if is_far else _live
	if deleted:
		if live.has(cell):
			for record in _records_of(is_far, cell):
				_unload(record)
		return
	# A cached or drawn cell is read again now; its groups are replaced once it arrives.
	if had or live.has(cell):
		_read_directory(is_far, cell)


# --- Sources ----------------------------------------------------------------------------------


# Collects the sources of this update: the default source (when on and placed) and every enabled
# CopiaSource3D of the scene tree's source group that applies to this node.
func _gather_sources() -> void:
	_source_revision = SourceScript._revision
	_sources_known = true
	_source_count = 0
	_source_points.clear()
	_source_globals.clear()
	_source_scales.clear()
	_source_densities.clear()
	_source_colliders.clear()
	_source_shadows.clear()
	_source_priorities.clear()
	_source_nodes.clear()
	_shadow_positions.clear()
	if use_default_source and _has_position:
		_add_source(null, _last_position, 1.0, 1.0, true, true, 1.0)
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(SourceScript.GROUP):
		if is_instance_of(node, SourceScript) and node.applies_to(self):
			_add_source(node, node.global_position, node.range_scale, node.density, node.colliders, node.shadows, node.priority)


func _add_source(node: Node, global: Vector3, scale: float, wanted_density: float, with_colliders: bool, with_shadows: bool, weight: float) -> void:
	var local := to_local(global) if is_inside_tree() else global
	_source_points.append(Vector2(local.x, local.z))
	_source_globals.append(global)
	_source_scales.append(maxf(scale, 0.01))
	_source_densities.append(clampf(wanted_density, 0.0, 1.0))
	_source_colliders.append(1 if with_colliders else 0)
	_source_shadows.append(1 if with_shadows else 0)
	_source_priorities.append(maxf(weight, 0.01))
	_source_nodes.append(node)
	if with_shadows:
		_shadow_positions.append(global)
	_source_count += 1


# The shadow range follows the sources with shadows on; nothing is evaluated before the first
# update has placed a source.
func _update_shadows() -> void:
	if _drawer != null and _sources_known and _source_count > 0:
		_drawer.update_cameras(_shadow_positions)


# Applies a quality change of a record that stays (the streamer's density and range scale of its
# needing sources) to its live groups; a draw group's impostor swap distance follows the scale.
func _apply_quality(record: _Record, new_density: float, new_scale: float) -> void:
	var old_scale := record.range_scale
	record.density = new_density
	record.range_scale = new_scale
	var info = _objects.get(record.path)
	if info == null:
		return
	var scaled := {}
	if old_scale != record.range_scale:
		# Only the range end follows the scale; the other values are unchanged.
		var base: Dictionary = info.impostor_params if record.kind == "impostor" else info.draw_params
		scaled = _scaled({"visibility_end": base.get("visibility_end", 0.0)}, record.range_scale)
		scaled.priority = _record_priority(record)
	for id in [record.group, record.old_group]:
		if id == 0:
			continue
		_drawer.set_group_density(id, record.density)
		if not scaled.is_empty():
			_drawer.set_group_params(id, scaled)
	if record.kind == "draw" and old_scale != record.range_scale and record.group != 0:
		_link_child(record)  # the swap distance follows the range scale


func _read_directory(is_far: bool, cell: Vector2i) -> void:
	_token += 1
	_dir_requests[_token] = [is_far, cell]
	(_far_dir_pending if is_far else _cell_dir_pending)[cell] = _token
	if _streamer != null:
		_streamer.set_directory_pending(is_far, cell, true)
	_tasks.append(WorkerThreadPool.add_task(_loader.read_directory.bind(_cell_file(is_far, cell), _token), false, "Copia directory"))


func _request_section(record: _Record, revision: int) -> void:
	_token += 1
	record.token = _token
	record.revision = revision
	record.failed = false
	record.requested_usec = Time.get_ticks_usec()
	_requests[_token] = record
	_sync_stale(record)
	var is_far := record.kind == "impostor"
	var section := "collider" if record.kind == "collider" else "draw"
	_tasks.append(WorkerThreadPool.add_task(_loader.read_section.bind(_cell_file(is_far, record.cell), record.path, section, _token), false, "Copia section"))


# The streamer's records pass: freed records are unloaded, changed ones get their new quality.
# Cells come before far cells, as the streamer lists them.
func _apply_records(changes: Dictionary) -> void:
	var handles: PackedInt64Array = changes.records
	var densities: PackedFloat64Array = changes.densities
	var scales: PackedFloat64Array = changes.scales
	for i in handles.size():
		var record: _Record = _records.get(handles[i])
		if record == null:
			continue
		if densities[i] < 0.0:
			_unload(record)
		else:
			_apply_quality(record, densities[i], scales[i])


# The streamer's new records are requested with the quality it gave them; a reload is a record
# read from an older directory, requested again once no read of it is in flight.
func _apply_requests(changes: Dictionary) -> void:
	var handles: PackedInt64Array = changes.requests
	var kinds: PackedInt32Array = changes.request_kinds
	var cells: PackedInt32Array = changes.request_cells
	var paths: PackedStringArray = changes.request_paths
	var densities: PackedFloat64Array = changes.request_densities
	var scales: PackedFloat64Array = changes.request_scales
	for i in handles.size():
		var kind: String = KIND_NAMES[kinds[i]]
		var cell := Vector2i(cells[i * 2], cells[i * 2 + 1])
		var path := paths[i]
		var record := _new_record(kind, cell, path)
		record.handle = handles[i]
		record.density = densities[i]
		record.range_scale = scales[i]
		_records[record.handle] = record
		if kind == "impostor":
			_far_live.get_or_add(cell, {})[path] = record
		else:
			_live.get_or_add(cell, {}).get_or_add(path, {})[kind] = record
		_request_section(record, _revision_of(record))
	for handle in changes.reloads:
		var record: _Record = _records.get(handle)
		if record == null:
			continue
		var revision := _revision_of(record)
		if record.token != 0 or record.revision == revision:
			continue
		_request_section(record, revision)


# The directory revision of a record's cell (far cell for an impostor).
func _revision_of(record: _Record) -> int:
	return (_far_revision if record.kind == "impostor" else _cell_revision).get(record.cell, 0)


# Tells the streamer whether a record was read from an older directory than its cell's current
# one, so that an update in reach requests it again.
func _sync_stale(record: _Record) -> void:
	if _streamer != null and _records.has(record.handle):
		_streamer.set_record_stale(record.handle, record.revision != _revision_of(record))


func _new_record(kind: String, cell: Vector2i, path: String) -> _Record:
	var record := _Record.new()
	record.kind = kind
	record.cell = cell
	record.path = path
	return record


func _records_of(is_far: bool, cell: Vector2i) -> Array:
	var result := []
	if is_far:
		result.append_array(_far_live.get(cell, {}).values())
	else:
		for per_kind in _live.get(cell, {}).values():
			result.append_array(per_kind.values())
	return result


func _collect_tasks() -> void:
	var i := 0
	while i < _tasks.size():
		if WorkerThreadPool.is_task_completed(_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_tasks[i])
			_tasks[i] = _tasks[_tasks.size() - 1]
			_tasks.pop_back()
		else:
			i += 1


func _wait_tasks() -> void:
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()


func _cancel_directory_reads() -> void:
	_dir_requests.clear()
	_cell_dir_pending.clear()
	_far_dir_pending.clear()
	if _streamer != null:
		_streamer.clear_pending()


func _drain_results() -> void:
	for item in _loader.take():
		var token: int = item[0]
		var data: Dictionary = item[1]
		if _dir_requests.has(token):
			var request: Array = _dir_requests[token]
			_dir_requests.erase(token)
			_on_directory(request[0], request[1], data)
		elif _requests.has(token):
			var record: _Record = _requests[token]
			_requests.erase(token)
			record.token = 0
			_on_section(record, data)
			_sync_stale(record)  # read from an older directory: requested again by the next update


func _on_directory(is_far: bool, cell: Vector2i, directory: Dictionary) -> void:
	var pending := _far_dir_pending if is_far else _cell_dir_pending
	pending.erase(cell)
	if not directory.get("ok", false):
		push_warning("CopiaStore3D: %s: %s" % [_cell_file(is_far, cell), directory.get("error")])
		directory = {"ok": false, "objects": {}}
	elif not is_equal_approx(directory.get("store_cell_size", cell_size), cell_size):
		push_warning("CopiaStore3D: %s was built for cell size %s; rebuild the store." % [_cell_file(is_far, cell), directory.store_cell_size])
		directory = {"ok": false, "objects": {}}
	(_far_dirs if is_far else _cell_dirs)[cell] = directory
	_update_needed = true  # the sections it holds are requested in this frame
	var previous: Dictionary = _previous_dirs.get([is_far, cell], {})
	_previous_dirs.erase([is_far, cell])
	var revisions := _far_revision if is_far else _cell_revision
	revisions[cell] = revisions.get(cell, 0) + 1
	for path in _streamer.set_directory(is_far, cell, directory.objects):
		if not _dir_paths.has(path):
			_dir_paths[path] = true
			_ranges_dirty = true
	# Groups of objects the cell no longer has go now; the others are read again and replaced.
	for record in _records_of(is_far, cell):
		var entry: Dictionary = directory.objects.get(record.path, {})
		var count: int = entry.get("collider_count" if record.kind == "collider" else "instance_count", 0)
		if count == 0:
			_unload(record)
		elif _same_sections(previous, directory, record.path):
			record.revision = revisions[cell]  # the object's sections cannot have changed
		elif record.token == 0 and _build_thread == null:
			_request_section(record, revisions[cell])
	for record in _records_of(is_far, cell):
		_sync_stale(record)


# True when an object's sections in a rebuilt file equal those in the previous one: same set
# inputs, same descriptor hash, same counts. Then its live groups are kept.
static func _same_sections(previous: Dictionary, current: Dictionary, path: String) -> bool:
	if not previous.get("ok", false) or not current.get("ok", false):
		return false
	if previous.inputs.sets != current.inputs.sets or previous.objects.get(path) != current.objects.get(path):
		return false
	var hashes := []
	for directory in [previous, current]:
		var found := ""
		for entry in directory.inputs.objects:
			if entry.path == path:
				found = entry.hash
		hashes.append(found)
	return hashes[0] == hashes[1] and not hashes[0].is_empty()


func _on_section(record: _Record, section: Dictionary) -> void:
	if not section.get("ok", false):
		record.failed = true
		push_warning("CopiaStore3D: %s of %s in %s: %s" % [record.kind, record.path, _cell_name(record.cell), section.get("error")])
		return
	var info = _objects.get(record.path)
	if info == null:
		_unload(record)
		return
	var id := 0
	if record.kind == "collider":
		if not info.has_physics:
			_unload(record)
			return
		var params := {"collision_layer": info.object.physics.collision_layer, "collision_mask": info.object.physics.collision_mask,
				"object_id": get_instance_id(), "priority": _record_priority(record)}
		id = _colliders.add_group(section.transforms, _shapes(info), params)
		record.count = section.count
		if id != 0:
			_collider_records[id] = record
	else:
		if record.kind == "impostor":
			record.batches.clear()
			var batch_cells: PackedInt32Array = section.batch_cells
			for b in section.batch_count:
				record.batches[Vector2i(batch_cells[b * 2], batch_cells[b * 2 + 1])] = b
		elif record.kind == "draw":
			record.impostor_cells = _impostor_cells(info, record, section)
		var params := _draw_params(info, record)
		if section.kind == "multimesh":
			id = _drawer.add_multimesh_group(section, params)
		else:
			id = _drawer.add_instance_group(section, params)
		if id != 0 and record.density < 1.0:
			_drawer.set_group_density(id, record.density)  # before any object is created
	if id == 0:
		record.failed = true
		return
	if record.group != 0:
		if record.old_group != 0:
			_drop_group(record, record.old_group)
		record.old_group = record.group
		_replacing[record] = true
	record.group = id
	_streamer.set_record_drawn(record.handle)
	_group_counts[record.kind] += 1
	group_added.emit(_group_info(record, id))
	if record.kind == "draw":
		_link_child(record)
	elif record.kind == "impostor" and record.old_group == 0:
		_link_children(record)


func _draw_params(info: Dictionary, record: _Record) -> Dictionary:
	var params: Dictionary = _object_params(info.object, record.path, record.kind == "impostor")
	params.object_id = get_instance_id()
	params.priority = _record_priority(record)
	# A group needed only by sources with a smaller range scale is culled at their scaled range.
	var end: float = params.get("visibility_end", 0.0)
	if end > 0.0 and record.range_scale != 1.0:
		params.visibility_end = end * record.range_scale
	return params


# Creation order of a record's group: the smallest distance ÷ priority among the sources that
# needed it at the last update (0 before any).
func _record_priority(record: _Record) -> float:
	var priority: float = _streamer.get_record_priority(record.handle) if _streamer != null else 0.0
	return priority if is_finite(priority) else 0.0


func _far_of(cell: Vector2i) -> Vector2i:
	var per_far := maxi(roundi(impostor_cell_size / cell_size), 1)
	return Vector2i(floori(float(cell.x) / per_far), floori(float(cell.y) / per_far))


# Impostor batch cells per cell of an object: 1 when its impostor batch is the cell.
func _impostor_per_cell(info) -> int:
	var size: float = info.get("impostor_batch_size", 0.0) if info != null else 0.0
	if size <= 0.0:
		return 1
	return maxi(roundi(cell_size / size), 1)


# The impostor batch cell of each batch or instance of a draw section, as the build assigns
# them, when the object's impostor batch cell is smaller than the cell; empty otherwise.
func _impostor_cells(info: Dictionary, record: _Record, section: Dictionary) -> PackedInt32Array:
	var cells := PackedInt32Array()
	var per_cell := _impostor_per_cell(info)
	if not info.has_impostor or per_cell == 1:
		return cells
	if section.kind == "multimesh":
		# A draw batch lies inside one impostor batch cell: its cell, floor-divided.
		var batch_cells: PackedInt32Array = section.batch_cells
		var batch: float = info.object.descriptor(impostor_cell_size).batch_size
		var per_draw := maxi(roundi(cell_size / batch) / per_cell, 1)
		cells.resize(batch_cells.size())
		for i in batch_cells.size():
			cells[i] = floori(float(batch_cells[i]) / per_draw)
	else:
		var transforms: PackedFloat32Array = section.transforms
		var size := cell_size / per_cell
		var count := transforms.size() / 12
		cells.resize(count * 2)
		for i in count:
			for axis in 2:
				var value := floori(float(transforms[i * 12 + 9 + axis * 2]) / size)
				var low := (record.cell.x if axis == 0 else record.cell.y) * per_cell
				cells[i * 2 + axis] = clampi(value, low, low + per_cell - 1)
	return cells


# Links a draw group to its impostor batch (or, with a finer impostor batch cell, each of its
# batches or instances to theirs), when the far cell's impostor group is live.
func _link_child(record: _Record) -> void:
	var info = _objects.get(record.path)
	if info == null or not info.has_impostor or info.range_end <= 0.0 or record.group == 0:
		return
	var impostor: _Record = _far_live.get(_far_of(record.cell), {}).get(record.path)
	if impostor == null or impostor.group == 0:
		return
	var swap: float = info.range_end * record.range_scale
	if record.impostor_cells.is_empty():
		if impostor.batches.has(record.cell):
			_drawer.link_impostor(impostor.group, record.group, swap, impostor.batches[record.cell])
		return
	var per_object := PackedInt32Array()
	per_object.resize(record.impostor_cells.size() / 2)
	var any := false
	for i in per_object.size():
		var batch: int = impostor.batches.get(Vector2i(record.impostor_cells[i * 2], record.impostor_cells[i * 2 + 1]), -1)
		per_object[i] = batch
		any = any or batch >= 0
	if any:
		_drawer.link_impostor(impostor.group, record.group, swap, per_object)


func _link_children(impostor: _Record) -> void:
	var per_cell := _impostor_per_cell(_objects.get(impostor.path))
	var cells := {}
	for batch_cell in impostor.batches:
		cells[Vector2i(floori(float(batch_cell.x) / per_cell), floori(float(batch_cell.y) / per_cell))] = true
	for cell in cells:
		var record: _Record = _live.get(cell, {}).get(impostor.path, {}).get("draw")
		if record != null and record.group != 0:
			_link_child(record)


func _check_replacements() -> void:
	for record in _replacing.keys():
		var ready := false
		if record.kind == "collider":
			ready = _colliders.get_group_info(record.group).get("ready", true)
		else:
			ready = _drawer.get_group_info(record.group).get("ready", true)
		if not ready:
			continue
		_replacing.erase(record)
		_drop_group(record, record.old_group)
		record.old_group = 0
		if record.kind == "impostor":
			_link_children(record)


func _drop_group(record: _Record, id: int) -> void:
	if id == 0:
		return
	if record.kind == "collider":
		if _colliders != null:
			_colliders.remove_group(id)
		_collider_records.erase(id)
	elif _drawer != null:
		# A linked child's impostor batch goes back to begin 0 inside remove_group, before any of
		# the child's objects is freed; an impostor's children get their own range back.
		_drawer.remove_group(id)
	_group_counts[record.kind] -= 1
	group_removed.emit(_group_info(record, id))


func _unload(record: _Record) -> void:
	if _streamer != null and record.handle != 0:
		_streamer.remove_record(record.handle)
	_records.erase(record.handle)
	if record.token != 0:
		_requests.erase(record.token)
		record.token = 0
	_replacing.erase(record)
	var old := record.old_group
	var current := record.group
	record.old_group = 0
	record.group = 0
	_drop_group(record, old)
	_drop_group(record, current)
	if record.kind == "impostor":
		var per_path: Dictionary = _far_live.get(record.cell, {})
		if per_path.get(record.path) == record:
			per_path.erase(record.path)
		if per_path.is_empty():
			_far_live.erase(record.cell)
	else:
		var per_path: Dictionary = _live.get(record.cell, {})
		var per_kind: Dictionary = per_path.get(record.path, {})
		if per_kind.get(record.kind) == record:
			per_kind.erase(record.kind)
		if per_kind.is_empty():
			per_path.erase(record.path)
		if per_path.is_empty():
			_live.erase(record.cell)


func _unload_all() -> void:
	for cell in _live.keys():
		for record in _records_of(false, cell):
			_unload(record)
	for cell in _far_live.keys():
		for record in _records_of(true, cell):
			_unload(record)
	_requests.clear()


func _group_info(record: _Record, id: int) -> Dictionary:
	return {"object_path": record.path, "cell": record.cell, "kind": record.kind, "group": id, "requested_usec": record.requested_usec}


func _append_group_infos(record: _Record, result: Array) -> void:
	for id in [record.group, record.old_group]:
		if id != 0:
			result.append(_group_info(record, id))


# --- to_nodes helpers -------------------------------------------------------------------------


func _multimesh_node(multimesh: MultiMesh, info: Dictionary, node_name: String, placement: Transform3D) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = multimesh
	node.transform = placement
	var params: Dictionary = info.object._get_draw_params()
	node.visibility_range_begin = params.visibility_begin
	node.visibility_range_end = params.visibility_end
	node.visibility_range_begin_margin = params.visibility_begin_margin
	node.visibility_range_end_margin = params.visibility_end_margin
	node.visibility_range_fade_mode = params.fade_mode
	node.cast_shadow = params.cast_shadows
	node.lod_bias = params.lod_bias
	node.layers = params.layers
	node.gi_mode = params.gi_mode
	node.extra_cull_margin = params.extra_cull_margin
	if info.object.material_override != null:
		node.material_override = info.object.material_override
	return node


# A transform section (basis x, y, z columns, then origin; 12 floats per instance) as a MultiMesh
# buffer (the 3 x 4 matrix row by row): CopiaCells.transforms_to_buffer.
static func _rows_from_columns(transforms: PackedFloat32Array, _count := -1) -> PackedFloat32Array:
	return _native_static("CopiaCells", "transforms_to_buffer", [transforms, false, false])
