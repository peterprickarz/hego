extends SceneTree
## Benchmark on ARTIFICIAL data (NOT part of run_tests.sh; needs a display and Forward+): a
## LargeWorldFixture terrain (procedural noise, not island content) is baked to a region
## directory, then streamed and drawn by the real StrataRenderer + StrataRegionStreamer while a
## scripted camera flies over it. Reports bake time, disk size, resident GPU bytes per tier,
## CPU cache and frame times, and exits non-zero when a Phase C budget
## (docs/development/strata_regions_plan.md, "Budgets") is missed.
##
##   Godot --rendering-method forward_plus --path demo --script res://tests/large_world_benchmark.gd -- [options]
##   --size=8192 --spacing=1     the fixture (default); --size=16384 --spacing=2 for 16 km at 2 m
##   --flight=120                frames per leg (four legs: corner > centre > opposite corner >
##                               descent to a start point > low pass over the centre)
##   --out=build/large_world_bench/   report directory (relative to the repository root); the baked
##                               world goes to <out>/world and is deleted at the start of a run
##   --bake-only                 build and bake, then report without flying
##   --keep-world                keep the regions on disk after the run (they are large)
##
## Needs several GB of RAM (the fixture holds about 330 MB per 8 km, the bake a few hundred MB
## more); run it with no other large Godot or Houdini process open.

const GPU_BUDGET := 64 * 1024 * 1024
const CACHE_BUDGET := 300
const FRAME_BUDGET_MS := 100.0
const GRACE_SECONDS := 1.0
const WARMUP_FRAMES := 30

var size_m := 8192.0
var spacing := 1.0
var leg_frames := 120
var out_directory := "build/large_world_bench"
var bake_only := false
var keep_world := false

func _initialize() -> void:
	run.call_deferred()

static func ms(started: int) -> float:
	return (Time.get_ticks_usec() - started) / 1000.0

static func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	for folder in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(folder))
		DirAccess.remove_absolute(path.path_join(folder))

static func directory_bytes(path: String) -> int:
	var total := 0
	for file in DirAccess.get_files_at(path):
		var handle := FileAccess.open(path.path_join(file), FileAccess.READ)
		if handle != null: total += handle.get_length()
	for folder in DirAccess.get_directories_at(path): total += directory_bytes(path.path_join(folder))
	return total

static func rss_mib() -> float:
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if status == null: return 0.0
	while not status.eof_reached():
		var line := status.get_line()
		if line.begins_with("VmRSS:"): return float(line.replace("\t", " ").split(" ", false)[1]) / 1024.0
	return 0.0

static func percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	if sorted.is_empty(): return 0.0
	return sorted[clampi(int(ceil(fraction * sorted.size())) - 1, 0, sorted.size() - 1)]

func fail(message: String, code: int = 1) -> void:
	push_error("LARGE_WORLD_BENCHMARK: " + message)
	quit(code)

