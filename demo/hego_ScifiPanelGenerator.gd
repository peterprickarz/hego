@tool
extends MeshInstance3D
class_name HDAScifiPanelGenerator

const ASSET_NAME : String = "Sop/hego_scifipanelgenerator"

@export var recook: bool = false:
	set(value):
		cook()
# array of nodes to support inputting multiple MeshInstance3D objects
@export var input_nodes: Array[MeshInstance3D] = []

var hego_asset_node: HEGoAssetNode
var hego_merge_node: HEGoMergeNode
# create an array of input nodes to keep track of multiple input meshes
var hego_input_nodes: Array[HEGoInputNode]

func cook():
	# Ensure valid AssetNode object
	if not hego_asset_node: hego_asset_node = HEGoAssetNode.new()
	hego_asset_node.op_name = ASSET_NAME
	hego_asset_node.instantiate()
	hego_asset_node.set_transform(global_transform)
	# Ensure valid MergeNode object
	if not hego_merge_node: hego_merge_node = HEGoMergeNode.new()
	hego_merge_node.instantiate()
	# Ensure array of InputNodes contains valid InputNode objects
	if hego_input_nodes.size() > input_nodes.size():
		hego_input_nodes.resize(input_nodes.size())
	for i in range(input_nodes.size()):
		if(hego_input_nodes.size()<i+1):
			hego_input_nodes.append(HEGoInputNode.new())
		hego_input_nodes[i].instantiate()
		hego_input_nodes[i].set_geo_from_mesh_instance_3d(input_nodes[i])
	# Connect inputs function takes an array of InputNode objects
	hego_merge_node.connect_inputs(hego_input_nodes)
	# Connect MergeNode to AssetNode and set parameters
	hego_asset_node.connect_input(hego_merge_node, 0)
	
	var res = load("res://hego/surface_configs/fetch_surfaces_split_by_mat.tres")
	var dict = hego_asset_node.fetch_surfaces(res)
	var arr_mesh = ArrayMesh.new()
	
	var m_accent = load("res://materials/m_accent.tres")
	var m_default = load("res://materials/m_default.tres")
	var m_dark_grey = load("res://materials/m_dark_grey.tres")
	var m_dark_accent = load("res://materials/m_dark_accent.tres")
	var m_black = load("res://materials/m_black.tres")
	var m_main = load("res://materials/m_main.tres")
	
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["Main"]["surface_array"])
	arr_mesh.surface_set_material(0,m_main)
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["DarkGrey"]["surface_array"])
	arr_mesh.surface_set_material(1,m_dark_grey)
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["Accent"]["surface_array"])
	arr_mesh.surface_set_material(2,m_accent)
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["DarkAccent"]["surface_array"])
	arr_mesh.surface_set_material(3,m_dark_accent)
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["Black"]["surface_array"])
	arr_mesh.surface_set_material(4,m_black)
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["default"]["surface_array"])
	arr_mesh.surface_set_material(5,m_default)
	
	self.mesh = arr_mesh
