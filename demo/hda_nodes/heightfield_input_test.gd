@tool
extends Node3D
class_name HeightfieldInputTest

const OUTPUT_ASSET_NAME := "Sop/test_HEGoHeightFieldOutput"
const HF_TEST_SAVE_DIR := "res://textures/hf_test"

var hego_heightfield_node: HEGoHeightfieldInputNode
var hego_asset_node: HEGoAssetNode

@export_tool_button("Send Heightfield", "Bake")
var action_send: Callable = func(): send_heightfield()

@export_tool_button("Send Heightfield Alt", "Bake")
var action_send_alt: Callable = func(): send_heightfield_alt()

@export_tool_button("Setup Output HDA", "Node")
var action_setup_output: Callable = func(): setup_output_hda()

@export_tool_button("Print Heightfield Layers", "Search")
var action_print_layers: Callable = func(): print_heightfield_layers()

func _await_task(task: HEGoTask) -> Variant:
	while task.get_status() < HEGoTask.COMPLETED:
		await get_tree().process_frame
	if task.get_status() == HEGoTask.FAILED:
		push_error("Task failed: " + task.get_error_message())
		return null
	return task.get_result()


func send_heightfield():
	var height_tex   = load("res://textures/stone/natural/Rock006_1K-JPG_Color_kuwahara.jpg")
	var mask_tex     = load("res://textures/stone/natural/Rock006_1K-JPG_NormalGL_kuwahara.jpg")
	var test_tex     = load("res://textures/stone/natural/Rock006_1K-JPG_Roughness_kuwahara.jpg")

	if not height_tex or not mask_tex or not test_tex:
		push_error("HeightfieldInputTest: failed to load one or more textures")
		return

	var layers := {
		"height": {
			"image": height_tex.get_image(),
			"attrs": { "test": "height" },
		},
		"mask": {
			"image": mask_tex.get_image(),
			"attrs": { "test": "mask" },
		},
		"test": {
			"image": test_tex.get_image(),
			"attrs": { "test": "test" },
		},
	}

	if not hego_heightfield_node:
		hego_heightfield_node = HEGoHeightfieldInputNode.new()

	await _await_task(hego_heightfield_node.set_layers(layers, 1, 100))

func setup_output_hda():
	if not hego_heightfield_node or hego_heightfield_node.get_id() < 0:
		push_error("HeightfieldInputTest: create/send heightfield layers first")
		return

	if not hego_asset_node:
		hego_asset_node = HEGoAssetNode.new()

	hego_asset_node.op_name = OUTPUT_ASSET_NAME
	await _await_task(hego_asset_node.instantiate())
	await _await_task(hego_asset_node.connect_input(hego_heightfield_node, 0))
	print("HeightfieldInputTest: connected output asset to heightfield input")

func print_heightfield_layers():
	if not hego_asset_node or hego_asset_node.get_id() < 0:
		push_error("HeightfieldInputTest: setup output HDA first")
		return

	var dir_err := DirAccess.make_dir_recursive_absolute(HF_TEST_SAVE_DIR)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_error("HeightfieldInputTest: failed creating save directory %s (err=%d)" % [HF_TEST_SAVE_DIR, dir_err])
		return

	var layers = await _await_task(hego_asset_node.get_heightfield_layers(PackedStringArray(["test"])))
	print("HeightfieldInputTest: get_heightfield_layers() -> ", layers)

	for layer_data in layers:
		var part_id := int(layer_data.get("part_id", -1))
		if part_id < 0:
			continue

		var layer_name := String(layer_data.get("layer_name", "layer"))
		var test_attr = _get_named_attr_value(layer_data.get("attrs", []), "test")
		print("HeightfieldInputTest: layer part_id=%d name=%s test_attr=%s" % [part_id, layer_name, str(test_attr)])

		var image = await _await_task(hego_asset_node.fetch_heightfield_layer_image(part_id))
		if not image:
			push_error("HeightfieldInputTest: failed fetching image for part_id=%d" % part_id)
			continue

		var texture := ImageTexture.create_from_image(image)
		if not texture:
			push_error("HeightfieldInputTest: failed creating texture for part_id=%d" % part_id)
			continue

		var safe_layer := _sanitize_filename(layer_name)
		var safe_attr := _sanitize_filename(str(test_attr))
		var res_path := "%s/%03d_%s__test_%s.tres" % [HF_TEST_SAVE_DIR, part_id, safe_layer, safe_attr]
		var save_err := ResourceSaver.save(texture, res_path)
		if save_err != OK:
			push_error("HeightfieldInputTest: failed saving texture resource at %s (err=%d)" % [res_path, save_err])
		else:
			print("HeightfieldInputTest: saved ", res_path)

func send_heightfield_alt():
	var height_tex = load("res://textures/stone/natural/Rock006_1K-JPG_Color_kuwahara.jpg")
	var mask_tex = load("res://textures/stone/natural/Rock006_1K-JPG_NormalGL_kuwahara.jpg")
	var stone_tex = load("res://textures/stone/natural/Rock006_1K-JPG_Roughness_kuwahara.jpg")
	var wood_tex = load("res://textures/wood/natural/bark_02_ambient_occlusion_1k.png")

	if not height_tex or not mask_tex or not stone_tex or not wood_tex:
		push_error("HeightfieldInputTest: failed to load one or more textures for alt layer set")
		return

	var layers := {
		"height": {
			"image": height_tex.get_image(),
			"attrs": { "test": "height" },
		},
		"mask": {
			"image": mask_tex.get_image(),
			"attrs": { "test": "mask" },
		},
		"wood": {
			"image": wood_tex.get_image(),
			"attrs": { "test": "wood" },
		},
		"stone": {
			"image": stone_tex.get_image(),
			"attrs": { "test": "stone" },
		},
	}

	if not hego_heightfield_node:
		hego_heightfield_node = HEGoHeightfieldInputNode.new()

	await _await_task(hego_heightfield_node.set_layers(layers))

func _get_named_attr_value(attrs: Array, attr_name: String) -> Variant:
	for attr in attrs:
		if attr is Dictionary and attr.get("name", "") == attr_name:
			return attr.get("value")
	return null

func _sanitize_filename(value: String) -> String:
	var sanitized := value.strip_edges().to_lower()
	if sanitized.is_empty():
		return "none"

	for bad_char in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		sanitized = sanitized.replace(bad_char, "_")

	sanitized = sanitized.replace(" ", "_")
	return sanitized
