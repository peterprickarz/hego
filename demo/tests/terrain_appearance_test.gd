extends SceneTree
## Actual production material shader: dry surfaces, predictable UVs, macro fields.
var failures := 0
var checks := 0
var viewport: SubViewport
var renderer: StrataRenderer
var terrain: StrataTerrain3D
var camera: Camera3D
var world: Node3D
func _initialize() -> void: run.call_deferred()
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures += 1; push_error(message)
func texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAF); image.fill(color)
	return ImageTexture.create_from_image(image)
func shader_override(tail: String) -> Shader:
	var code := (load("res://addons/strata/shaders/terrain_surface.gdshader") as Shader).code
	code = code.replace('#include "', '#include "res://addons/strata/shaders/')
	var end := code.rfind("}")
	var shader := Shader.new(); shader.code = code.substr(0, end) + tail + code.substr(end)
	return shader
func draw(frames: int = 6) -> Image:
	for index in range(frames): await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
func linear_pixel(image: Image) -> Color:
	return image.get_pixelv(viewport.size / 2).srgb_to_linear()
func controls(id: int) -> bool:
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8); ids.fill(Color(float(id) / 255.0, 0.0, 0.0, 0.0))
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF); weights.fill(Color(1.0, 0.0, 0.0, 0.0))
	return renderer.set_control_maps(ids, weights)
