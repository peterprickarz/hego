## Real HAPI input-chain regression for recursive discovery and dynamic membership.
## No project HDA is needed; native Add SOP exposes the merged input points.
extends SceneTree
class Host extends Node3D:
	var input_stash: Array = []
	func hego_get_input_stash() -> Array:return input_stash
	func hego_set_input_stash(value: Array) -> void:input_stash=value
func _initialize() -> void:call_deferred("run")
func add(parent: Node, node: Node, label: String) -> Node:
	node.name=label;parent.add_child(node);return node
func points(agent: HEGoAssetAgent, asset: HEGoAssetNode, host: Host, paths: Array, include_children: bool) -> Array:
	host.input_stash=[{"inputs":PackedStringArray(paths),"settings":{"include_children":include_children}}]
	await agent.sync_inputs(asset)
	assert(await agent.task(asset.cook()) != null)
	var output:HEGoPointOutput=await agent.task(asset.get_point_output(PackedStringArray(["P"])))
	return output.get_attribute("P") if output.get_point_count() else []
func run() -> void:
	AudioServer.set_bus_mute(0,true)
	var api=HEGoAPI.get_singleton();assert(api.start_session(HEGoAPI.SESSION_NAMED_PIPE,"children_native_%d"%OS.get_process_id()))
	var scene=add(root,Node3D.new(),"Fixture");current_scene=scene
	var host:Host=add(scene,Host.new(),"Generator")
	var group=add(scene,Node3D.new(),"Inputs");group.position=Vector3(5,0,0)
	var a=add(group,CSGBox3D.new(),"A");a.position=Vector3(0,1,0)
	var assembly=add(group,CSGBox3D.new(),"Assembly");assembly.position=Vector3(3,0,0)
	var cut=add(assembly,CSGBox3D.new(),"Cut");cut.operation=CSGShape3D.OPERATION_SUBTRACTION;cut.size=Vector3(.5,3,.5)
	await process_frame;await process_frame
	var agent=HEGoAssetAgent.new(host);var asset=agent.asset("Sop/add")
	assert(await agent.instantiate(asset));await agent.task(asset.set_parm("keep",1))
	var explicit=await points(agent,asset,host,["Inputs/A","Inputs/Assembly"],false)
	assert(not explicit.is_empty())
	var expanded=await points(agent,asset,host,["Inputs"],true)
	assert(expanded==explicit,"Parent discovery must match explicit baked CSG roots with their transforms")
	# A Boolean result can become completely empty. It must clear that source,
	# without failed zero-length HAPI uploads or stale geometry from the last cook.
	cut.size=Vector3(3,3,3)
	await process_frame;await process_frame
	var without_assembly=await points(agent,asset,host,["Inputs"],true)
	var only_a=await points(agent,asset,host,["Inputs/A"],false)
	assert(without_assembly==only_a)
	cut.size=Vector3(.5,3,.5)
	await process_frame;await process_frame

	assert(await points(agent,asset,host,["Inputs","Inputs/A","Inputs/Assembly/Cut"],true)==explicit,"No duplicate source or Boolean operand upload")
	assert((await points(agent,asset,host,["Inputs"],false)).is_empty(),"Turning expansion off clears the previous children")
	assert(await points(agent,asset,host,["Inputs"],true)==explicit,"Turning expansion back on reconnects the children")
	var nested=add(group,Node3D.new(),"Nested");var mesh=add(nested,MeshInstance3D.new(),"Mesh");mesh.mesh=BoxMesh.new();mesh.position=Vector3(-3,0,0)
	var after_add=await points(agent,asset,host,["Inputs"],true)
	assert(after_add.size()>explicit.size(),"Adding a child changes the existing input chain")
	assert(after_add==await points(agent,asset,host,["Inputs/A","Inputs/Assembly","Inputs/Nested/Mesh"],false))
	a.free();assembly.free();mesh.reparent(group);mesh.name="Moved"
	var after_remove=await points(agent,asset,host,["Inputs"],true)
	assert(after_remove==await points(agent,asset,host,["Inputs/Moved"],false),"Removal/reparenting discards stale inputs")
	mesh.free()
	assert((await points(agent,asset,host,["Inputs"],true)).is_empty(),"An empty parent clears previously connected geometry")
	api.stop_session();current_scene=null;scene.free()
	print("HEGO_INPUT_CHILDREN_NATIVE_PASS");quit()
