@tool
extends MeshInstance3D
class_name HDAPigHead

const ASSET_NAME : String = "Sop/hego_testpighead_tool"


@export var recook: bool = false:
	set(value):
		print("cooking")
		cook()

var hego_asset_node: HEGoAssetNode

func cook():
	
	for child in get_children():
		child.queue_free()
	
	# Ensure valid AssetNode object
	if not hego_asset_node: hego_asset_node = HEGoAssetNode.new()
	hego_asset_node.op_name = ASSET_NAME
	hego_asset_node.instantiate()
	hego_asset_node.set_transform(global_transform)
	# Ensure valid MergeNode object
	# Fetch and set cook result of AssetNode
	var res = load("res://hego/surface_configs/fetch_surfaces_split_by_lod.tres")
	var dict = hego_asset_node.fetch_surfaces(res)
	
	
	var arr_mesh = ArrayMesh.new()
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	for i in surface_array.size():
		surface_array[i] = null
	var index_offset = 0
	
	var lods = {}
	var dict_keys = dict.keys()

	var lod_0_indices = dict[dict_keys[0]]["surface_array"][12]
	
	for key in dict.keys():
		var lod_array : Array = dict[key]["surface_array"]
		for i in range(lod_array[12].size()):
			lod_array[12][i] += index_offset
		for i in range(lod_array.size()):
			if surface_array[i] == null:
				surface_array[i] = lod_array[i]
			else:
				surface_array[i] += lod_array[i]
		
		index_offset += lod_array[0].size()
		if key != 0:
			lods[key] = lod_array[12]
		
	surface_array[12] = lod_0_indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array, [], lods)
	
	self.mesh = arr_mesh

