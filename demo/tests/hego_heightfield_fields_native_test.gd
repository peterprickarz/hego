extends SceneTree
## Explicit-field transport: real HAPI, no project HDA or user GUI scene.

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		push_error(description)

func task_result(task: HEGoTask, description: String) -> Dictionary:
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	var success := task.get_status() == HEGoTask.COMPLETED
	check(success, "%s: %s" % [description, task.get_error_message()])
	return {"ok": success, "result": task.get_result()}

func field(name: String, width: int, height: int, origin: Vector3, sx: Vector3, sy: Vector3) -> Dictionary:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			image.set_pixel(x, y, Color(100.0 * y + x, 0, 0, 1))
	return {"name": name, "image": image, "sample_origin": origin, "sample_step_x": sx, "sample_step_y": sy, "attrs": {"field_label": name, "large_int": 1234567890123, "precision": 1.234567890123, "direction": Vector3(1, 2, 3)}}

func copy_fields(fields: Array) -> Array:
	var copied: Array = []
	for item: Dictionary in fields:
		var copy := item.duplicate(true)
		copy.image = item.image.duplicate()
		copied.append(copy)
	return copied

func verify_fields(actual: Array, expected: Array, transform: Transform3D) -> void:
	check(actual.size() == expected.size(), "all and only explicit fields survive; no dummy height/mask")
	var by_name: Dictionary = {}
	for item: Dictionary in actual:
		by_name[item.name] = item
	for source: Dictionary in expected:
		check(by_name.has(source.name), "exact field name and case retained: " + source.name)
		if not by_name.has(source.name): continue
		var output: Dictionary = by_name[source.name]
		var image: Image = output.image
		var reference: Image = source.image
		# A grid whose step_x x step_y points down arrives transposed, in Houdini's
		# HeightField layout, so the volume's height axis is up.
		var transposed: bool = source.sample_step_x.cross(source.sample_step_y).y < 0.0
		var expected_size := Vector2i(reference.get_height(), reference.get_width()) if transposed else reference.get_size()
		check(image.get_format() == Image.FORMAT_RF and image.get_size() == expected_size, "rectangular RF resolution retained, transposed only to keep the height axis up: " + source.name)
		check(output.coordinate_space == "sop_local" and output.resolution == expected_size, "explicit grid metadata identifies SOP-local samples")
		check(output.sample_step_x.cross(output.sample_step_y).y > 0.0, "uploaded heightfields point their height axis up like Houdini's HeightField: " + source.name)
		check(output.attrs.get("large_int") == source.attrs.large_int and output.attrs.get("field_label") == source.name, "primitive scalar/string attributes retain their values")
		check(absf(output.attrs.get("precision", 0.0) - source.attrs.precision) < 0.000000000001 and output.attrs.get("direction") == Vector3(1, 2, 3), "float64 and vector primitive attributes retain their values")
		for y in range(reference.get_height()):
			for x in range(reference.get_width()):
				var index := Vector2i(y, x) if transposed else Vector2i(x, y)
				var source_point: Vector3 = source.sample_origin + source.sample_step_x * x + source.sample_step_y * y
				var output_point: Vector3 = output.sample_origin + output.sample_step_x * index.x + output.sample_step_y * index.y
				check(output_point.distance_to(transform * source_point) < 0.0002, "every physical sample center survives anisotropic/negative/rotated grids: %s %s" % [source.name, Vector2i(x, y)])
				check(image.get_pixel(index.x, index.y).r == reference.get_pixel(x, y).r, "every asymmetric RF value remains at its physical source position: %s %s" % [source.name, Vector2i(x, y)])

func _run() -> void:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "explicit_fields_%d" % OS.get_process_id()):
		push_error("Could not start the isolated native transport session")
		quit(1)
		return
	await exercise()
	api.stop_session()
	if failures.is_empty():
		print("HEGO_HEIGHTFIELD_FIELDS_NATIVE_PASS")
		quit(0)
	else:
		push_error("Explicit-field native transport failures: %d" % failures.size())
		quit(1)

