## Run with a rendering backend (e.g. xvfb-run godot --rendering-method gl_compatibility),
## because the headless dummy renderer does not retain LOD buffers.
extends SceneTree

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  %s %s" % ["ok" if condition else "FAIL", message])
	if not condition:
		failures += 1

func surface_data(vertex_count := 4) -> Dictionary:
	var vertices := PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3.ONE])
	vertices.resize(vertex_count)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2, 0, 2, 3])
	return {"surface_array": arrays, "hego_lod": [0.0, 0.0, 8.0]}

func _initialize() -> void:
	var surface := surface_data()
	var original: PackedInt32Array = surface.surface_array[Mesh.ARRAY_INDEX].duplicate()
	var first := HEGoMeshOutput.build_array_mesh({null: surface})
	check(surface.surface_array[Mesh.ARRAY_INDEX] == original, "building preserves the caller's combined indices")
	if surface.surface_array[Mesh.ARRAY_INDEX] == original:
		var second := HEGoMeshOutput.build_array_mesh({null: surface})
		check(first.surface_get_arrays(0) == second.surface_get_arrays(0), "repeated builds produce identical surfaces")
		check(RenderingServer.mesh_get_surface(second.get_rid(), 0).get("lods", []).size() == 1, "repeated builds retain the LOD")
	print("failures: ", failures)
	quit(1 if failures else 0)
