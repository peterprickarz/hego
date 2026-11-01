extends SceneTree
## Forward+ regression for the renderer's residency tiers (Phase B): near arrays, far arrays and
## terrain-wide coarse maps on a synthetic 64 m terrain of 4 x 4 regions of 16 cells. The
## production vertex() and fragment() run unchanged except that the final colour encodes
## (material id, height, macro tint), the tier, or the vertex-stage height, so pixels can be
## compared with fixtures computed on the CPU from the regions' own level data. Every field here
## is an in-memory fixture; no asset is read or written.

const BOUNDS := Rect2(-32, -32, 64, 64)
const CELLS := 16
const FAR_LEVEL := 1
const COARSE_LEVEL := 2
const BACKGROUND := Color(0.9, 0.2, 0.9)
const TAIL_VALUES := "ALBEDO = vec3(float(ids[0]) / 31.0, base_height(terrain_position) / 16.0, terrain_macro.r);"
const TAIL_TIER := "{ vec2 unused_local; int unused_slot; int tier_code = terrain_region_entry(terrain_region_locate(terrain_position, unused_local), unused_slot); ALBEDO = vec3(float(tier_code) / 4.0, 0.0, 0.0); }"
const TAIL_VERTEX := "ALBEDO = vec3(vertex_y / 16.0, base_height(terrain_position) / 16.0, 0.0);"
const HOLES := [Vector2i(30, 30), Vector2i(40, 40), Vector2i(50, 50)] # near, far, coarse tier in the final layout
const NEAR_FINAL: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 1), Vector2i(0, 2), Vector2i(1, 2)]
const FAR_FINAL: Array[Vector2i] = [Vector2i(2, 1), Vector2i(3, 1), Vector2i(2, 2), Vector2i(3, 2), Vector2i(0, 3), Vector2i(1, 3)]
var failures := 0
var viewport: SubViewport
var view: Camera3D
var source: StrataTerrain3D
var renderer: StrataRenderer
var spec: Dictionary
var regions: Dictionary = {}
var coarse: Dictionary = {}

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	create_timer(240.0).timeout.connect(func(): push_error("Residency render test watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null:
		push_error("Residency render tests require graphical Forward+.")
		quit(2)
		return
	print("RESIDENCY_RENDER_GPU ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_video_adapter_api_version())
	setup_scene()
	build_fixture()
	test_rejections()
	await test_coarse_only()
	test_slot_api()
	await test_tiers()
	await test_seams()
	test_window_and_stats()
	await test_release_to_coarse()
	print("RESIDENCY_RENDER_TEST failures=", failures)
	quit(0 if failures == 0 else 1)

func setup_scene() -> void:
	viewport = SubViewport.new(); viewport.size = Vector2i(256, 256); viewport.use_hdr_2d = true; viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node3D.new(); viewport.add_child(world)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = BACKGROUND
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.add_child(environment)
	view = Camera3D.new(); view.projection = Camera3D.PROJECTION_ORTHOGONAL; view.near = 0.05; view.far = 2000.0; view.size = 64.0
	world.add_child(view); view.current = true
	top_view()
	source = StrataTerrain3D.new(); source.base_bounds = BOUNDS; world.add_child(source)
	renderer = StrataRenderer.new(); source.add_child(renderer)
	var pool: Array[StrataMaterial] = []
	for index in range(10): pool.append(StrataMaterial.new())
	check(renderer.configure(source, pool), "Renderer configures on a 64 m terrain")
	renderer.set_camera(view); renderer.displacement_enabled = false

func top_view() -> void:
	view.position = Vector3(0, 400, 0); view.look_at(Vector3(0, 0, 0), Vector3.FORWARD)

# ---- fixtures ----

static func height_at(position: Vector2) -> float:
	return 3.0 + position.x / 8.0 + position.y / 16.0 + 0.3 * sin(0.5 * position.x) * cos(0.4 * position.y)

func material_id_at(index: Vector2i) -> int:
	return 1 + (index.x / CELLS + (index.y / CELLS) * 3) % 8

func macro_at(position: Vector2) -> float:
	return 0.3 + 0.005 * (position.x - BOUNDS.position.x)

func map_value(name: String, index: Vector2i, description: Dictionary) -> Color:
	var scale := int(description.scale)
	var is_cell := String(description.kind) == StrataRegions.KIND_CELL
	var lattice_max := Vector2i.ONE * (64 / scale - (1 if is_cell else 0))
	var clamped := index.clamp(Vector2i.ZERO, lattice_max)
	match name:
		"height": return Color(height_at(BOUNDS.position + Vector2(clamped)), 0, 0, 1)
		"material_ids": return Color8(material_id_at(clamped), 0, 0, 0)
		"material_weights": return Color(1, 0, 0, 0)
		"holes": return Color(1, 0, 0, 1) if clamped in HOLES else Color(0, 0, 0, 1)
		"macro": return Color(macro_at(BOUNDS.position + Vector2(clamped) * 4.0), 0.5, 0.25, 1.0)
	return Color()

func make_region(xy: Vector2i) -> StrataRegionData:
	var data := StrataRegionData.new()
	data.region = xy; data.cells = int(spec.cells); data.apron = int(spec.apron); data.spacing = float(spec.spacing)
	data.origin = StrataRegions.region_origin(spec, xy)
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		var window := StrataRegions.map_window(spec, xy, description, 0)
		var image := Image.create(window.size.x, window.size.y, false, int(description.format))
		for v in range(window.size.y):
			for u in range(window.size.x):
				image.set_pixel(u, v, map_value(name, window.first + Vector2i(u, v), description))
		check(data.set_image(name, image, 0, description), "Fixture %s of region %s stores" % [name, str(xy)])
	var low := INF; var high := -INF
	for v in range(CELLS + 1):
		for u in range(CELLS + 1):
			var h := height_at(BOUNDS.position + Vector2(xy * CELLS + Vector2i(u, v)))
			low = minf(low, h); high = maxf(high, h)
	data.height_min = low; data.height_max = high
	StrataRegions.build_mips(data, 3)
	make_height_levels_decimated(data)
	return data

## Height levels share lattice points with level 0: texel u of level l is the level-0 sample
## (u - apron) << l, whatever the bake's mip rule is (the checks here compare level data).
func make_height_levels_decimated(data: StrataRegionData) -> void:
	var base := data.get_image("height", 0)
	var apron := int(spec.apron)
	for level in range(1, 3):
		var size := StrataRegions.map_size(CELLS, spec.maps.height, level)
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
		for v in range(size.y):
			for u in range(size.x):
				var source_texel := (Vector2i(u, v) - Vector2i.ONE * apron) * (1 << level) + Vector2i.ONE * apron
				image.set_pixelv(Vector2i(u, v), base.get_pixelv(source_texel.clamp(Vector2i.ZERO, base.get_size() - Vector2i.ONE)))
		check(data.set_image("height", image, level), "Decimated height level %d of region %s stores" % [level, str(data.region)])

func build_fixture() -> void:
	spec = StrataRegions.standard_spec(BOUNDS, 1.0, CELLS, 2)
	for y in range(4):
		for x in range(4): regions[Vector2i(x, y)] = make_region(Vector2i(x, y))
	for name in spec.maps:
		var description: Dictionary = spec.maps[name]
		var size := StrataRegions.coarse_map_size(spec, description, COARSE_LEVEL)
		var image := Image.create(size.x, size.y, false, int(description.format))
		for xy in regions:
			var placement := StrataRegions.coarse_placement(spec, xy, description, COARSE_LEVEL)
			var core: Image = (regions[xy] as StrataRegionData).get_image(name, COARSE_LEVEL)
			image.blit_rect(core, placement.source, placement.destination)
		coarse[name] = image
	check(coarse.height.get_size() == Vector2i(17, 17) and coarse.holes.get_size() == Vector2i(16, 16) and coarse.macro.get_size() == Vector2i(5, 5), "Coarse images follow StrataRegions.coarse_map_size (%s %s %s)" % [str(coarse.height.get_size()), str(coarse.holes.get_size()), str(coarse.macro.get_size())])

func residency(near_slots := 4, far_slots := 6) -> Dictionary:
	return {"near_slots": near_slots, "far_slots": far_slots, "far_level": FAR_LEVEL, "coarse_level": COARSE_LEVEL, "coarse_maps": coarse}

func override_shader(tail: String, capture_vertex := false) -> void:
	var code := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	for name in ["terrain_regions.gdshaderinc", "terrain_controls.gdshaderinc", "terrain_texture_dispatch.gdshaderinc", "terrain_normals.gdshaderinc", "terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:
		code = code.replace('#include "' + name + '"', FileAccess.get_file_as_string("res://addons/strata/shaders/" + name))
	code = code.replace("render_mode cull_back,", "render_mode unshaded, cull_back,")
	if capture_vertex:
		code = code.replace("varying vec2 terrain_position;", "varying vec2 terrain_position;\nvarying float vertex_y;")
		code = code.replace("VERTEX = vec3(terrain_position.x, height, terrain_position.y) + direction * offset;", "VERTEX = vec3(terrain_position.x, height, terrain_position.y) + direction * offset;\n\tvertex_y = VERTEX.y;")
	var end := code.rfind("}")
	var shader := Shader.new(); shader.code = code.substr(0, end) + tail + code.substr(end)
	renderer._shader_material.shader = shader

func render(frames := 6) -> Image:
	for index in range(frames): await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func pixel_of(position: Vector2) -> Vector2i:
	var screen := view.unproject_position(Vector3(position.x, 0.0, position.y))
	return Vector2i(screen.floor())

func world_of(pixel: Vector2i) -> Vector2:
	var origin := view.project_ray_origin(Vector2(pixel) + Vector2(0.5, 0.5))
	return Vector2(origin.x, origin.z)

func grid(step: int, margin: int) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	for y in range(margin, viewport.size.y - margin, step):
		for x in range(margin, viewport.size.x - margin, step): pixels.append(Vector2i(x, y))
	return pixels

func color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

func is_hole_pixel(position: Vector2) -> bool:
	for cell in HOLES:
		if Rect2(BOUNDS.position + Vector2(cell) - Vector2.ONE * 5.0, Vector2.ONE * 12.0).has_point(position): return true
	return false

# ---- CPU model of what each tier draws ----

static func bilinear(image: Image, texel: Vector2) -> float:
	var last := image.get_size() - Vector2i.ONE
	var base := Vector2i(texel.floor()).clamp(Vector2i.ZERO, last)
	var f := (texel - Vector2(base)).clamp(Vector2.ZERO, Vector2.ONE)
	var next := (base + Vector2i.ONE).min(last)
	var top := lerpf(image.get_pixel(base.x, base.y).r, image.get_pixel(next.x, base.y).r, f.x)
	var bottom := lerpf(image.get_pixel(base.x, next.y).r, image.get_pixel(next.x, next.y).r, f.x)
	return lerpf(top, bottom, f.y)

## Bilinear height of a region's own level data at a terrain position.
func level_height(xy: Vector2i, level: int, position: Vector2) -> float:
	var texel := StrataRegions.texel_at(spec, xy, spec.maps.height, position, level)
	return bilinear((regions[xy] as StrataRegionData).get_image("height", level), texel)

func coarse_height(position: Vector2) -> float:
	return bilinear(coarse.height, (position - BOUNDS.position) / float(1 << COARSE_LEVEL))

## Height of the fine lattice point the shader reads for a region (higher region on shared edges).
func point_height(index: Vector2i) -> float:
	var lattice := index.clamp(Vector2i.ZERO, Vector2i(64, 64))
	var xy := Vector2i(lattice / CELLS).clamp(Vector2i.ZERO, Vector2i(3, 3))
	var position := BOUNDS.position + Vector2(lattice)
	var level := renderer.region_level(xy)
	if level == 0: return level_height(xy, 0, position)
	if level == FAR_LEVEL: return level_height(xy, FAR_LEVEL, position)
	return coarse_height(position)

## The shader's base_height: triangle interpolation of the lattice point heights.
func surface_height(position: Vector2) -> float:
	var grid_position := (position - BOUNDS.position).clamp(Vector2.ZERO, Vector2(64, 64))
	var first := Vector2i(grid_position.floor()).min(Vector2i(63, 63))
	var f := grid_position - Vector2(first)
	var a := point_height(first); var b := point_height(first + Vector2i(1, 0))
	var c := point_height(first + Vector2i(0, 1)); var d := point_height(first + Vector2i.ONE)
	return a + (b - a) * f.x + (c - a) * f.y if f.x + f.y <= 1.0 else d + (c - d) * (1.0 - f.x) + (b - d) * (1.0 - f.y)

func centre_of(xy: Vector2i) -> Vector2:
	return StrataRegions.region_origin(spec, xy) + Vector2.ONE * (CELLS * 0.5)

# ---- tests ----

func test_rejections() -> void:
	var spec_before := renderer.region_spec()
	var stats_before := renderer.get_stats()
	var good := residency()
	check(not renderer.set_regions(spec, {}, residency(0, 6)), "Zero near slots are rejected")
	check(not renderer.set_regions(spec, {}, residency(4, -1)), "Negative far slots are rejected")
	check(not renderer.set_regions(spec, {}, residency(100000, 6)), "More near slots than the device has array layers are rejected")
	check(not renderer.set_regions(spec, {}, residency(4, 100000)), "More far slots than the device has array layers are rejected")
	var deep := good.duplicate(); deep.far_level = 3
	check(not renderer.set_regions(spec, {}, deep), "A far level beyond the deepest every map has is rejected")
	var flat := good.duplicate(); flat.far_level = 0
	check(not renderer.set_regions(spec, {}, flat), "Far level 0 is rejected")
	var small := good.duplicate(); small.coarse_maps = coarse.duplicate(); small.coarse_maps.height = Image.create(5, 5, false, Image.FORMAT_RF)
	check(not renderer.set_regions(spec, {}, small), "A mis-sized coarse map is rejected")
	var wrong := good.duplicate(); wrong.coarse_maps = coarse.duplicate(); wrong.coarse_maps.macro = Image.create(5, 5, false, Image.FORMAT_RGBA8)
	check(not renderer.set_regions(spec, {}, wrong), "A coarse map in the wrong format is rejected")
	var missing := good.duplicate(); missing.coarse_maps = coarse.duplicate(); missing.coarse_maps.erase("holes")
	check(not renderer.set_regions(spec, {}, missing), "A coarse set lacking a spec map is rejected")
	check(not renderer.set_regions(spec, {Vector2i(0, 0): regions[Vector2i(0, 0)], Vector2i(1, 0): regions[Vector2i(1, 0)], Vector2i(2, 0): regions[Vector2i(2, 0)], Vector2i(3, 0): regions[Vector2i(3, 0)], Vector2i(0, 1): regions[Vector2i(0, 1)]}, residency()), "Five regions do not fit four near slots")
	var stats_after := renderer.get_stats()
	check(renderer.region_spec() == spec_before and stats_after.regions == stats_before.regions and stats_after.get("near_slots", -1) == stats_before.get("near_slots", -1), "Rejected residency calls change nothing")

func test_coarse_only() -> void:
	var spec_before_binding := renderer.region_spec()
	var pool: Array[StrataMaterial] = []
	for index in range(10): pool.append(StrataMaterial.new())
	check(not renderer.configure_regions(source, pool, spec, {}, residency(0, 6)) and renderer.region_spec() == spec_before_binding, "configure_regions rejects an invalid residency and keeps the configuration")
	check(renderer.configure_regions(source, pool, spec, {}, residency()), "configure_regions accepts residency with no regions bound")
	var stats := renderer.get_stats()
	check(stats.near_slots == 4 and stats.far_slots == 6 and stats.near_resident == 0 and stats.far_resident == 0 and stats.regions == 0, "Stats report the slots and no resident region")
	var table: Image = renderer._region_table_image
	var all_none := true
	for y in range(4):
		for x in range(4):
			var texel := table.get_pixel(x, y)
			all_none = all_none and texel.a8 == 0 and texel.b8 == 255
	check(all_none, "The table marks every region as no tier (B 255, A 0)")
	check(renderer.free_slots(0) == 4 and renderer.free_slots(FAR_LEVEL) == 6 and renderer.free_slots(2) == 0 and renderer.free_slots(5) == 0, "free_slots reports the empty tiers and 0 for other levels")
	check(renderer._region_arrays.height.get_layers() == 4 and renderer._far_arrays.height.get_layers() == 6, "Near and far arrays have near_slots and far_slots layers")
	check(Vector2i(renderer._far_arrays.height.get_width(), renderer._far_arrays.height.get_height()) == StrataRegions.map_size(CELLS, spec.maps.height, FAR_LEVEL), "Far layers have the level-far_level map size")
	check(renderer.get_stats().gpu_bytes_coarse == coarse.values().reduce(func(total, image): return total + (image as Image).get_data_size(), 0), "gpu_bytes_coarse counts the coarse images")
	# The patch bounds of regions drawn from the coarse maps cover their coarse heights.
	var covered := 0
	for patch: MeshInstance3D in renderer._patches.values():
		var bounds: Rect2 = patch.get_meta("terrain_patch_bounds")
		var xy := StrataRegions.region_at(spec, bounds.get_center())
		if StrataRegions.region_bounds(spec, xy).encloses(bounds):
			var extrema: Vector2 = renderer._coarse_extrema[xy]
			check(patch.custom_aabb.end.y >= extrema.y - 0.001 and patch.custom_aabb.position.y <= extrema.x + 0.001, "Patch bounds over coarse-only region %s cover its heights" % str(xy))
			covered += 1
	check(covered > 0, "Some patch lies wholly over one coarse-only region")
	override_shader(TAIL_TIER)
	var tiers: Image = await render()
	var wrong_tier := 0; var tested := 0
	for pixel in grid(7, 6):
		if is_hole_pixel(world_of(pixel)): continue
		tested += 1
		if absf(tiers.get_pixelv(pixel).r * 4.0 - 3.0) > 0.02: wrong_tier += 1
	check(tested > 400 and wrong_tier == 0, "Every region renders from the coarse tier (%d of %d pixels differ)" % [wrong_tier, tested])
	override_shader(TAIL_VALUES)
	var values: Image = await render()
	var worst_height := 0.0; var worst_macro := 0.0; var skipped := 0
	for pixel in grid(5, 8):
		var position := world_of(pixel)
		if is_hole_pixel(position): skipped += 1; continue
		var color := values.get_pixelv(pixel)
		worst_height = maxf(worst_height, absf(color.g * 16.0 - surface_height(position)))
		worst_macro = maxf(worst_macro, absf(color.b - (0.3 + 0.005 * (position.x - BOUNDS.position.x))))
	print("RESIDENCY_RENDER_COARSE height_error=", worst_height, " macro_error=", worst_macro)
	check(worst_height < 0.03, "Coarse-only heights follow the coarse height map (worst %f)" % worst_height)
	check(worst_macro < 0.02, "Coarse-only macro tint follows the coarse macro map (worst %f)" % worst_macro)
	# (f) A region that was never set shows the coarse texel at its centre.
	for xy in [Vector2i(0, 0), Vector2i(3, 2), Vector2i(2, 3)]:
		var centre := centre_of(xy)
		var color := values.get_pixelv(pixel_of(centre))
		var texel := Vector2i((centre - BOUNDS.position) / float(1 << COARSE_LEVEL))
		var expected_id := (coarse.material_ids as Image).get_pixelv(texel).r8
		check(absf(color.r * 31.0 - float(expected_id)) < 0.1, "Region %s centre shows coarse material %d (got %f)" % [str(xy), expected_id, color.r * 31.0])
		check(absf(color.g * 16.0 - coarse_height(centre)) < 0.03, "Region %s centre shows the coarse height" % str(xy))
		check(absf(color.b - macro_at(centre)) < 0.02, "Region %s centre shows the coarse macro tint" % str(xy))

func test_slot_api() -> void:
	var near: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var far: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0), Vector2i(2, 1), Vector2i(3, 1), Vector2i(0, 2), Vector2i(1, 2)]
	for xy in near: check(renderer.set_region_level(xy, regions[xy], 0), "Near region %s binds" % str(xy))
	for xy in far: check(renderer.set_region_level(xy, regions[xy], FAR_LEVEL), "Far region %s binds" % str(xy))
	check(renderer.free_slots(0) == 0 and renderer.free_slots(FAR_LEVEL) == 0, "Both tiers are full")
	check(not renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], 0) and renderer.region_level(Vector2i(2, 2)) == -1, "A fifth near region fails with no free slot")
	check(not renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], FAR_LEVEL), "A seventh far region fails with no free slot")
	check(not renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], 2) and not renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], -1), "A level that is neither near nor far is rejected")
	check(renderer.region_level(Vector2i(0, 0)) == 0 and renderer.region_level(Vector2i(3, 1)) == FAR_LEVEL, "region_level reports near and far")
	var table: Image = renderer._region_table_image
	var near_texel := table.get_pixelv(Vector2i(1, 1)); var far_texel := table.get_pixelv(Vector2i(3, 1))
	check(near_texel.a8 == 1 and near_texel.b8 == 0 and far_texel.a8 == 2 and far_texel.b8 == FAR_LEVEL, "The table flags near 1 / level 0 and far 2 / far level")
	var slots := {}
	for xy in near: slots[table.get_pixelv(xy).r8 + table.get_pixelv(xy).g8 * 256] = true
	check(slots.size() == 4 and slots.keys().all(func(slot): return slot >= 0 and slot < 4), "Near regions hold distinct slots below near_slots")
	check(renderer.release_region(Vector2i(1, 1)) and renderer.free_slots(0) == 1 and renderer.region_level(Vector2i(1, 1)) == -1, "release_region frees the near slot")
	check(renderer._region_table_image.get_pixelv(Vector2i(1, 1)).a8 == 0 and renderer.get_region(Vector2i(1, 1)) == null, "A released region is no tier and has no CPU data")
	check(not renderer.release_region(Vector2i(1, 1)), "Releasing an unbound region is false")
	check(renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], 0) and renderer.free_slots(0) == 0, "The freed slot takes another region")
	check(renderer.release_region(Vector2i(0, 1)), "Release makes room for a move")
	check(renderer.set_region_level(Vector2i(2, 0), regions[Vector2i(2, 0)], 0) and renderer.free_slots(FAR_LEVEL) == 1 and renderer.region_level(Vector2i(2, 0)) == 0, "Moving a far region to near frees its far slot")
	check(renderer.set_region_level(Vector2i(0, 1), regions[Vector2i(0, 1)], FAR_LEVEL) and renderer.free_slots(FAR_LEVEL) == 0 and renderer.free_slots(0) == 0, "A released region binds far into the freed far slot")
	check(not renderer.set_region_level(Vector2i(0, 1), regions[Vector2i(0, 1)], 0) and renderer.region_level(Vector2i(0, 1)) == FAR_LEVEL and renderer.free_slots(0) == 0 and renderer.free_slots(FAR_LEVEL) == 0, "A move into a full tier fails and keeps the region where it is")
	check(renderer.release_region(Vector2i(0, 0)) and renderer.set_region_level(Vector2i(0, 1), regions[Vector2i(0, 1)], 0) and renderer.free_slots(0) == 0 and renderer.free_slots(FAR_LEVEL) == 1, "Moving a far region to near frees its far slot and takes the near slot")
	check(renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], FAR_LEVEL) and renderer.free_slots(0) == 1 and renderer.free_slots(FAR_LEVEL) == 0, "Moving a near region to far frees its near slot")
	check(not renderer.set_region_level(Vector2i(1, 0), regions[Vector2i(1, 0)], FAR_LEVEL) and renderer.region_level(Vector2i(1, 0)) == 0 and renderer.free_slots(0) == 1, "A near region cannot move into the full far tier")
	check(renderer.set_region_level(Vector2i(2, 2), regions[Vector2i(2, 2)], 0) and renderer.free_slots(0) == 0 and renderer.free_slots(FAR_LEVEL) == 1, "Moving it back restores the slot counts")
	# Data without the level or not matching the spec changes nothing.
	var shallow := make_region(Vector2i(3, 3))
	var levels: Array = shallow.maps.height.levels
	levels.resize(1)
	check(not renderer.set_region_level(Vector2i(3, 3), shallow, FAR_LEVEL) and renderer.region_level(Vector2i(3, 3)) == -1 and renderer.free_slots(FAR_LEVEL) == 1, "Data lacking the far level is rejected without a change")
	check(not renderer.set_region_level(Vector2i(3, 3), regions[Vector2i(0, 0)], FAR_LEVEL), "Data for another region is rejected")
	check(not renderer.update_region(Vector2i(3, 3), regions[Vector2i(3, 3)]), "update_region refuses a region that is not bound")
	# update_region keeps the tier.
	var far_slot_before := renderer._far_layers[Vector2i(3, 1)] as int
	check(renderer.update_region(Vector2i(3, 1), regions[Vector2i(3, 1)]) and renderer.region_level(Vector2i(3, 1)) == FAR_LEVEL and renderer._far_layers[Vector2i(3, 1)] == far_slot_before, "update_region keeps a far region in its far slot")
	check(renderer.update_region(Vector2i(1, 0), regions[Vector2i(1, 0)]) and renderer.region_level(Vector2i(1, 0)) == 0, "update_region keeps a near region near")
	check(not renderer.set_coarse_maps(COARSE_LEVEL, {"height": coarse.height}) and not renderer.set_coarse_maps(7, coarse), "set_coarse_maps rejects incomplete images and an impossible level")
	# Reduce to the layout the render checks use.
	for xy in renderer._regions.keys(): renderer.release_region(xy)
	check(renderer.free_slots(0) == 4 and renderer.free_slots(FAR_LEVEL) == 6, "Releasing every region empties both tiers")
	for xy in NEAR_FINAL: check(renderer.set_region_level(xy, regions[xy], 0), "Final near region %s binds" % str(xy))
	for xy in FAR_FINAL: check(renderer.set_region_level(xy, regions[xy], FAR_LEVEL), "Final far region %s binds" % str(xy))

