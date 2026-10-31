extends SceneTree
## The editor preview bridge on regions (Track E of docs/development/strata_regions_plan.md).
## Small artificial terrains only: a flat base, a partial procedural material distribution and a
## manual layer holding heights, materials, holes and tint. Checks that the regions the renderer
## holds equal StrataRegions.compose_region for every region, that height, material, hole and
## tint dabs patched through refresh_region() equal a fresh full composition bit for bit, that a
## dab never recomposes a class it does not touch, and prints the dab cost.
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
func build(size: float, origin: Vector2, spacing: float, cells: int, with_bridge: bool = true) -> Dictionary:
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
	var camera := Camera3D.new(); camera.position = Vector3(origin.x + size * 0.5, size, origin.y + size * 0.5); terrain.add_child(camera); camera.look_at(camera.position - Vector3.UP, Vector3.FORWARD); camera.current = true
	var bridge := StrataEditorPreview.new(); terrain.add_child(bridge); bridge.setup(terrain); bridge.set_camera(camera)
	return {"terrain": terrain, "bridge": bridge, "hand": hand, "base": base, "distribution": distribution}

## Every region of the renderer (and of the bridge cache) equals a fresh compose_region.
func regions_match(label: String, scene: Dictionary) -> bool:
	var terrain: StrataTerrain3D = scene.terrain
	var bridge: StrataEditorPreview = scene.bridge
	var renderer := bridge.renderer
	var spec := terrain.region_spec()
	check(renderer.region_spec() == spec and bridge.get_spec() == spec, label + ": the renderer holds the terrain's region spec")
	var good := true
	var mismatched := []
	for y in range(StrataRegions.grid_size(spec).y):
		for x in range(StrataRegions.grid_size(spec).x):
			var xy := Vector2i(x, y)
			var fresh := StrataRegions.compose_region(terrain, terrain.preview_through_layer, xy, spec)
			if not fresh.ok: good = false; mismatched.append(str(xy) + " " + String(fresh.message)); continue
			var held := renderer.get_region(xy)
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
	if RenderingServer.get_rendering_device() == null: push_error("Use graphical Forward+"); quit(2); return
	await exact_lattice()
	await inexact_lattice()
	await cutoffs_and_configuration()
	await headless_cache()
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
	var scene := build(64.0, Vector2(-30.3, -33.1), 0.75, 16)
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
	var weights := bridge.renderer.get_region(Vector2i.ZERO).get_image("material_weights")
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
	var spec := terrain.region_spec()
	var fresh := StrataRegions.compose_region(terrain, null, Vector2i(1, 1), spec)
	check(fresh.ok and bridge.get_region(Vector2i(1, 1)).get_image("height").get_data() == fresh.region.get_image("height").get_data(), "cached regions equal compose_region")
	var compositions: int = bridge.get_stats().material_compositions
	check(bridge.compose_cache() and bridge.get_stats().material_compositions == compositions, "an unchanged stack reuses the cache")
	terrain.free()
	await process_frame
