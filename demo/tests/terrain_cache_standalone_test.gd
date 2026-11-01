## Terrain resource persistence without the HEGo/Houdini add-on or extension.
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if ClassDB.class_exists("HEGoAPI"):
		_fail("HEGo native class unexpectedly exists in the standalone terrain project")
		return
	if not ClassDB.class_exists("StrataLayerData"):
		_fail("Standalone terrain data extension is not registered")
		return
	if not _test_native_data_resource():
		return
	if not _test_procedural_scene_cache():
		return
	print("HEGO_TERRAIN_STANDALONE_CACHE_PASS (procedural grid scene; HEGoAPI absent)")
	quit(0)

func _test_native_data_resource() -> bool:
	var data := StrataLayerData.new()
	data.sample_spacing = 0.25
	data.grid_origin = Vector2(-2.5, 4.0)
	data.set_sample(&"height", Vector2i(3, -2), -12.75)
	data.set_sample(&"constraint", Vector2i(-4, 6), 8.5)
	data.set_sample(&"height", Vector2i(0, 0), 0.0)
	var owned_before := data.get_owned_samples(&"height")
	var path := "user://terrain_standalone_roundtrip.res"
	var save_result := ResourceSaver.save(data, path)
	if save_result != OK:
		_fail("Could not save standalone terrain resource: %s" % error_string(save_result))
		return false
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataLayerData
	if loaded == null:
		_fail("Could not reload standalone terrain resource")
		return false
	var height := loaded.sample_channel(&"height", loaded.grid_origin + Vector2(3, -2) * loaded.sample_spacing)
	var constraint := loaded.sample_channel(&"constraint", loaded.grid_origin + Vector2(-4, 6) * loaded.sample_spacing)
	if not (loaded.sample_spacing == 0.25 and loaded.grid_origin == Vector2(-2.5, 4.0)
			and is_equal_approx(float(height.value), -12.75) and is_equal_approx(float(constraint.value), 8.5)
			and loaded.get_owned_samples(&"height") == owned_before and loaded.has_sample(&"height", Vector2i.ZERO)):
		_fail("LayerData ResourceSaver/ResourceLoader round-trip lost grid data or explicit ownership")
		return false
	return true