func test_tiers() -> void:
	override_shader(TAIL_TIER)
	var tiers: Image = await render()
	var wrong := 0
	for pixel in grid(5, 6):
		var position := world_of(pixel)
		if is_hole_pixel(position): continue
		var xy := StrataRegions.region_at(spec, position)
		var expected := 3.0 if renderer.region_level(xy) < 0 else (1.0 if renderer.region_level(xy) == 0 else 2.0)
		if absf(tiers.get_pixelv(pixel).r * 4.0 - expected) > 0.02: wrong += 1
	check(wrong == 0, "Every pixel renders from its region's tier (%d wrong)" % wrong)
	override_shader(TAIL_VALUES)
	var values: Image = await render()
	var worst_height := 0.0; var worst_macro := 0.0; var wrong_ids := 0; var tested := 0
	for pixel in grid(5, 8):
		var position := world_of(pixel)
		if is_hole_pixel(position): continue
		tested += 1
		var color := values.get_pixelv(pixel)
		var error := absf(color.g * 16.0 - surface_height(position))
		if error > worst_height and error > 0.03:
			var first := Vector2i((position - BOUNDS.position).floor())
			print("RESIDENCY_RENDER_POINTS ", first, " ", point_height(first), " ", point_height(first + Vector2i(1, 0)), " ", point_height(first + Vector2i(0, 1)), " ", point_height(first + Vector2i.ONE), " analytic ", height_at(BOUNDS.position + Vector2(first)), " ", height_at(BOUNDS.position + Vector2(first + Vector2i(0, 1))))
			print("RESIDENCY_RENDER_WORST ", position, " region ", StrataRegions.region_at(spec, position), " got ", color.g * 16.0, " expected ", surface_height(position))
		worst_height = maxf(worst_height, error)
		worst_macro = maxf(worst_macro, absf(color.b - macro_at(position)))
	print("RESIDENCY_RENDER_TIERS pixels=", tested, " height_error=", worst_height, " macro_error=", worst_macro)
	check(tested > 500, "The probe covers many pixels")
	check(worst_height < 0.03, "Heights follow each tier's level data across all boundaries (worst %f)" % worst_height)
	check(worst_macro < 0.02, "Macro tint follows each tier (worst %f)" % worst_macro)
	for xy in regions:
		var centre := centre_of(xy)
		if is_hole_pixel(centre): continue
		var level := renderer.region_level(xy)
		var color := values.get_pixelv(pixel_of(centre))
		var index := Vector2i(centre - BOUNDS.position)
		var expected_id := material_id_at(index) if level >= 0 else (coarse.material_ids as Image).get_pixelv(Vector2i((centre - BOUNDS.position) / float(1 << COARSE_LEVEL))).r8
		if level == FAR_LEVEL: expected_id = (regions[xy] as StrataRegionData).get_image("material_ids", FAR_LEVEL).get_pixelv(Vector2i(2 + CELLS / 4, 2 + CELLS / 4)).r8
		check(absf(color.r * 31.0 - float(expected_id)) < 0.1, "Region %s (level %d) centre shows material %d (got %f)" % [str(xy), level, expected_id, color.r * 31.0])
	# Holes live in every tier.
	for cell in HOLES:
		var centre := BOUNDS.position + Vector2(cell) + Vector2(0.5, 0.5)
		var hole := values.get_pixelv(pixel_of(centre))
		check(color_distance(hole, BACKGROUND.srgb_to_linear()) < 0.02, "Hole cell %s discards its fragments in tier %d" % [str(cell), renderer.region_level(Vector2i(cell / CELLS))])
		var beside := values.get_pixelv(pixel_of(centre + Vector2(-6.0, 0.0)))
		check(color_distance(beside, BACKGROUND.srgb_to_linear()) > 0.1, "The terrain beside hole %s still draws" % str(cell))

