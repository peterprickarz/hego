@tool
extends Node3D
class_name HeightfieldInputTest

var hego_heightfield_node: HEGoHeightfieldInputNode

@export_tool_button("Send Heightfield", "Bake")
var action_send: Callable = func(): send_heightfield()

@export_tool_button("Send Heightfield Alt", "Bake")
var action_send_alt: Callable = func(): send_heightfield_alt()

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

	hego_heightfield_node.set_layers(layers)

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

	hego_heightfield_node.set_layers(layers)
