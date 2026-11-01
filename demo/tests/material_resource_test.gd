extends SceneTree
## Resource lifetime/signals/persistence and actual island profiles. No GPU/Houdini.
var failures := 0
var checks := 0
var changes := 0
func _initialize() -> void: run.call_deferred()
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures += 1; push_error(message)
func changed() -> void: changes += 1
func run() -> void:
	var material := StrataMaterial.new()
	check(material.height_blend_contrast == 0.0 and material.height_blend_bias == 0.0, "Legacy/default resources preserve the original blend")
	check(material.roughness_scale == 1.0 and material.roughness_bias == 0.0, "Default roughness remap is identity")
	check(material.triplanar_sharpness == 4.0, "Default triplanar transition sharpness is four")
	check(material.projection == StrataMaterial.ProjectionMode.TRIPLANAR, "Default projection is triplanar")
	var projection_material := StrataMaterial.new()
	var projection_changes := [0]
	projection_material.changed.connect(func() -> void: projection_changes[0] += 1)
	projection_material.projection = StrataMaterial.ProjectionMode.SIDES; projection_material.projection = StrataMaterial.ProjectionMode.SIDES
	check(projection_changes[0] == 1 and projection_material.projection == StrataMaterial.ProjectionMode.SIDES, "Projection emits changed once per change")
	material.changed.connect(changed)
	material.height_blend_contrast = 12.0
	material.height_blend_bias = 0.11
	check(changes == 2, "New scalar edits each emit changed")
	material.height_blend_contrast = 12.0; material.height_blend_bias = 0.11
	check(changes == 2, "Identical scalar assignments emit no changes")
	for value in [NAN, INF, -1.0, 16.1]: material.height_blend_contrast = value
	for value in [NAN, -INF, -0.51, 0.51]: material.height_blend_bias = value
	check(material.height_blend_contrast == 12.0 and material.height_blend_bias == 0.11 and changes == 2, "Invalid new values retain the accepted state without change signals")
	material.triplanar_sharpness = 1.0; material.triplanar_sharpness = 64.0
	check(changes == 4 and material.triplanar_sharpness == 64.0, "Both sharpness endpoints are accepted and emit changed")
	for value in [64.0, NAN, INF, -INF, -1.0, 0.0, 0.99, 64.1]: material.triplanar_sharpness = value
	check(changes == 4 and material.triplanar_sharpness == 64.0, "Invalid/no-op sharpness assignments preserve state without signals")
	material.triplanar_sharpness = 6.5
	check(changes == 5, "A fractional sharpness edit emits changed")
	material.roughness_scale = 0.75; material.roughness_bias = 0.52
	accepted_roughness_inputs(material)
	material.uv_scale = 32.0; material.displacement_strength = 16.0
	check(material.uv_scale == 32.0 and material.displacement_strength == 16.0, "Existing finite scalar domains remain broader than Inspector ranges")
	var accepted_changes := changes
	material.uv_scale = NAN; material.displacement_strength = INF
	check(changes == accepted_changes and material.uv_scale == 32.0 and material.displacement_strength == 16.0, "Nonfinite legacy scalars cannot poison shader uniforms")
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8); image.fill(Color(0.2, 0.4, 0.6, 0.8))
	var texture := ImageTexture.create_from_image(image)
	material.color_texture = texture; material.normal_texture = texture; material.ormh_texture = texture
	accepted_changes = changes
	texture.changed.emit()
	check(changes == accepted_changes + 1, "One texture shared by three slots forwards one signal")
	material.color_texture = null; material.normal_texture = null
	accepted_changes = changes
	texture.changed.emit()
	check(changes == accepted_changes + 1, "Replacing slots keeps a texture watched while another slot uses it")
	material.ormh_texture = null
	accepted_changes = changes
	texture.changed.emit()
	check(changes == accepted_changes, "Unreferenced textures disconnect their notifications")
	material.color_texture = texture; material.normal_texture = texture; material.ormh_texture = texture
	material.uv_scale = 0.1; material.displacement_strength = 1.0
	var variant := material.make_variant(1.48)
	check(variant != null and variant.color_texture == texture and is_equal_approx(variant.uv_scale, 0.148), "UV variants share actual source textures")
	check(variant.triplanar_sharpness == 6.5, "UV variant starts with its source projection sharpness")
	material.height_blend_contrast = 14.0; material.height_blend_bias = -0.1
	material.uv_scale = 0.2; material.displacement_strength = 2.0
	material.roughness_scale = 0.8; material.roughness_bias = 0.2
	material.triplanar_sharpness = 12.0
	check(variant.height_blend_contrast == 14.0 and variant.height_blend_bias == -0.1 and is_equal_approx(variant.uv_scale, 0.296) and variant.displacement_strength == 2.0, "Source profile edits refresh all variant scalars")
	check(variant.roughness_scale == 0.8 and variant.roughness_bias == 0.2, "Roughness remap follows its source profile")
	check(variant.triplanar_sharpness == 12.0, "Live source sharpness edits propagate without a UV multiplier")
	var replacement := ImageTexture.create_from_image(image)
	material.ormh_texture = replacement
	check(variant.ormh_texture == replacement, "Texture replacement also reaches linked variants")
	var weak_variant: WeakRef = weakref(variant)
	variant = null
	check(weak_variant.get_ref() == null, "Source signal connections do not retain unused variants")
	material.height_blend_contrast = 13.0
	check(material.make_variant(NAN) == null, "Invalid variant scale rejects safely")
	var source_lifetime := StrataMaterial.new()
	var linked := source_lifetime.make_variant()
	var weak_source: WeakRef = weakref(source_lifetime)
	source_lifetime = null
	check(weak_source.get_ref() != null, "A live variant retains its source profile")
	linked = null
	check(weak_source.get_ref() == null, "The source and signal connection release with their last variant")
	var legacy := FileAccess.open("user://terrain-material-legacy.tres", FileAccess.WRITE)
	legacy.store_string('[gd_resource type="Resource" script_class="StrataMaterial" load_steps=2 format=3]\n[ext_resource type="Script" path="res://addons/strata/strata_material.gd" id="1"]\n[resource]\nscript = ExtResource("1")\nuv_scale = 0.2\n')
	legacy.close()
	var legacy_loaded := ResourceLoader.load("user://terrain-material-legacy.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as StrataMaterial
	check(legacy_loaded != null and legacy_loaded.height_blend_contrast == 0.0 and legacy_loaded.height_blend_bias == 0.0, "An old serialized resource with no new properties loads the exact neutral defaults")
	check(legacy_loaded.roughness_scale == 1.0 and legacy_loaded.roughness_bias == 0.0, "Old resources preserve packed roughness unchanged")
	check(legacy_loaded.triplanar_sharpness == 4.0, "Old serialized resources inherit default triplanar sharpness")
	# Both text/binary resources and exported PackedScene metadata retain the
	# actual material payload, independently of any runtime authoring addon.
	var saved := material.make_variant(1.13)
	for extension in ["tres", "res"]:
		var path: String = "user://terrain-material-roundtrip." + extension
		check(ResourceSaver.save(saved, path) == OK, "Save material " + extension)
		var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataMaterial
		check(loaded != null and loaded.height_blend_contrast == 13.0 and loaded.height_blend_bias == -0.1 and is_equal_approx(loaded.uv_scale, 0.226) and loaded.displacement_strength == 2.0, "Resource reload retains every material control " + extension)
		check(loaded.roughness_scale == 0.8 and loaded.roughness_bias == 0.2, "Roughness controls persist in " + extension)
		check(loaded.triplanar_sharpness == 12.0, "Triplanar sharpness persists in " + extension)
		check(loaded != null and loaded.ormh_texture.get_image().get_data() == image.get_data(), "Resource reload retains packed texture data " + extension)
		material.height_blend_contrast = 12.0
		material.triplanar_sharpness = 8.0
		check(loaded != null and loaded.height_blend_contrast == 13.0, "Saved variant is an independent snapshot " + extension)
		check(loaded.triplanar_sharpness == 12.0 and saved.triplanar_sharpness == 8.0, "Saved sharpness is independent while its live variant still follows the source " + extension)
		material.height_blend_contrast = 13.0
		material.triplanar_sharpness = 12.0
	var node := Node3D.new(); node.set_meta("terrain_material", saved)
	var packed := PackedScene.new()
	check(packed.pack(node) == OK and ResourceSaver.save(packed, "user://terrain-material-export.scn") == OK, "Export a scene containing the configured material")
	node.free()
	var scene := ResourceLoader.load("user://terrain-material-export.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var exported := scene.instantiate()
	var exported_material: StrataMaterial = exported.get_meta("terrain_material")
	check(exported_material.height_blend_contrast == 13.0 and exported_material.height_blend_bias == -0.1 and exported_material.ormh_texture.get_image().get_data() == image.get_data(), "Compiled scene reload retains controls and texture references without Houdini")
	check(exported_material.roughness_scale == 0.8 and exported_material.roughness_bias == 0.2, "Roughness controls survive scene export")
	check(exported_material.triplanar_sharpness == 12.0, "Triplanar sharpness survives scene export")
	exported.free()
	# The island's real material profiles, whichever the registry lists.
	if not preload("res://tests/lfs_data.gd").island_textures_present():
		print("MATERIAL_RESOURCE_TEST: island textures are Git LFS pointers; the registry profile checks are skipped")
		finish(); return
	var profiles: Array[StrataMaterial] = []
	for entry in HEGoIslandMaterialRegistry.registry().get("entries", []):
		var source := load(String(entry.resource)) as StrataMaterial
		check(source != null and source.color_texture != null and source.normal_texture != null and source.ormh_texture != null, "Actual source retains its three textures: " + String(entry.name))
		if source != null: profiles.append(source)
	check(profiles.size() == HEGoIslandMaterialRegistry.count() and not profiles.is_empty(), "every registry material loads")
	if profiles.is_empty(): finish(); return
	# Artist edits can intentionally reverse the original demonstration profiles.
	# The reusable make_variant API below is a deliberate synthetic alias fixture
	# (32 slots aliased over the registry's few sources); it is not the showcase pool.
	for profile in profiles:
		check(is_finite(profile.height_blend_contrast) and profile.height_blend_contrast >= 0.0 and profile.height_blend_contrast <= 16.0, "Actual artist contrast remains valid without forcing a cliff/grass hierarchy")
		check(is_finite(profile.triplanar_sharpness) and profile.triplanar_sharpness >= 1.0 and profile.triplanar_sharpness <= 64.0, "Actual artist projection sharpness remains valid")
	var variants: Array[StrataMaterial] = []
	for index in range(32):
		var source := profiles[index % profiles.size()]
		var item := source.make_variant()
		check(item.height_blend_contrast == source.height_blend_contrast and item.height_blend_bias == source.height_blend_bias and item.ormh_texture == source.ormh_texture, "Synthetic32-alias fixture inherits each source's height controls")
		check(item.uv_scale == source.uv_scale and item.roughness_scale == source.roughness_scale and item.roughness_bias == source.roughness_bias, "Aliases use one physical material scale and the same dry-surface controls")
		variants.append(item)
	var edited := profiles.size() - 1
	var original := profiles[edited].height_blend_contrast
	profiles[edited].height_blend_contrast = 11.0
	for index in range(32):
		if index % profiles.size() == edited: check(variants[index].height_blend_contrast == 11.0, "Source Inspector contrast edits reach every matching UV definition")
	profiles[edited].height_blend_contrast = original
	finish()

func finish() -> void:
	print("MATERIAL_RESOURCE_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func accepted_roughness_inputs(material: StrataMaterial) -> void:
	var before := changes
	material.roughness_scale = 0.75; material.roughness_bias = 0.52
	for value in [NAN, INF, -0.1, 2.1]: material.roughness_scale = value
	for value in [NAN, INF, -1.1, 1.1]: material.roughness_bias = value
	check(material.roughness_scale == 0.75 and material.roughness_bias == 0.52 and changes == before, "Invalid/no-op roughness assignments preserve values and emit no changes")