func test_seams() -> void:
	# Shared lattice points: the near region's edge column equals the far region's first column.
	var worst := 0.0
	for pair in [[Vector2i(1, 1), Vector2i(2, 1)], [Vector2i(1, 2), Vector2i(2, 2)]]:
		var near_height: Image = (regions[pair[0]] as StrataRegionData).get_image("height", 0)
		var far_height: Image = (regions[pair[1]] as StrataRegionData).get_image("height", FAR_LEVEL)
		var apron := int(spec.apron)
		for v in range(0, CELLS + 1, 2):
			worst = maxf(worst, absf(near_height.get_pixel(apron + CELLS, apron + v).r - far_height.get_pixel(apron, apron + v / 2).r))
	check(worst == 0.0, "Near and far data agree at shared lattice points (worst %f)" % worst)
	# Rendered: the surface step across the near | far boundary and the near | coarse boundary
	# matches the model, in the rasterized vertex heights as well as in the fragment heights.
	override_shader(TAIL_VERTEX, true)
	var image: Image = await render()
	var worst_step := 0.0; var worst_mesh := 0.0; var pairs := 0
	for t in range(-28, 28, 2):
		for edge in [Vector2(0.0, 1.0), Vector2(-16.0, 1.0)]:
			var low := Vector2(edge.x - 0.13, t + 0.37); var high := Vector2(edge.x + 0.13, t + 0.37)
			var region_row := StrataRegions.region_at(spec, Vector2(edge.x, t + 0.37)).y
			if pixel_of(low) == pixel_of(high) or is_hole_pixel(low) or is_hole_pixel(high) or region_row < 0 or region_row > 3: continue
			var a := image.get_pixelv(pixel_of(low)); var b := image.get_pixelv(pixel_of(high))
			var plow := world_of(pixel_of(low)); var phigh := world_of(pixel_of(high))
			worst_step = maxf(worst_step, absf((b.g - a.g) * 16.0 - (surface_height(phigh) - surface_height(plow))))
			worst_mesh = maxf(worst_mesh, absf((b.r - a.r) * 16.0 - (surface_height(phigh) - surface_height(plow))))
			pairs += 1
	print("RESIDENCY_RENDER_SEAMS pairs=", pairs, " fragment_step_error=", worst_step, " vertex_step_error=", worst_mesh)
	check(pairs > 20, "The seam probe covers many pixel pairs")
	check(worst_step < 0.03, "The fragment surface steps across tier boundaries as modelled (worst %f)" % worst_step)
	check(worst_mesh < 0.05, "The rasterized vertex heights step across tier boundaries as modelled, no crack (worst %f)" % worst_mesh)
	# Side view: no background leaks along the boundaries.
	view.position = Vector3(0, 120, 120); view.look_at(Vector3(0, 3, 0), Vector3.UP)
	override_shader(TAIL_VALUES)
	var oblique: Image = await render()
	var leaks := 0; var probes := 0
	for edge_x in [0.0, -16.0, 16.0]:
		for z in range(-27, 28, 1):
			var position := Vector2(edge_x + 0.05, float(z) + 0.5)
			var screen := Vector2i(view.unproject_position(Vector3(position.x, surface_height(position), position.y)).round())
			if is_hole_pixel(position): continue
			probes += 1
			if color_distance(oblique.get_pixelv(screen), BACKGROUND.srgb_to_linear()) < 0.05: leaks += 1
	check(probes > 100 and leaks == 0, "No background shows along tier boundaries in an oblique view (%d leaks in %d probes)" % [leaks, probes])
	top_view()

