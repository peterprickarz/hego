## Native indexed graph upload regression: shared points, attributes, updates.
## Requires a Houdini Engine installation; no project HDAs are needed.
extends SceneTree
func _initialize()->void:call_deferred("run")
func wait_task(task:HEGoTask)->Variant:
	while task.get_status()<HEGoTask.COMPLETED:await process_frame
	assert(task.get_status()==HEGoTask.COMPLETED,task.get_error_message())
	return task.get_result()
func run()->void:
	var api:=HEGoAPI.get_singleton();assert(api.start_session(HEGoAPI.SESSION_NAMED_PIPE,"graph_native_%d"%OS.get_process_id()))
	var input:=HEGoInputNode.new();await wait_task(input.instantiate())
	var points:=PackedVector3Array([Vector3.ZERO,Vector3.UP,Vector3.LEFT,Vector3.RIGHT])
	var edges:=PackedInt32Array([0,1,0,2,0,3]);var counts:=PackedInt32Array([2,2,2])
	var attrs:Array=[{"name":"radius","type":"point","values":PackedFloat32Array([.3,.1,.12,.15])},{"name":"tag","type":"prim","values":PackedInt32Array([7,11,13])}]
	await wait_task(input.set_geo(points,"polyline",edges,counts,attrs))
	var probe:=HEGoAssetNode.new();probe.op_name="Sop/attribwrangle";await wait_task(probe.instantiate());await wait_task(probe.set_parms_batch({"class":2,"snippet":"i@degree=neighbourcount(0,@ptnum);i@incident_sum=0;foreach(int p;pointprims(0,@ptnum))i@incident_sum+=prim(0,\"tag\",p);"}));await wait_task(probe.connect_input(input,0))
	var output:=HEGoAssetNode.new();output.op_name="Sop/add";await wait_task(output.instantiate());await wait_task(output.set_parm("keep",1));await wait_task(output.connect_input(probe,0));await wait_task(output.cook())
	var point_output:HEGoPointOutput=await wait_task(output.get_point_output(PackedStringArray(["radius","degree","P","incident_sum"])))
	print("GRAPH_NATIVE_ATTRIBUTES ",point_output.get_attribute("degree"),point_output.get_attribute("radius"))
	assert(point_output.get_point_count()==4,"Shared points must not be expanded or lost")
	var degrees:Array=point_output.get_attribute("degree");assert(degrees==[3,1,1,1])
	var radii:Array=point_output.get_attribute("radius");assert(is_equal_approx(radii[0],.3) and is_equal_approx(radii[3],.15))
	assert(point_output.get_attribute("incident_sum")==[31,7,11,13],"Connection attributes retain their primitive ownership")
	# Attribute-only edits must invalidate the upload cache independently for
	# point floats, primitive floats, strings and integer/toggle fields.
	attrs.append({"name":"name","type":"point","values":PackedStringArray(["hub","a","b","c"])})
	attrs.append({"name":"weight","type":"prim","values":PackedFloat32Array([1.,2.,3.])})
	attrs.append({"name":"edge_name","type":"prim","values":PackedStringArray(["a","b","c"])})
	await wait_task(probe.set_parm("snippet","i@degree=neighbourcount(0,@ptnum);i@incident_sum=0;f@weight_sum=0;s@edge_names='';foreach(int p;pointprims(0,@ptnum)){i@incident_sum+=prim(0,'tag',p);f@weight_sum+=prim(0,'weight',p);s@edge_names+=prim(0,'edge_name',p);}"))
	await wait_task(input.set_geo(points,"polyline",edges,counts,attrs))
	for edit in range(5):
		match edit:
			0: attrs[0].values=PackedFloat32Array([.8,.1,.12,.15])
			1: attrs[3].values=PackedFloat32Array([4.,2.,3.])
			2: attrs[2].values=PackedStringArray(["changed","a","b","c"])
			3: attrs[4].values=PackedStringArray(["changed","b","c"])
			4: attrs[1].values=PackedInt32Array([17,11,13])
		await wait_task(input.set_geo(points,"polyline",edges,counts,attrs))
		await wait_task(output.cook())
		point_output=await wait_task(output.get_point_output(PackedStringArray(["radius","weight_sum","name","edge_names","incident_sum"])))
		match edit:
			0: assert(is_equal_approx(point_output.get_attribute("radius")[0],.8),"Point float-only edits upload")
			1: assert(is_equal_approx(point_output.get_attribute("weight_sum")[0],9.),"Edge float-only edits upload")
			2: assert(point_output.get_attribute("name")[0]=="changed","Point string-only edits upload")
			3: assert(point_output.get_attribute("edge_names")[0].contains("changed"),"Edge string-only edits upload")
			4: assert(point_output.get_attribute("incident_sum")[0]==41,"Edge integer-only edits upload")
	# A repeated instantiate must retain the open-curve output node, then edits
	# must change that same graph without resetting the connection cache.
	var original_id:=input.get_id();await wait_task(input.instantiate());assert(input.get_id()==original_id)
	points[1]=Vector3.UP*2.;await wait_task(input.set_geo(points,"polyline",edges,counts,attrs));assert(input.get_id()==original_id)
	await wait_task(output.cook());point_output=await wait_task(output.get_point_output(PackedStringArray(["P","degree"])));print("GRAPH_NATIVE_UPDATED ",point_output.get_attribute("P"));assert(point_output.get_point_count()==4)
	assert(point_output.get_attribute("P")[1]==Vector3.UP*2. and point_output.get_attribute("degree")==[3,1,1,1])

	# Three vertices distinguish an open polyline from a closed polygon.
	var triple:=PackedVector3Array([Vector3.ZERO,Vector3.UP,Vector3.RIGHT])
	var order:=PackedInt32Array([0,1,2]);var one:=PackedInt32Array([3])
	await wait_task(input.set_geo(triple,"polyline",order,one,[]))
	await wait_task(output.cook())
	point_output=await wait_task(output.get_point_output(PackedStringArray(["degree"])))
	print("GRAPH_NATIVE_OPEN_DEGREES ",point_output.get_attribute("degree"));assert(point_output.get_attribute("degree")==[1,2,1],"Polyline endpoints must remain open")
	# Reusing an input for polygons must bypass the cached Ends node.
	await wait_task(input.set_geo(triple,"polygon",order,one,[]))
	assert(input.get_id()!=original_id)
	await wait_task(probe.connect_input(input,0));await wait_task(output.cook())
	point_output=await wait_task(output.get_point_output(PackedStringArray(["degree"])))
	assert(point_output.get_attribute("degree")==[2,2,2],"Polygon upload must remain closed")
	await wait_task(input.set_geo(triple,"polyline",order,one,[]))
	assert(input.get_id()==original_id)
	await wait_task(probe.connect_input(input,0));await wait_task(output.cook())
	point_output=await wait_task(output.get_point_output(PackedStringArray(["degree"])))
	assert(point_output.get_attribute("degree")==[1,2,1],"Returning to polylines reuses the open output")
	api.stop_session();print("HEGO_GRAPH_NATIVE_PASS");quit()
