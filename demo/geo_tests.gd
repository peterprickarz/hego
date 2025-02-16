@tool
extends MeshInstance3D



@export var test:bool = false :
	set(value):
		var g_basis = global_basis
		var g_q = global_transform
		var test = g_basis.get_rotation_quaternion()
		var rot2 = test.get_euler(EULER_ORDER_YXZ)
		var rot = global_basis.get_euler(EULER_ORDER_ZYX)
		HEGoAPI.get_singleton().test_godot_mesh_input(self)

 
# Called when the node enters the scene tree for the first time.
func _ready():
	# print(mesh.surface_get_arrays(0))
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

