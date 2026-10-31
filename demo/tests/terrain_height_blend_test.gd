extends SceneTree
var failures:=0
var output:="/tmp/hego-terrain-prototype/height-blend-fixtures"
func _initialize():call_deferred("run")
func check(condition:bool,message:String):
	if not condition:failures+=1;push_error(message)
func close4(a:Vector4,b:Vector4,tolerance:=0.00001)->bool:return (a-b).length()<tolerance
func run():
	create_timer(90.0).timeout.connect(func():push_error("Height blend watchdog");quit(1))
	DirAccess.make_dir_recursive_absolute(output)
	test_cpu()
	if RenderingServer.get_rendering_device()==null:push_error("Use graphical Forward+");quit(2);return
	await test_gpu_kernel()
	await test_spatial()
	print("TERRAIN_HEIGHT_BLEND_TEST failures=",failures)
	quit(0 if failures==0 else 1)
func draw(count:=3):
	for i in range(count):await process_frame
	await RenderingServer.frame_post_draw
func finite_weights(value:Vector4)->bool:
	return value.is_finite() and minf(minf(value.x,value.y),minf(value.z,value.w))>=0 and absf(value.x+value.y+value.z+value.w-1.0)<0.00001
func reference(w:Vector4,h:Vector4,c:Vector4,b:Vector4=Vector4.ZERO,enabled:=true)->Vector4:
	return StrataRenderer.height_blend_weights(w,h,c,b,enabled)
func test_cpu():
	var w:=Vector4(0.2,0.3,0.1,0.4);var h:=Vector4(0.9,0.3,0.1,0.7);var c:=Vector4(12,2,1,0)
	check(reference(w,h,c,Vector4.ZERO,false)==w,"Disabled weights are exact identity")
	check(reference(w,h,Vector4.ZERO,Vector4.ONE*0.4)==w,"Zero contrast is exact identity despite bias")
	check(reference(Vector4(1,0,0,0),h,c)==Vector4(1,0,0,0),"Single material is unchanged")
	var zero:=reference(Vector4(0,0.5,0.5,0),h,Vector4.ONE*16,Vector4.ONE*0.5)
	check(zero.x==0 and zero.w==0 and finite_weights(zero),"Unpainted slots cannot resurrect")
	var peak:=reference(Vector4(0.2,0.8,0,0),Vector4(0.9,0.3,0,0),Vector4(12,2,0,0))
	var valley:=reference(Vector4(0.2,0.8,0,0),Vector4(0.1,0.3,0,0),Vector4(12,2,0,0))
	check(peak.x>0.8 and valley.x<0.02,"Rock height peaks emerge while valleys reveal softer material")
	check(close4(reference(Vector4(.5,.5,0,0),Vector4(1.2,-.2,0,0),Vector4(2,2,0,0),Vector4(-.5,.5,0,0)),reference(Vector4(.5,.5,0,0),Vector4(.7,.3,0,0),Vector4(2,2,0,0))),"Bias is applied before final height clamping")
	var original:=reference(w,h,c)
	var perm:=reference(Vector4(w.z,w.x,w.w,w.y),Vector4(h.z,h.x,h.w,h.y),Vector4(c.z,c.x,c.w,c.y))
	check(close4(original,Vector4(perm.y,perm.w,perm.x,perm.z)),"Slot permutation preserves by-material mixture")
	var duplicate:=reference(Vector4(0.1,0.2,0.3,0.4),Vector4(0.9,0.9,0.2,0.5),Vector4(12,12,2,1))
	var merged:=reference(Vector4(0.3,0.3,0.4,0),Vector4(0.9,0.2,0.5,0),Vector4(12,2,1,0))
	check(close4(Vector4(duplicate.x+duplicate.y,duplicate.z,duplicate.w,0),merged),"Duplicate material contributions equal the merged ID")
	check(finite_weights(reference(w,Vector4(NAN,INF,-INF,0.5),c)),"Nonfinite alpha is neutral and weights remain finite")
	for i in range(21):
		var t:=float(i)/20.0;var value:=reference(Vector4(t,1-t,0,0),Vector4(0.9,0.2,0,0),Vector4(16,16,0,0),Vector4(0.5,-0.5,0,0))
		check(finite_weights(value),"Extreme valid contrast/bias remains normalized")