func test_window_and_stats() -> void:
	var description: Dictionary = spec.maps.material_ids
	var size := StrataRegions.map_size(CELLS, description, 0)
	var patch := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	patch.fill(Color8(9, 0, 0, 0))
	check(not renderer.update_region_window(Vector2i(3, 1), "material_ids", patch, Vector2i.ZERO), "update_region_window refuses a far region")
	check(not renderer.update_region_window(Vector2i(3, 3), "material_ids", patch, Vector2i.ZERO), "update_region_window refuses a coarse-only region")
	var far_copy := (renderer.get_region(Vector2i(3, 1)) as StrataRegionData).get_image("material_ids", 0).get_pixel(5, 5)
	check(renderer.update_region_window(Vector2i(1, 1), "material_ids", patch, Vector2i.ZERO), "update_region_window patches a near region")
	check(renderer.get_region(Vector2i(1, 1)).get_image("material_ids", 0).get_pixel(3, 3).r8 == 9 and far_copy.r8 != 9, "Only the near region's CPU data carries the patch")
	check(renderer.get_region(Vector2i(3, 1)) == regions[Vector2i(3, 1)] and renderer.get_region(Vector2i(3, 3)) == null, "get_region returns far data and null for coarse-only regions")
	var stats := renderer.get_stats()
	var per_near := 0; var per_far := 0
	for name in spec.maps:
		per_near += StrataRegions.map_bytes(CELLS, spec.maps[name], 0)
		per_far += StrataRegions.map_bytes(CELLS, spec.maps[name], FAR_LEVEL)
	var coarse_bytes := 0
	for image: Image in coarse.values(): coarse_bytes += image.get_data_size()
	check(stats.near_resident == 4 and stats.far_resident == 6 and stats.regions == 10, "Stats count resident regions per tier (%d/%d)" % [stats.near_resident, stats.far_resident])
	check(stats.near_slots == 4 and stats.far_slots == 6, "Stats report the slots")
	check(stats.gpu_bytes_near == 4 * per_near and stats.gpu_bytes_far == 6 * per_far and stats.gpu_bytes_coarse == coarse_bytes, "Stats report GPU bytes per tier (%d %d %d)" % [stats.gpu_bytes_near, stats.gpu_bytes_far, stats.gpu_bytes_coarse])
	print("RESIDENCY_RENDER_MEMORY near=", stats.gpu_bytes_near, " far=", stats.gpu_bytes_far, " coarse=", stats.gpu_bytes_coarse, " phase_a_equivalent=", 16 * per_near)

