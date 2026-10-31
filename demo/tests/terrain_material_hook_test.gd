extends SceneTree
## StrataMaterial.custom_fragment_code in the real Forward+ terrain shader: a
## fresnel rim on one of two materials changes only the pixels that material
## covers, parameter edits need no recompile, broken code falls back per
## material, and removing the code restores the plain shader file exactly.
const FRESNEL := "float facing = clamp(dot(s.normal, c.view), 0.0, 1.0);\ns.emission += rim_color.rgb * pow(1.0 - facing, rim_power);"
var failures := 0
var viewport: SubViewport
var renderer: StrataRenderer
var terrain: StrataTerrain3D
var camera: Camera3D
var regions := {}  # "sand"/"grass" -> Array[Vector2i] of pixels where that material has full weight

func _initialize() -> void: run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAF); image.fill(color)
	return ImageTexture.create_from_image(image)

func material(color: Color, normal: Color) -> StrataMaterial:
	var result := StrataMaterial.new()
	result.color_texture = texture(color); result.normal_texture = texture(normal)
	result.ormh_texture = texture(Color(1.0, 0.8, 0.0, 0.5)); result.uv_scale = 0.25
	return result

func draw(frames: int = 8) -> Image:
	for index in range(frames): await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

## Largest 8-bit channel difference over a region.
func max_difference(a: Image, b: Image, pixels: Array) -> int:
	var largest := 0
	for pixel: Vector2i in pixels:
		var x := a.get_pixelv(pixel); var y := b.get_pixelv(pixel)
		largest = maxi(largest, roundi(maxf(maxf(absf(x.r - y.r), absf(x.g - y.g)), absf(x.b - y.b)) * 255.0))
	return largest

## Share of a region whose blue channel rose by more than 8/255.
func brightened_share(after: Image, before: Image, pixels: Array) -> float:
	var count := 0
	for pixel: Vector2i in pixels:
		if after.get_pixelv(pixel).b - before.get_pixelv(pixel).b > 8.0 / 255.0: count += 1
	return float(count) / maxf(1.0, pixels.size())

