## Recursive source discovery without a Houdini session.
extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func add(parent: Node, node: Node, label: String) -> Node:
	node.name=label;parent.add_child(node);return node
func sources(host: Node, paths: Array, enabled := true) -> Array:
	return HEGoInputNodes.resolve_paths(host, paths, {"include_children":enabled})
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var scene=add(root,Node3D.new(),"TestScene");current_scene=scene
	var host=add(scene,Node3D.new(),"Generator")
	var group=add(scene,Node3D.new(),"Inputs")
	var nested=add(group,Node3D.new(),"Nested")
	var box=add(nested,MeshInstance3D.new(),"Box");box.mesh=BoxMesh.new();box.hide()
	add(nested,MeshInstance3D.new(),"EmptyMesh")
	add(group,Marker3D.new(),"Marker")
	var path=add(group,Path3D.new(),"Path");path.curve=Curve3D.new();path.curve.add_point(Vector3.ZERO);path.curve.add_point(Vector3.UP)
	var graph=add(group,HEGoGraphInput3D.new(),"Graph");graph.add_point(Vector3.ZERO)
	var csg=add(group,CSGBox3D.new(),"Assembly")
	var cut=add(csg,CSGBox3D.new(),"BooleanCut");cut.operation=CSGShape3D.OPERATION_SUBTRACTION
	var output=add(host,Node3D.new(),"Outputs");var generated=add(output,MeshInstance3D.new(),"Generated");generated.mesh=BoxMesh.new()
	await process_frame
	var expected=["Inputs/Nested/Box","Inputs/Path","Inputs/Graph","Inputs/Assembly"]
	check(sources(host,["Inputs"])==expected,"recursive mixed sources, hidden inputs, and CSG assembly ownership")
	check(sources(host,["Inputs","Inputs/Nested/Box","Inputs/Assembly/BooleanCut"])==expected,"overlapping selections and nested CSG operands do not duplicate geometry")
	check(sources(host,["Inputs"],false).is_empty(),"turning expansion off does not keep stale children from a container")
	check(HEGoInputNodes.resolve_paths(host,["Inputs/Nested/Box"],{})==["Inputs/Nested/Box"],"legacy rows preserve explicit compatible inputs")
	check(sources(host,[".","Generator/Outputs/Generated"])==expected,"own generated outputs cannot feed back through an ancestor or direct selection")
	var extra=add(nested,MeshInstance3D.new(),"AddedLater");extra.mesh=BoxMesh.new()
	check(sources(host,["Inputs"]).has("Inputs/Nested/AddedLater"),"new descendants appear on the next resolution")
	box.free()
	check(not sources(host,["Inputs"]).has("Inputs/Nested/Box"),"deleted descendants disappear")
	extra.reparent(group);extra.name="Renamed"
	check(sources(host,["Inputs"]).has("Inputs/Renamed"),"renamed and reparented descendants use their current path")
	extra.queue_free()
	check(not sources(host,["Inputs"]).has("Inputs/Renamed"),"queued deletions are not uploaded")
	check(sources(host,["MissingParent"]).is_empty(),"missing parents resolve empty instead of retaining old children")
	var stash=[{"inputs":["Inputs"],"settings":{"include_children":true,"curve_sample_length":.04}}]
	var original=stash.duplicate(true)
	HEGoInputNodes.resolve_paths(host,stash[0].inputs,stash[0].settings)
	check(stash==original,"expansion does not replace the saved parent list")
	current_scene=null;scene.free()
	print("HEGO_INPUT_CHILDREN_FAILURES ",failures);quit(1 if failures else 0)
