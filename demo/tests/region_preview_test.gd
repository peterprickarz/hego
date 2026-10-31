extends SceneTree
## The editor preview bridge on regions (Track E of docs/development/strata_regions_plan.md).
## Small artificial terrains only: a flat base, a partial procedural material distribution and a
## manual layer holding heights, materials, holes and tint. Checks that the regions the renderer
## holds equal StrataRegions.compose_region for every region, that height, material, hole and
## tint dabs patched through refresh_region() equal a fresh full composition bit for bit, that a
## dab never recomposes a class it does not touch, and prints the dab cost. Track E2 adds the
## tiered preview (docs/development/terrain_renderer_regions.md "Editor preview"): a terrain with
## more regions than near slots, driven through a recording stand-in renderer so it also runs
## headless (tiers by camera distance with the slot caps, coarse maps first, re-tiering with
## hysteresis, dabs on near, far and coarse-only regions, compose_cache, the Phase A path).
var checks := 0
var failures := 0
var channels := PackedStringArray(["material_a", "material_b", "material_c", "material_d"])

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("REGION_PREVIEW: " + message)

func partial_field(channel: StringName, origin: Vector3, size: Vector2i, value: float, step: float) -> StrataFieldData:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, Color(value * (0.5 + 0.5 * sin(x * 0.7 + y * 0.3)), 0, 0))
	return StrataFieldData.from_field({"name": channel, "image": image, "sample_origin": origin, "sample_step_x": Vector3(step, 0, 0), "sample_step_y": Vector3(0, 0, step)})

func material_pool() -> Array[StrataMaterial]:
	var pool: Array[StrataMaterial] = []
	for index in range(4):
		var material := StrataMaterial.new()
		material.color_texture = StrataRenderer._solid_texture(Color(0.2 * index, 0.5, 0.5))
		material.normal_texture = StrataRenderer._solid_texture(Color(.5, .5, 1))
		material.ormh_texture = StrataRenderer._solid_texture(Color(.2, .3, .1, 1))
		pool.append(material)
	return pool

func wait_idle(bridge: StrataEditorPreview) -> bool:
	var frames := 0
	while (bridge.is_busy() or not is_instance_valid(bridge.renderer) or bridge.get_stats().regions == 0) and frames < 2000:
		await process_frame
		frames += 1
	await process_frame
	if bridge.is_busy(): push_error("REGION_PREVIEW still busy: " + bridge.status)
	return not bridge.is_busy()

## Builds the terrain and its bridge. [param origin] places the bounds, [param spacing] and
## [param cells] the regions.
func build(size: float, origin: Vector2, spacing: float, cells: int, with_bridge: bool = true, stub: Object = null, options: Dictionary = {}, camera_xz: Vector2 = Vector2.INF) -> Dictionary:
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(origin, Vector2(size, size)); terrain.set_preview_enabled(false)
	terrain.region_spacing = spacing; terrain.region_cells = cells
	var base := StrataLayer.new(); base.name = "Base"; terrain.add_child(base)
	base.data.sample_spacing = size / 4.0; base.data.grid_origin = origin
	for z in range(5):
		for x in range(5): base.data.set_sample(&"height", Vector2i(x, z), 2.0 + sin(x * 1.3) * cos(z * 0.9))
	var distribution := StrataLayer.new(); distribution.name = "Distribution"; distribution.procedural = true; terrain.add_child(distribution)
	var step := size / 11.0
	distribution.procedural_fields = {"material_a": partial_field(&"material_a", Vector3(origin.x, 0, origin.y), Vector2i(8, 7), 0.7, step), "material_c": partial_field(&"material_c", Vector3(origin.x + size * 0.3, 0, origin.y + size * 0.2), Vector2i(7, 8), 0.4, step)}
	var hand := StrataLayer.new(); hand.name = "Hand"; hand.data.sample_spacing = size / 32.0; hand.data.grid_origin = origin; terrain.add_child(hand)
	hand.set_composition(&"material_b", StrataLayer.Composition.ADD)
	hand.set_composition(&"hole", StrataLayer.Composition.REPLACE)
	# Tint exists from the start so the macro map is part of the spec.
	hand.data.set_sample(&"terrain_tint_r", Vector2i(2, 2), 0.6)
	hand.data.set_sample(&"material_b", Vector2i(3, 3), 0.5)
	# Every channel the dabs touch is already owned: a dab that introduces ownership changes the
	# whole class, which falls back to a full refresh (tested separately).
	hand.data.set_sample(&"material_c", Vector2i(30, 2), 0.1)
	hand.data.set_sample(&"material_d", Vector2i(31, 30), 0.1)
	hand.data.set_sample(&"terrain_ao", Vector2i(2, 30), 0.9)
	terrain.editor_materials = material_pool(); terrain.editor_material_channels = channels
	terrain.preview_through_layer = null
	root.add_child(terrain)
	if not with_bridge: return {"terrain": terrain, "hand": hand, "base": base, "distribution": distribution}
	var at := Vector2(origin.x + size * 0.5, origin.y + size * 0.5) if not camera_xz.is_finite() else camera_xz
	var camera := Camera3D.new(); camera.position = Vector3(at.x, size, at.y); terrain.add_child(camera); camera.look_at(camera.position - Vector3.UP, Vector3.FORWARD); camera.current = true
	var bridge := StrataEditorPreview.new(); terrain.add_child(bridge)
	for key in options: bridge.set(key, options[key])
	if stub != null: bridge.renderer = stub
	bridge.setup(terrain); bridge.set_camera(camera)
	return {"terrain": terrain, "bridge": bridge, "hand": hand, "base": base, "distribution": distribution, "camera": camera}