func plane_point(pixel: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	return terrain.to_local(origin + direction * (-origin.y / direction.y))

func classify() -> void:
	regions = {"sand": [], "grass": []}
	for y in range(viewport.size.y):
		for x in range(viewport.size.x):
			var point := plane_point(Vector2(x + 0.5, y + 0.5))
			if absf(point.x) > 15.0 or absf(point.z) > 15.0: continue
			# Control texels are 4 m apart: columns 0-3 are sand, 4-8 grass, so
			# x < -4 is pure sand and x > 0 pure grass. Keep a margin.
			if point.x < -5.0: regions.sand.append(Vector2i(x, y))
			elif point.x > 1.0: regions.grass.append(Vector2i(x, y))

func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void: push_error("Material hook test watchdog"); quit(1))
	if RenderingServer.get_rendering_device() == null or DisplayServer.get_name() == "headless":
		push_error("Use a graphical Forward+ run"); quit(2); return
	viewport = SubViewport.new(); viewport.size = Vector2i(160, 120); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := Node3D.new(); viewport.add_child(world)
	terrain = StrataTerrain3D.new(); terrain.base_bounds = Rect2(-16, -16, 32, 32); world.add_child(terrain)
	renderer = StrataRenderer.new(); terrain.add_child(renderer); renderer.displacement_enabled = false
	var sand := material(Color(0.8, 0.7, 0.5), Color(0.5, 0.5, 1.0))
	# A tilted normal map, so the identity check covers the per-material normal path.
	var grass := material(Color(0.2, 0.5, 0.15), Color(0.62, 0.45, 0.92))
	var pool: Array[StrataMaterial] = [sand, grass]
	var field := Image.create(33, 33, false, Image.FORMAT_RF)
	check(renderer.configure_compiled_field(terrain, pool, {"ok": true, "image": field, "bounds": terrain.base_bounds, "resolution": field.get_size(), "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK, "min": 0.0, "max": 0.0}), "Configure the terrain with two materials")
	var ids := Image.create(9, 9, false, Image.FORMAT_RGBA8); var weights := Image.create(9, 9, false, Image.FORMAT_RGBAF)
	for z in range(9):
		for x in range(9):
			ids.set_pixel(x, z, Color(0.0 if x < 4 else 1.0 / 255.0, 0.0, 0.0, 0.0)); weights.set_pixel(x, z, Color(1.0, 0.0, 0.0, 0.0))
	check(renderer.set_control_maps(ids, weights), "Sand on the left, grass on the right")
	camera = Camera3D.new(); camera.fov = 60.0; camera.position = Vector3(0.0, 14.0, 26.0)
	world.add_child(camera); camera.look_at(Vector3.ZERO); camera.current = true; renderer.set_camera(camera)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; environment.environment.ambient_light_color = Color.WHITE; environment.environment.ambient_light_energy = 0.3
	world.add_child(environment)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0); sun.shadow_enabled = false; world.add_child(sun)
	classify()
	check(regions.sand.size() > 500 and regions.grass.size() > 500, "Both materials cover a useful share of the view")
	var plain: Shader = load(StrataRenderer.SURFACE_SHADER_PATH)
	for uniform in plain.get_shader_uniform_list():
		check(not String(uniform.name).begins_with("strata_material_"), "Plain shader uniforms cannot collide with generated parameter names")

	check(renderer._shader_material.shader == plain, "Without custom code the renderer uses the plain shader file")
	var base := await draw()

	# Unchanged surface: the per-material path reproduces the blended result.
	grass.custom_fragment_code = "s.albedo = s.albedo;"
	var identity := await draw()
	var generated := renderer._shader_material.shader
	check(generated != plain and generated.code.begins_with("#define STRATA_MATERIAL_HOOKS\n"), "Custom code generates a hook shader")
	check(renderer.get_stats().custom_shader_material_ids == PackedInt32Array([1]), "Only material 1 is hooked")
	var identity_sand := max_difference(identity, base, regions.sand); var identity_grass := max_difference(identity, base, regions.grass)
	print("HOOK identity max difference sand=%d grass=%d" % [identity_sand, identity_grass])
	check(identity_sand <= 1 and identity_grass <= 1, "A hook that changes nothing renders like the plain shader")

	# Fresnel rim on grass only, with its colour and power as parameters.
	grass.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 2.0}
	grass.custom_fragment_code = FRESNEL
	var rim := await draw()
	var rim_shader := renderer._shader_material.shader
	check(rim_shader.code.contains("uniform vec4 strata_material_1_rim_color : source_color;") and rim_shader.code.contains("uniform float strata_material_1_rim_power;"), "Parameters become per-material uniforms")
	var rim_sand := max_difference(rim, base, regions.sand); var rim_grass := brightened_share(rim, base, regions.grass)
	print("HOOK fresnel sand max difference=%d grass brightened share=%.3f" % [rim_sand, rim_grass])
	check(rim_sand <= 1, "The rim leaves pixels where the other material dominates unchanged")
	check(rim_grass > 0.98, "The rim brightens the pixels where its material dominates")
	# The added emission matches rim * (1 - n.v)^2 with the view vector of that pixel.
	var probe: Vector2i = regions.grass[regions.grass.size() / 2]
	var point := plane_point(Vector2(probe) + Vector2(0.5, 0.5))
	var view := (camera.global_position - terrain.to_global(point)).normalized()
	# Flat ground uses only the top projection: the grass normal map's detail
	# (0.24, -0.1) reoriented onto +Y gives this terrain-local normal.
	var detail := Vector2(0.62 * 2.0 - 1.0, 0.45 * 2.0 - 1.0)
	var normal := Vector3(detail.x, sqrt(1.0 - detail.length_squared()), -detail.y).normalized()
	var facing := clampf(normal.dot(view), 0.0, 1.0)
	var expected := Color(0.2, 0.6, 1.0).srgb_to_linear().b * pow(1.0 - facing, 2.0)
	var added := rim.get_pixelv(probe).srgb_to_linear().b - base.get_pixelv(probe).srgb_to_linear().b
	print("HOOK fresnel probe pixel=%s added_blue=%.4f expected=%.4f" % [probe, added, expected])
	check(absf(added - expected) < 0.03, "Rim strength follows the material normal and view vector")

	# A parameter edit uploads a uniform; the shader is not regenerated.
	grass.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 1.0}
	var softer := await draw()
	check(renderer._shader_material.shader == rim_shader, "Parameter values do not recompile the shader")
	check(brightened_share(softer, rim, regions.grass) > 0.98 and max_difference(softer, base, regions.sand) <= 1, "A lower power widens the rim on grass only")

	# Crease variant carries the hooks too; returning reuses the cached shader.
	renderer.crease_angle_degrees = 60.0
	var creased := await draw()
	var crease_code := renderer._shader_material.shader.code
	check(crease_code.contains("#define HEGO_TERRAIN_CREASES") and crease_code.contains("#define STRATA_MATERIAL_HOOKS"), "The crease variant is generated with the hooks")
	check(brightened_share(creased, base, regions.grass) > 0.98 and max_difference(creased, softer, regions.sand) <= 1, "Hooks render in the crease variant")
	renderer.crease_angle_degrees = 180.0
	await draw(2)
	check(renderer._shader_material.shader == rim_shader, "The smooth hook shader is cached")

	# Broken code on sand is reported and left out; grass keeps its rim.
	sand.custom_fragment_code = "s.albedo = undefined_value;"
	var broken := await draw()
	var stats := renderer.get_stats()
	check(stats.custom_shader_failed_ids == PackedInt32Array([0]) and stats.custom_shader_material_ids == PackedInt32Array([1]), "The failing material is identified")
	check(max_difference(broken, base, regions.sand) <= 1 and max_difference(broken, softer, regions.grass) <= 1, "Sand renders plain, grass keeps its rim")

	# Invalid parameter names are ignored with a warning, never declared.
	grass.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 1.0, "s": 1.0, "Bad Name": 2.0, "strata_x": 3.0, "blob": PackedByteArray()}
	var spec := renderer._material_hook_spec()
	check(spec.size() == 2 and spec[1].parameters.map(func(parameter: Dictionary) -> String: return parameter.uniform) == ["strata_material_1_rim_color", "strata_material_1_rim_power"], "Only valid parameters become uniforms")

	# Removing every snippet restores the plain shader file byte for byte.
	sand.custom_fragment_code = ""; grass.custom_fragment_code = ""
	var restored := await draw()
	check(renderer._shader_material.shader == plain, "Without custom code the plain shader file returns")
	check(restored.get_data() == base.get_data(), "The plain path renders byte-identically")

	# The code and its parameters are saved with the material and follow variants.
	grass.custom_fragment_code = FRESNEL
	grass.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 2.0}
	var variant := grass.make_variant(2.0)
	check(variant.custom_fragment_code == FRESNEL and variant.custom_fragment_parameters.rim_power == 2.0, "UV variants share the custom code")
	grass.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 3.0}
	check(variant.custom_fragment_parameters.rim_power == 3.0, "Variants follow source edits of the parameters")
	var path := "user://strata_material_hook_test.tres"
	var saved := StrataMaterial.new(); saved.custom_fragment_code = FRESNEL; saved.custom_fragment_parameters = {"rim_color": Color(0.2, 0.6, 1.0), "rim_power": 2.0}
	check(ResourceSaver.save(saved, path) == OK, "Save a material with custom code outside the project")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataMaterial
	check(loaded != null and loaded.custom_fragment_code == FRESNEL and loaded.custom_fragment_parameters == saved.custom_fragment_parameters, "Custom code and parameters round-trip through .tres")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("TERRAIN_MATERIAL_HOOK_TEST failures=", failures)
	viewport.free()
	quit(0 if failures == 0 else 1)
