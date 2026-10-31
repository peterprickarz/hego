extends SceneTree
## Graphical Forward+ shading tests. No authoring data/collision is modified.
var failures := 0
var output := "/tmp/hego-terrain-prototype/smooth-shading"
var renderer: StrataRenderer
var source: StrataTerrain3D
var camera: Camera3D
var world: Node3D
var material: StrataMaterial

func _initialize(): call_deferred("run")
func check(value: bool, message: String):
	if not value: failures += 1; push_error(message)
func run():
	create_timer(120.0).timeout.connect(func(): push_error("Shading test watchdog expired"); quit(1))
	if RenderingServer.get_rendering_device() == null: push_error("Use a real graphical Forward+ device"); quit(2); return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output = argument.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(output)
	print("SHADING_GPU ",RenderingServer.get_video_adapter_name()," ",RenderingServer.get_video_adapter_api_version())
	await test_gradients()
	await test_spatial()
	print("TERRAIN_SHADING_TEST failures=",failures)
	quit(0 if failures==0 else 1)

func frame(count := 3):
	for index in range(count): await process_frame
	await RenderingServer.frame_post_draw

func test_gradients():
	var viewport := SubViewport.new(); viewport.size=Vector2i(64,1); viewport.use_hdr_2d=true;viewport.transparent_bg=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var shader:=Shader.new(); shader.code="""#define HEGO_TERRAIN_CREASES
shader_type canvas_item;
render_mode unshaded,blend_disabled;
uniform sampler2D height_field : filter_linear,repeat_disable;
uniform vec2 field_origin;
uniform vec2 field_size;
uniform vec2 probes[64];
uniform float crease_cosine=-1.0;
vec2 terrain_lattice_step(){return field_size/vec2(textureSize(height_field,0)-ivec2(1));}
ivec2 terrain_lattice_max(){return textureSize(height_field,0)-ivec2(1);}
float terrain_texel_height(ivec2 index){return texelFetch(height_field,index,0).r;}
float terrain_linear_height(vec2 position){vec2 d=vec2(textureSize(height_field,0));vec2 l=clamp((position-field_origin)/field_size,vec2(0.0),vec2(1.0));return textureLod(height_field,(l*(d-vec2(1.0))+vec2(0.5))/d,0.0).r;}
"""+FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_normals.gdshaderinc")+"""
void fragment(){vec2 p=probes[int(FRAGCOORD.x)];vec2 g=terrain_smooth_gradient(p);vec3 n=crease_cosine>-0.999999?terrain_crease_normal(p,crease_cosine):normalize(vec3(-g.x,1.0,-g.y));COLOR=vec4(n*0.5+0.5,1.0);}
"""
	var m:=ShaderMaterial.new();m.shader=shader
	var rect:=ColorRect.new();rect.size=Vector2(64,1);rect.material=m;viewport.add_child(rect)
	var bounds:=Rect2(-3.25,2.5,20,12)
	var image:=Image.create(11,7,false,Image.FORMAT_RF)
	for z in range(7):
		for x in range(11):
			var p:=bounds.position+Vector2(x,z)*2.0
			image.set_pixel(x,z,Color(0.2*p.x-0.4*p.y+3.0,0,0,1))
	var probes:=PackedVector2Array()
	for i in range(64): probes.append(bounds.position+bounds.size*Vector2(float(i%8)/7.0,float(i/8)/7.0))
	m.set_shader_parameter("height_field",ImageTexture.create_from_image(image));m.set_shader_parameter("field_origin",bounds.position);m.set_shader_parameter("field_size",bounds.size);m.set_shader_parameter("probes",probes)
	await frame()
	var pixels:=viewport.get_texture().get_image();var expected:=Vector3(-0.2,1.0,0.4).normalized()
	for i in range(64):
		var c:=pixels.get_pixel(i,0);var n:=Vector3(c.r,c.g,c.b)*2.0-Vector3.ONE
		check(n.distance_to(expected)<0.003,"GPU plane normal preserves physical sample spacing, including outer edges")
	# Bilinear saddle: canonical triangle derivatives have a diagonal jump,
	# while the shared smooth derivative is continuous across that same edge.
	bounds=Rect2(0,0,4,4);image=Image.create(5,5,false,Image.FORMAT_RF)
	for z in range(5):
		for x in range(5): image.set_pixel(x,z,Color(float(x*z)*0.4,0,0,1))
	probes.clear()
	for p in [Vector2(1.4,1.5999),Vector2(1.4,1.6001),Vector2(1.9999,1.4),Vector2(2.0001,1.4),Vector2(1.4,1.9999),Vector2(1.4,2.0001)]: probes.append(p)
	while probes.size()<64:probes.append(Vector2(1.4,1.6))
	m.set_shader_parameter("height_field",ImageTexture.create_from_image(image));m.set_shader_parameter("field_origin",bounds.position);m.set_shader_parameter("field_size",bounds.size);m.set_shader_parameter("probes",probes)
	await frame();pixels=viewport.get_texture().get_image()
	for i in range(0,6,2):
		var a:=pixels.get_pixel(i,0);var b:=pixels.get_pixel(i+1,0)
		check(Vector3(a.r,a.g,a.b).distance_to(Vector3(b.r,b.g,b.b))<0.001,"GPU normal is continuous across sample-cell and triangle-diagonal boundaries")
	for i in range(6):
		var p:=probes[i];var c:=pixels.get_pixel(i,0);var n:=Vector3(c.r,c.g,c.b)*2.0-Vector3.ONE
		check(n.distance_to(Vector3(-0.4*p.y,1.0,-0.4*p.x).normalized())<0.003,"GPU shared normal matches analytic saddle gradient")
	# A true 90-degree ridge retains its separate smoothing groups at 30 degrees.
	for z in range(5):
		for x in range(5): image.set_pixel(x,z,Color(absf(float(x)-2.0),0,0,1))
	probes[0]=Vector2(1.9999,2.4);probes[1]=Vector2(2.0001,2.4)
	m.set_shader_parameter("height_field",ImageTexture.create_from_image(image));m.set_shader_parameter("probes",probes);m.set_shader_parameter("crease_cosine",cos(deg_to_rad(30.0)))
	await frame();pixels=viewport.get_texture().get_image()
	var left:=pixels.get_pixel(0,0);var right:=pixels.get_pixel(1,0)
	var nl:=Vector3(left.r,left.g,left.b)*2.0-Vector3.ONE;var nr:=Vector3(right.r,right.g,right.b)*2.0-Vector3.ONE
	check(nl.distance_to(Vector3(1,1,0).normalized())<0.004 and nr.distance_to(Vector3(-1,1,0).normalized())<0.004,"Crease angle preserves the actual adjacent-face ridge discontinuity")
	m.set_shader_parameter("crease_cosine",cos(deg_to_rad(120.0)));await frame();pixels=viewport.get_texture().get_image();left=pixels.get_pixel(0,0);right=pixels.get_pixel(1,0)
	check(Vector3(left.r,left.g,left.b).distance_to(Vector3(right.r,right.g,right.b))<0.002,"Crease angle above the dihedral joins the smoothing groups")
	# Absolute steepness is irrelevant: all triangles of this steep plane join.
	for z in range(5):
		for x in range(5): image.set_pixel(x,z,Color(4.0*x+7.0*z,0,0,1))
	m.set_shader_parameter("height_field",ImageTexture.create_from_image(image));m.set_shader_parameter("crease_cosine",cos(deg_to_rad(5.0)));await frame();pixels=viewport.get_texture().get_image()
	for i in range(64):
		var c:=pixels.get_pixel(i,0);var n:=Vector3(c.r,c.g,c.b)*2.0-Vector3.ONE
		check(n.distance_to(Vector3(-4,1,-7).normalized())<0.004,"Steep planar slope is not treated as an angular crease")
	viewport.free()

func field(bounds:Rect2,plane:bool=false)->Dictionary:
	var image:=Image.create(65,65,false,Image.FORMAT_RF);var minimum:=INF;var maximum:=-INF
	for z in range(65):
		for x in range(65):
			var p:=bounds.position+Vector2(x,z)*2.0
			var h:=0.2*p.x-0.4*p.y+3.0 if plane else 9.0*cos(p.x*0.13)*sin(p.y*0.11)+2.0*cos((p.x+p.y)*0.21)+0.03*p.x
			image.set_pixel(x,z,Color(h,0,0,1));minimum=minf(minimum,h);maximum=maxf(maximum,h)
	return {"ok":true,"image":image,"bounds":bounds,"resolution":image.get_size(),"sample_step_x":Vector3(2,0,0),"min":minimum,"max":maximum}

func expanded_shader()->String:
	var code:=FileAccess.get_file_as_string("res://addons/strata/shaders/terrain_surface.gdshader")
	for name in ["terrain_regions.gdshaderinc", "terrain_controls.gdshaderinc","terrain_texture_dispatch.gdshaderinc","terrain_normals.gdshaderinc","terrain_height_blend.gdshaderinc", "terrain_triplanar.gdshaderinc"]:code=code.replace('#include "'+name+'"',FileAccess.get_file_as_string("res://addons/strata/shaders/"+name))
	return code

func test_spatial():
	world=Node3D.new();root.add_child(world)
	source=StrataTerrain3D.new();source.base_bounds=Rect2(-64,-64,128,128);world.add_child(source)
	renderer=StrataRenderer.new();source.add_child(renderer)
	material=StrataMaterial.new();material.color_texture=StrataRenderer._solid_texture(Color(0.4,0.4,0.4));material.normal_texture=StrataRenderer._solid_texture(Color(0.5,0.5,1));material.ormh_texture=StrataRenderer._solid_texture(Color(1,0.95,0,0.5))
	var pool:Array[StrataMaterial]=[material]
	check(renderer.smooth_shading and renderer.crease_angle_degrees==180.0,"Smooth shading without creases is the renderer default")
	check(renderer.configure_compiled_field(source,pool,field(source.base_bounds)),"Configure real native-patch spatial shader")
	camera=Camera3D.new();camera.fov=54.0;camera.far=1000.0;world.add_child(camera);camera.current=true;camera.position=Vector3(94,58,88);camera.look_at(Vector3.ZERO)
	renderer.set_camera(camera);renderer.displacement_enabled=false
	var environment:=WorldEnvironment.new();environment.environment=Environment.new();environment.environment.background_mode=Environment.BG_COLOR;environment.environment.background_color=Color(0.08,0.09,0.1);environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;environment.environment.ambient_light_color=Color.WHITE;environment.environment.ambient_light_energy=0.1;world.add_child(environment)
	var sun:=DirectionalLight3D.new();sun.rotation_degrees=Vector3(-35,-40,0);sun.light_energy=1.0;sun.shadow_enabled=false;world.add_child(sun)
	var default_shader:=renderer._shader_material.shader
	var saved_bindings:Dictionary={}
	for name in ["height_regions","material_ids_regions","material_weights_regions","region_table","normal_maps","color_maps","ormh_maps"]:saved_bindings[name]=renderer._shader_material.get_shader_parameter(name)
	renderer.crease_angle_degrees=30.0
	var crease_shader:=renderer._shader_material.shader
	check(crease_shader!=default_shader and crease_shader.code.begins_with("#define HEGO_TERRAIN_CREASES"),"Crease code uses a separate compile-time shader variant")
	check(renderer._shader_material.get_shader_parameter("height_regions")==saved_bindings.height_regions,"Variant switch preserves field texture binding")
	renderer.smooth_shading=false;check(renderer._shader_material.shader==default_shader,"Compatibility mode does not carry crease shader code")
	renderer.smooth_shading=true;check(renderer._shader_material.shader==crease_shader,"Explicit variant toggle reuses the cached crease shader")
	renderer.crease_angle_degrees=180.0;check(renderer._shader_material.shader==default_shader,"180 degree default restores the fast shader resource")
	for name in saved_bindings:check(renderer._shader_material.get_shader_parameter(name)==saved_bindings[name],"Variant roundtrip preserves "+name+" bindings")
	var meshes:=[];for p in renderer._patches.values():meshes.append(p.mesh)
	var original_bytes:=renderer._height_image.get_data();var camera_pose:=camera.global_transform
	for normal_view in [false,true]:
		renderer.debug_shading_normals=normal_view
		for smooth in [false,true]:
			renderer.smooth_shading=smooth;await frame(8)
			var label:="smooth" if smooth else "legacy"
			root.get_texture().get_image().save_png(output+"/fixture_"+label+("_normals.png" if normal_view else "_lit.png"))
	check(camera.global_transform==camera_pose and renderer._height_image.get_data()==original_bytes,"Shading controls preserve camera and RF geometry bytes")
	var after_meshes:=[];for p in renderer._patches.values():after_meshes.append(p.mesh)
	check(meshes==after_meshes,"Shading controls retain native meshes and LOD partition")
	# Same orthographic view and RF field, different actual quadtree leaf sets:
	# normals must not inherit mesh-face/patch/LOD interpolation boundaries.
	sun.visible=false;environment.environment.ambient_light_energy=0.0
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=120.0;camera.position=Vector3(0,200,0);camera.look_at(Vector3.ZERO,Vector3.FORWARD)
	var lod_camera:=Camera3D.new();world.add_child(lod_camera)
	var lod_images:Array[Image]=[];var lod_counts:Array[int]=[]
	for position in [Vector3(0,20,0),Vector3(10000,20,10000)]:
		lod_camera.position=position;renderer.set_camera(lod_camera);renderer.smooth_shading=true;renderer.debug_shading_normals=true
		await frame(6);lod_images.append(root.get_texture().get_image());lod_counts.append(int(renderer.get_stats().patches))
	var maximum_difference:=0.0
	for z in range(160,900,4):
		for x in range(500,1420,4):
			var a:=lod_images[0].get_pixel(x,z);var b:=lod_images[1].get_pixel(x,z)
			maximum_difference=maxf(maximum_difference,maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b))))
	print("NORMAL_LOD_CONTINUITY patches=",lod_counts," max_rgb_difference=",maximum_difference)
	check(lod_counts[0]!=lod_counts[1] and maximum_difference<0.015,"Full spatial smooth normals remain stable across actual patch/LOD changes")
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE;camera.global_transform=camera_pose;renderer.set_camera(camera);lod_camera.free()
	# A constant unshaded silhouette must be pixel-identical in both modes.
	var shader:=Shader.new();var code:=expanded_shader().replace("render_mode cull_back,","render_mode unshaded, cull_back,")
	var end:=code.rfind("}");shader.code=code.substr(0,end)+"ALBEDO=vec3(1.0);EMISSION=vec3(0.0);"+code.substr(end)
	renderer._shader_material.shader=shader;renderer.debug_shading_normals=false
	var silhouettes:Array[PackedByteArray]=[]
	for smooth in [false,true]:renderer.smooth_shading=smooth;await frame(6);silhouettes.append(root.get_texture().get_image().get_data())
	renderer.crease_angle_degrees=30.0;renderer._shader_material.shader=shader;await frame(6);silhouettes.append(root.get_texture().get_image().get_data());renderer.crease_angle_degrees=180.0
	check(silhouettes[0]==silhouettes[1] and silhouettes[1]==silhouettes[2],"Smooth shading leaves actual rendered silhouette/coverage unchanged")
	# Read the full spatial shader's final view normal on a plane with a known
	# tangent-space map, before and after translation+yaw. This includes the
	# production normal-map blend and VIEW*MODEL transform.
	check(renderer.set_compiled_field(field(source.base_bounds,true)),"Set planar spatial normal fixture")
	material.normal_texture=StrataRenderer._solid_texture(Color(0.7,0.4,1));material.triplanar_sharpness=64.0;renderer._bind_material_pool()
	sun.visible=false;environment.environment.ambient_light_energy=0.0
	shader=Shader.new();code=expanded_shader();end=code.rfind("}");shader.code=code.substr(0,end)+"ALBEDO=vec3(0.0);EMISSION=NORMAL*0.5+0.5;"+code.substr(end);renderer._shader_material.shader=shader;renderer.smooth_shading=true
	# On this shallow plane sharpness 64 selects the top frame. OpenGL green
	# points toward image up (-Z); RNM rotates detail by the shortest arc Y->base.
	var gradient:=Vector2(0.2,-0.4);var base:=Vector3(-gradient.x,1,-gradient.y).normalized()
	var detail:=Vector3(0.4,sqrt(0.8),0.2);var arc:=Vector3.UP.cross(base)
	var expected_local:Vector3=(detail+arc.cross(detail)+arc.cross(arc.cross(detail))/(1.0+Vector3.UP.dot(base))).normalized()
	for yaw in [0.0,0.645771823]:
		source.transform=Transform3D(Basis(Vector3.UP,yaw),Vector3(40,20,-75))
		camera.global_position=source.to_global(Vector3(0,80,70));camera.look_at(source.to_global(Vector3(0,3,0)))
		renderer.force_lod_update();await frame(8)
		var expected_view:Vector3=camera.global_basis.inverse()*source.global_basis*expected_local
		var linear:=Color(expected_view.x*0.5+0.5,expected_view.y*0.5+0.5,expected_view.z*0.5+0.5,1);var srgb:=linear.linear_to_srgb();var read:=root.get_texture().get_image().get_pixelv(root.size/2)
		var actual:=Vector3(read.r,read.g,read.b)
		print("SPATIAL_NORMAL yaw=",yaw," actual=",actual," expected_linear=",linear," expected_srgb=",srgb)
		check(minf(actual.distance_to(Vector3(linear.r,linear.g,linear.b)),actual.distance_to(Vector3(srgb.r,srgb.g,srgb.b)))<0.035,"Full spatial shader preserves mapped normal detail and yaw/translation transform")
	world.free()