func run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="): size_m = float(argument.trim_prefix("--size="))
		elif argument.begins_with("--spacing="): spacing = float(argument.trim_prefix("--spacing="))
		elif argument.begins_with("--flight="): leg_frames = maxi(2, int(argument.trim_prefix("--flight=")))
		elif argument.begins_with("--out="): out_directory = argument.trim_prefix("--out=")
		elif argument == "--bake-only": bake_only = true
		elif argument == "--keep-world": keep_world = true
	if not bake_only and RenderingServer.get_rendering_device() == null:
		return fail("needs graphical Forward+ (--rendering-method forward_plus without --headless)", 2)
	var repository := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var out := out_directory if out_directory.is_absolute_path() else repository.path_join(out_directory)
	out = out.simplify_path()
	var world := out.path_join("world")
	remove_tree(world)
	DirAccess.make_dir_recursive_absolute(world)
	print("LARGE_WORLD_BENCHMARK ", LargeWorldFixture.describe())
	print("LARGE_WORLD_BENCHMARK size %.0f m, spacing %.2f m, %d frames per leg, report in %s" % [size_m, spacing, leg_frames, out])
	var report := {"label": LargeWorldFixture.describe(), "size_m": size_m, "spacing": spacing, "flight_frames_per_leg": leg_frames}
	if not bake_only: DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var started := Time.get_ticks_usec()
	var terrain := LargeWorldFixture.build(size_m, spacing)
	var fixture_ms := ms(started)
	var materials: Array[StrataMaterial] = terrain.editor_materials.duplicate()
	root.add_child(terrain)
	var rss_fixture := rss_mib()
	started = Time.get_ticks_usec()
	var baked := StrataBake.compile(terrain, {"cell_masks": true, "region_directory": world.path_join(StrataStorage.REGION_DIRECTORY)})
	var bake_ms := ms(started)
	if not baked.ok: return fail("bake failed: %s" % baked.get("message", ""))
	var manifest_path := world.path_join(StrataStorage.RUNTIME_DATA_FILE)
	if ResourceSaver.save(baked.data, manifest_path) != OK: return fail("could not save the manifest")
	var disk_bytes := directory_bytes(world)
	var region_count: int = baked.report.regions
	report["fixture_ms"] = fixture_ms
	report["bake"] = {"ms": bake_ms, "regions": region_count, "grid": [baked.report.grid.x, baked.report.grid.y], "cells": baked.report.cells, "disk_bytes": disk_bytes, "batches": baked.report.get("batches", 0), "peak_regions_in_memory": baked.report.get("peak_regions_in_memory", 0), "rss_mib_after_fixture": rss_fixture, "rss_mib_after_bake": rss_mib()}
	print("LARGE_WORLD_BENCHMARK fixture %.1f s, bake %.1f s (%d regions, %.0f MB on disk, peak %s regions in memory), RSS %.0f MiB" % [fixture_ms / 1000.0, bake_ms / 1000.0, region_count, disk_bytes / 1048576.0, report.bake.peak_regions_in_memory, report.bake.rss_mib_after_bake])
	var budget_misses: Array[String] = []
	if bake_ms > 60000.0 and size_m >= 8192.0: budget_misses.append("bake %.1f s exceeds the 60 s budget" % (bake_ms / 1000.0))
	terrain.free()
	await process_frame
	if bake_only: return finish(out, report, budget_misses, world)

	# A fresh manifest: regions come from the files only.
	var data := ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
	if data == null or not data.validate().get("ok", false): return fail("the manifest does not reload")
	var scene := Node3D.new()
	scene.name = "LargeWorldBenchmark"
	root.add_child(scene)
	var camera := Camera3D.new()
	camera.far = size_m * 2.0
	camera.near = 0.3
	scene.add_child(camera)
	camera.current = true
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.7, 0.85)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.65, 0.7)
	environment.ambient_light_energy = 0.6
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -40, 0)
	scene.add_child(sun)
	var renderer := StrataRenderer.new()
	scene.add_child(renderer)
	var streamer := StrataRegionStreamer.new()
	streamer.renderer = renderer
	streamer.data = data
	streamer.camera = camera
	scene.add_child(streamer)
	var half := size_m * 0.5 - 100.0
	camera.global_position = Vector3(-half, 600.0, -half)
	if not streamer.start(scene, materials): return fail("the renderer rejected the manifest")
	renderer.set_camera(camera)
	var coarse_height := data.coarse_image(StrataRegions.MAP_HEIGHT)
	var coarse_step := StrataRegions.texel_step(data.get_spec(), data.description(StrataRegions.MAP_HEIGHT), data.coarse_level)
	var bounds_origin := data.bounds.position
	var ground := func(point: Vector2) -> float:
		var u := clampi(roundi((point.x - bounds_origin.x) / coarse_step), 0, coarse_height.get_width() - 1)
		var v := clampi(roundi((point.y - bounds_origin.y) / coarse_step), 0, coarse_height.get_height() - 1)
		return coarse_height.get_pixel(u, v).r

	var pass_half := minf(1200.0, size_m * 0.15)
	var corner_a := Vector2(-half, -half)
	var corner_b := Vector2(half, half)
	var pass_start := Vector2(-pass_half, 0)
	var pass_end := Vector2(pass_half, 0)
	var legs := [
		{"name": "corner_to_centre", "from": corner_a, "to": Vector2.ZERO, "high": 600.0, "high_to": 350.0},
		{"name": "centre_to_opposite_corner", "from": Vector2.ZERO, "to": corner_b, "high": 350.0, "high_to": 600.0},
		{"name": "descent_to_pass", "from": corner_b, "to": pass_start, "high": 600.0, "high_to": 15.0},
		{"name": "low_pass_over_centre", "from": pass_start, "to": pass_end, "high": 15.0, "high_to": 15.0},
	]
	for warm in range(WARMUP_FRAMES): await process_frame

	var samples: Array[Dictionary] = []
	var frame_times := PackedFloat64Array()
	var leg_reports: Array[Dictionary] = []
	var flight_started := Time.get_ticks_usec()
	var previous := Time.get_ticks_usec()
	var peak_rss := 0.0
	var worst_after_grace := 0.0
	var slow_frames := 0
	var peak_gpu := 0
	var peak_cached := 0
	var peak_pending := 0
	var peak_cache_bytes := 0
	var position := Vector3(corner_a.x, ground.call(corner_a) + 600.0, corner_a.y)
	for leg: Dictionary in legs:
		var times := PackedFloat64Array()
		var leg_peak_near := 0
		var leg_peak_far := 0
		var leg_peak_pending := 0
		var leg_peak_cached := 0
		var leg_patches := 0
		for frame in range(1, leg_frames + 1):
			var t := float(frame) / leg_frames
			var flat: Vector2 = (leg.from as Vector2).lerp(leg.to as Vector2, t)
			var altitude := lerpf(float(leg.high), float(leg.high_to), t) + float(ground.call(flat))
			var ahead: Vector2 = (leg.to as Vector2) - (leg.from as Vector2)
			position = Vector3(flat.x, altitude, flat.y)
			camera.global_position = position
			var look := position + Vector3(ahead.x, -0.15 * ahead.length() * (1.0 if float(leg.high) > 100.0 else 0.0) * 0.1, ahead.y)
			camera.look_at(look, Vector3.UP)
			await process_frame
			var now := Time.get_ticks_usec()
			var frame_ms := (now - previous) / 1000.0
			previous = now
			var elapsed := (now - flight_started) / 1000000.0
			times.append(frame_ms)
			frame_times.append(frame_ms)
			if elapsed > GRACE_SECONDS:
				worst_after_grace = maxf(worst_after_grace, frame_ms)
				if frame_ms > FRAME_BUDGET_MS: slow_frames += 1
			var s := streamer.stats()
			var r := renderer.get_stats()
			var gpu := int(r.get("gpu_bytes_near", 0)) + int(r.get("gpu_bytes_far", 0)) + int(r.get("gpu_bytes_coarse", 0))
			var cache_bytes := data.cache_bytes()
			peak_gpu = maxi(peak_gpu, gpu)
			peak_cached = maxi(peak_cached, s.cached)
			peak_pending = maxi(peak_pending, s.pending)
			peak_cache_bytes = maxi(peak_cache_bytes, cache_bytes)
			leg_peak_near = maxi(leg_peak_near, s.near)
			leg_peak_far = maxi(leg_peak_far, s.far)
			leg_peak_pending = maxi(leg_peak_pending, s.pending)
			leg_peak_cached = maxi(leg_peak_cached, s.cached)
			leg_patches = maxi(leg_patches, int(r.get("patches", 0)))
			if frame % 10 == 0: peak_rss = maxf(peak_rss, rss_mib())
			samples.append({"leg": leg.name, "frame": frame, "ms": snappedf(frame_ms, 0.01), "near": s.near, "far": s.far, "pending": s.pending, "cached": s.cached, "cache_bytes": cache_bytes, "loads": s.loads, "evictions": s.evictions, "gpu_near": r.get("gpu_bytes_near", 0), "gpu_far": r.get("gpu_bytes_far", 0), "gpu_coarse": r.get("gpu_bytes_coarse", 0), "near_resident": r.get("near_resident", 0), "far_resident": r.get("far_resident", 0), "patches": r.get("patches", 0), "triangles": r.get("triangles", 0), "renderer_cpu_ms": snappedf(float(r.get("process_cpu_ms", 0.0)), 0.01)})
		var sorted := times.duplicate()
		sorted.sort()
		var sum := 0.0
		for value in times: sum += value
		var final_stats := streamer.stats()
		leg_reports.append({"name": leg.name, "frames": times.size(), "mean_ms": sum / times.size(), "p95_ms": percentile(sorted, 0.95), "max_ms": sorted[sorted.size() - 1], "peak_near": leg_peak_near, "peak_far": leg_peak_far, "peak_pending": leg_peak_pending, "peak_cached": leg_peak_cached, "patches": leg_patches, "loads_total": final_stats.loads, "evictions_total": final_stats.evictions})
	var flight_ms := ms(flight_started)
	var all_sorted := frame_times.duplicate()
	all_sorted.sort()
	var last := renderer.get_stats()
	var summary := {"frames": frame_times.size(), "flight_ms": flight_ms, "p50_ms": percentile(all_sorted, 0.5), "p95_ms": percentile(all_sorted, 0.95), "p99_ms": percentile(all_sorted, 0.99), "max_ms": all_sorted[all_sorted.size() - 1], "worst_after_first_second_ms": worst_after_grace, "frames_over_100ms_after_first_second": slow_frames, "peak_gpu_bytes": peak_gpu, "gpu_bytes_near": last.get("gpu_bytes_near", 0), "gpu_bytes_far": last.get("gpu_bytes_far", 0), "gpu_bytes_coarse": last.get("gpu_bytes_coarse", 0), "peak_cached_regions": peak_cached, "peak_cache_bytes": peak_cache_bytes, "peak_pending": peak_pending, "peak_rss_mib": peak_rss, "texture_memory_mib": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0, "video_adapter": RenderingServer.get_video_adapter_name()}
	report["legs"] = leg_reports
	report["flight"] = summary
	report["frames"] = samples
	if peak_gpu >= GPU_BUDGET: budget_misses.append("resident GPU %.1f MiB is not under 64 MiB" % (peak_gpu / 1048576.0))
	if peak_cached >= CACHE_BUDGET: budget_misses.append("CPU region cache peaked at %d regions (budget under %d)" % [peak_cached, CACHE_BUDGET])
	if slow_frames > 0: budget_misses.append("%d frames over %.0f ms after the first second (worst %.1f ms)" % [slow_frames, FRAME_BUDGET_MS, worst_after_grace])
	streamer.stop()
	finish(out, report, budget_misses, world)

