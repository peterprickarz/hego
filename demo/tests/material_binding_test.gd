extends SceneTree
## Headless resource-to-uniform plumbing. The tiny shader is a synthetic binding
## fixture; production shader projection and normal orientation need GPU tests.
var failures := 0
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures += 1; push_error(message)

func run() -> void:
	var first := StrataMaterial.new()
	var second := StrataMaterial.new()
	first.triplanar_sharpness = 1.0
	second.triplanar_sharpness = 64.0
	check(StrataRenderer._valid_material(first) and StrataRenderer._valid_material(second), "Renderer accepts both projection sharpness endpoints")
	check(not StrataRenderer._valid_material(null), "Renderer rejects absent materials")
	var renderer := StrataRenderer.new()
	root.add_child(renderer)
	renderer._materials = [first, second]
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform float triplanar_sharpnesses[32]; void fragment() { ALBEDO = vec3(triplanar_sharpnesses[0] / 64.0); }"
	renderer._shader_material = ShaderMaterial.new()
	renderer._shader_material.shader = shader
	renderer._bind_material_pool()
	renderer._watch_materials()
	var values: PackedFloat32Array = renderer._shader_material.get_shader_parameter("triplanar_sharpnesses")
	check(values.size() == 32 and values[0] == 1.0 and values[1] == 64.0, "Independent material sharpness values reach their shader slots")
	var defaults_valid := true
	for index in range(2, values.size()): defaults_valid = defaults_valid and values[index] == 4.0
	check(defaults_valid, "Unused material slots retain default sharpness")
	var refreshes := int(renderer.get_stats().get("material_binding_updates", 0))
	first.triplanar_sharpness = 8.0
	first.triplanar_sharpness = 12.0
	second.triplanar_sharpness = 2.5
	check(renderer._shader_material.get_shader_parameter("triplanar_sharpnesses") == values, "Edit bursts retain the old coherent bindings until the deferred refresh")
	await process_frame
	values = renderer._shader_material.get_shader_parameter("triplanar_sharpnesses")
	check(values[0] == 12.0 and values[1] == 2.5, "Deferred refresh uploads the final independent material edits")
	check(int(renderer.get_stats().get("material_binding_updates", 0)) == refreshes + 1, "Sharpness edit burst coalesces into one material binding refresh")
	first.triplanar_sharpness = NAN
	second.triplanar_sharpness = 0.0
	await process_frame
	check(renderer._shader_material.get_shader_parameter("triplanar_sharpnesses") == values and int(renderer.get_stats().get("material_binding_updates", 0)) == refreshes + 1, "Rejected sharpness edits preserve bindings and schedule no refresh")
	renderer.free()
	print("MATERIAL_BINDING_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
