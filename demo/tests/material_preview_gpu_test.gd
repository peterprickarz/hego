extends SceneTree
## Dedicated artificial red material/flat terrain fixture. Exercises the real
## production shader without loading or editing the normal island showcase.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_PREVIEW_GPU: " + message)
func draw() -> void:
	for index in range(6): await process_frame
	await RenderingServer.frame_post_draw
func probe_shader(tail: String) -> Shader:
	var code := FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	for name in ["terrain_regions.gdshaderinc", "terrain_controls.gdshaderinc", "terrain_texture_dispatch.gdshaderinc", "terrain_normals.gdshaderinc", "terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:
		code = code.replace('#include "' + name + '"', FileAccess.get_file_as_string("res://addons/strata/shaders/" + name))
	var last := code.rfind("}")
	var shader := Shader.new(); shader.code = code.substr(0, last) + tail + code.substr(last)
	return shader
func pixel() -> Vector3:
	var value := root.get_texture().get_image().get_pixelv(root.size / 2).srgb_to_linear()
	return Vector3(value.r, value.g, value.b)

func run() -> void:
	create_timer(45).timeout.connect(func(): push_error("Material preview GPU watchdog"); quit(1))
	if RenderingServer.get_rendering_device() == null: push_error("Use graphical Forward+"); quit(2); return
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(-8, -8, 16, 16); terrain.set_preview_enabled(false); root.add_child(terrain)
	var renderer := StrataRenderer.new(); terrain.add_child(renderer)
	var material := StrataMaterial.new()
	material.color_texture = StrataRenderer._solid_texture(Color(1, 0, 0))
	material.normal_texture = StrataRenderer._solid_texture(Color(.5, .5, 1))
	material.ormh_texture = StrataRenderer._solid_texture(Color(.2, .3, .1, 1))
	material.displacement_strength = 4; material.height_blend_contrast = 16
	var pool: Array[StrataMaterial] = [material]
	var empty := StrataMaterialControls.unassigned()
	check(renderer.set_control_maps(empty.ids, empty.weights), "zero controls accepted before shader configuration")
	var field := Image.create(17, 17, false, Image.FORMAT_RF)
	check(renderer.configure_compiled_field(terrain, pool, {"ok": true, "image": field, "bounds": terrain.base_bounds, "resolution": field.get_size(), "sample_step_x": Vector3.RIGHT, "min": 0.0, "max": 0.0}), "production terrain shader configures with unassigned controls")
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 8; camera.position = Vector3(0, 20, 0); terrain.add_child(camera); camera.look_at(Vector3.ZERO, Vector3.FORWARD); camera.current = true; renderer.set_camera(camera)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new(); environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color.BLACK; terrain.add_child(environment)
	for family in ["color", "orm", "displacement"]:
		var tail := "ALBEDO=vec3(0.0);ROUGHNESS=1.0;METALLIC=0.0;AO=1.0;"
		var expected := Vector3.ZERO
		match family:
			"color": tail += "EMISSION=color;"; expected = Vector3.ONE * .45
			"orm": tail += "EMISSION=orm;"; expected = Vector3(1, .94, 0)
			"displacement": tail += "EMISSION=vec3((INV_VIEW_MATRIX*vec4(VERTEX,1.0)).y+.5);"; expected = Vector3.ONE * .5
		renderer._shader_material.shader = probe_shader(tail)
		await draw()
		var actual := pixel()
		print("MATERIAL_PREVIEW_GPU ", family, " actual=", actual, " expected=", expected)
		check(actual.distance_to(expected) < .018, "unassigned " + family + " uses neutral values without sampling material zero")
	var assigned := Image.create(2, 2, false, Image.FORMAT_RGBAF); assigned.fill(Color(1, 0, 0, 0))
	check(renderer.set_control_maps(empty.ids, assigned), "ordinary positive assignment accepted")
	renderer._shader_material.shader = probe_shader("ALBEDO=vec3(0.0);EMISSION=color;")
	await draw()
	check(pixel().distance_to(Vector3(1, 0, 0)) < .018, "positive assignment still renders the actual source material")
	terrain.free()
	await process_frame
	await test_editor_bridge(material, empty.ids, assigned)
	print("MATERIAL_PREVIEW_GPU checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

## Frames until the bridge's sliced composition has finished, then a draw.
func settle(bridge: StrataEditorPreview) -> void:
	var frames := 0
	await process_frame
	while bridge.is_busy() and frames < 600:
		await process_frame
		frames += 1
	await draw()
## Material weights of lattice sample (0, 0): texel (apron, apron) of region (0, 0).
func lattice_weights(bridge: StrataEditorPreview) -> Color:
	var region: StrataRegionData = bridge.renderer.get_region(Vector2i.ZERO)
	return region.get_image("material_weights").get_pixel(region.apron, region.apron)

func test_editor_bridge(material: StrataMaterial, saved_ids: Image, saved_weights: Image) -> void:
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(-8, -8, 16, 16); terrain.set_preview_enabled(false)
	terrain.editor_materials = [material]; terrain.editor_material_channels = PackedStringArray(["material_a"])
	terrain.editor_control_ids = saved_ids; terrain.editor_control_weights = saved_weights
	var height := StrataLayer.new(); height.name = "HeightOnly"; terrain.add_child(height)
	var distribution := StrataLayer.new(); distribution.name = "MaterialAssignment"; terrain.add_child(distribution)
	distribution.data.grid_origin = Vector2(-8, -8); distribution.data.sample_spacing = 8
	for z in range(3):
		for x in range(3): distribution.data.set_sample(&"material_a", Vector2i(x, z), 1)
	terrain.preview_through_layer = height
	root.add_child(terrain)
	var camera := Camera3D.new(); camera.position = Vector3(0, 20, 0); terrain.add_child(camera); camera.look_at(Vector3.ZERO, Vector3.FORWARD); camera.current = true
	var bridge := StrataEditorPreview.new(); terrain.add_child(bridge); bridge.setup(terrain); bridge.set_camera(camera)
	await settle(bridge)
	check(is_instance_valid(bridge.renderer) and lattice_weights(bridge) == Color(0, 0, 0, 0), "actual editor bridge initially binds the selected early stage instead of saved final controls")
	terrain.preview_through_layer = distribution
	await settle(bridge)
	check(lattice_weights(bridge) == Color(1, 0, 0, 0), "changing the actual editor cutoff binds its newly included material stage")
	distribution.enabled = false
	await settle(bridge)
	check(lattice_weights(bridge) == Color(0, 0, 0, 0), "disabling the material stage clears the actual renderer assignment")
	distribution.enabled = true; terrain.move_child(distribution, 0); terrain.preview_through_layer = height
	await settle(bridge)
	check(lattice_weights(bridge) == Color(1, 0, 0, 0), "layer reorder refreshes actual editor controls through the current cutoff")
	var previous_ids: PackedByteArray = bridge.renderer.get_region(Vector2i.ZERO).get_image("material_ids").get_data()
	var previous_weights: PackedByteArray = bridge.renderer.get_region(Vector2i.ZERO).get_image("material_weights").get_data()
	# Deliberately invalid configuration: the expected renderer error below is
	# part of this rollback test, never an island asset or editor change.
	print("MATERIAL_PREVIEW_GPU expected invalid empty-pool renderer error follows")
	terrain.editor_materials = []; bridge.sync_configuration()
	await settle(bridge)
	check(bridge.status.contains("previous rendered terrain retained") and bridge.renderer.get_region(Vector2i.ZERO).get_image("material_ids").get_data() == previous_ids and bridge.renderer.get_region(Vector2i.ZERO).get_image("material_weights").get_data() == previous_weights, "failed editor reconfiguration retains the previous material region maps")
	check(terrain.editor_control_ids == saved_ids and terrain.editor_control_weights == saved_weights and saved_weights.get_pixel(0, 0) == Color(1, 0, 0, 0), "actual editor stage changes preserve separately saved final bindings")
	terrain.free()
	await process_frame
