extends SceneTree
## Opt-in pixel sampling: setting contract and compile check of the shader variants.
var failures := 0
var checks := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("PIXEL_SAMPLING: " + message)

func variant(creases: bool, pixel: bool) -> Shader:
	var code := (load("res://addons/strata/shaders/terrain_surface.gdshader") as Shader).code.replace('#include "', '#include "res://addons/strata/shaders/')
	var shader := Shader.new()
	shader.code = StrataRenderer._variant_defines(creases, pixel) + code
	return shader

func run() -> void:
	var settings := StrataRenderSettings.new()
	check(not settings.pixel_sampling, "pixel sampling is off by default")
	var changes := [0]
	settings.changed.connect(func() -> void: changes[0] += 1)
	settings.pixel_sampling = true
	settings.pixel_sampling = true
	check(changes[0] == 1, "setting the same value emits no change")
	check(StrataRenderer._variant_defines(false, false) == "", "default build has no defines")
	check(StrataRenderer._variant_defines(true, true) == "#define STRATA_PIXEL_SAMPLING\n#define HEGO_TERRAIN_CREASES\n", "defines combine")
	var reference := variant(false, false).get_shader_uniform_list().size()
	check(reference > 0, "default shader compiles")
	for creases in [false, true]:
		for pixel in [false, true]:
			var names := {}
			for uniform in variant(creases, pixel).get_shader_uniform_list(): names[uniform.name] = true
			check(names.has("color_maps") and names.has("ormh_maps") and names.has("normal_maps"), "variant creases=%s pixel=%s compiles with sampler arrays" % [creases, pixel])
			check(names.size() == reference, "variant creases=%s pixel=%s keeps the uniform set" % [creases, pixel])
	var source := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	check(source.contains("color_maps[32] : source_color, filter_nearest_mipmap") and source.contains("ormh_maps[32] : filter_nearest_mipmap") and source.contains("normal_maps[32] : filter_linear_mipmap"), "pixel variant: nearest colour/ORMH, bilinear normals")
	var dispatch := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_texture_dispatch.gdshaderinc")
	check(not dispatch.contains("textureGrad(color_maps[0], uv") and dispatch.contains("terrain_pixel_uv(uv, textureSize(ormh_maps[31], 0))"), "colour and ORMH fetches snap through terrain_pixel_uv")
	check(dispatch.contains("textureGrad(normal_maps[0], uv, dx, dy)"), "normal fetches are not snapped")
	check(source.contains("uniform int projection_modes[32]") and source.count("terrain_projection_weights(projection_normal, triplanar_sharpnesses[id], projection_modes[id])") == 2, "fragment and vertex paths use the per-material projection")
	var material := StrataMaterial.new()
	material.projection = StrataMaterial.ProjectionMode.SIDES
	var variant := material.make_variant(2.0)
	if variant != null: check(variant.projection == StrataMaterial.ProjectionMode.SIDES, "UV variants inherit the projection")
	print("PIXEL_SAMPLING checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
