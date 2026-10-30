extends SceneTree
var failures := 0
func _initialize(): call_deferred("run")
func check(value: bool, message: String):
	if not value: failures+=1; push_error(message)
func run():
	create_timer(60.0).timeout.connect(func(): push_error("Pool test watchdog");quit(1))
	var source:=StrataTerrain3D.new();source.base_bounds=Rect2(-128,-128,256,256);root.add_child(source)
	var renderer:=StrataRenderer.new();source.add_child(renderer)
	var camera:=Camera3D.new();root.add_child(camera);camera.position=Vector3(0,10,0)
	var image:=Image.create(257,257,false,Image.FORMAT_RF);image.fill(Color(5,0,0,1))
	var compiled:={"ok":true,"image":image,"bounds":source.base_bounds,"resolution":image.get_size(),"sample_step_x":Vector3.RIGHT,"min":0.0,"max":0.0}
	var materials:Array[StrataMaterial]=[StrataMaterial.new()]
	check(renderer.configure_compiled_field(source,materials,compiled),"Configure actual compiled renderer")
	renderer.set_camera(camera)
	for index in range(48):
		camera.position=Vector3(-120+((index*67)%240),10,-120+((index*113)%240));renderer.force_lod_update()
		check(renderer.get_child_count()==renderer._patches.size()+renderer._patch_pool.size() and renderer.get_child_count()<=renderer.get_patch_capacity(),"Active and pooled instances remain bounded")
		for pooled:MeshInstance3D in renderer._patch_pool: check(not pooled.visible,"Pooled patch is hidden")
		var plan:Array=renderer._select_patch_plan(source.base_bounds,Vector2(camera.position.x,camera.position.z))
		for leaf:Dictionary in plan:
			var p:Vector2i=leaf.lattice_origin
			var key:=Vector4i(p.x,p.y,leaf.lattice_span,leaf.lattice_units)
			var patch:MeshInstance3D=renderer._patches[key]
			check(patch.visible and patch.mesh==renderer._mesh_cache[Vector3(leaf.size,leaf.stitch_mask,renderer.cells_per_patch)],"Retained/reused patch has current stitched topology")
			check(patch.get_instance_shader_parameter("patch_uv_origin")==Vector2(p)/float(leaf.lattice_units),"Reused patch has current dyadic origin")
			check(patch.custom_aabb.has_point(Vector3(patch.get_meta("terrain_patch_bounds").get_center().x,5.0,patch.get_meta("terrain_patch_bounds").get_center().y)),"Bounds use validated RF extrema rather than caller's incorrect min/max")
	var instances:=renderer._patches.values();renderer.force_lod_update()
	check(renderer._patches.values()==instances and renderer.get_stats().last_patch_allocated==0 and renderer.get_stats().last_patch_mesh_changes==0,"Unchanged plan retains instances and does not rewrite mesh")
	source.base_bounds=Rect2(-124.75,-133.5,256,256);compiled.bounds=source.base_bounds
	check(renderer.set_compiled_field(compiled),"Accept translated field bounds with retained lattice keys")
	for patch:MeshInstance3D in renderer._patches.values():
		var uv:Vector2=patch.get_instance_shader_parameter("patch_uv_origin");var expected:=source.base_bounds.position+source.base_bounds.size*uv
		check(patch.get_meta("terrain_patch_bounds").position==expected,"Retained patch bounds invalidate when root field moves")
	renderer.cells_per_patch=16;check(renderer.force_lod_update(),"Patch cell setting invalidates cached topology")
	for patch:MeshInstance3D in renderer._patches.values(): check(patch.mesh.surface_get_array_len(0)==289,"Cell setting changes active mesh vertex resolution")
	camera.free();source.free()
	print("RENDERER_POOL_TEST failures=",failures)
	quit(0 if failures==0 else 1)
