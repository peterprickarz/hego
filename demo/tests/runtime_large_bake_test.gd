extends "res://tests/runtime_test_base.gd"
## 4097 x 4097 samples at 1 m: native compile, bake, bounded collision and
## navigation around one gameplay point. Reports timings; no speed claims.

func _initialize() -> void:
	call_deferred("run")

func ms(started: int) -> float:
	return (Time.get_ticks_usec() - started) / 1000.0

func run() -> void:
	var memory_start := OS.get_static_memory_usage()
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-2048.0, -2048.0, 4096.0, 4096.0)
	terrain.set_preview_enabled(false)
	get_root().add_child(terrain)
	var base := StrataLayer.new()
	base.name = "RoughBase"
	base.data.sample_spacing = 4.0
	base.data.grid_origin = Vector2(-2048.0, -2048.0)
	terrain.add_child(base)
	var image := Image.create(1025, 1025, false, Image.FORMAT_RF)
	for y in range(0, 1025, 8):
		for x in range(0, 1025, 8):
			image.fill_rect(Rect2i(x, y, 8, 8), Color(12.0 * sin(x * 0.01) * cos(y * 0.013) - 3.0, 0, 0))
	check(base.data.replace_dense(&"height", Vector2i.ZERO, image), "dense 1025^2 base imported natively")
	var fine := StrataLayer.new()
	fine.name = "ManualFine"
	fine.set_composition(&"height", StrataLayer.Composition.ADD)
	terrain.add_child(fine)
	for j in range(-20, 21):
		for i in range(-20, 21):
			fine.data.set_sample(&"height", Vector2i(i, j), 0.5)
	var holes := Image.create(4096, 4096, false, Image.FORMAT_L8)
	holes.fill_rect(Rect2i(2040, 2060, 6, 4), Color(1, 1, 1))
	var started := Time.get_ticks_usec()
	var baked := StrataBake.bake(terrain, {"holes": holes})
	var bake_ms := ms(started)
	check(baked.ok, "4097^2 bake: %s" % baked.get("message", ""))
	if not baked.ok:
		finish("RUNTIME_LARGE_BAKE_TEST")
		return
	var data := terrain.runtime_data
	check(data.get_cell_resolution() == Vector2i(4096, 4096) and data.cell_mask_window("holes", Rect2i(Vector2i.ZERO, data.get_cell_resolution())).count(255) == 24, "full-resolution data and canonical holes")
	near(data.sample_height(Vector2(0, 0)).value, terrain.sample_height(Vector2(0, 0)), 0.000002, "baked centre matches the stack")
	near(data.sample_height(Vector2(1000.0, -1500.0)).value, terrain.sample_height(Vector2(1000.0, -1500.0)), 0.000002, "baked far point matches the stack")
	holes = null
	var memory_baked := OS.get_static_memory_usage()

	var root := Node3D.new()
	get_root().add_child(root)
	var collision := StrataCollision.new()
	collision.data = data
	root.add_child(collision)
	started = Time.get_ticks_usec()
	var around := collision.prepare_around(Vector3(0, 0, 0), 96.0)
	var collision_ms := ms(started)
	check(around.ok and around.resident <= 9, "bounded collision around the player: %s" % around)
	check(collision.prepare_region(data.bounds).ok == false, "the full 1024-chunk terrain is not built by default")
	await physics_frame
	await physics_frame
	var hit := root.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(3.3, 100, -7.7), Vector3(3.3, -100, -7.7)))
	check(not hit.is_empty() and absf(hit.position.y - data.sample_height(Vector2(3.3, -7.7)).value) < 0.0005, "large-terrain collision matches the bake")
	var hole_hit := root.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(-5.5, 100, 13.5), Vector3(-5.5, -100, 13.5)))
	check(hole_hit.is_empty(), "large-terrain hole is open")

	var navigation := StrataNavigation.new()
	navigation.data = data
	navigation.use_async = false
	root.add_child(navigation)
	started = Time.get_ticks_usec()
	var nav := navigation.bake_region(Rect2(-64, -64, 128, 128))
	var navigation_ms := ms(started)
	check(nav.ok and nav.regions == 4, "bounded 128 m navigation area: %s" % nav)
	print("runtime payload %.1f MiB; static memory peak during run %.1f MiB above start" % [data.get_manifest().total_bytes / 1048576.0, (OS.get_static_memory_peak_usage() - memory_start) / 1048576.0])
	print("4097^2 bake %.0f ms (static memory retained +%.1f MiB, includes native layer tiles); collision around player %.0f ms (%d chunks); navigation 128 m %.0f ms (%d tiles)" % [bake_ms, (memory_baked - memory_start) / 1048576.0, collision_ms, around.get("resident", 0), navigation_ms, nav.get("regions", 0)])
	print("bake report: %s" % baked.report)
	root.free()
	terrain.free()
	finish("RUNTIME_LARGE_BAKE_TEST")