func exercise() -> void:
	var yaw := Basis(Vector3.UP, deg_to_rad(30.0))
	var fields: Array = [
		field("MiXeD_Field", 3, 5, Vector3(11, 3, -7), Vector3(2, 0, 0), Vector3(0, 0, 3)),
		field("constraint_ExactCase", 4, 2, Vector3(-4, 2, 8), yaw * Vector3(-0.5, 0, 0), yaw * Vector3(0, 0, 1.25)),
		field("another_Field", 2, 4, Vector3(5, -2, 1), Vector3(0, 0, -2), Vector3(3, 0, 0)),
	]
	var expected := copy_fields(fields)
	var input := HEGoHeightfieldInputNode.new()
	var upload: HEGoTask = input.set_fields(fields)
	# Mutation immediately after submission cannot alter the enqueued snapshot.
	fields[0].image.fill(Color(999, 0, 0, 1))
	fields[0].attrs.large_int = 0
	if not (await task_result(upload, "immutable explicit field upload")).ok: return
	var input_transform := Transform3D(Basis(Vector3.UP, deg_to_rad(37.0)), Vector3(11, 7, -9))
	var host_transform := Transform3D(Basis(Vector3.UP, deg_to_rad(-23.0)), Vector3(-3, 2, 4))
	if not (await task_result(input.set_transform(input_transform), "input terrain transform")).ok: return
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/null"
	if not (await task_result(asset.instantiate(), "built-in Null SOP")).ok: return
	var preset := await task_result(asset.get_preset(), "strict preset read")
	if not preset.ok: return
	check(preset.result is PackedByteArray and not preset.result.is_empty(), "a successful preset read is a complete nonempty buffer")
	if not (await task_result(asset.set_preset(preset.result), "strict preset write")).ok: return
	var bad_preset: HEGoTask = asset.set_preset(PackedByteArray())
	while bad_preset.get_status() < HEGoTask.COMPLETED: await process_frame
	check(bad_preset.get_status() == HEGoTask.FAILED, "an invalid preset write cannot masquerade as successful")
	if not (await task_result(asset.set_transform(host_transform), "different asset host transform")).ok: return
	if not (await task_result(asset.connect_input(input, 0), "cross-OBJ field connection")).ok: return
	var fetched := await task_result(asset.get_heightfield_fields(), "strict all-field fetch and cook")
	if not fetched.ok: return
	verify_fields(fetched.result, expected, host_transform.affine_inverse() * input_transform)
	var old_id := input.get_id()
	if not (await task_result(input.set_fields(expected), "identical field payload cache hit")).ok: return
	check(input.get_id() == old_id, "identical accepted fields reuse the valid input")
	var invalid := copy_fields(expected)
	invalid[1].name = invalid[0].name
	var rejected: HEGoTask = input.set_fields(invalid)
	check(rejected.get_status() == HEGoTask.FAILED and input.get_id() == old_id, "invalid complete payload preserves the old input without changing its cache")
	if not (await task_result(input.set_fields(expected, true), "forced replacement field upload")).ok: return
	check(input.get_id() != old_id, "forced replacement publishes a new complete input")
	if not (await task_result(input.set_transform(input_transform), "identical transform must reapply after replacement")).ok: return
	if not (await task_result(asset.connect_input(input, 0), "reconnect replacement input")).ok: return
	var again := await task_result(asset.get_heightfield_fields(), "fetch replacement fields")
	if not again.ok: return
	verify_fields(again.result, expected, host_transform.affine_inverse() * input_transform)
	var merge := HEGoAssetNode.new()
	merge.op_name = "Sop/merge"
	if not (await task_result(merge.instantiate(), "duplicate-name output merge")).ok: return
	if not (await task_result(merge.connect_input(input, 0), "first merge branch")).ok: return
	if not (await task_result(merge.connect_input(input, 1), "second merge branch")).ok: return
	var duplicated := await task_result(merge.get_heightfield_fields(), "fetch all duplicate-name output parts")
	if not duplicated.ok: return
	check(duplicated.result.size() == expected.size() * 2, "native fetch preserves duplicate field names for higher-level target routing")
	var part_ids: Dictionary = {}
	for item: Dictionary in duplicated.result: part_ids[item.part_id] = true
	check(part_ids.size() == duplicated.result.size(), "duplicate-name volumes retain distinct part identities")
	var shear := HEGoAssetNode.new()
	shear.op_name = "Sop/xform"
	if not (await task_result(shear.instantiate(), "unsupported-grid transform SOP")).ok: return
	if not (await task_result(shear.connect_input(input, 0), "connect shear fixture")).ok: return
	if not (await task_result(shear.set_parm("shear", Vector3(0, 0.25, 0)), "set shear fixture")).ok: return
	var sheared: HEGoTask = shear.get_heightfield_fields()
	while sheared.get_status() < HEGoTask.COMPLETED: await process_frame
	check(sheared.get_status() == HEGoTask.FAILED and sheared.get_result() == null, "actual sheared output fails atomically despite unreliable SDK shear metadata")
	var generated := HEGoAssetNode.new()
	generated.op_name = "Sop/heightfield"
	if not (await task_result(generated.instantiate(), "built-in HeightField SOP")).ok: return
	if not (await task_result(generated.set_parm("size", Vector2(8, 6)), "small HeightField extent")).ok: return
	if not (await task_result(generated.set_parm("gridspacing", 1.0), "small HeightField spacing")).ok: return
	var built_in := await task_result(generated.get_heightfield_fields(), "fetch genuine Houdini HeightField output")
	if not built_in.ok: return
	check(built_in.result.size() == 2, "built-in HeightField output retains height and mask")
	for item: Dictionary in built_in.result:
		check(item.resolution == Vector2i(6, 8), "real HeightField resolution maps image columns and rows without transposition")
		check(item.sample_origin.distance_to(Vector3(-3.5, 0, -2.5)) < 0.00001 and item.sample_step_x == Vector3(0, 0, 1) and item.sample_step_y == Vector3(1, 0, 0), "native metadata matches real Houdini HeightField indexed sample centers and orientation")
	# reset_node_id is an internal C++ lifecycle hook, not a script API. Its
	# epoch/publication locking is reviewed natively; session cleanup invokes it.
	await native_heightfield_shape()