func configure(pool: Array[StrataMaterial]) -> bool:
	var image := Image.create(17, 17, false, Image.FORMAT_RF); image.fill(Color(0.0, 0.0, 0.0, 1.0))
	return renderer.configure_compiled_field(terrain, pool, {"ok": true, "image": image, "bounds": terrain.base_bounds, "resolution": image.get_size(), "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK, "min": 0.0, "max": 0.0})
func field(color: Color) -> Image:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAH); image.fill(color); return image
func plane_point(pixel: Vector2) -> Vector2:
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	var hit := terrain.to_local(origin + direction * (-origin.y / direction.y))
	return Vector2(hit.x, hit.z)
func close_rgb(a: Color, b: Color, tolerance: float = 0.018) -> bool:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() < tolerance
func test_macro(material: StrataMaterial, pool: Array[StrataMaterial]) -> void:
	material.color_texture = texture(Color.WHITE); material.uv_scale = 0.25
	check(configure(pool) and controls(0), "Configure macro appearance fixture")
	renderer.distance_uv_enabled = false
	if renderer.render_settings == null: renderer.render_settings = StrataRenderSettings.new()
	renderer.render_settings.terrain_tint_strength = 1.0; renderer.render_settings.terrain_ao_strength = 1.0
	renderer._shader_material.shader = shader_override("EMISSION=ALBEDO; ALBEDO=vec3(0.0);")
	check(renderer.set_macro_map(null, Rect2()), "Missing macro map clears to neutral")
	var no_map: Image = await draw()
	var base := linear_pixel(no_map)
	check(close_rgb(base, Color.WHITE), "Without macro data the shader retains material color, with no hidden procedural tint")
	check(renderer.set_macro_map(field(Color.WHITE), terrain.base_bounds), "Bind neutral linear RGBAH field")
	var neutral: Image = await draw()
	check(no_map.get_data() == neutral.get_data(), "White macro map is byte-exact no-map identity")
	check(renderer.set_macro_map(field(Color(0.5, 0.75, 0.9, 1.0)), terrain.base_bounds), "Bind constant terrain tint")
	var tinted: Image = await draw()
	check(close_rgb(linear_pixel(tinted), Color(base.r * 0.5, base.g * 0.75, base.b * 0.9)), "Macro RGB multiplies albedo in linear space once")
	renderer.render_settings.terrain_tint_strength = 0.5
	tinted = await draw()
	check(close_rgb(linear_pixel(tinted), Color(base.r * 0.75, base.g * 0.875, base.b * 0.95)), "Tint strength blends from neutral multiplicatively")
	renderer.render_settings.terrain_tint_strength = 1.0
	check(renderer.set_macro_map(field(Color(1.0, 1.0, 1.0, 0.4)), terrain.base_bounds), "Bind AO without tint")
	tinted = await draw()
	check(no_map.get_data() == tinted.get_data(), "Macro AO does not darken albedo a second time")
	renderer._shader_material.shader = shader_override("EMISSION=vec3(AO); ALBEDO=vec3(0.0);")
	var ao: Image = await draw()
	check(absf(linear_pixel(ao).r - 0.32) < 0.015, "AO multiplies packed material AO exactly once")
	renderer.render_settings.terrain_ao_strength = 0.5
	ao = await draw()
	check(absf(linear_pixel(ao).r - 0.56) < 0.015, "AO strength preserves neutral interpolation")
	renderer.render_settings.terrain_ao_strength = 1.0
	var grid := field(Color.WHITE)
	grid.set_pixel(0, 0, Color(0.25, 0.5, 1.5, 0.8)); grid.set_pixel(1, 0, Color(1.75, 0.5, 0.25, 0.6))
	grid.set_pixel(0, 1, Color(0.25, 1.5, 0.5, 0.4)); grid.set_pixel(1, 1, Color(1.75, 1.5, 1.5, 0.2))
	var first := plane_point(Vector2(32.5, 32.5)); var last := plane_point(Vector2(96.5, 96.5))
	check(renderer.set_macro_map(grid, Rect2(first, last - first)), "Bind asymmetric HDR field with negative local origin")
	renderer._shader_material.shader = shader_override("EMISSION=terrain_macro_sample(terrain_position).rgb*0.25; ALBEDO=vec3(0.0);")
	var mapped: Image = await draw()
	check(close_rgb(mapped.get_pixel(32, 32).srgb_to_linear(), Color(0.0625, 0.125, 0.375)), "First sample center exactly reaches its macro texel")
	check(close_rgb(mapped.get_pixel(96, 96).srgb_to_linear(), Color(0.4375, 0.375, 0.375)), "Last sample center reaches its macro texel without edge half-texel drift")
	check(close_rgb(linear_pixel(mapped), Color(0.25, 0.25, 0.234375)), "Interior macro sampling is bilinear and retains HDR values without sRGB decoding")
	check(close_rgb(mapped.get_pixel(0, 0).srgb_to_linear(), Color(0.0625, 0.125, 0.375)), "Macro field clamps at its declared extent instead of repeating")
	material.uv_scale = 0.75
	var retiled: Image = await draw()
	check(mapped.get_data() == retiled.get_data(), "Terrain macro UVs are independent of source material tiling")
	world.position = Vector3(5.0, 3.0, -7.0); world.rotation.y = 0.45
	var moved: Image = await draw()
	check(close_rgb(linear_pixel(moved), linear_pixel(mapped)), "Translation/yaw keep macro tint attached to terrain-local coordinates")
	world.position = Vector3.ZERO; world.rotation = Vector3.ZERO
	check(renderer.set_macro_map(null, Rect2()), "Clear macro after diagnostics")
	var diagnostic := Image.create(2, 2, false, Image.FORMAT_RF); diagnostic.fill(Color(0.25, 0.0, 0.0, 1.0))
	check(renderer.set_channel_preview(diagnostic, terrain.base_bounds, true), "Bind scalar mask-value diagnostic")
	renderer._shader_material.shader = load("res://addons/strata/shaders/terrain_surface.gdshader")
	var preview: Image = await draw()
	check(close_rgb(linear_pixel(preview), Color(0.25, 0.25, 0.25)), "Scalar diagnostic shows unlit values without changing geometry")
	var owned_layer := StrataLayer.new(); owned_layer.data.sample_spacing = 16.0; owned_layer.data.grid_origin = Vector2(-8.0, -8.0)
	terrain.add_child(owned_layer)
	var zero_values := Image.create(2, 2, false, Image.FORMAT_RF); zero_values.fill(Color(0.0, 0.0, 0.0, 1.0))
	check(owned_layer.data.replace_dense(&"mask", Vector2i.ZERO, zero_values) and renderer.set_ownership_overlay(owned_layer, &"mask"), "Enable owned-zero footprint alongside scalar values")
	var both: Image = await draw()
	check(close_rgb(linear_pixel(both), Color(0.25, 0.25, 0.25).lerp(Color(0.95, 0.24, 0.055), 0.8)), "Mask grayscale and ownership orange coexist without hiding authored zero")
	owned_layer.data.clear_channel(&"mask")
	check(renderer.set_ownership_overlay(owned_layer, &"mask"), "Refresh ownership after erase")
	var erased: Image = await draw()
	check(close_rgb(linear_pixel(erased), Color(0.25, 0.25, 0.25)), "Erase removes the footprint while scalar preview remains visible")
func run() -> void:
	create_timer(90.0).timeout.connect(func(): push_error("Appearance test watchdog"); quit(1))
	if RenderingServer.get_rendering_device() == null: push_error("Appearance test requires graphical Forward+"); quit(2); return
	viewport = SubViewport.new(); viewport.size = Vector2i(128, 128); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	world = Node3D.new(); viewport.add_child(world)
	terrain = StrataTerrain3D.new(); terrain._preview_enabled = false; terrain.base_bounds = Rect2(-8, -8, 16, 16); world.add_child(terrain)
	renderer = StrataRenderer.new(); terrain.add_child(renderer); renderer.displacement_enabled = false
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 12; camera.position = Vector3(0, 20, 0)
	world.add_child(camera); camera.look_at(Vector3.ZERO, Vector3.FORWARD); camera.current = true; renderer.set_camera(camera)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color.BLACK
	world.add_child(environment)
	var material := StrataMaterial.new(); material.color_texture = texture(Color.WHITE)
	material.normal_texture = texture(Color(0.5, 0.5, 1.0)); material.ormh_texture = texture(Color(0.8, 0.25, 0.0, 0.5))
	var pool: Array[StrataMaterial] = [material]
	check(configure(pool) and controls(0), "Configure actual production appearance shader")
	renderer._shader_material.shader = shader_override("ALBEDO=vec3(0.0); EMISSION=vec3(ROUGHNESS);")
	var image: Image = await draw()
	check(absf(linear_pixel(image).r - 0.25) < 0.015, "Identity roughness remap retains packed green")
	material.roughness_scale = 0.5; material.roughness_bias = 0.3
	image = await draw()
	check(absf(linear_pixel(image).r - 0.425) < 0.015, "Material changes remap roughness before blending")
	material.roughness_scale = 2.0; material.roughness_bias = 1.0
	image = await draw()
	check(absf(linear_pixel(image).r - 1.0) < 0.015, "Roughness remap clamps to dry upper bound")
	material.roughness_bias = -1.0
	image = await draw()
	check(absf(linear_pixel(image).r - 0.04) < 0.015, "Existing final minimum roughness remains")
	var count := HEGoIslandMaterialRegistry.count()
	var actual_pool := HEGoIslandMaterials.pool()
	check(count == 4 and actual_pool.size() == count, "Load the four real island material definitions")
	if actual_pool.size() != count or count == 0:
		viewport.free(); quit(1); return
	var registry: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://island/materials/material_registry.json"))
	check(registry is Array and registry.size() == count, "Actual showcase registry declares every stable material ID")
	if not registry is Array or registry.size() != count:
		viewport.free(); quit(1); return
	var source_ids := {}; var resource_paths := {}; var texture_paths := {}
	for index in range(count):
		var entry: Dictionary = registry[index]
		check(entry.id == index and entry.channel == "material_" + entry.name, "Real registry material ID and channel agree")
		check(not source_ids.has(entry.ambientcg_id) and not resource_paths.has(entry.resource), "Each actual slot has a distinct source and resource")
		source_ids[entry.ambientcg_id] = true; resource_paths[entry.resource] = true
		check(actual_pool[index].resource_path == entry.resource and is_finite(actual_pool[index].uv_scale) and actual_pool[index].uv_scale > 0.0, "Actual artist material loads its explicit resource with a valid physical scale")
		for pair in [[actual_pool[index].color_texture, "color.jpg"], [actual_pool[index].normal_texture, "normal_gl.jpg"], [actual_pool[index].ormh_texture, "ormh.png"]]:
			var path: String = pair[0].resource_path
			check(path == "res://island/materials/textures/" + entry.name + "_" + pair[1] and not texture_paths.has(path), "Every actual slot binds its own named PBR texture; no alias fallback")
			texture_paths[path] = true
		var color_image := actual_pool[index].color_texture.get_image()
		var normal_image := actual_pool[index].normal_texture.get_image()
		var packed_image := actual_pool[index].ormh_texture.get_image()
		print("APPEARANCE_TEXTURE_FORMAT source=%d color=%d normal=%d ormh=%d mips=%s" % [index, color_image.get_format(), normal_image.get_format(), packed_image.get_format(), color_image.has_mipmaps() and normal_image.has_mipmaps() and packed_image.has_mipmaps()])
		check(color_image.get_format() == Image.FORMAT_BPTC_RGBA and packed_image.get_format() == Image.FORMAT_BPTC_RGBA and normal_image.get_format() == Image.FORMAT_RGTC_RG, "Explicit imports retain BC7 color/ORMH and BC5 normals")
		check(color_image.has_mipmaps() and normal_image.has_mipmaps() and packed_image.has_mipmaps(), "Explicit imports retain all source mipmaps")
	check(source_ids.size() == count and resource_paths.size() == count and texture_paths.size() == 3 * count, "Showcase binds genuine sources and distinct real textures")
	check(configure(actual_pool), "Bind real island materials")
	renderer._shader_material.shader = shader_override("ALBEDO=vec3(0.0); EMISSION=color;")
	check(controls(1), "Paint actual grass ID1")
	var grass_a: Image = await draw(10)
	check(controls(2), "Paint actual gravel ID2")
	var gravel: Image = await draw(10)
	check(grass_a.get_data() != gravel.get_data(), "Distinct grass and gravel source IDs render distinct actual material appearance")
	check(controls(1), "Return to actual grass ID1")
	var grass_again: Image = await draw(10)
	check(grass_a.get_data() == grass_again.get_data(), "Selecting another real source does not alter the artist's grass scale or texture")
	# Pattern makes the explicit distance path observable independently of the
	# real source photograph or changed viewpoint/lighting.
	var pattern := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for y in range(8):
		for x in range(8): pattern.set_pixel(x, y, Color(float(x % 2), float(y % 2), 0.2, 1.0))
	material.color_texture = ImageTexture.create_from_image(pattern)
	material.roughness_scale = 1.0; material.roughness_bias = 0.0
	check(controls(0), "Reset selected real ID before reducing to the synthetic UV fixture")
	check(configure(pool) and controls(0), "Configure UV pattern fixture")
	renderer._shader_material.shader = shader_override("ALBEDO=vec3(0.0); EMISSION=color;")
	renderer.distance_uv_enabled = false
	renderer.uv_near_distance = 0.0; renderer.uv_far_distance = 1.0
	var physical_a: Image = await draw()
	renderer.uv_near_distance = 16.0; renderer.uv_far_distance = 128.0
	var physical_b: Image = await draw()
	check(physical_a.get_data() == physical_b.get_data(), "Disabled distance tiling ignores crossfade distances exactly")
	renderer.uv_near_distance = 0.0; renderer.uv_far_distance = 1.0; renderer.distance_uv_enabled = true
	var distance_scaled: Image = await draw()
	check(distance_scaled.get_data() != physical_b.get_data(), "Distance scaling remains an explicit observable opt-in")
	await test_macro(material, pool)
	viewport.free()
	print("TERRAIN_APPEARANCE_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
