@tool

extends MeshInstance3D
class_name HDATestScatter

const ASSET_NAME : String = "Sop/hego_testscatter_tool"
const PARM_NAME_SPIKE_SCALE : String = "spike_scale"
const PARM_NAME_SPIKE_DENSITY : String = "spike_density"
const PARM_NAME_NORMAL_ALIGNED : String = "normal_aligned"

@export var auto_cook: bool = false
@export var recook: bool = false:
	set(value):
		cook()
		
@export var input_nodes: Array[Node] = []: 
	set(value):
		input_nodes = value
		update_change_time("input_nodes")
@export var normal_aligned = true:
	set(value):
		normal_aligned = value
		update_change_time("normal_aligned")
@export var spike_scale = 1.0:
	set(value):
		spike_scale = value
		update_change_time("spike_scale")
@export var spike_density = 1.0:
	set(value):
		spike_density = value
		update_change_time("spike_density")

var last_change_time = {
	"input_nodes": 0.0,
	"normal_aligned": 0.0,
	"spike_scale": 0.0,
	"spike_density": 0.0
}

var change_detected = false
var change_delay = 0.1

var hda_node_id = -1
var merge_node_id = -1
var input_ids = Array()

func _process(delta):
	if not Engine.is_editor_hint():
		return
	if not self in EditorInterface.get_selection().get_selected_nodes():
		return
	if not auto_cook:
		return
	if change_detected:
		var current_time = Time.get_ticks_msec() / 1000.0
		var last_change = get_max_value(last_change_time)
		if current_time - last_change >= change_delay:
			change_detected = false
			print("auto cook")
			cook()
		
func _ready():
	set_process(true)

func cook():
	var hego = HEGoAPI.get_singleton()
	hda_node_id = hego.instantiate_hda_from_name(ASSET_NAME, hda_node_id)
	hego.set_transform(hda_node_id, global_transform)
	merge_node_id = hego.create_merge_sop(merge_node_id)
	if(input_nodes.size()<input_ids.size()):
		input_ids.resize(input_nodes.size())
	for i in range(input_nodes.size()):
		if(input_ids.size()<i+1):
			input_ids.append(-1)
		input_ids[i] = hego.create_input_from_mesh_instance_3d(input_nodes[i], input_ids[i])
	hego.connect_to_merge(merge_node_id, input_ids)
	hego.connect_merge_to_input(hda_node_id, 0, merge_node_id)
	
	hego.set_parm(hda_node_id, PARM_NAME_SPIKE_SCALE, spike_scale)
	hego.set_parm(hda_node_id, PARM_NAME_SPIKE_DENSITY, spike_density)
	hego.set_parm(hda_node_id, PARM_NAME_NORMAL_ALIGNED, int(normal_aligned))
	
	var surface_array = hego.fetch_surface_array(hda_node_id)
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)

func update_change_time(var_name: String):
	last_change_time[var_name] = Time.get_ticks_msec() / 1000.0
	change_detected = true
	
func get_max_value(dict):
	var max_value = -INF
	for value in dict.values():
		if value > max_value:
			max_value = value
	return max_value