func _test_procedural_scene_cache() -> bool:
	var terrain := StrataTerrain3D.new()
	terrain.name = "Terrain"
	terrain.base_bounds = Rect2(-8.0, -8.0, 16.0, 16.0)
	terrain.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(27.0)), Vector3(12.0, 0.0, -5.0))
	var target := StrataLayer.new()
	target.name = "Procedural"
	target.procedural = true
	target.producer_id = "standalone-cache-fixture"
	target.set_composition(&"height", StrataLayer.Composition.ADD)
	terrain.add_child(target)
	root.add_child(terrain)
	target.owner = terrain
	var image := Image.create(3, 2, false, Image.FORMAT_RF)
	var pixels := [[1.25, 2.5, 3.75], [-4.0, 5.5, 8.25]]
	for y in range(2):
		for x in range(3):
			image.set_pixel(x, y, Color(pixels[y][x], 0.0, 0.0, 1.0))
	var origin := Vector3(1.25, 6.5, -2.5)
	var step_x := Vector3(0.4, 0.0, 0.3)
	var step_y := Vector3(0.45, 0.0, -0.6)
	var attrs := {"source": "procedural-cache-test", "nested": {"seed": 419, "label": "rotated anisotropic"}}
	var field := {"name": "height", "image": image, "sample_origin": origin, "sample_step_x": step_x, "sample_step_y": step_y, "attrs": attrs, "composition": "add"}
	var mask_image := Image.create(3, 2, false, Image.FORMAT_RF)
	for y in range(2):
		for x in range(3):
			mask_image.set_pixel(x, y, Color(0.2 + 0.1 * x + 0.05 * y, 0.0, 0.0, 1.0))
	var mask_field := {"name": "mask", "image": mask_image, "sample_origin": origin, "sample_step_x": step_x, "sample_step_y": step_y, "attrs": {"purpose": "preserved mask grid"}, "composition": "replace"}
	var host := Node.new()
	host.name = "ProducerHost"
	root.add_child(host)
	var ticket := StrataProcedural.begin_transaction(host, target.producer_id,
		[{"layer": target, "channels": PackedStringArray(["height", "mask"]), "required_channels": PackedStringArray(["height", "mask"])}], [])
	if not ticket.get("ok", false):
		_fail("Could not begin standalone procedural cache transaction: %s" % ticket.get("message", "unknown error"))
		return false
	var committed := StrataProcedural.commit_fields(ticket,
		[{"layer_id": target.layer_id, "fields": [field, mask_field]}])
	if not committed.get("ok", false):
		_fail("Could not commit standalone procedural cache: %s" % committed.get("message", "unknown error"))
		return false
	var field_ref: StrataFieldData = target.procedural_fields.get("height")
	if field_ref == null or field_ref.resolution != Vector2i(3, 2) or field_ref.sample_origin != origin \
			or field_ref.sample_step_x != step_x or field_ref.sample_step_y != step_y \
			or field_ref.attrs.get("nested", {}).get("seed") != 419 or target.get_composition(&"height") != StrataLayer.Composition.ADD:
		_fail("Committed procedural FieldData omitted its basis, attributes or composition")
		return false
	var local_sample_position := Vector2(origin.x + step_x.x + step_y.x, origin.z + step_x.z + step_y.z)
	if not is_equal_approx(terrain.sample_height(local_sample_position), pixels[1][1]):
		_fail("Terrain did not sample the committed nonzero-datum procedural grid before save")
		return false
	var packed := PackedScene.new()
	var pack_error := packed.pack(terrain)
	if pack_error != OK:
		_fail("Could not pack standalone procedural terrain scene: %s" % error_string(pack_error))
		return false
	var scene_path := "user://terrain_procedural_cache_roundtrip.tscn"
	var save_error := ResourceSaver.save(packed, scene_path)
	if save_error != OK:
		_fail("Could not save standalone procedural terrain scene: %s" % error_string(save_error))
		return false
	var reloaded_scene := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if reloaded_scene == null:
		_fail("Could not reload standalone procedural terrain scene")
		return false
	var restored := reloaded_scene.instantiate() as StrataTerrain3D
	if restored == null:
		_fail("Reloaded scene did not instantiate StrataTerrain3D")
		return false
	root.add_child(restored)
	restored.rebuild_preview()
	var restored_mesh := restored.get_preview_mesh()
	var restored_layer := restored.get_node_or_null("Procedural") as StrataLayer
	var restored_field: StrataFieldData = restored_layer.procedural_fields.get("height") if restored_layer != null else null
	var restored_sample_position := Vector2(origin.x + step_x.x + step_y.x, origin.z + step_x.z + step_y.z)
	var restored_value := restored.sample_height(restored_sample_position) if restored_layer != null else NAN
	var restored_world_origin := restored.global_transform * origin
	var expected_world_origin := terrain.global_transform * origin
	var valid: bool = restored_layer != null and restored_layer.procedural \
		and restored_layer.producer_id == "standalone-cache-fixture" \
		and restored_layer.layer_id == target.layer_id \
		and restored_layer.get_composition(&"height") == StrataLayer.Composition.ADD \
		and restored_field != null and restored_field.resolution == Vector2i(3, 2) \
		and restored_field.sample_origin == origin and restored_field.sample_step_x == step_x and restored_field.sample_step_y == step_y \
		and restored_field.attrs.get("nested", {}).get("label") == "rotated anisotropic" \
		and restored_mesh != null and restored_mesh.get_surface_count() == 1 \
		and restored_layer.procedural_fields.has("mask") \
		and restored_layer.procedural_fields["mask"].sample_step_x == step_x \
		and restored_layer.procedural_fields["mask"].attrs.get("purpose") == "preserved mask grid" \
		and is_equal_approx(restored_layer.procedural_fields["mask"].data.get_sample(&"mask", Vector2i(1, 1)), 0.35) \
		and is_equal_approx(restored_field.data.get_sample(&"height", Vector2i(1, 1)), 5.5) \
		and is_equal_approx(restored_value, 5.5) and restored_world_origin.is_equal_approx(expected_world_origin) \
		and restored_layer.procedural_stale
	if not valid:
		_fail("Reloaded procedural scene lost grid basis, attrs, role, producer identity, composition, values or sampling")
		return false
	return true

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
