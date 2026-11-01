extends SceneTree
## Forward+ regression for the region-based terrain renderer (Phase A, every region resident
## at level 0): synthetic StrataRegionData for a 64 m terrain of 4 x 4 regions of 16 cells,
## bound with set_regions(). The production vertex() and fragment() run unchanged except that
## the final colour encodes (material id, height, macro tint) so pixels can be compared with the
## analytic fixtures. Every field here is an in-memory fixture; no asset is read or written.

const BOUNDS := Rect2(-32, -32, 64, 64)
const CELLS := 16
const BACKGROUND := Color(0.9, 0.2, 0.9)
const TAIL := "ALBEDO = vec3(float(ids[0]) / 31.0, base_height(terrain_position) / 16.0, terrain_macro.r);"
var failures := 0
var viewport: SubViewport
var view: Camera3D
var source: StrataTerrain3D
var renderer: StrataRenderer
var spec: Dictionary
var regions: Dictionary = {}
var overrides := {"holes": [Vector2i(30, 30), Vector2i(15, 15), Vector2i(16, 16)], "peak": 40.0}

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	create_timer(240.0).timeout.connect(func(): push_error("Region renderer test watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null:
		push_error("Region renderer tests require graphical Forward+.")
		quit(2)
		return
	print("REGION_RENDERER_GPU ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_video_adapter_api_version())
	setup_scene()
	await test_binding()
	test_cpu_sampling()
	await test_rendering()
	await test_normals()
	await test_window_update()
	test_hole_raycast()
	test_extrema_bounds()
	test_transactional_rejection()
	test_adapters()
	await test_configure_regions()
	print("REGION_RENDERER_TEST failures=", failures)
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
	view.position = Vector3(0, 400, 0); view.look_at(Vector3(0, 0, 0), Vector3.FORWARD)
	source = StrataTerrain3D.new(); source.base_bounds = BOUNDS; world.add_child(source)
	renderer = StrataRenderer.new(); source.add_child(renderer)

# ---- fixtures ----

static func height_at(position: Vector2) -> float:
	return 3.0 + 0.1 * position.x + 0.05 * position.y + 0.3 * sin(0.5 * position.x) * cos(0.4 * position.y)

func clamped_position(index: Vector2i, step: float, lattice_max: Vector2i) -> Vector2:
	return BOUNDS.position + Vector2(index.clamp(Vector2i.ZERO, lattice_max)) * step

func material_id_at(index: Vector2i) -> int:
	return 1 + (index.x / 8 + (index.y / 8) * 3) % 8

func macro_at(position: Vector2) -> float:
	return 0.3 + 0.005 * (position.x - BOUNDS.position.x)

func map_value(name: String, index: Vector2i, description: Dictionary) -> Color:
	var scale := int(description.scale)
	var cells_axis := 64 / scale
	var is_cell := String(description.kind) == StrataRegions.KIND_CELL
	var lattice_max := Vector2i.ONE * (cells_axis - (1 if is_cell else 0))
	var clamped := index.clamp(Vector2i.ZERO, lattice_max)
	match name:
		"height": return Color(height_at(clamped_position(index, 1.0, Vector2i.ONE * 64)), 0, 0, 1)
		"material_ids": return Color8(material_id_at(clamped), 0, 0, 0)
		"material_weights": return Color(1, 0, 0, 0)
		"holes": return Color(1, 0, 0, 1) if clamped in overrides.holes else Color(0, 0, 0, 1)
		"macro": return Color(macro_at(clamped_position(index, 4.0, lattice_max)), 0.5, 0.25, 1.0)
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
	var side := int(spec.cells) + 1
	for v in range(side):
		for u in range(side):
			var h := map_value("height", window_first(xy) + Vector2i(u, v), spec.maps.height).r
			low = minf(low, h); high = maxf(high, h)
	if xy == Vector2i.ZERO: high = overrides.peak
	data.height_min = low; data.height_max = high
	return data

func window_first(xy: Vector2i) -> Vector2i:
	return xy * int(spec.cells)

func build_regions() -> void:
	spec = StrataRegions.standard_spec(BOUNDS, 1.0, CELLS, 2)
	regions.clear()
	for y in range(4):
		for x in range(4): regions[Vector2i(x, y)] = make_region(Vector2i(x, y))

func override_shader(tail := TAIL, creases := false) -> void:
	var code := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	for name in ["terrain_regions.gdshaderinc", "terrain_controls.gdshaderinc", "terrain_texture_dispatch.gdshaderinc", "terrain_normals.gdshaderinc", "terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:
		code = code.replace('#include "' + name + '"', FileAccess.get_file_as_string("res://addons/strata/shaders/" + name))
	code = code.replace("render_mode cull_back,", "render_mode unshaded, cull_back,")
	var end := code.rfind("}")
	var shader := Shader.new(); shader.code = ("#define HEGO_TERRAIN_CREASES\n" if creases else "") + code.substr(0, end) + tail + code.substr(end)
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

## Hardware bilinear of the analytic height lattice (what the height layers hold).
func expected_height(position: Vector2) -> float:
	var grid := (position - BOUNDS.position).clamp(Vector2.ZERO, Vector2(64, 64))
	var base := Vector2i(floor(grid.x), floor(grid.y)).min(Vector2i(63, 63))
	var f := grid - Vector2(base)
	var a := height_at(BOUNDS.position + Vector2(base)); var b := height_at(BOUNDS.position + Vector2(base + Vector2i(1, 0)))
	var c := height_at(BOUNDS.position + Vector2(base + Vector2i(0, 1))); var d := height_at(BOUNDS.position + Vector2(base + Vector2i.ONE))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

# ---- tests ----

func test_binding() -> void:
	var pool: Array[StrataMaterial] = []
	for index in range(10):
		var material := StrataMaterial.new(); pool.append(material)
	check(renderer.configure(source, pool), "Renderer configures on a 64 m terrain")
	renderer.set_camera(view); renderer.displacement_enabled = false
	build_regions()
	check(StrataRegions.grid_size(spec) == Vector2i(4, 4), "Fixture spec is a 4 x 4 grid")
	check(renderer.set_regions(spec, regions), "set_regions accepts a complete synthetic region set")
	var stats := renderer.get_stats()
	check(stats.regions == 16 and stats.region_cells == CELLS, "Stats report the resident regions and region size")
	check(stats.height_resolution == Vector2i(65, 65) and stats.control_resolution == Vector2i(65, 65), "Stats report the lattice the regions imply")
	check(renderer.region_spec().cells == CELLS and renderer.region_spec().maps.has("macro"), "region_spec returns the spec in effect")
	check(renderer.get_region(Vector2i(3, 3)) == regions[Vector2i(3, 3)] and renderer.get_region(Vector2i(4, 0)) == null, "get_region returns the CPU region or null")
	var table: Image = renderer._region_table_image
	var layers := {}
	var all_resident := table.get_size() == Vector2i(4, 4)
	for y in range(4):
		for x in range(4):
			var texel := table.get_pixel(x, y)
			var entry := Color8(0, 0, 0, 0)
			all_resident = all_resident and texel.a8 == 255 and texel.b8 == 0
			layers[texel.r8 + texel.g8 * 256] = true
	check(all_resident and layers.size() == 16, "The region table marks all 16 regions resident at level 0 with distinct layers")
	for name in ["height", "material_ids", "material_weights", "holes", "macro"]:
		var array: Texture2DArray = renderer._region_arrays[name]
		check(array != null and array.get_layers() == 16, "%s array holds one layer per region" % name)
	var size: Vector2i = Vector2i(renderer._region_arrays.height.get_width(), renderer._region_arrays.height.get_height())
	check(size == Vector2i(21, 21), "Height layers are cells + 1 + 2 apron texels square")
	print("REGION_RENDERER_MEMORY per_region_bytes=", stats.region_bytes, " total_bytes=", stats.region_bytes * 16)
	override_shader()

func test_cpu_sampling() -> void:
	var worst := 0.0
	for z in range(0, 65, 1):
		for x in range(0, 65, 1):
			var p := BOUNDS.position + Vector2(x, z)
			worst = maxf(worst, absf(renderer.sample_render_height(p) - height_at(p)))
	check(worst < 0.00001, "sample_render_height equals the analytic height at every lattice point, region edges included (worst %f)" % worst)
	worst = 0.0
	for edge in [-16.0, 0.0, 16.0]:
		for t in [-9.5, -0.5, 0.5, 15.5, 20.5]:
			for p in [Vector2(edge + 0.5, t), Vector2(edge - 0.5, t), Vector2(t, edge + 0.5), Vector2(t, edge - 0.5)]:
				worst = maxf(worst, absf(renderer.sample_render_height(p) - expected_height(p)))
	check(worst < 0.00001, "sample_render_height interpolates across region edges like one surface (worst %f)" % worst)
	check(renderer.sample_render_height(BOUNDS.position + Vector2(-1, 0)) == 0.0, "Outside the terrain samples 0")

func test_rendering() -> void:
	var image: Image = await render()
	var worst_height := 0.0; var worst_macro := 0.0; var wrong_ids := 0; var tested := 0
	var seams := 0
	for pixel in grid(5, 8):
		var position := world_of(pixel)
		var color := image.get_pixelv(pixel)
		var lattice := position - BOUNDS.position
		if is_hole_pixel(position):
			continue
		tested += 1
		worst_height = maxf(worst_height, absf(color.g * 16.0 - expected_height(position)))
		worst_macro = maxf(worst_macro, absf(color.b - macro_at(position)))
		if absf(color.r * 31.0 - float(material_id_at(Vector2i(lattice.round())))) > 0.1 and absf(color.r * 31.0 - float(material_id_at(Vector2i(lattice.floor())))) > 0.1: wrong_ids += 1
		if absf(fmod(lattice.x + 64.0, 16.0)) < 0.3 or absf(fmod(lattice.y + 64.0, 16.0)) < 0.3: seams += 1
	print("REGION_RENDERER_RENDER pixels=", tested, " seam_pixels=", seams, " height_error=", worst_height, " macro_error=", worst_macro, " id_mismatches=", wrong_ids)
	check(tested > 500 and seams > 40, "The render probe covers many pixels including region seams")
	check(worst_height < 0.03, "Rendered height matches the analytic function across region edges")
	check(worst_macro < 0.02, "Rendered macro tint follows the macro regions")
	check(wrong_ids == 0, "Rendered material IDs follow the control regions")
	for cell in overrides.holes:
		var center := BOUNDS.position + Vector2(cell) + Vector2(0.5, 0.5)
		var color := image.get_pixelv(pixel_of(center))
		check(color_distance(color, BACKGROUND.srgb_to_linear()) < 0.02, "Hole cell %s discards its fragments" % str(cell))
		var beside := image.get_pixelv(pixel_of(center + Vector2(-2.0, 0.0)))
		check(color_distance(beside, BACKGROUND.srgb_to_linear()) > 0.1, "The cell beside hole %s still draws" % str(cell))

func color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

## Lighting normals (central differences, and the crease variant's corner fetches) read across
## region edges and must show no seam: neighbouring pixels on either side of an edge agree.
func test_normals() -> void:
	for creases in [false, true]:
		renderer.crease_angle_degrees = 30.0 if creases else 180.0
		override_shader("ALBEDO = final_normal * 0.5 + vec3(0.5);", creases)
		var image: Image = await render()
		var worst := 0.0; var pairs := 0
		for edge in [-16.0, 0.0, 16.0]:
			for t in range(-28, 28, 3):
				for axis in range(2):
					var low := Vector2(edge - 0.2, t + 0.3) if axis == 0 else Vector2(t + 0.3, edge - 0.2)
					var high := low + (Vector2(0.4, 0.0) if axis == 0 else Vector2(0.0, 0.4))
					var a := image.get_pixelv(pixel_of(low)); var b := image.get_pixelv(pixel_of(high))
					if pixel_of(low) == pixel_of(high) or is_hole_pixel(low) or is_hole_pixel(high): continue
					worst = maxf(worst, color_distance(a, b)); pairs += 1
		print("REGION_RENDERER_NORMALS creases=", creases, " pairs=", pairs, " worst_difference=", worst)
		check(pairs > 40 and worst < 0.03, "Normals are continuous across region edges (creases %s, worst %f)" % [str(creases), worst])
	renderer.crease_angle_degrees = 180.0
	override_shader()

func is_hole_pixel(position: Vector2) -> bool:
	for cell in overrides.holes:
		if Rect2(BOUNDS.position + Vector2(cell) - Vector2.ONE * 0.5, Vector2.ONE * 2.0).has_point(position): return true
	return false

func grid(step: int, margin: int) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	for y in range(margin, viewport.size.y - margin, step):
		for x in range(margin, viewport.size.x - margin, step): pixels.append(Vector2i(x, y))
	return pixels

func test_window_update() -> void:
	var inside := Vector2(-8.0, -8.0) # region (1, 1)
	var outside := Vector2(8.0, 8.0) # region (2, 2)
	var before: Image = await render()
	var inside_before := before.get_pixelv(pixel_of(inside)); var outside_before := before.get_pixelv(pixel_of(outside))
	var description: Dictionary = spec.maps.material_ids
	var size := StrataRegions.map_size(CELLS, description, 0)
	var patch := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	patch.fill(Color8(9, 0, 0, 0))
	var identity: Texture2DArray = renderer._region_arrays.material_ids
	check(renderer.update_region_window(Vector2i(1, 1), "material_ids", patch, Vector2i.ZERO), "update_region_window patches one region's ids")
	check(renderer._region_arrays.material_ids == identity, "The layer is updated in place, the array keeps its identity")
	var after: Image = await render()
	var inside_after := after.get_pixelv(pixel_of(inside)); var outside_after := after.get_pixelv(pixel_of(outside))
	print("REGION_RENDERER_WINDOW inside ", inside_before.r * 31.0, " -> ", inside_after.r * 31.0, " outside ", outside_before.r * 31.0, " -> ", outside_after.r * 31.0)
	check(absf(inside_after.r * 31.0 - 9.0) < 0.1 and inside_after != inside_before, "The patched region renders its new material")
	check(outside_after == outside_before, "A neighbouring region keeps its pixels")
	check(renderer.get_region(Vector2i(1, 1)).get_image("material_ids", 0).get_pixel(3, 3).r8 == 9, "The CPU region carries the same patch")
	# A window crossing nothing: rejects leave everything alone.
	check(not renderer.update_region_window(Vector2i(1, 1), "material_ids", patch, Vector2i(1, 0)), "A window leaving the map is rejected")
	check(not renderer.update_region_window(Vector2i(1, 1), "nonexistent", patch, Vector2i.ZERO), "An unknown map is rejected")
	check(not renderer.update_region_window(Vector2i(9, 9), "material_ids", patch, Vector2i.ZERO), "An unknown region is rejected")
	var wrong_format := Image.create(2, 2, false, Image.FORMAT_RF)
	check(not renderer.update_region_window(Vector2i(1, 1), "material_ids", wrong_format, Vector2i.ZERO), "A patch of the wrong format is rejected")
	# Heights: a raised window changes the CPU surface and extrema of that region only.
	var raise := Image.create(5, 5, false, Image.FORMAT_RF)
	raise.fill(Color(50.0, 0, 0, 1))
	var neighbor_before := renderer.sample_render_height(Vector2(8, 8))
	check(renderer.update_region_window(Vector2i(1, 1), "height", raise, Vector2i(6, 6)), "update_region_window patches heights")
	check(absf(renderer.sample_render_height(BOUNDS.position + Vector2(16 + 6 - 2 + 1, 16 + 6 - 2 + 1)) - 50.0) < 0.00001, "The raised window shows in CPU sampling")
	check(renderer.sample_render_height(Vector2(8, 8)) == neighbor_before, "Other regions keep their heights")
	check(renderer.get_region(Vector2i(1, 1)).height_max == 50.0, "The region's height extrema follow the patch")
	var nan_patch := Image.create(2, 2, false, Image.FORMAT_RF)
	nan_patch.fill(Color(NAN, 0, 0, 1))
	check(not renderer.update_region_window(Vector2i(1, 1), "height", nan_patch, Vector2i.ZERO), "Non-finite heights are rejected")
	check(renderer.get_region(Vector2i(1, 1)).height_max == 50.0, "A rejected window changes nothing")

func test_hole_raycast() -> void:
	var cell := Vector2i(30, 30)
	var center := BOUNDS.position + Vector2(cell) + Vector2(0.5, 0.5)
	var hit_hole := renderer.raycast_heightfield(Vector3(center.x, 100.0, center.y), Vector3.DOWN)
	check(hit_hole.is_empty(), "A ray through a hole cell passes the terrain")
	var solid := center + Vector2(-5.0, 0.0)
	check(not renderer.raycast_heightfield(Vector3(solid.x, 100.0, solid.y), Vector3.DOWN).is_empty(), "A ray beside the hole hits")

func test_extrema_bounds() -> void:
	# Region (0, 0) peaks at 40 (fixture) and region (1,1) was raised to 50 by the window test.
	var tall := 0; var low := 0
	for patch: MeshInstance3D in renderer._patches.values():
		var top := patch.custom_aabb.end.y
		var bounds: Rect2 = patch.get_meta("terrain_patch_bounds")
		if bounds.end.x > 0.0 and bounds.end.y > 0.0 and bounds.position.x >= 0.0 and bounds.position.y >= 0.0:
			low += 1
			check(top < 20.0, "A patch over low regions keeps a tight bound (%f)" % top)
		if bounds.intersects(StrataRegions.region_bounds(spec, Vector2i.ZERO)) and bounds.size.x <= 16.0: tall += int(top >= 40.0)
	check(low > 0, "Some patch lies wholly over low regions")
	# update_region replaces the data; the bounds must shrink again, not only grow.
	var lowered := make_region(Vector2i.ZERO)
	lowered.height_max = 6.0
	check(renderer.update_region(Vector2i.ZERO, lowered), "update_region replaces a region")
	check(renderer.get_region(Vector2i.ZERO) == lowered, "update_region stores the new CPU region")
	var global_before := renderer._height_max
	check(is_equal_approx(global_before, 50.0), "The global range still holds the other region's peak")
	var raised_back := make_region(Vector2i(1, 1)) # the original (lower) data of the raised region
	check(renderer.update_region(Vector2i(1, 1), raised_back), "update_region restores the original region")
	check(renderer._height_max < 20.0, "Extrema shrink after lower data replaces higher (global max %f)" % renderer._height_max)
	for patch: MeshInstance3D in renderer._patches.values():
		check(patch.custom_aabb.end.y < 20.0, "No patch keeps the old peak (%f)" % patch.custom_aabb.end.y)

func test_transactional_rejection() -> void:
	var arrays: Dictionary = renderer._region_arrays.duplicate()
	var table: ImageTexture = renderer._region_table_texture
	var kept_region: StrataRegionData = renderer.get_region(Vector2i(2, 2))
	var kept_height := renderer.sample_render_height(Vector2(5, 5))
	var bad := spec.duplicate(true)
	bad.cells = 32
	check(not renderer.set_regions(bad, regions), "A spec whose cells differ from the regions is rejected")
	var no_height := spec.duplicate(true)
	no_height.maps.erase("height")
	check(not renderer.set_regions(no_height, regions), "A spec without height is rejected")
	var moved := spec.duplicate(true)
	moved.bounds = Rect2(BOUNDS.position + Vector2.ONE, BOUNDS.size)
	check(not renderer.set_regions(moved, regions), "Bounds that differ from the terrain are rejected")
	var wrong_apron := spec.duplicate(true)
	wrong_apron.maps.height.apron = 1
	check(not renderer.set_regions(wrong_apron, regions), "A map apron that differs from the region maps is rejected")
	var partial := regions.duplicate()
	partial[Vector2i(7, 7)] = regions[Vector2i(0, 0)]
	check(not renderer.set_regions(spec, partial), "A region outside the grid is rejected")
	var broken := make_region(Vector2i(1, 0))
	broken.remove_map("holes")
	var with_broken := regions.duplicate(); with_broken[Vector2i(1, 0)] = broken
	check(not renderer.set_regions(spec, with_broken), "A region lacking a spec map is rejected")
	check(not renderer.update_region(Vector2i(1, 0), broken), "update_region rejects data lacking a spec map")
	check(renderer._region_table_texture == table and renderer._region_arrays.hash() == arrays.hash(), "Rejected calls keep every texture")
	check(renderer.get_region(Vector2i(2, 2)) == kept_region and renderer.sample_render_height(Vector2(5, 5)) == kept_height, "Rejected calls keep the CPU regions")
	# A missing region is allowed: it stays non-resident.
	var sparse := regions.duplicate()
	sparse.erase(Vector2i(3, 3))
	check(renderer.set_regions(spec, sparse), "A set missing a region binds it non-resident")
	check(renderer._region_table_image.get_pixel(3, 3).a8 == 0 and renderer._region_table_image.get_pixel(2, 3).a8 == 255, "Only the missing region is non-resident")
	check(renderer.update_region(Vector2i(3, 3), regions[Vector2i(3, 3)]) and renderer._region_table_image.get_pixel(3, 3).a8 == 255, "update_region makes a missing region resident")

func test_adapters() -> void:
	# The whole-image adapters slice into regions; a plane makes every sample comparable.
	var bounds := BOUNDS
	var image := Image.create(65, 65, false, Image.FORMAT_RF)
	for z in range(65):
		for x in range(65): image.set_pixel(x, z, Color(height_at(bounds.position + Vector2(x, z)), 0, 0, 1))
	var extrema: Dictionary = StrataLayerData.validate_dense(image)
	var pool: Array[StrataMaterial] = []
	for index in range(10): pool.append(StrataMaterial.new())
	var compiled := {"ok": true, "image": image, "bounds": bounds, "resolution": image.get_size(), "sample_step_x": Vector3.RIGHT, "min": extrema.min, "max": extrema.max}
	check(renderer.configure_compiled_field(source, pool, compiled), "configure_compiled_field slices a whole image into regions")
	var stats := renderer.get_stats()
	check(stats.regions == 1 and stats.region_cells == 64 and stats.height_resolution == Vector2i(65, 65), "The adapter picks one 64-cell region for a 64 m terrain (%d regions, %d cells)" % [stats.regions, stats.region_cells])
	var worst := 0.0
	for z in range(0, 65, 3):
		for x in range(0, 65, 3):
			var p := bounds.position + Vector2(x, z)
			worst = maxf(worst, absf(renderer.sample_render_height(p) - height_at(p)))
	check(worst < 0.00001, "Adapter regions reproduce the image (worst %f)" % worst)
	# Control maps on a coarser lattice become a region map of that scale.
	var ids := Image.create(17, 17, false, Image.FORMAT_RGBA8)
	var weights := Image.create(17, 17, false, Image.FORMAT_RGBAF)
	weights.fill(Color(1, 0, 0, 0))
	for z in range(17):
		for x in range(17): ids.set_pixel(x, z, Color8(1 + (x + z) % 5, 0, 0, 0))
	check(renderer.set_control_maps(ids, weights), "set_control_maps slices a 4 m control lattice")
	check(renderer.get_stats().control_resolution == Vector2i(17, 17) and int(renderer.region_spec().maps.material_ids.scale) == 4, "A 4 m lattice over a 1 m terrain becomes scale 4")
	var blend := renderer.sample_control_blend(bounds.position + Vector2(5.9, 9.2))
	var reference := StrataRenderer.blend_control_samples(ids, weights, bounds.position + Vector2(5.9, 9.2), bounds)
	check(blend.ids == reference.ids and blend.weights == reference.weights, "The region blend equals the image blend")
	# A brush patch touches only its regions and the image reference stays consistent.
	var patch_ids := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	patch_ids.fill(Color8(7, 0, 0, 0))
	var patch_weights := Image.create(3, 3, false, Image.FORMAT_RGBAF)
	patch_weights.fill(Color(1, 0, 0, 0))
	check(renderer.update_control_region(patch_ids, patch_weights, Vector2i(7, 7)), "update_control_region patches regions in place")
	check(roundi(renderer.sample_control_blend(bounds.position + Vector2(32.0, 32.0)).ids[0]) == 7, "The patched controls read back from the regions")
	var raised := Image.create(5, 5, false, Image.FORMAT_RF)
	raised.fill(Color(20.0, 0, 0, 1))
	check(renderer.update_compiled_region({"ok": true, "image": raised, "bounds": Rect2(bounds.position + Vector2(10, 10), Vector2(4, 4))}), "update_compiled_region patches the region layers")
	check(absf(renderer.sample_render_height(bounds.position + Vector2(12, 12)) - 20.0) < 0.00001 and absf(renderer._height_image.get_pixel(12, 12).r - 20.0) < 0.00001, "The patch reaches the regions and the CPU image")
	check(renderer._height_max == 20.0, "The global range follows the patch")

func test_configure_regions() -> void:
	build_regions()
	var pool: Array[StrataMaterial] = []
	for index in range(10):
		pool.append(StrataMaterial.new())
	var fresh := StrataRenderer.new(); source.add_child(fresh)
	var moved := spec.duplicate(true)
	moved.bounds = Rect2(BOUNDS.position + Vector2.ONE, BOUNDS.size)
	check(not fresh.configure_regions(source, pool, moved, regions), "configure_regions rejects a spec whose bounds differ from the terrain")
	check(fresh.get_region(Vector2i(0, 0)) == null, "A rejected first configuration binds nothing")
	check(fresh.configure_regions(source, pool, spec, regions), "configure_regions configures straight from regions on a StrataTerrain3D")
	check(not fresh._runtime_mode and fresh._render_bounds == BOUNDS and is_equal_approx(fresh._height_spacing, 1.0), "A terrain source gives runtime_mode false, the spec's bounds and spacing")
	check(fresh.get_stats().regions == 16 and fresh.get_region(Vector2i(3, 3)) == regions[Vector2i(3, 3)] and not source.is_preview_enabled(), "All regions are resident and the legacy preview is off")
	check(fresh.configure_regions(source, pool, spec, {}) and fresh.get_stats().regions == 0, "Reconfiguring with no regions binds none (editor bridge path)")
	check(fresh.set_regions(spec, regions) and fresh.get_stats().regions == 16, "set_regions binds the composed regions afterwards")
	var kept := fresh.get_region(Vector2i(2, 2))
	check(not fresh.configure_regions(source, pool, moved, regions) and fresh.get_region(Vector2i(2, 2)) == kept and fresh.get_stats().regions == 16, "A rejected reconfiguration keeps the previous regions")
	var broken := regions.duplicate()
	broken[Vector2i(1, 0)] = make_region(Vector2i(1, 0))
	broken[Vector2i(1, 0)].remove_map("holes")
	check(not fresh.configure_regions(source, pool, spec, broken) and fresh.get_region(Vector2i(1, 0)) == regions[Vector2i(1, 0)], "A region lacking a spec map is rejected and nothing changes")
	var plain := Node3D.new(); viewport.get_child(0).add_child(plain)
	var runtime := StrataRenderer.new(); plain.add_child(runtime)
	check(runtime.configure_regions(plain, pool, spec, regions) and runtime._runtime_mode and runtime.get_stats().regions == 16, "A non-terrain source configures a runtime renderer")
	await process_frame
	runtime.queue_free(); fresh.queue_free(); plain.queue_free()
