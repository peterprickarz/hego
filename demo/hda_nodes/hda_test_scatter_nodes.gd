@icon('res://addons/hego/assets/houdini.svg')
@tool
extends MeshInstance3D
class_name HDATestScatterNodes

const ASSET_NAME: String = "Sop/hego_testscatter_tool"
#const PARM_NAME_SPIKE_SCALE : String = "spike_scale"
const PARM_NAME_SPIKE_DENSITY: String = "spike_density"
const PARM_NAME_NORMAL_ALIGNED: String = "normal_aligned"
const PARM_NAME_DENSITY_BIAS: String = "density_bias"
const PARM_NAME_MIN_SCALE: String = "min_scale"
const PARM_NAME_MAX_SCALE: String = "max_scale"


@export_tool_button("Cook", "Bake")
var action_cook = func(): cook() # button to trigger cook function
@export var input_nodes: Array[Node] = []
@export var dist_input_nodes: Array[Node] = []
@export var normal_aligned = true
#@export var spike_scale = 1.0
@export var spike_density = 1.0
@export var density_bias = 1.0
@export var min_scale = 1.0
@export var max_scale = 1.0

var hego_asset_node: HEGoAssetNode
var hego_merge_node: HEGoMergeNode
var hego_input_nodes: Array[HEGoInputNode]
var hego_dist_merge_node: HEGoMergeNode
var hego_dist_input_nodes: Array[HEGoInputNode]

func cook():
	for child in get_children():
		child.queue_free()
	
	# Ensure valid AssetNode object
	if not hego_asset_node: hego_asset_node = HEGoAssetNode.new()
	hego_asset_node.op_name = ASSET_NAME
	hego_asset_node.instantiate()
	hego_asset_node.set_transform(global_transform)
	# Ensure valid MergeNode object
	if not hego_merge_node: hego_merge_node = HEGoMergeNode.new()
	hego_merge_node.instantiate()
	if not hego_dist_merge_node: hego_dist_merge_node = HEGoMergeNode.new()
	hego_dist_merge_node.instantiate()
	# Ensure array of InputNodes contains valid InputNode objects
	if hego_input_nodes.size() > input_nodes.size():
		hego_input_nodes.resize(input_nodes.size())
	for i in range(input_nodes.size()):
		if (hego_input_nodes.size() < i + 1):
			hego_input_nodes.append(HEGoInputNode.new())
		hego_input_nodes[i].instantiate()
		hego_input_nodes[i].set_geo_from_mesh_instance_3d(input_nodes[i])
	if hego_dist_input_nodes.size() > dist_input_nodes.size():
		hego_dist_input_nodes.resize(dist_input_nodes.size())
	for i in range(dist_input_nodes.size()):
		if (hego_dist_input_nodes.size() < i + 1):
			hego_dist_input_nodes.append(HEGoInputNode.new())
		hego_dist_input_nodes[i].instantiate()
		hego_dist_input_nodes[i].set_geo_from_mesh_instance_3d(dist_input_nodes[i])
	# Connect inputs function takes an array of InputNode objects
	hego_merge_node.connect_inputs(hego_input_nodes)
	hego_dist_merge_node.connect_inputs(hego_dist_input_nodes)
	# Connect MergeNode to AssetNode and set parameters
	hego_asset_node.connect_input(hego_merge_node, 0)
	hego_asset_node.connect_input(hego_dist_merge_node, 1)
	hego_asset_node.set_parm(PARM_NAME_DENSITY_BIAS, density_bias)
	hego_asset_node.set_parm(PARM_NAME_MIN_SCALE, min_scale)
	hego_asset_node.set_parm(PARM_NAME_MAX_SCALE, max_scale)
	hego_asset_node.set_parm(PARM_NAME_SPIKE_DENSITY, spike_density)
	hego_asset_node.set_parm(PARM_NAME_NORMAL_ALIGNED, int(normal_aligned))
	# Fetch and set cook result of AssetNode
	var res = load("res://addons/hego/point_filters/fetch_points_default.tres")
	var dict = hego_asset_node.fetch_points(res)
	var multimesh = MultiMesh.new()

	multimesh.transform_format = RenderingServer.MULTIMESH_TRANSFORM_3D
	multimesh.instance_count = dict["ids"].size()
	multimesh.visible_instance_count = -1
	multimesh.mesh = load("res://models/test_grass_subnet1.res")
	

	for i in range(dict["P"].size()):
		var normal: Vector3 = dict["N"][i]
		var up: Vector3 = dict["up"][i]
		var pos: Vector3 = dict["P"][i]
		var pscale: float = dict["pscale"][i]
		
		normal = normal.normalized()
		up = up.normalized()
		var cross: Vector3 = normal.cross(up)
		cross = cross.normalized()
		
		var basis = Basis(cross, up, normal)
		
		var transform = Transform3D(basis, pos)
		var scale_vector = Vector3(pscale, pscale, pscale)
		var scale_transform = Transform3D(Basis().scaled(scale_vector))
		
		transform *= scale_transform
		
		multimesh.set_instance_transform(i, transform)
	var multimesh_instance = MultiMeshInstance3D.new()
	print(multimesh_instance)
	multimesh_instance.multimesh = multimesh
	add_child(multimesh_instance, true, Node.INTERNAL_MODE_DISABLED)
	multimesh_instance.owner = get_tree().edited_scene_root
	var shader_mat = ShaderMaterial.new()
	shader_mat.shader = load("res://grass_shader.tres")
	multimesh_instance.material_override = shader_mat
