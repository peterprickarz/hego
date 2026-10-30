extends SceneTree
## Narrow settings/controller contract test; native mesher tests own topology.
var failures := 0
var checks := 0

class OldMesher extends RefCounted:
	var base_calls := 0
	func select_patches(_bounds: Rect2, _camera: Vector2, _minimum: float, _ratio: float, _budget: int) -> Array:
		base_calls += 1
		return [{"size": 8.0}]

class RefinedMesher extends OldMesher:
	var arguments: Array = []
	var effective := 4.0
	var limited := false
	func select_refined_patches(bounds: Rect2, camera: Vector2, minimum: float, ratio: float, budget: int, target: float, radius: float, extra: int) -> Dictionary:
		arguments = [bounds, camera, minimum, ratio, budget, target, radius, extra]
		return {"patches": [{"size": effective}], "base_patch_count": 1, "refinement_patch_count": 3, "effective_refinement_patch_size": effective, "refinement_limited": limited}

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("REFINEMENT_SETTINGS: " + message)

func run() -> void:
	var settings := StrataRenderSettings.new()
	var base := settings.parameters().duplicate()
	check(settings.displacement_refinement_enabled and settings.displacement_vertex_spacing == 0.0625 and settings.displacement_refinement_radius == 32.0 and settings.displacement_refinement_budget == 1024, "independent refinement defaults")
	settings.displacement_vertex_spacing = 0.125
	settings.displacement_refinement_radius = 64.0
	settings.displacement_refinement_budget = 512
	check(settings.parameters() == base, "near geometry leaves all base preset parameters unchanged")
	for invalid in [-1.0, 0.0, NAN, INF]:
		settings.displacement_vertex_spacing = invalid
		check(settings.displacement_vertex_spacing == 0.125, "invalid spacing retained previous setting")
	for invalid in [-1.0, NAN, INF]:
		settings.displacement_refinement_radius = invalid
		check(settings.displacement_refinement_radius == 64.0, "invalid radius retained previous setting")
	settings.displacement_refinement_budget = -1
	check(settings.displacement_refinement_budget == 512, "negative extra budget rejected")
	settings.displacement_refinement_budget = 4097
	check(settings.displacement_refinement_budget == 512, "unbounded extra budget rejected")
	settings.displacement_refinement_radius = 0.0
	settings.displacement_refinement_budget = 0
	check(settings.displacement_refinement_radius == 0.0 and settings.displacement_refinement_budget == 0, "explicit zero radius/budget accepted")
	var visible := {}
	for property in settings.get_property_list(): visible[property.name] = property
	for name in ["displacement_refinement_enabled", "displacement_vertex_spacing", "displacement_refinement_radius", "displacement_refinement_budget"]:
		check(visible.has(name) and int(visible[name].usage) & PROPERTY_USAGE_EDITOR != 0 and int(visible[name].usage) & PROPERTY_USAGE_STORAGE != 0, "Inspector and serialization expose " + name)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test_exports"))
	check(ResourceSaver.save(settings, "res://test_exports/refinement_settings.tres") == OK, "settings resource saved")
	var loaded := ResourceLoader.load("res://test_exports/refinement_settings.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRenderSettings
	check(loaded != null and loaded.displacement_vertex_spacing == 0.125 and loaded.displacement_refinement_radius == 0.0 and loaded.displacement_refinement_budget == 0, "settings resource roundtrip")
	var bounds := Rect2(-2048, -2048, 4096, 4096)
	check(StrataRenderer.refinement_target_patch_size(bounds, 64, 0.0625) == 4.0, "default requests 4 m patches independently from 8 m base")
	check(StrataRenderer.refinement_target_patch_size(bounds, 64, 0.09) == 4.0, "non-dyadic spacing snaps finer to supported lattice")
	check(StrataRenderer.refinement_target_patch_size(bounds, 32, 0.0625) == 2.0, "uniform patch cells determine target patch size")
	check(StrataRenderer.refinement_target_patch_size(bounds, 64, 1e-100) == 1.0, "depth twelve caps very fine finite request")
	check(StrataRenderer.refinement_target_patch_size(bounds, 64, 1e100) == 4096.0, "very large finite request is safe root-sized target")
	for size in [64.0, 256.0, 4096.0]:
		for cells in [4, 8, 16, 32, 64]:
			for depth in range(13):
				var patch_size: float = size / float(1 << depth)
				check(StrataRenderer.refinement_target_patch_size(Rect2(0, 0, size, size), cells, patch_size / cells) == patch_size, "exact dyadic target survives logarithm rounding")
	check(StrataRenderer.vertex_spacing_is_representable(Rect2(65536, 65536, 64, 64), 0.0078125), "exact float32 ULP spacing is retained")
	check(not StrataRenderer.vertex_spacing_is_representable(Rect2(65536, 65536, 64, 64), 0.00390625), "sub-ULP spacing is rejected")
	var renderer := StrataRenderer.new()
	var mesher := RefinedMesher.new()
	renderer._mesher = mesher
	var plan := renderer._select_patch_plan(bounds, Vector2.ZERO)
	check(not plan.is_empty() and mesher.arguments[2] == 8.0 and mesher.arguments[4] == 1024 and mesher.arguments[5] == 4.0 and mesher.arguments[7] == 1024, "native call has separate unchanged base and extra budgets")
	check(mesher.arguments[6] == 33.0 and renderer._pending_plan_stats.refinement_guard_band == 1.0, "native circle includes matching movement guard; shader radius stays 32")
	check(renderer._pending_plan_stats.refinement_effective_vertex_spacing == 0.0625 and renderer._pending_plan_stats.refinement_patch_count == 3, "effective native spacing and extra counts exposed")
	check(renderer.get_patch_capacity() == 2048, "combined pool capacity includes extra budget")
	mesher.limited = true; mesher.effective = 8.0
	renderer._select_patch_plan(bounds, Vector2.ZERO)
	check(renderer._pending_plan_stats.refinement_limited and renderer._pending_plan_stats.refinement_effective_vertex_spacing == 0.125, "budget fallback reports actual coarser spacing")
	renderer.displacement_vertex_spacing = 0.25
	renderer._select_patch_plan(bounds, Vector2.ZERO)
	check(mesher.arguments[5] == 16.0, "target coarser than nominal base minimum still reaches native budget-fallback logic")
	renderer.displacement_enabled = false
	check(renderer._lod_settings_dirty, "displacement toggle invalidates geometry while stationary")
	check(not renderer._select_patch_plan(bounds, Vector2.ZERO).is_empty() and mesher.base_calls == 1 and renderer._pending_plan_stats.refinement_patch_count == 0, "disabling displacement uses unchanged base selector")
	check(renderer.get_patch_capacity() == renderer.max_patches, "disabled extras shrink pool capacity")
	renderer.displacement_enabled = true
	renderer.displacement_radius = 64.0
	check(renderer.displacement_refinement_radius == 64.0, "legacy radius aliases the single new radius")
	renderer.displacement_refinement_enabled = false
	check(renderer.displacement_radius == 64.0, "refinement toggle never changes appearance radius")
	renderer.displacement_refinement_enabled = true
	renderer.displacement_vertex_spacing = 0.0625
	mesher.effective = 4.0
	check(renderer._select_patch_plan(Rect2(1100000, 1100000, 4096, 4096), Vector2(1100000, 1100000)).is_empty(), "actual refined vertex precision rejects collapsing floats although base spacing fits")
	var source := Node3D.new(); root.add_child(source); source.add_child(renderer)
	var camera := Camera3D.new(); root.add_child(camera); camera.position = Vector3(0, 100, 0)
	renderer._source = source; renderer.set_camera(camera)
	renderer.displacement_refinement_radius = 32.0
	renderer._height_image = Image.create(2, 2, false, Image.FORMAT_RF)
	renderer._height_min = 0.0; renderer._height_max = 0.0
	renderer._select_patch_plan(bounds, Vector2.ZERO)
	check(not renderer._pending_plan_stats.refinement_active, "global height extrema safely cull an overhead camera")
	renderer._select_patch_plan(bounds, Vector2.ZERO, Vector2(90, 110))
	check(renderer._pending_plan_stats.refinement_active, "new validated field range activates refinement before publication")
	camera.free()
	renderer._source = null
	renderer._height_image = null
	source.remove_child(renderer); source.free()
	renderer._mesher = OldMesher.new()
	check(renderer._select_patch_plan(bounds, Vector2.ZERO).is_empty() and not renderer.get_stats().refinement_supported, "old native backend rejects requested refinement explicitly")
	renderer.free()
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(-8, -8, 16, 16)
	terrain.set_preview_enabled(false)
	root.add_child(terrain)
	var layer := StrataLayer.new(); terrain.add_child(layer)
	terrain.render_settings.displacement_vertex_spacing = 0.03125
	terrain.render_settings.displacement_refinement_radius = 24.0
	terrain.render_settings.displacement_refinement_budget = 768
	var baked := StrataBake.compile(terrain, {"spacing": 1.0})
	check(baked.get("ok", false), "actual runtime bake accepts refinement settings")
	if baked.get("ok", false):
		check(baked.data.render_settings != terrain.render_settings, "runtime bake snapshots settings independently")
		check(ResourceSaver.save(baked.data, "res://test_exports/refinement_runtime.res", ResourceSaver.FLAG_COMPRESS) == OK, "runtime resource saved")
		var runtime := ResourceLoader.load("res://test_exports/refinement_runtime.res", "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData
		check(runtime != null and runtime.render_settings.displacement_vertex_spacing == 0.03125 and runtime.render_settings.displacement_refinement_radius == 24.0 and runtime.render_settings.displacement_refinement_budget == 768, "runtime resource preserves refinement settings")
		terrain.render_settings.displacement_refinement_radius = 48.0
		check(baked.data.render_settings.displacement_refinement_radius == 24.0, "live settings edits never alter a published runtime artifact")
	var status_renderer := StrataRenderer.new(); terrain.add_child(status_renderer)
	terrain.editor_renderer = status_renderer
	status_renderer._stats.merge({"refinement_active": true, "refinement_limited": true, "refinement_effective_vertex_spacing": 0.125, "refinement_requested_vertex_spacing": 0.0625, "refinement_patch_count": 15}, true)
	check("Limited" in terrain.near_displacement_status and "0.125" in terrain.near_displacement_status and "15" in terrain.near_displacement_status, "Terrain Inspector status exposes effective spacing and budget limitation")
	for property in terrain.get_property_list():
		if property.name == "near_displacement_status": check(int(property.usage) & PROPERTY_USAGE_READ_ONLY != 0 and int(property.usage) & PROPERTY_USAGE_STORAGE == 0, "Inspector status is read-only and never stored")
	terrain.free()
	print("DISPLACEMENT_REFINEMENT_SETTINGS checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