func finish(out: String, report: Dictionary, misses: Array[String], world: String) -> void:
	report["budget_misses"] = misses
	report["passed"] = misses.is_empty()
	print("")
	print("LARGE_WORLD_BENCHMARK %s" % report.label)
	if report.has("legs"):
		print("%-28s %6s %8s %8s %8s %5s %5s %5s %6s" % ["leg", "frames", "mean ms", "p95 ms", "max ms", "near", "far", "pend", "cached"])
		for leg: Dictionary in report.legs:
			print("%-28s %6d %8.2f %8.2f %8.2f %5d %5d %5d %6d" % [leg.name, leg.frames, leg.mean_ms, leg.p95_ms, leg.max_ms, leg.peak_near, leg.peak_far, leg.peak_pending, leg.peak_cached])
		var f: Dictionary = report.flight
		print("frames %d p50 %.2f p95 %.2f p99 %.2f max %.2f ms; worst after first second %.2f ms (%d over 100 ms)" % [f.frames, f.p50_ms, f.p95_ms, f.p99_ms, f.max_ms, f.worst_after_first_second_ms, f.frames_over_100ms_after_first_second])
		print("resident GPU near %.1f + far %.1f + coarse %.1f MiB (budget 64); CPU cache peak %d regions, %.1f MiB (budget 300 regions); peak pending %d; RSS peak %.0f MiB; texture memory %.0f MiB; %s" % [f.gpu_bytes_near / 1048576.0, f.gpu_bytes_far / 1048576.0, f.gpu_bytes_coarse / 1048576.0, f.peak_cached_regions, f.peak_cache_bytes / 1048576.0, f.peak_pending, f.peak_rss_mib, f.texture_memory_mib, f.video_adapter])
	print("bake %.1f s, %d regions, %.0f MB on disk; fixture %.1f s" % [report.bake.ms / 1000.0, report.bake.regions, report.bake.disk_bytes / 1048576.0, report.fixture_ms / 1000.0])
	DirAccess.make_dir_recursive_absolute(out)
	var path := out.path_join("large_world_%d_%s.json" % [int(report.size_m), String.num(report.spacing).replace(".", "_")])
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle != null:
		handle.store_string(JSON.stringify(report, "\t"))
		handle.close()
		print("LARGE_WORLD_BENCHMARK report written to ", path)
	if not keep_world: remove_tree(world)
	if misses.is_empty():
		print("LARGE_WORLD_BENCHMARK: PASS")
		quit(0)
	else:
		for miss in misses: push_error("LARGE_WORLD_BENCHMARK budget miss: " + miss)
		print("LARGE_WORLD_BENCHMARK: FAIL")
		quit(1)