func test_gpu_kernel():
	var viewport:=SubViewport.new();viewport.size=Vector2i(2,2);viewport.use_hdr_2d=true;viewport.transparent_bg=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var shader:=Shader.new();shader.code="""shader_type canvas_item;
render_mode unshaded,blend_disabled;
uniform bool height_blend_enabled=true;
uniform vec4 probe_painted;
uniform vec4 probe_heights;
uniform vec4 probe_contrasts;
uniform vec4 probe_biases;
"""+FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_height_blend.gdshaderinc")+"""
void fragment(){COLOR=terrain_height_blend_weights(probe_painted,probe_heights,probe_contrasts,probe_biases);}
"""
	var m:=ShaderMaterial.new();m.shader=shader;var rect:=ColorRect.new();rect.size=Vector2(2,2);rect.material=m;viewport.add_child(rect)
	var cases:=[
		[Vector4(.2,.3,.1,.4),Vector4(.9,.3,.1,.7),Vector4(12,2,1,0),Vector4.ZERO,false],
		[Vector4(.2,.3,.1,.4),Vector4(.9,.3,.1,.7),Vector4.ZERO,Vector4.ONE*.4,true],
		[Vector4(.2,.3,.1,.4),Vector4(.9,.3,.1,.7),Vector4(12,2,1,0),Vector4.ZERO,true],
		[Vector4(.1,.2,.3,.4),Vector4(.9,.9,.2,.5),Vector4(12,12,2,1),Vector4.ZERO,true],
		[Vector4(0,.5,.5,0),Vector4(1,0,1,1),Vector4.ONE*16,Vector4.ONE*.5,true],
		[Vector4(1,0,0,0),Vector4(.9,.3,.1,.7),Vector4.ONE*16,Vector4.ONE*.5,true],
		[Vector4(.2,.3,.1,.4),Vector4(NAN,INF,-INF,.5),Vector4(12,2,1,0),Vector4.ZERO,true]]
	var identities:Array[PackedByteArray]=[]
	for fixture:Array in cases:
		m.set_shader_parameter("probe_painted",fixture[0]);m.set_shader_parameter("probe_heights",fixture[1]);m.set_shader_parameter("probe_contrasts",fixture[2]);m.set_shader_parameter("probe_biases",fixture[3]);m.set_shader_parameter("height_blend_enabled",fixture[4]);await draw()
		var image:=viewport.get_texture().get_image();var pixel:=image.get_pixel(0,0);var actual:=Vector4(pixel.r,pixel.g,pixel.b,pixel.a)
		check(close4(actual,reference(fixture[0],fixture[1],fixture[2],fixture[3],fixture[4]),0.0015),"GPU shared kernel matches CPU normalized reference")
		if identities.size()<2:identities.append(image.get_data())
	check(identities[0]==identities[1],"GPU disabled and zero-influence identity are byte-exact")
	viewport.free()
func texture(color:Color)->ImageTexture:
	var image:=Image.create(2,2,false,Image.FORMAT_RGBAF);image.fill(color);return ImageTexture.create_from_image(image)
func shader_override(tail:String)->Shader:
	var code:=(load("res://addons/strata/shaders/terrain_surface.gdshader") as Shader).code
	for name in ["terrain_regions.gdshaderinc", "terrain_controls.gdshaderinc","terrain_texture_dispatch.gdshaderinc","terrain_normals.gdshaderinc","terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:code=code.replace('#include "'+name+'"',FileAccess.get_file_as_string("res://addons/strata/shaders/"+name))
	var end:=code.rfind("}");var shader:=Shader.new();shader.code=code.substr(0,end)+tail+code.substr(end);return shader
func linear_pixel()->Vector3:
	var c:=root.get_texture().get_image().get_pixelv(root.size/2).srgb_to_linear();return Vector3(c.r,c.g,c.b)
func test_spatial():
	var world:=Node3D.new();root.add_child(world)
	var source:=StrataTerrain3D.new();source.base_bounds=Rect2(-8,-8,16,16);world.add_child(source)
	var renderer:=StrataRenderer.new();source.add_child(renderer)
	var rock:=StrataMaterial.new();rock.color_texture=texture(Color(1,0,0));rock.normal_texture=texture(Color(.8,.5,1));rock.ormh_texture=texture(Color(.2,.3,.1,.9));rock.height_blend_contrast=12;rock.height_blend_bias=.1;rock.displacement_strength=1.5
	var grass:=StrataMaterial.new();grass.color_texture=texture(Color(0,1,0));grass.normal_texture=texture(Color(.5,.5,1));grass.ormh_texture=texture(Color(.9,.9,0,.2));grass.height_blend_contrast=2;grass.height_blend_bias=.18;grass.displacement_strength=.4
	var pool:Array[StrataMaterial]=[rock,grass];var image:=Image.create(17,17,false,Image.FORMAT_RF)
	check(renderer.configure_compiled_field(source,pool,{"ok":true,"image":image,"bounds":source.base_bounds,"resolution":image.get_size(),"sample_step_x":Vector3.RIGHT,"min":0.0,"max":0.0}),"Production material shader configures")
	var ids:=Image.create(2,2,false,Image.FORMAT_RGBA8);ids.fill(Color(0,1.0/255.0,0,0));var weights:=Image.create(2,2,false,Image.FORMAT_RGBAF);weights.fill(Color(.25,.75,0,0));check(renderer.set_control_maps(ids,weights),"Set two-material categorical controls")
	var camera:=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=8;camera.position=Vector3(0,20,0);world.add_child(camera);camera.look_at(Vector3.ZERO,Vector3.FORWARD);camera.current=true;renderer.set_camera(camera)
	var env:=WorldEnvironment.new();env.environment=Environment.new();env.environment.background_mode=Environment.BG_COLOR;env.environment.background_color=Color.BLACK;world.add_child(env)
	var final_weights:=reference(Vector4(.25,.75,0,0),Vector4(.9,.2,0,0),Vector4(12,2,0,0),Vector4(.1,.18,0,0))
	for family in ["color","orm","normal","displacement"]:
		var tail:="ALBEDO=vec3(0.0);ROUGHNESS=1.0;METALLIC=0.0;AO=1.0;"
		var expected:=Vector3.ZERO
		match family:
			"color":tail+="EMISSION=color;";expected=Vector3(final_weights.x,final_weights.y,0)
			"orm":tail+="EMISSION=orm;";expected=Vector3(.2,.3,.1)*final_weights.x+Vector3(.9,.9,0)*final_weights.y
			"normal":
				tail+="EMISSION=final_normal*.5+.5;"
				var n:Vector3=(Vector3(.6,.8,0)*final_weights.x+Vector3(0,1,0)*final_weights.y).normalized();expected=n*.5+Vector3.ONE*.5
			"displacement":
				tail+="EMISSION=vec3((INV_VIEW_MATRIX*vec4(VERTEX,1.0)).y+.5);"
				var fade:=1.0-smoothstep(32.0*.55,32.0,20.0);var h:float=(.4*1.5*final_weights.x-.3*.4*final_weights.y)*.2*fade;expected=Vector3.ONE*(h+.5)
		renderer._shader_material.shader=shader_override(tail);await draw(6)
		var actual:=linear_pixel();print("HEIGHT_BLEND_FAMILY ",family," actual=",actual," expected=",expected)
		check(actual.distance_to(expected)<.018,"Production "+family+" uses the final height weights")
	var base_before:=renderer._height_image.get_data();check(renderer.sample_render_height(Vector2.ZERO)==0.0,"Visual material displacement does not change base query")
	var base_hit:=renderer.raycast_heightfield(Vector3(0,20,0),Vector3.DOWN);check(not base_hit.is_empty() and absf(base_hit.position.y)<.001,"Base brush ray remains unchanged")
	var updates:=int(renderer.get_stats().get("material_binding_updates",0));rock.height_blend_contrast=8;rock.height_blend_bias=.15;grass.height_blend_contrast=3;await draw()
	var values:PackedFloat32Array=renderer._shader_material.get_shader_parameter("height_blend_contrasts");var biases:PackedFloat32Array=renderer._shader_material.get_shader_parameter("height_blend_biases")
	check(values[0]==8 and values[1]==3 and absf(biases[0]-.15)<.00001,"Material edits refresh uniform arrays")
	check(int(renderer.get_stats().get("material_binding_updates",0))==updates+1,"Material edit burst is coalesced to one binding refresh")
	check(renderer._height_image.get_data()==base_before,"Material updates preserve heightfield bytes")
	# Single-material bias cannot act as a physical displacement offset.
	weights.fill(Color(1,0,0,0));renderer.set_control_maps(ids,weights);rock.height_blend_bias=-.5;await draw();var low:=linear_pixel();rock.height_blend_bias=.5;await draw();check(linear_pixel().distance_to(low)<.002,"Height bias never offsets raw displacement")
	world.free()
