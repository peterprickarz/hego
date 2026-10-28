## Run with a real renderer and --audio-driver Dummy; Dummy rendering has no LOD buffers.
extends SceneTree
func _initialize()->void:call_deferred("run")
func run()->void:
	var arrays:=[];arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3.ZERO,Vector3.RIGHT,Vector3(1,0,1),Vector3.BACK,Vector3(.5,0,.5)])
	arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2,0,2,3])
	var source:=ArrayMesh.new();source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{.2:PackedInt32Array([0,2,4])})
	var target:=ArrayMesh.new();HEGoMeshOutput.copy_array_mesh_contents(target,source)
	var raw:Dictionary=target.get("_surfaces")[0]
	assert(raw.lods.size()==2,"Overwriting an ArrayMesh must preserve its LOD buffers")
	var bytes:PackedByteArray=raw.lods[1]
	assert(bytes.decode_u16(0)==0 and bytes.decode_u16(2)==2 and bytes.decode_u16(4)==4)
	assert(is_equal_approx(raw.lods[0],.2))
	assert(target.surface_get_arrays(0)[Mesh.ARRAY_INDEX]==arrays[Mesh.ARRAY_INDEX])
	print("HEGO_MESH_COPY_LOD_PASS");quit()
