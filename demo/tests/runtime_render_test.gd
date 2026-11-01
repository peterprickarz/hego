extends SceneTree
## Forward+ check of the compiled-only renderer path: a 64 m terrain is baked with StrataBake into
## 4 x 4 regions of 16 cells, exported like the island runtime scene, and StrataRenderer is built
## by configure_runtime() on a plain Node3D. The CPU height the renderer samples must equal the
## runtime data at lattice points, cell interiors and region edges, and a hole cell must be a
## miss for raycast_heightfield(). Every height and hole here is an in-memory fixture.

const BOUNDS := Rect2(-32, -32, 64, 64)
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	create_timer(120.0).timeout.connect(func(): push_error("Runtime render test watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null:
		push_error("Runtime render test requires graphical Forward+.")
		quit(2)
		return
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = BOUNDS
	terrain.set_preview_enabled(false)
	root.add_child(terrain)
	var base := StrataLayer.new()
	base.name = "Base"
	base.data.sample_spacing = 2.0
	base.data.grid_origin = BOUNDS.position
	terrain.add_child(base)
	var image := Image.create(33, 33, false, Image.FORMAT_RF)
	for y in range(33):
		for x in range(33):
			image.set_pixel(x, y, Color(3.0 + 0.1 * x - 0.05 * y + 1.5 * sin(x * 0.5) * cos(y * 0.4), 0, 0))
	check(base.data.replace_dense(&"height", Vector2i.ZERO, image), "fixture height imported")
	var holes := Image.create(64, 64, false, Image.FORMAT_L8)
	var hole_cell := Vector2i(33, 20)
	holes.set_pixelv(hole_cell, Color(1, 1, 1))
	var baked := StrataBake.bake(terrain, {"holes": holes, "region_cells": 16})
	check(baked.ok, "bake: %s" % baked.get("message", ""))
	if not baked.ok:
		quit(1)
		return
	var exported := StrataBake.export_runtime(terrain, {"name": "RuntimeTerrain"})
	check(exported.ok, "export: %s" % exported.get("message", ""))
	var data: StrataRuntimeData = exported.data
	exported.root.free()
	check(data.grid == Vector2i(4, 4) and data.cells == 16, "4 x 4 grid of 16-cell regions")

	var scene := Node3D.new()
	scene.name = "RuntimeScene"
	root.add_child(scene)
	var materials: Array[StrataMaterial] = []
	for index in range(4): materials.append(StrataMaterial.new())
	var renderer := StrataRenderer.new()
	scene.add_child(renderer)
	check(renderer.configure_runtime(scene, data, materials), "configure_runtime builds the renderer from regions")
	var stats := renderer.get_stats()
	check(stats.regions == 16 and stats.region_cells == 16 and stats.height_resolution == Vector2i(65, 65), "renderer holds the 16 manifest regions: %s" % [stats.get("height_resolution")])
	check(renderer.region_spec().bounds == data.bounds and not renderer.region_spec().maps.has("nav_exclusion"), "spec comes from the manifest, shader maps only")
	var worst := 0.0
	var points: Array[Vector2] = []
	for lattice in [Vector2(0, 0), Vector2(16, 16), Vector2(32, 32), Vector2(64, 64), Vector2(48, 16), Vector2(16, 0), Vector2(63, 17), Vector2(15.999, 15.999), Vector2(16.001, 31.5)]:
		points.append(data.lattice_to_local(lattice))
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for index in range(100):
		points.append(BOUNDS.position + Vector2(rng.randf(), rng.randf()) * BOUNDS.size)
	for point in points:
		var expected: Dictionary = data.sample_height(point, StrataRuntimeData.Interpolation.TRIANGLE, true)
		var got := renderer.sample_render_height(point)
		worst = maxf(worst, absf(got - expected.value))
		check(absf(got - expected.value) < 0.0005, "render height equals data height at %s (%f vs %f)" % [point, got, expected.value])
	print("RUNTIME_RENDER max height difference %f over %d points" % [worst, points.size()])
	var center := BOUNDS.position + Vector2(hole_cell) + Vector2(0.5, 0.5)
	check(data.is_hole_cell(hole_cell) and renderer.raycast_heightfield(Vector3(center.x, 100.0, center.y), Vector3.DOWN).is_empty(), "a ray through the hole cell is a miss")
	var solid := center + Vector2(-6.0, 0.0)
	var hit := renderer.raycast_heightfield(Vector3(solid.x, 100.0, solid.y), Vector3.DOWN)
	check(not hit.is_empty() and absf(hit.position.y - data.sample_height(solid).value) < 0.001, "a ray beside the hole hits the data surface")
	print("RUNTIME_RENDER_TEST failures=", failures)
	quit(0 if failures == 0 else 1)