# Reports what a cook received: the detail volvis value types and each volume's border.
const PROBE_CODE := """
geo = hou.pwd().geometry()
volvis = geo.dictAttribValue("volvis") if geo.findGlobalAttrib("volvis") else {}
summary = ";".join("%s:%s:%s" % (key, type(volvis[key]).__name__, volvis[key] if isinstance(volvis[key], str) and not volvis[key].startswith("{") else "") for key in sorted(volvis))
geo.addAttrib(hou.attribType.Prim, "probe_volvis", "")
geo.addAttrib(hou.attribType.Prim, "probe_border", "")
for prim in geo.prims():
    prim.setAttribValue("probe_volvis", summary)
    prim.setAttribValue("probe_border", prim.intrinsicValue("volumebordertype"))
"""
const NATIVE_VOLVIS := "cdfield:str:mask;cdramp:str:;cdrampperiodic:int:;cdrange:Vector2:;densityfield:str:height;densityramp:str:;densityrampperiodic:int:;densityrange:Vector2:;emitcdfield:str:;emitcdramp:str:;emitcdrampperiodic:int:;emitcdrange:Vector2:;emitfield:str:Alpha;emitramp:str:;emitrampperiodic:int:;emitrange:Vector2:;emitscale:float:;shadowscale:float:"

func probe(input: HEGoHeightfieldInputNode, description: String) -> Array:
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/python"
	if not (await task_result(asset.instantiate(), description + ": Python SOP probe")).ok: return []
	if not (await task_result(asset.set_parm("python", PROBE_CODE), description + ": probe code")).ok: return []
	if not (await task_result(asset.connect_input(input, 0), description + ": connect probe")).ok: return []
	var fetched := await task_result(asset.get_heightfield_fields(), description + ": fetch probed fields")
	return fetched.result if fetched.ok else []