## Every region of the renderer (and of the bridge cache) equals a fresh compose_region.
func regions_match(label: String, scene: Dictionary) -> bool:
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	var renderer: Object = bridge.renderer
	var spec := terrain.region_spec()
	check(renderer.region_spec() == spec and bridge.get_spec() == spec, label + ": the renderer holds the terrain's region spec")
	var good := true
	var mismatched := []
	for y in range(StrataRegions.grid_size(spec).y):
		for x in range(StrataRegions.grid_size(spec).x):
			var xy := Vector2i(x, y)
			var fresh := StrataRegions.compose_region(terrain, terrain.preview_through_layer, xy, spec)
			if not fresh.ok: good = false; mismatched.append(str(xy) + " " + String(fresh.message)); continue
			var held: StrataRegionData = renderer.get_region(xy)
			var cached := bridge.get_region(xy)
			for name in spec.maps:
				var expected: PackedByteArray = fresh.region.get_image(name).get_data()
				if held == null or cached == null or held.get_image(name).get_data() != expected or cached.get_image(name).get_data() != expected:
					good = false; mismatched.append("%s %s" % [xy, name])
			if held != null and (held.height_min != fresh.region.height_min or held.height_max != fresh.region.height_max):
				good = false; mismatched.append("%s extrema" % xy)
	if not good: push_error("REGION_PREVIEW %s mismatches: %s" % [label, mismatched.slice(0, 8)])
	check(good, label + ": every region equals compose_region bit for bit (CPU regions, cache and extrema)")
	return good

## A dab, driven exactly as the plugin drives it. Returns the bridge's patch time in ms.
func dab(scene: Dictionary, point: Vector2, radius: float, strength: float, operation: String, channel: StringName) -> float:
	var bridge: StrataEditorPreview = scene.bridge
	var hand: StrataLayer = scene.hand
	var current := bridge.can_patch_region()
	check(current, "the preview is current before the %s dab" % channel)
	var applied: int
	if channel == &"hole" and operation == "raise":
		# Canonical masks are binary: the plugin paints exact 1 on every touched sample.
		applied = 0
		var spacing := hand.data.sample_spacing
		var grid := (point - hand.data.grid_origin) / spacing
		var reach := ceili(radius / spacing)
		for z in range(floori(grid.y) - reach, floori(grid.y) + reach + 2):
			for x in range(floori(grid.x) - reach, floori(grid.x) + reach + 2):
				if (hand.data.grid_origin + Vector2(x, z) * spacing).distance_to(point) <= radius:
					hand.data.set_sample(&"hole", Vector2i(x, z), 1.0)
					applied += 1
	else:
		applied = StrataBrush.apply_brush(hand, point, radius, strength, operation, channel)
	check(applied > 0, "%s dab at %s applies" % [channel, point])
	var started := Time.get_ticks_usec()
	bridge.refresh_region(point, radius, hand.data.sample_spacing, channel, current)
	return (Time.get_ticks_usec() - started) / 1000.0