func test_release_to_coarse() -> void:
	override_shader(TAIL_VALUES)
	var before: Image = await render()
	var xy := Vector2i(1, 1)
	var centre := centre_of(xy)
	var near_id := before.get_pixelv(pixel_of(centre)).r * 31.0
	check(renderer.release_region(xy), "A near region releases")
	var after: Image = await render()
	var color := after.get_pixelv(pixel_of(centre))
	var texel := Vector2i((centre - BOUNDS.position) / float(1 << COARSE_LEVEL))
	var expected_id := (coarse.material_ids as Image).get_pixelv(texel).r8
	check(absf(color.r * 31.0 - float(expected_id)) < 0.1, "A released region draws its coarse material (%f -> %f, coarse %d)" % [near_id, color.r * 31.0, expected_id])
	var probed := world_of(pixel_of(centre))
	check(absf(color.g * 16.0 - surface_height(probed)) < 0.03, "A released region draws the coarse height (got %f, expected %f)" % [color.g * 16.0, surface_height(probed)])
	# A released region's patch bounds fall back to the coarse extrema.
	for patch: MeshInstance3D in renderer._patches.values():
		var bounds: Rect2 = patch.get_meta("terrain_patch_bounds")
		if StrataRegions.region_bounds(spec, xy).encloses(bounds):
			check(patch.custom_aabb.end.y >= (renderer._coarse_extrema[xy] as Vector2).y - 0.001, "A released region's patch bounds cover the coarse heights")
	# set_coarse_maps with the same images keeps everything drawable; an empty set removes the tier.
	check(renderer.set_coarse_maps(COARSE_LEVEL, coarse), "set_coarse_maps accepts the images again")
	check(renderer.set_coarse_maps(COARSE_LEVEL, {}) and renderer.get_stats().gpu_bytes_coarse == 0, "An empty coarse set removes the tier")
