extends SceneTree
## Native integration regression using artificial pixels and the dedicated COP texture fixture.
## Run with a licensed Houdini installation and a rebuilt HEGo extension:
## godot --headless --path demo --script res://tests/hego_cop_texture_test.gd

const FIXTURE := "res://tests/fixtures/hego_test_cop_texture.hda"
const FETCH := "copnet1/fetch1"
const SPLIT := "copnet1/channelsplit1"
const EPSILON := 0.001

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> bool:
	if not condition:
		failures += 1
		push_error(message)
	return condition


func wait_task(task: HEGoTask, expect_success := true) -> Variant:
	if not check(task != null, "Expected a native task"):
		return null
	while task.get_status() < HEGoTask.COMPLETED:
		await process_frame
	var expected := HEGoTask.COMPLETED if expect_success else HEGoTask.FAILED
	if not check(task.get_status() == expected, "%s returned %s, expected %s: %s" % [
			task.get_description(), task.get_status(), expected, task.get_error_message()]):
		return null
	if not expect_success:
		check(not task.get_error_message().is_empty(), "Rejected task supplies an error message")
		return null
	return task.get_result()


func pattern(size: Vector2i, format: Image.Format) -> Image:
	var image := Image.create(size.x, size.y, false, format)
	for y in size.y:
		for x in size.x:
			var value := (1.0 + x + y * size.x) / 16.0
			image.set_pixel(x, y, Color(value, 0.5 + value, 1.0 - value, 0.25 + value))
	return image


func check_transfer(asset: HEGoAssetNode, source: Image, srgb: bool) -> void:
	await wait_task(asset.cook())
	var output: HEGoPointOutput = await wait_task(asset.get_point_output(["red_corner"]))
	if check(output != null and output.get_point_count() == 1, "SOP produced one texture sample"):
		var samples := output.get_attribute("red_corner")
		var bottom_left := source.get_pixel(0, source.get_height() - 1)
		if srgb:
			bottom_left = bottom_left.srgb_to_linear()
		check(samples.size() == 1 and absf(samples[0] - bottom_left.r) < EPSILON,
				"SOP volume voxel (0, 0) reads the linear red channel of the Godot bottom-left pixel")

	var pixels: Image = await wait_task(asset.fetch_cop_image(FETCH))
	var green: Image = await wait_task(asset.fetch_cop_image(SPLIT, "green"))
	if not check(pixels != null and green != null, "Both COP images reached Godot"):
		return
	if not check(pixels.get_size() == source.get_size() and green.get_size() == source.get_size(),
			"COP outputs use the current image dimensions"):
		return
	check(pixels.get_format() == Image.FORMAT_RGBAF, "RGBA COP returns an RGBA float image")
	check(green.get_format() == Image.FORMAT_RF, "Single-channel COP returns a scalar float image")
	for y in source.get_height():
		for x in source.get_width():
			var wanted := source.get_pixel(x, y)
			if srgb:
				wanted = wanted.srgb_to_linear()
			var actual := pixels.get_pixel(x, y)
			check(absf(actual.r - wanted.r) < EPSILON and absf(actual.g - wanted.g) < EPSILON
					and absf(actual.b - wanted.b) < EPSILON and absf(actual.a - wanted.a) < EPSILON,
					"RGBA at (%d, %d) returned %s, expected %s" % [x, y, actual, wanted])
			check(absf(green.get_pixel(x, y).r - wanted.g) < EPSILON,
					"Named green output reads the second channel at (%d, %d)" % [x, y])


func exercise(api: HEGoAPI) -> void:
	await wait_task(api.load_hda_library(FIXTURE))
	var asset := HEGoAssetNode.new()
	asset.op_name = "Sop/hego_test_cop_texture"
	await wait_task(asset.instantiate())
	if not check(asset.get_id() >= 0, "Fixture HDA instantiated"):
		return
	var source := HEGoTextureInputNode.new()
	var first := pattern(Vector2i(3, 2), Image.FORMAT_RGBAF)
	await wait_task(source.set_image(first))
	await wait_task(asset.set_node_parm("source_texture", source))
	await check_transfer(asset, first, false)

	# Changing size, storage and encoding must update the existing operator-path binding.
	var second := pattern(Vector2i(2, 4), Image.FORMAT_RGBA8)
	await wait_task(source.set_image(second, HEGoTextureInputNode.ENCODING_SRGB))
	await check_transfer(asset, second, true)

	await wait_task(source.set_image(Image.new()), false)
	await wait_task(asset.fetch_cop_image(), false) # The fixture root is a SOP.
	await wait_task(asset.fetch_cop_image("copnet1/no_such_cop"), false)
	await wait_task(asset.fetch_cop_image(SPLIT, "no_such_output"), false)
	await check_transfer(asset, second, true)

	# The independent layers request specific native precision in the saved fixture.
	var half: Image = await wait_task(asset.fetch_cop_image("copnet1/layer1"))
	if check(half != null and half.get_size() == Vector2i(2, 2) and half.get_format() == Image.FORMAT_RGF,
			"Two-channel half raster widens to Godot RGF"):
		for y in half.get_height():
			for x in half.get_width():
				var sample := half.get_pixel(x, y)
				check(sample.r == -2.25 and sample.g == 4.5, "Signed and HDR half values survive extraction")
	await wait_task(asset.fetch_cop_image("copnet1/layer2"), false)

	# A numbered SOP socket receives a single path point. The same source can also
	# serve the node parameter used above and remains wired through pixel changes.
	var socket_asset := HEGoAssetNode.new()
	socket_asset.op_name = asset.op_name
	await wait_task(socket_asset.instantiate())
	await wait_task(socket_asset.connect_input(source, 0))
	await check_transfer(socket_asset, second, true)
	var point: HEGoPointOutput = await wait_task(socket_asset.get_point_output(["texture_count", "first_cop"]))
	if check(point != null and point.get_point_count() == 1, "Socket fixture reports its input"):
		check(point.get_attribute("texture_count")[0] == 1, "Each texture supplies exactly one SOP point")
		var path: String = point.get_attribute("first_cop")[0]
		check(path.begins_with("/"), "The point carries an absolute Houdini operator path")
		var direct: Image = await wait_task(socket_asset.fetch_cop_image(path))
		check(direct != null and direct.get_size() == second.get_size(), "The point path resolves to the uploaded image")
	await wait_task(source.set_image(first))
	await check_transfer(socket_asset, first, false)
	await wait_task(socket_asset.delete_node())
	await wait_task(asset.delete_node())
	await wait_task(source.delete_node())


func run() -> void:
	var api := HEGoAPI.get_singleton()
	if not api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_cop_texture_%d" % OS.get_process_id()):
		push_error("Could not start the private Houdini session")
		quit(1)
		return
	await exercise(api)
	api.stop_session()
	api.clear_completed_task_history()
	await process_frame
	if failures == 0:
		print("HEGO_COP_TEXTURE_PASS")
	quit(0 if failures == 0 else 1)