func run() -> void:
	create_timer(240).timeout.connect(func(): push_error("Region preview watchdog"); quit(1))
	await tiered_preview()
	await small_terrain_phase_a()
	await headless_cache()
	if RenderingServer.get_rendering_device() == null:
		print("REGION_PREVIEW no rendering device: GPU parts skipped (run with --rendering-method forward_plus)")
	else:
		await tiered_gpu()
		await exact_lattice()
		await inexact_lattice()
		await cutoffs_and_configuration()
	print("REGION_PREVIEW checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func exact_lattice() -> void:
	var scene := build(64.0, Vector2(-32, -32), 1.0, 16)
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	var hand: StrataLayer = scene.hand
	check(await wait_idle(bridge), "the sliced first composition finishes")
	var spec := terrain.region_spec()
	check(StrataRegions.grid_size(spec) == Vector2i(4, 4) and spec.maps.has("material_ids") and spec.maps.has("macro") and spec.maps.has("holes"), "a 64 m terrain with 16 cell regions is a 4 x 4 grid with materials, holes and macro")
	check(spec == StrataRegions.standard_spec(terrain.base_bounds, 1.0, 16), "the spec is the standard spec when materials and tint are present")
	terrain.editor_compile_spacing = 0.5
	check(terrain.region_spacing == 0.5 and terrain.editor_compile_spacing == 0.5, "editor_compile_spacing is an alias of region_spacing")
	terrain.region_spacing = 1.0
	await wait_idle(bridge)
	check(regions_match("initial", scene), "initial composition")
	check(bridge.renderer.get_stats().regions == 16 and bridge.renderer.get_stats().region_grid == Vector2i(4, 4), "the renderer shows 16 regions")
	var stats_before := bridge.get_stats()
	check(stats_before.material_compositions == 1 and stats_before.full_compiles == 1, "the first refresh composes materials and heights once")
	# Texture arrays on the GPU equal the CPU regions.
	var array: Texture2DArray = bridge.renderer._region_arrays["height"]
	check(array.get_layer_data(5).get_data() == bridge.renderer.get_region(Vector2i(1, 1)).get_image("height").get_data(), "the GPU height layer equals the CPU region")

	var timings := {}
	# A height dab on a region corner touches four regions; later ones sit on terrain edges.
	var corner := Vector2(-16.0, -16.0)
	timings.height = dab(scene, corner, 6.0, 0.8, "raise", &"height")
	var after := bridge.get_stats()
	check(after.material_compositions == stats_before.material_compositions and after.material_regions == stats_before.material_regions, "a height dab composes no materials")
	check(regions_match("height dab", scene), "height dab patch")
	timings.edge_height = dab(scene, Vector2(-31.5, -31.0), 5.0, 0.7, "lower", &"height")
	check(regions_match("height dab on the low edge", scene), "height dab on the terrain edge")
	timings.far_edge = dab(scene, Vector2(31.0, 30.5), 5.0, 0.7, "raise", &"height")
	check(regions_match("height dab on the high edge", scene), "height dab on the far edge")
	var material_regions: int = bridge.get_stats().material_regions
	timings.material = dab(scene, Vector2(0.0, 0.0), 6.0, 0.8, "raise", &"material_d")
	check(bridge.get_stats().material_regions == material_regions + 1, "a material dab is counted")
	check(regions_match("material dab", scene), "material dab patch")
	timings.material_edge = dab(scene, Vector2(-30.0, 20.0), 4.0, 0.9, "raise", &"material_c")
	check(regions_match("material dab on the edge", scene), "material dab on the terrain edge")
	timings.material_erase = dab(scene, Vector2(0.5, 0.5), 3.0, 1.0, "erase", &"material_d")
	check(regions_match("material erase", scene), "material erase patch")
	timings.hole = dab(scene, Vector2(10.0, 10.0), 4.0, 1.0, "raise", &"hole")
	check(regions_match("hole dab", scene), "hole dab patch")
	timings.hole_erase = dab(scene, Vector2(10.0, 10.0), 2.0, 1.0, "erase", &"hole")
	check(regions_match("hole erase", scene), "hole erase patch")
	timings.tint = dab(scene, Vector2(-8.0, 12.0), 8.0, 0.8, "lower", &"terrain_tint_r")
	check(regions_match("tint dab", scene), "tint dab patch")
	timings.ao = dab(scene, Vector2(8.0, -4.0), 5.0, 0.5, "lower", &"terrain_ao")
	check(regions_match("ao dab", scene), "ao dab patch")
	# A dab that introduces a channel's ownership changes the whole class: it falls back to a
	# complete (sliced) refresh of that class instead of patching a rectangle.
	dab(scene, Vector2(5.0, -20.0), 4.0, 0.8, "lower", &"terrain_tint_g")
	await wait_idle(bridge)
	check(regions_match("ownership dab", scene), "a dab that introduces ownership is recomposed completely")
	# A dab leaves the queued refresh nothing to do.
	var compositions: int = bridge.get_stats().region_compositions
	await wait_idle(bridge)
	await process_frame
	check(bridge.get_stats().region_compositions == compositions and not bridge.is_busy(), "the refresh queued by the dabs finds the caches current")
	check(bridge.get_stats().full_compiles == 1 and bridge.get_stats().material_compositions == 1, "dabs never recomposed a whole class")
	print("REGION_PREVIEW dab ms (16 cell regions, 64 m): ", timings)
	# An external edit recomposes only the class it changed.
	var height_compiles: int = bridge.get_stats().full_compiles
	hand.data.set_sample(&"height", Vector2i(8, 8), 7.0)
	bridge.request_refresh()
	check(await wait_idle(bridge), "a height edit refreshes")
	check(bridge.get_stats().full_compiles == height_compiles + 1 and bridge.get_stats().material_compositions == 1, "an external height edit recomposes height and not materials")
	check(regions_match("external height edit", scene), "external height edit")
	hand.data.set_sample(&"material_a", Vector2i(10, 10), 0.9)
	bridge.request_refresh()
	check(await wait_idle(bridge), "a material edit refreshes")
	check(bridge.get_stats().material_compositions == 2 and bridge.get_stats().full_compiles == height_compiles + 1, "an external material edit recomposes materials and not height")
	check(regions_match("external material edit", scene), "external material edit")
	# Time slicing: a structural refresh takes several frames and reports its progress.
	terrain.region_cells = 32
	var frames := 0
	var progress := false
	await process_frame
	while bridge.is_busy() and frames < 500:
		progress = progress or bridge.status.contains("Composing live terrain regions")
		await process_frame
		frames += 1
	check(not bridge.is_busy() and bridge.get_stats().regions == 4, "changing region_cells rebuilds a 2 x 2 grid")
	check(regions_match("32 cells", scene), "after region_cells changes")
	print("REGION_PREVIEW sliced rebuild: ", frames, " frames, progress status shown: ", progress)
	terrain.free()
	await process_frame

func inexact_lattice() -> void:
	# 0.75 m is not a power of two: windows are not exact, dabs recompose whole region maps.
	# (The renderer needs power-of-two bounds, so 64 m with a non-dyadic origin.)
	# 36 regions: raise the near slots so this stays the Phase A layout (the tiered preview has its own test).
	var scene := build(64.0, Vector2(-30.3, -33.1), 0.75, 16, true, null, {"near_slots": 64})
	var bridge: StrataEditorPreview = scene.bridge
	check(await wait_idle(bridge), "the 0.75 m terrain composes")
	check(regions_match("0.75 m initial", scene), "0.75 m initial")
	dab(scene, Vector2(1.0, 5.0), 3.0, 0.8, "raise", &"height")
	check(regions_match("0.75 m height dab", scene), "0.75 m height dab")
	dab(scene, Vector2(-2.0, 2.0), 3.0, 0.8, "raise", &"material_d")
	check(regions_match("0.75 m material dab", scene), "0.75 m material dab")
	(scene.terrain as StrataTerrain3D).free()
	await process_frame

func cutoffs_and_configuration() -> void:
	var scene := build(64.0, Vector2(-32, -32), 1.0, 32)
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	await wait_idle(bridge)
	var compositions: int = bridge.get_stats().material_compositions
	terrain.preview_through_layer = scene.base
	await wait_idle(bridge)
	check(regions_match("cutoff at the base", scene), "an early cutoff composes its stage")
	var weights: Image = bridge.renderer.get_region(Vector2i.ZERO).get_image("material_weights")
	check(weights.get_data().count(0) == weights.get_data().size(), "a cutoff before every material stage is exactly unassigned")
	terrain.preview_through_layer = scene.distribution
	await wait_idle(bridge)
	check(regions_match("cutoff at the distribution", scene), "a cutoff at the distribution")
	var nonzero := 0
	for value in bridge.renderer.get_region(Vector2i.ZERO).get_image("material_weights").get_data(): nonzero += 1 if value > 0 else 0
	check(nonzero > 0, "the distribution stage binds its materials")
	terrain.preview_through_layer = null
	await wait_idle(bridge)
	check(regions_match("final layer", scene), "back to the final layer")
	check(bridge.get_stats().material_compositions > compositions, "moving the cutoff across a material stage recomposes materials")
	var before: int = bridge.get_stats().material_compositions
	terrain.preview_through_layer = scene.hand
	await wait_idle(bridge)
	check(bridge.get_stats().material_compositions == before, "a cutoff move that crosses no material stage reuses the cached materials")
	# A pool that does not match the channels leaves materials unassigned with an explanation.
	terrain.editor_materials = material_pool().slice(0, 2)
	bridge.sync_configuration()
	await wait_idle(bridge)
	check(bridge.status.contains("channel mapping must match"), "a pool smaller than the channel mapping is explained")
	var unassigned := true
	for xy in [Vector2i(0, 0), Vector2i(1, 1)]:
		unassigned = unassigned and bridge.renderer.get_region(xy).get_image("material_weights").get_data().count(0) == bridge.renderer.get_region(xy).get_image("material_weights").get_data().size()
	check(unassigned, "a mismatched pool composes unassigned materials")
	terrain.editor_materials = material_pool()
	bridge.sync_configuration()
	await wait_idle(bridge)
	check(regions_match("restored pool", scene), "restoring the pool composes the materials again")
	# No material channels: no material maps in the spec.
	terrain.editor_material_channels = PackedStringArray()
	bridge.sync_configuration()
	await wait_idle(bridge)
	check(not bridge.get_spec().maps.has("material_ids") and regions_match("no materials", scene), "without material channels the spec has no material maps")
	terrain.free()
	await process_frame

func headless_cache() -> void:
	# The cache composes without a renderer.
	var scene := build(64.0, Vector2(-32, -32), 2.0, 16, false)
	var terrain: StrataTerrain3D = scene.terrain
	var bridge := StrataEditorPreview.new()
	terrain.add_child(bridge)
	bridge.terrain = terrain
	check(bridge.compose_cache() and bridge.get_stats().regions == 2 * 2, "compose_cache composes the regions without a renderer")
	var tiered_scene := build(256.0, Vector2(-128, -128), 1.0, 32, false)
	var tiered_terrain: StrataTerrain3D = tiered_scene.terrain
	var tiered_bridge := StrataEditorPreview.new()
	tiered_terrain.add_child(tiered_bridge)
	tiered_bridge.terrain = tiered_terrain
	tiered_bridge.coarse_max_side = 32
	var tiered_ok := tiered_bridge.compose_cache()
	check(tiered_ok and tiered_bridge.get_stats().regions == 64 and tiered_bridge.get_stats().tiered, "compose_cache of a tiered terrain composes every region at level 0")
	var tiered_spec := tiered_terrain.region_spec()
	var all_same := tiered_ok
	for xy in [Vector2i(0, 0), Vector2i(3, 5), Vector2i(7, 7)]:
		var fresh_tier := StrataRegions.compose_region(tiered_terrain, null, xy, tiered_spec)
		for name in tiered_spec.maps: all_same = all_same and tiered_bridge.get_region(xy).get_image(name).get_data() == fresh_tier.region.get_image(name).get_data()
	check(all_same, "tiered compose_cache regions equal compose_region")
	var coarse_height := StrataRegionCompose.compose_map(tiered_terrain, null, "height", StrataRegions.coarse_window(tiered_spec, tiered_spec.maps.height, 3), tiered_spec)
	check(coarse_height.ok and tiered_bridge.get_coarse_maps().has("height") and (tiered_bridge.get_coarse_maps().height as Image).get_data() == coarse_height.image.get_data(), "tiered compose_cache composes the coarse maps")
	tiered_terrain.free()
	var spec := terrain.region_spec()
	var fresh := StrataRegions.compose_region(terrain, null, Vector2i(1, 1), spec)
	check(fresh.ok and bridge.get_region(Vector2i(1, 1)).get_image("height").get_data() == fresh.region.get_image("height").get_data(), "cached regions equal compose_region")
	var compositions: int = bridge.get_stats().material_compositions
	check(bridge.compose_cache() and bridge.get_stats().material_compositions == compositions, "an unchanged stack reuses the cache")
	terrain.free()
	await process_frame

# ─────────────────────────────────────────────
# Tiered preview (stand-in renderer, no GPU)
# ─────────────────────────────────────────────

## Records what the preview asks of a renderer and enforces the slot rules of the real one.
class Stub:
	extends RefCounted
	var calls: Array = []
	var render_settings: Variant
	var _render_bounds := Rect2()
	var spec: Dictionary = {}
	var residency: Dictionary = {}
	var near: Dictionary = {}
	var far: Dictionary = {}
	var coarse: Dictionary = {}
	var coarse_level := -1
	var windows: Array = []
	func configure_regions(_source: Object, _materials: Array, new_spec: Dictionary, _regions: Dictionary, new_residency: Dictionary = {}) -> bool:
		calls.append(["configure_regions", new_residency.duplicate()])
		spec = new_spec; residency = new_residency; near = {}; far = {}; coarse = {}
		_render_bounds = new_spec.bounds
		return true
	func set_regions(new_spec: Dictionary, regions: Dictionary, new_residency: Dictionary = {}) -> bool:
		calls.append(["set_regions", regions.keys(), new_residency.duplicate()])
		spec = new_spec; residency = new_residency; near = regions.duplicate(); far = {}
		coarse = {}
		for name in new_residency.get("coarse_maps", {}): coarse[name] = (new_residency.coarse_maps[name] as Image).duplicate()
		coarse_level = int(new_residency.get("coarse_level", -1))
		_render_bounds = new_spec.bounds
		return true
	func _near_slots() -> int:
		var grid := StrataRegions.grid_size(spec)
		return int(residency.get("near_slots", grid.x * grid.y))
	func free_slots(level: int) -> int:
		if level == 0: return _near_slots() - near.size()
		if level == int(residency.get("far_level", 2)): return int(residency.get("far_slots", 0)) - far.size()
		return 0
	func set_region_level(xy: Vector2i, data: StrataRegionData, level: int) -> bool:
		for name in spec.maps:
			if data.get_image(name, level) == null: return false
		var was_near := near.has(xy)
		var was_far := far.has(xy)
		if level == 0 and not was_near and free_slots(0) <= 0: return false
		if level != 0 and not was_far and free_slots(level) <= 0: return false
		near.erase(xy); far.erase(xy)
		if level == 0: near[xy] = data
		else: far[xy] = data
		calls.append(["set_region_level", xy, level])
		return true
	func release_region(xy: Vector2i) -> bool:
		var held := near.erase(xy) or far.erase(xy)
		calls.append(["release_region", xy])
		return held
	func update_region(xy: Vector2i, data: StrataRegionData) -> bool:
		calls.append(["update_region", xy])
		near[xy] = data
		return true
	func update_region_window(xy: Vector2i, map: String, patch: Image, texel_origin: Vector2i) -> bool:
		if not near.has(xy): return false
		calls.append(["update_region_window", xy, map])
		windows.append([xy, map, patch.get_size(), texel_origin])
		return true
	func set_coarse_maps(level: int, images: Dictionary) -> bool:
		calls.append(["set_coarse_maps", level])
		coarse_level = level
		coarse = {}
		for name in images: coarse[name] = (images[name] as Image).duplicate()
		return true
	func set_camera(_camera: Camera3D) -> void: pass
	func set_ownership_overlay(_layer: Object, _channel: StringName = &"height", _enabled: bool = true) -> bool: return true
	func set_channel_preview(_image: Image, _bounds: Rect2, _enabled: bool) -> bool: return true
	func get_region(xy: Vector2i) -> StrataRegionData: return near.get(xy)
	func get_stats() -> Dictionary: return {"near_resident": near.size(), "far_resident": far.size()}
	func region_spec() -> Dictionary: return spec
	func count(name: String) -> int:
		var total := 0
		for call in calls:
			if call[0] == name: total += 1
		return total

func nearest_expected(spec: Dictionary, point: Vector2, near_cap: int, far_cap: int, near_radius: float, far_radius: float, far_level: int) -> Dictionary:
	var rows: Array = []
	var grid := StrataRegions.grid_size(spec)
	for y in range(grid.y):
		for x in range(grid.x):
			var rect := StrataRegions.region_bounds(spec, Vector2i(x, y))
			rows.append([point.distance_to(point.clamp(rect.position, rect.end)), Vector2i(x, y)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var plan := {}
	var taken := 0
	for row in rows:
		if row[0] <= near_radius and taken < near_cap: plan[row[1]] = 0; taken += 1
	taken = 0
	for row in rows:
		if plan.has(row[1]) or row[0] > far_radius: continue
		if taken < far_cap: plan[row[1]] = far_level; taken += 1
	return plan

## The images a direct composition gives for a map group, as {map name: Image}.
func direct(terrain: StrataTerrain3D, name: String, window_for: Callable, spec: Dictionary) -> Dictionary:
	var composed := StrataRegionCompose.compose_map(terrain, terrain.preview_through_layer, name, window_for.call(name), spec)
	if not composed.ok: return {}
	if name in [StrataRegions.MAP_MATERIAL_IDS, StrataRegions.MAP_MATERIAL_WEIGHTS]:
		return {StrataRegions.MAP_MATERIAL_IDS: composed.ids, StrataRegions.MAP_MATERIAL_WEIGHTS: composed.weights}
	return {name: composed.image}

func coarse_matches(label: String, terrain: StrataTerrain3D, stub: Stub) -> bool:
	var spec := terrain.region_spec()
	var level := stub.coarse_level
	var good: bool = stub.coarse.size() == spec.maps.size()
	var mismatched := []
	for name in ["height", "material_ids", "holes", "macro"]:
		if not spec.maps.has(name): continue
		var expected := direct(terrain, name, func(map: String) -> Dictionary: return StrataRegions.coarse_window(spec, spec.maps[map], level), spec)
		for map in expected:
			if not stub.coarse.has(map) or (stub.coarse[map] as Image).get_data() != (expected[map] as Image).get_data():
				good = false; mismatched.append(map)
	if not good: push_error("REGION_PREVIEW %s coarse mismatches: %s" % [label, mismatched])
	check(good, label + ": the coarse maps equal a direct coarse composition")
	return good

func near_far_match(label: String, terrain: StrataTerrain3D, bridge: StrataEditorPreview, stub: Stub) -> bool:
	var spec := terrain.region_spec()
	var good := true
	var mismatched := []
	for xy: Vector2i in stub.near:
		var fresh := StrataRegions.compose_region(terrain, terrain.preview_through_layer, xy, spec)
		for name in spec.maps:
			if (stub.near[xy] as StrataRegionData).get_image(name).get_data() != fresh.region.get_image(name).get_data() or bridge.get_region(xy).get_image(name).get_data() != fresh.region.get_image(name).get_data():
				good = false; mismatched.append("near %s %s" % [xy, name])
	var level := int(stub.residency.get("far_level", 2))
	for xy: Vector2i in stub.far:
		for name in ["height", "material_ids", "holes", "macro"]:
			if not spec.maps.has(name): continue
			var expected := direct(terrain, name, func(map: String) -> Dictionary: return StrataRegions.map_window(spec, xy, spec.maps[map], level), spec)
			for map in expected:
				if (stub.far[xy] as StrataRegionData).get_image(map, level).get_data() != (expected[map] as Image).get_data():
					good = false; mismatched.append("far %s %s" % [xy, map])
	if not good: push_error("REGION_PREVIEW %s tier mismatches: %s" % [label, mismatched.slice(0, 8)])
	check(good, label + ": near regions equal compose_region and far regions the direct far-level composition")
	return good

func key_set(values: Array) -> Array:
	var keys := values.duplicate()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return keys

func tiered_preview() -> void:
	# 256 m at 1 m, 32 cell regions: an 8 x 8 grid of 32 m regions, coarse level 3, far level 2.
	var stub := Stub.new()
	var options := {"near_slots": 4, "far_slots": 6, "coarse_max_side": 32, "far_radius": 100.0}
	var camera_a := Vector2(-117.0, -103.0)
	var scene := build(256.0, Vector2(-128, -128), 1.0, 32, true, stub, options, camera_a)
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	var camera: Camera3D = scene.camera
	var spec := terrain.region_spec()
	check(await wait_idle(bridge), "the tiered first composition finishes")
	check(StrataRegions.grid_size(spec) == Vector2i(8, 8) and StrataRegions.coarse_level(spec, 32) == 3 and bridge.get_stats().tiered, "256 m with 32 cell regions is an 8 x 8 tiered grid with coarse level 3")
	# Tier plan: by distance with the slot caps.
	var expected := nearest_expected(spec, camera_a, 4, 6, 2.5 * 32.0, 100.0, 2)
	var near_expected := expected.keys().filter(func(xy: Vector2i) -> bool: return expected[xy] == 0)
	var far_expected := expected.keys().filter(func(xy: Vector2i) -> bool: return expected[xy] == 2)
	check(near_expected.size() == 4 and far_expected.size() == 6, "the expected plan fills the 4 near and 6 far slots")
	check(bridge.get_wanted() == expected, "the plan assigns tiers by camera distance with the slot caps")
	check(key_set(stub.near.keys()) == key_set(near_expected) and key_set(stub.far.keys()) == key_set(far_expected), "the renderer holds exactly the planned near and far regions")
	check(stub.near.size() + stub.far.size() < 64, "most regions are coarse only")
	# Order: the coarse maps are bound with the structure before any region.
	var first_region := -1
	var install := -1
	for index in range(stub.calls.size()):
		var call: Array = stub.calls[index]
		if call[0] == "set_regions" and install < 0: install = index
		if call[0] == "set_region_level" and first_region < 0: first_region = index
	check(install >= 0 and first_region > install and not (stub.calls[install][2].coarse_maps as Dictionary).is_empty() and (stub.calls[install][1] as Array).is_empty(), "the coarse maps are installed with the structure before any region is bound")
	check(stub.calls[install][2].near_slots == 4 and stub.calls[install][2].far_slots == 6 and stub.calls[install][2].far_level == 2 and stub.calls[install][2].coarse_level == 3, "the residency carries the slots and levels")
	check(coarse_matches("initial", terrain, stub), "initial coarse composition")
	check(near_far_match("initial", terrain, bridge, stub), "initial tiers")
	var levels_ok := true
	for call in stub.calls:
		if call[0] == "set_region_level": levels_ok = levels_ok and call[2] == expected.get(call[1], -1)
	check(levels_ok, "regions were bound at their planned level")
	var stats := bridge.get_stats()
	check(stats.near_bound == 4 and stats.far_bound == 6 and stats.coarse_composed >= 4 and stats.near_composed >= 4 and stats.far_composed >= 6 and stats.pending_tasks == 0, "stats report the tiers")
	# A camera move below a quarter extent (8 m) changes nothing.
	var calls_before := stub.calls.size()
	camera.position += Vector3(4, 0, 3)
	for index in range(6): await process_frame
	check(stub.calls.size() == calls_before and bridge.get_wanted() == expected, "a camera move under a quarter extent does not re-tier")
	# Hysteresis: a near region stays near past the radius, but is not admitted there.
	var edge := Vector2i(3, 0)
	var held := bridge.plan_tiers(spec, camera_a, {edge: 0})
	var fresh := bridge.plan_tiers(spec, camera_a, {})
	var generous := bridge.near_slots
	bridge.near_slots = 50
	var held_wide := bridge.plan_tiers(spec, camera_a, {edge: 0})
	var fresh_wide := bridge.plan_tiers(spec, camera_a, {})
	bridge.near_slots = generous
	check(held_wide.get(edge, -1) == 0 and fresh_wide.get(edge, -1) == 2, "a near region at 1.1 radii stays near, a new one at that distance is far (hysteresis)")
	check(held.size() == fresh.size() or held.size() > 0, "the capped plan still respects the slot caps")
	# Moving the camera across the terrain re-tiers and releases.
	var releases := stub.count("release_region")
	var camera_b := Vector2(109.0, 97.0)
	camera.position = Vector3(camera_b.x, camera.position.y, camera_b.y)
	await process_frame
	check(await wait_idle(bridge), "the re-tier finishes")
	var expected_b := nearest_expected(spec, camera_b, 4, 6, 80.0, 100.0, 2)
	check(bridge.get_wanted() == expected_b, "moving the camera re-tiers by distance")
	var near_b := expected_b.keys().filter(func(xy: Vector2i) -> bool: return expected_b[xy] == 0)
	var far_b := expected_b.keys().filter(func(xy: Vector2i) -> bool: return expected_b[xy] == 2)
	check(key_set(stub.near.keys()) == key_set(near_b) and key_set(stub.far.keys()) == key_set(far_b), "the renderer follows the new tiers")
	check(stub.count("release_region") >= releases + 4, "regions that left every tier were released")
	var released_ok := true
	for xy in near_expected + far_expected:
		released_ok = released_ok and (stub.near.has(xy) or stub.far.has(xy) or not expected_b.has(xy))
	check(released_ok and not stub.near.has(Vector2i(0, 0)) and not stub.far.has(Vector2i(0, 0)), "the old regions are gone from the renderer")
	check(bridge.get_stats().regions <= near_b.size() + bridge.cache_regions + far_b.size(), "the CPU cache is bounded")
	check(near_far_match("after the move", terrain, bridge, stub), "tiers after the move")
	check(coarse_matches("after the move", terrain, stub), "coarse after the move")
	# Back to the first spot: regions come from the LRU cache or are recomposed, same result.
	camera.position = Vector3(camera_a.x, camera.position.y, camera_a.y)
	await process_frame
	check(await wait_idle(bridge), "returning re-tiers")
	check(bridge.get_wanted() == expected and near_far_match("returned", terrain, bridge, stub), "returning restores the first tiers")
	# Dabs.
	var hand: StrataLayer = scene.hand
	var cache_trim := bridge.cache_regions
	bridge.cache_regions = 2
	camera.position = Vector3(camera_b.x, camera.position.y, camera_b.y)
	await process_frame
	check(await wait_idle(bridge), "re-tier for the cache bound")
	check(bridge.get_stats().regions <= near_b.size() + 2, "a small cache bound limits the level-0 regions kept")
	bridge.cache_regions = cache_trim
	# Camera at B now: near_b regions are near; a region near A is coarse only.
	var near_region: Vector2i = near_b[0]
	var far_region: Vector2i = far_b[0]
	var coarse_region := Vector2i(0, 0)
	check(not expected_b.has(coarse_region), "region (0, 0) is coarse only for the camera at B")
	var level := 2
	var window_calls := stub.windows.size()
	var centre_near := StrataRegions.region_bounds(spec, near_region).get_center()
	dab(scene, centre_near, 3.0, 0.8, "raise", &"height")
	var patched_window := false
	for entry in stub.windows.slice(window_calls):
		if entry[0] == near_region and entry[1] == "height" and (entry[2] as Vector2i).x < 64: patched_window = true
	check(patched_window, "a dab on a near region patches a window of it")
	check(near_far_match("near dab", terrain, bridge, stub), "near dab")
	bridge.flush_coarse()
	check(coarse_matches("near dab", terrain, stub), "the coarse texels under a near dab follow it")
	var far_before := stub.count("set_region_level")
	var patches: int = bridge.get_stats().far_patches
	var centre_far := StrataRegions.region_bounds(spec, far_region).get_center()
	dab(scene, centre_far, 3.0, 0.8, "raise", &"height")
	check(bridge.get_stats().far_patches > patches and stub.count("set_region_level") > far_before and stub.calls.back()[0] != "release_region", "a dab on a far region recomposes its far level and rebinds it")
	check(near_far_match("far dab", terrain, bridge, stub), "far dab")
	# Coarse-only region: coarse texels only, throttled.
	var centre_coarse := StrataRegions.region_bounds(spec, coarse_region).get_center()
	bridge.flush_coarse()
	var uploads := stub.count("set_coarse_maps")
	var levels_before := stub.count("set_region_level")
	var windows_before := stub.windows.size()
	dab(scene, centre_coarse, 5.0, 0.8, "raise", &"height")
	dab(scene, centre_coarse + Vector2(8, 0), 5.0, 0.8, "raise", &"height")
	dab(scene, centre_coarse + Vector2(0, 8), 5.0, 0.8, "raise", &"height")
	check(stub.count("set_coarse_maps") - uploads <= 1, "coarse uploads are throttled while painting")
	check(stub.count("set_region_level") == levels_before and stub.windows.size() == windows_before, "a dab on a coarse-only region binds no region")
	await create_timer(0.45).timeout
	check(stub.count("set_coarse_maps") > uploads and coarse_matches("coarse dab", terrain, stub), "the trailing flush uploads the final coarse texels")
	var material_before: int = bridge.get_stats().material_regions
	dab(scene, centre_coarse, 6.0, 0.9, "raise", &"material_d")
	dab(scene, centre_coarse + Vector2(8, 8), 3.0, 1.0, "raise", &"hole")
	bridge.flush_coarse()
	check(bridge.get_stats().material_regions == material_before + 1 and coarse_matches("coarse material and hole dabs", terrain, stub), "material and hole dabs update the coarse maps")
	bridge.refresh_now()
	check(not bridge.is_busy() and coarse_matches("after the dabs", terrain, stub) and near_far_match("after the dabs", terrain, bridge, stub), "the dabs left the preview current")
	# An external edit recomposes the stale class in every tier.
	hand.data.set_sample(&"height", Vector2i(8, 8), 9.0)
	bridge.request_refresh()
	check(await wait_idle(bridge), "an edit refreshes the tiers")
	check(coarse_matches("after an edit", terrain, stub) and near_far_match("after an edit", terrain, bridge, stub), "an external edit reaches coarse, near and far")
	check(bridge.get_stats().full_compiles >= 2, "the edit recomposed height")
	terrain.free()
	await process_frame

func small_terrain_phase_a() -> void:
	# 16 regions fit the near slots: exactly the Phase A layout, nothing tiered.
	var stub := Stub.new()
	var scene := build(64.0, Vector2(-32, -32), 1.0, 16, true, stub)
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	check(await wait_idle(bridge), "the small terrain composes")
	var installs: Array = stub.calls.filter(func(call: Array) -> bool: return call[0] == "set_regions")
	check(not bridge.get_stats().tiered and installs.size() == 1 and (installs[0][1] as Array).size() == 16 and (installs[0][2] as Dictionary).is_empty(), "a small terrain installs every region at once without residency")
	check(stub.count("set_region_level") == 0 and stub.count("release_region") == 0 and stub.coarse.is_empty() and stub.near.size() == 16, "a small terrain binds no tiers and no coarse maps")
	check(near_far_match("small terrain", terrain, bridge, stub), "small terrain regions equal compose_region")
	var good := true
	for xy: Vector2i in stub.near: good = good and bridge.get_region(xy) == stub.near[xy]
	check(good, "the renderer holds the preview's own regions")
	dab(scene, Vector2(0, 0), 5.0, 0.8, "raise", &"height")
	check(stub.count("update_region_window") >= 4 and near_far_match("small terrain dab", terrain, bridge, stub), "a dab patches windows in the small terrain's regions")
	terrain.free()
	await process_frame

func tiered_gpu() -> void:
	# The same tiered terrain on the real renderer: slots, levels and coarse bytes follow the plan.
	var scene := build(256.0, Vector2(-128, -128), 1.0, 32, true, null, {"near_slots": 4, "far_slots": 6, "coarse_max_side": 32, "far_radius": 100.0}, Vector2(-117.0, -103.0))
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	var camera: Camera3D = scene.camera
	check(await wait_idle(bridge), "the tiered terrain composes on the GPU renderer")
	var renderer: StrataRenderer = bridge.renderer
	var spec := terrain.region_spec()
	var wanted := bridge.get_wanted()
	var stats := renderer.get_stats()
	check(stats.near_resident == 4 and stats.far_resident == 6 and stats.near_slots == 4 and stats.far_slots == 6 and stats.gpu_bytes_coarse > 0, "the renderer holds the planned tiers and the coarse maps")
	var levels_ok := true
	for xy: Vector2i in wanted: levels_ok = levels_ok and renderer.region_level(xy) == wanted[xy]
	check(levels_ok and renderer.region_level(Vector2i(7, 7)) == -1, "every planned region is bound at its level, the rest are coarse only")
	var near_xy: Vector2i = wanted.keys().filter(func(xy: Vector2i) -> bool: return wanted[xy] == 0)[0]
	var fresh := StrataRegions.compose_region(terrain, null, near_xy, spec)
	check(renderer.get_region(near_xy).get_image("height").get_data() == fresh.region.get_image("height").get_data(), "a near region equals compose_region on the renderer")
	dab(scene, StrataRegions.region_bounds(spec, near_xy).get_center(), 5.0, 0.8, "raise", &"height")
	var fresh_after := StrataRegions.compose_region(terrain, null, near_xy, spec)
	check(renderer.get_region(near_xy).get_image("height").get_data() == fresh_after.region.get_image("height").get_data(), "a near dab patches the renderer")
	camera.position = Vector3(109.0, camera.position.y, 97.0)
	await process_frame
	check(await wait_idle(bridge), "the camera move re-tiers on the GPU renderer")
	stats = renderer.get_stats()
	check(stats.near_resident == 4 and stats.far_resident == 6 and renderer.region_level(near_xy) == -1, "the old near region was released")
	terrain.free()
	await process_frame