func native_heightfield_shape() -> void:
	# A height field alone gains a zero mask on exactly its grid, right after it; a
	# channel on another grid is left alone.
	var height := field("height", 5, 4, Vector3(-2, 0, 3), Vector3(0, 0, 1.5), Vector3(1.5, 0, 0))
	var cliff := field("cliff", 3, 3, Vector3(7, 0, -1), Vector3(0, 0, 4), Vector3(4, 0, 0))
	var input := HEGoHeightfieldInputNode.new()
	if not (await task_result(input.set_fields([height, cliff]), "height-only field upload")).ok: return
	var fields := await probe(input, "height-only fields")
	var names := fields.map(func(item: Dictionary) -> String: return item.name)
	check(names == ["height", "mask", "cliff"], "a default mask follows height and nothing else is added: %s" % [names])
	if names != ["height", "mask", "cliff"]: return
	var h: Dictionary = fields[0]
	var m: Dictionary = fields[1]
	check(m.resolution == h.resolution and m.sample_origin.is_equal_approx(h.sample_origin) and m.sample_step_x.is_equal_approx(h.sample_step_x) and m.sample_step_y.is_equal_approx(h.sample_step_y), "the default mask lies on exactly the height grid")
	var zero := Image.create(m.image.get_width(), m.image.get_height(), false, Image.FORMAT_RF)
	check(m.image.get_data() == zero.get_data(), "the default mask is zero-filled")
	check(fields[2].resolution == Vector2i(3, 3), "a channel on its own grid keeps it")
	check(h.attrs.get("probe_border") == "streak" and m.attrs.get("probe_border") == "constant" and fields[2].attrs.get("probe_border") == "streak", "like a native HeightField, only the mask has a constant border: %s" % [fields.map(func(item): return item.attrs.get("probe_border"))])
	check(h.attrs.get("probe_volvis") == NATIVE_VOLVIS, "volvis matches the HeightField SOP's keys and value types: " + str(h.attrs.get("probe_volvis")))
	# A supplied mask is kept, still with a constant border.
	var mask := field("mask", 5, 4, Vector3(-2, 0, 3), Vector3(0, 0, 1.5), Vector3(1.5, 0, 0))
	if not (await task_result(input.set_fields([height, mask]), "height and mask upload")).ok: return
	fields = await probe(input, "height and supplied mask")
	check(fields.size() == 2 and fields[1].name == "mask" and fields[1].image.get_data() == mask.image.get_data() and fields[1].attrs.get("probe_border") == "constant", "a supplied mask is kept as is, with a constant border")
	# A caller's own volvis attribute is never overwritten.
	var custom := field("height", 2, 2, Vector3.ZERO, Vector3(0, 0, 1), Vector3(1, 0, 0))
	custom.attrs["volvis"] = "custom"
	if not (await task_result(input.set_fields([custom]), "height with its own volvis")).ok: return
	fields = await probe(input, "caller volvis")
	check(fields.size() == 2 and fields[0].attrs.get("probe_volvis") == "", "no detail volvis is written over a caller's volvis attribute")
	# Without height there is no mask and no volvis.
	if not (await task_result(input.set_fields([cliff]), "field upload without height")).ok: return
	fields = await probe(input, "no height")
	check(fields.size() == 1 and fields[0].attrs.get("probe_volvis") == "", "without height, no mask or volvis is added")
	# The legacy layer path matches.
	var layer_image := Image.create(4, 4, false, Image.FORMAT_RF)
	var layers := HEGoHeightfieldInputNode.new()
	if not (await task_result(layers.set_layers({"height": {"image": layer_image}}), "legacy layer upload")).ok: return
	fields = await probe(layers, "legacy layers")
	var borders := {}
	for item: Dictionary in fields: borders[item.name] = item.attrs.get("probe_border")
	check(borders == {"height": "streak", "mask": "constant"}, "legacy layers: only the mask has a constant border: %s" % [borders])
	check(fields.size() > 0 and fields[0].attrs.get("probe_volvis") == NATIVE_VOLVIS, "legacy layers carry the HeightField SOP's volvis")

