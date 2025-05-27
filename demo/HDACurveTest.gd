@tool
extends MeshInstance3D # node can directly contain a mesh to be rendered
class_name HDACurveTest # makes this node placeable directly

const ASSET_NAME : String = "Sop/hego_curvetests" # defines which operator to use

@export var input_node: Node = null # expose node input reference
@export var stash: PackedByteArray
		
var hego_asset_node: HEGoAssetNode # create the asset node var
var hego_curve_input_node: HEGoCurveInputNode # create a curve input node var

func cook():
	# Ensure valid AssetNode object
	if not hego_asset_node: hego_asset_node = HEGoAssetNode.new()
	# instantiate asset node in Houdini and set transform
	hego_asset_node.op_name = ASSET_NAME
	var id = hego_asset_node.get_id()
	hego_asset_node.instantiate()
	hego_asset_node.set_transform(global_transform)
	if id == -1 and stash.size()>0:
		hego_asset_node.set_preset(stash)
	

	# Ensure valid curve node object
	if not hego_curve_input_node: hego_curve_input_node = HEGoCurveInputNode.new()
	# instantiate curve input node in houdini, send curve over and connect as input
	hego_curve_input_node.instantiate()
	hego_curve_input_node.set_curve_from_path_3d(input_node, 2)
	hego_asset_node.connect_input(hego_curve_input_node, 0)
	# use config to fetch output mesh
	var res = load("res://addons/hego/surface_filters/fetch_surfaces_default.tres")
	# retrieve dictionary output, containing the mesh in godots surface_array format
	var dict = hego_asset_node.fetch_surfaces(res)
	# add surface to new array mesh and assign to this node
	var arr_mesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dict["surface_array"])
	self.mesh = arr_mesh
	hego_set_parm_stash(hego_asset_node.get_preset())
	

func hego_set_parm_stash(preset:PackedByteArray):
	stash = preset
	
func hego_get_stashed_parms():
	return stash
	
func hego_use_bottom_panel():
	return true
	
func hego_get_asset_node():
	return hego_asset_node;
	
func hego_get_input_stash():
	return [[input_node]]
	
func hego_set_input_stash(input_array: Array):
	# Extract the instance ID from the string
	var regex = RegEx.new()
	regex.compile("#(\\d+)") # Match the number after '#'
	var result = regex.search(input_array[0]["inputs"][0])
	input_node = instance_from_id(int(result.get_string()))
