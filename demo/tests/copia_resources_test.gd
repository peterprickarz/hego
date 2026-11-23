## Copia resource classes: descriptor keys and types, mesh-path resolution, overridable hooks,
## which changes emit build_inputs_changed (the impostor batch size among them), the shapes each
## physics kind resolves to, and the per-surface materials (RIDs for single instances, a cached
## mesh copy for batches) and impostor draw params.
## Headless; needs no native library and no scene. Writes one mesh under user://.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_resources_test.gd
##
## Prints COPIA_RESOURCES_TEST PASS or FAIL and exits 0 or 1. Run time: well under 1 s.
extends SceneTree

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const RenderScript := preload("res://addons/copia/copia_render_settings.gd")
const PhysicsScript := preload("res://addons/copia/copia_physics_settings.gd")

var failures: Array[String] = []
var scratch := "user://copia_resources_test_%d" % OS.get_process_id()


## A subclass defined inline, as a game would extend the class.
class TintedObject extends "res://addons/copia/copia_object.gd":
	func _get_default_color() -> Color:
		return Color(0.25, 0.5, 0.75, 0.5)

	func _get_default_custom() -> Color:
		return Color(1, 2, 3, 4)

	func _get_draw_params() -> Dictionary:
		var params := super._get_draw_params()
		params["tag"] = "tinted"
		return params


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, description: String) -> void:
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)


## Counts the emissions of both signals while a callable changes the resource.
func signals_of(resource: Resource, change: Callable) -> Dictionary:
	var counts := {"changed": 0, "build": 0}
	var on_changed := func(): counts.changed += 1
	var on_build := func(): counts.build += 1
	resource.changed.connect(on_changed)
	resource.build_inputs_changed.connect(on_build)
	change.call()
	resource.changed.disconnect(on_changed)
	resource.build_inputs_changed.disconnect(on_build)
	return counts


func expect_build(resource: Resource, description: String, change: Callable) -> void:
	var counts := signals_of(resource, change)
	check(counts.build == 1 and counts.changed >= 1, "%s emits build_inputs_changed and changed (%s)" % [description, counts])


func expect_no_build(resource: Resource, description: String, change: Callable) -> void:
	var counts := signals_of(resource, change)
	check(counts.build == 0 and counts.changed >= 1, "%s emits changed only (%s)" % [description, counts])


func offset_box() -> ArrayMesh:
	# 2 x 4 x 2, centred on (0, 3, 0): bounds from y = 1 to y = 5.
	var box := BoxMesh.new()
	box.size = Vector3(2, 4, 2)
	var arrays := box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i] += Vector3(0, 3, 0)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Per-surface materials: RIDs for single instances, a cached mesh copy carrying them for batches,
## nothing with a material override; the hook supplies them; impostor params.
func test_surface_materials() -> void:
	var two := ArrayMesh.new()
	var box := BoxMesh.new()
	var own := StandardMaterial3D.new()
	for s in 2:
		two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
		two.surface_set_material(s, own)
	var red := StandardMaterial3D.new()
	var object = ObjectScript.new()
	object.mesh = two
	object.render = RenderScript.new()
	object.render.draw_mode = RenderScript.DrawMode.INSTANCE
	var params: Dictionary = object._get_draw_params()
	check(params.surface_materials == [] and params.mesh == two.get_rid() and params.impostor_min_scale == 0.0, "no surface materials by default")
	check(object.get_surface_material_mesh() == two, "without surface materials the material mesh is the mesh")
	var counts := signals_of(object, func() -> void: object.surface_materials = [null, red] as Array[Material])
	check(counts.changed >= 1 and counts.build == 0, "surface_materials emits changed only (%s)" % counts)
	params = object._get_draw_params()
	check(params.surface_materials == [RID(), red.get_rid()] and params.mesh == two.get_rid(), "instance mode: one RID per surface, empty for the mesh's own (%s)" % [params.surface_materials])
	object.render.draw_mode = RenderScript.DrawMode.MULTIMESH
	params = object._get_draw_params()
	var copy: Mesh = object.get_surface_material_mesh()
	check(params.surface_materials == [] and params.mesh == copy.get_rid() and copy != two, "multimesh mode: a mesh copy instead of per-surface RIDs")
	check(copy.surface_get_material(0) == own and copy.surface_get_material(1) == red and two.surface_get_material(1) == own, "the copy carries the materials; the mesh is unchanged")
	check(copy.get_aabb() == two.get_aabb() and copy.get_surface_count() == 2, "the copy has the mesh's surfaces and bounds")
	check(object.get_surface_material_mesh() == copy, "the copy is cached")
	object.surface_materials = [red, red] as Array[Material]
	var second: Mesh = object.get_surface_material_mesh()
	check(second != copy and second.surface_get_material(0) == red, "changed materials make a new copy")
	var primitive = ObjectScript.new()
	primitive.mesh = BoxMesh.new()
	primitive.surface_materials = [red] as Array[Material]
	var primitive_copy: Mesh = primitive.get_surface_material_mesh()
	check(primitive_copy is ArrayMesh and primitive_copy.surface_get_material(0) == red and primitive_copy.get_surface_count() == 1, "a primitive mesh becomes an ArrayMesh copy")
	object.material_override = red
	params = object._get_draw_params()
	check(params.surface_materials == [] and params.mesh == two.get_rid() and object.get_surface_material_mesh() == two, "material_override wins over surface materials")
	object.material_override = null
	# The hook supplies materials at load without saving them.
	var hooked = SurfaceHookObject.new()
	hooked.mesh = two
	hooked.render = RenderScript.new()
	hooked.render.draw_mode = RenderScript.DrawMode.INSTANCE
	hooked.supplied = red
	params = hooked._get_draw_params()
	check(params.surface_materials == [red.get_rid(), red.get_rid()], "_get_surface_materials supplies them (%s)" % [params.surface_materials])
	# Impostor params.
	var impostor_material := StandardMaterial3D.new()
	object.impostor_mesh = QuadMesh.new()
	object.impostor_material = impostor_material
	object.impostor_min_scale = 0.6
	object.render.impostor_range_end = 900.0
	object.render.visibility_range_begin = 3.0
	object.render.fade_mode = RenderScript.FadeMode.SELF
	params = object._get_draw_params()
	check(params.impostor_min_scale == 0.6, "draw params carry the impostor min scale")
	var far: Dictionary = object._get_impostor_draw_params()
	check(far.mesh == object.impostor_mesh.get_rid() and far.material_override == impostor_material.get_rid() and far.surface_materials == [], "impostor params: impostor mesh and material, no surface materials")
	check(far.visibility_begin == 0.0 and far.visibility_end == 900.0 and far.fade_mode == RenderingServer.VISIBILITY_RANGE_FADE_DISABLED and not far.low_lod_shadows and far.impostor_min_scale == 0.0, "impostor params: range 0 to the impostor range, no fade")


## Supplies one material for every surface, as a game's subclass would at load.
class SurfaceHookObject extends "res://addons/copia/copia_object.gd":
	var supplied: Material

	func _get_surface_materials() -> Array[Material]:
		var result: Array[Material] = []
		for s in mesh.get_surface_count():
			result.append(supplied)
		return result


func shapes_with(kind: int, mesh: Mesh) -> Array:
	var settings = PhysicsScript.new()
	settings.kind = kind
	return settings.resolve_shapes(mesh)


func run() -> void:
	var Kind = PhysicsScript.Kind
	DirAccess.make_dir_recursive_absolute(scratch)

	# Descriptor: exactly the design page's keys and types, no hash.
	var object = ObjectScript.new()
	var descriptor: Dictionary = object.descriptor()
	var expected_keys := ["draw", "mesh_aabb", "batch_size", "default_color", "default_custom", "collider", "collider_min_scale", "impostor", "impostor_cell_size", "impostor_min_scale", "impostor_batch_size"]
	var keys := descriptor.keys()
	keys.sort()
	expected_keys.sort()
	check(keys == expected_keys, "descriptor keys are %s (got %s)" % [expected_keys, keys])
	check(descriptor.draw is String and descriptor.draw == "multimesh", "draw is the string multimesh by default")
	check(descriptor.mesh_aabb is AABB and descriptor.mesh_aabb == AABB(), "mesh_aabb is an empty AABB without a mesh")
	check(descriptor.batch_size is float, "batch_size is a float")
	check(descriptor.default_color is Color and descriptor.default_color == Color.WHITE, "default_color is white")
	check(descriptor.default_custom is Color and descriptor.default_custom == Color(0, 0, 0, 0), "default_custom is zero")
	check(descriptor.collider is bool and not descriptor.collider and descriptor.collider_min_scale == 0.0, "no physics settings, no collider, min scale 0")
	check(descriptor.impostor is bool and not descriptor.impostor and descriptor.impostor_cell_size == 0.0 and descriptor.impostor_min_scale == 0.0 and descriptor.impostor_batch_size == 0.0, "no impostor mesh, no impostor")

	var render = RenderScript.new()
	var physics = PhysicsScript.new()
	object.mesh = offset_box()
	object.render = render
	object.physics = physics
	object.impostor_mesh = BoxMesh.new()
	physics.min_scale = 0.5
	object.impostor_min_scale = 0.75
	render.draw_mode = RenderScript.DrawMode.INSTANCE
	render.batch_size = 32.0
	descriptor = object.descriptor()
	check(descriptor.draw == "instance" and descriptor.batch_size == 32.0, "render settings reach the descriptor")
	check(descriptor.mesh_aabb == AABB(Vector3(-1, 1, -1), Vector3(2, 4, 2)), "mesh_aabb is the mesh's bounds (%s)" % descriptor.mesh_aabb)
	check(descriptor.collider and descriptor.collider_min_scale == 0.5, "physics settings reach the descriptor")
	check(descriptor.impostor and descriptor.impostor_cell_size == 0.0 and descriptor.impostor_min_scale == 0.75, "impostor settings reach the descriptor; no far grid size unless the store passes one")
	check(object.descriptor(256.0).impostor_cell_size == 256.0, "descriptor(impostor_cell_size) carries the store's far grid size")
	check(not ("impostor_cell_size" in render), "the far grid size is not a render setting")
	object.impostor_mesh = null
	check(object.descriptor(256.0).impostor_cell_size == 0.0, "without an impostor mesh the far grid size is 0")
	object.impostor_mesh = BoxMesh.new()
	physics.kind = Kind.SHAPES
	check(not object.descriptor().collider, "physics settings with the SHAPES kind and no shapes give no collider")
	var params: Dictionary = object.call("_get_draw_params")
	check(params.has("mesh") and params.mesh is RID and params.mesh == object.mesh.get_rid() and params.material_override == RID(), "draw params carry the mesh and material RIDs")

	# Render settings draw params.
	var fresh = RenderScript.new()
	var expected_params := ["visibility_begin", "visibility_end", "visibility_begin_margin", "visibility_end_margin", "fade_mode", "cast_shadows", "low_lod_shadows", "shadow_range", "shadow_range_margin", "lod_bias", "layers", "gi_mode", "extra_cull_margin"]
	var param_keys: Array = fresh.draw_params().keys()
	param_keys.sort()
	expected_params.sort()
	check(param_keys == expected_params, "draw_params keys are the drawer's (%s)" % [param_keys])
	fresh.shadow = RenderScript.Shadow.LOW_LOD
	fresh.fade_mode = RenderScript.FadeMode.SELF
	var low: Dictionary = fresh.draw_params()
	check(low.cast_shadows == RenderingServer.SHADOW_CASTING_SETTING_OFF and low.low_lod_shadows and low.fade_mode == RenderingServer.VISIBILITY_RANGE_FADE_SELF, "LOW_LOD draws with shadows off plus a low-LOD shadow instance; SELF fade maps to the server value")
	fresh.draw_mode = RenderScript.DrawMode.INSTANCE
	check(fresh.draw_params().fade_mode == RenderingServer.VISIBILITY_RANGE_FADE_DISABLED, "fade applies to the MULTIMESH draw mode only")

	# A mesh path resolves to a default object; other things do not.
	var mesh_path := scratch.path_join("box.tres")
	check(ResourceSaver.save(offset_box(), mesh_path) == OK, "test mesh is written")
	ObjectScript.clear_cache()
	var resolved = ObjectScript.resolve(mesh_path)
	check(resolved != null and resolved.mesh != null and resolved.render == null and resolved.physics == null and resolved.impostor_mesh == null, "a mesh path resolves to a default object")
	check(ObjectScript.resolve(mesh_path) == resolved, "resolve is cached by path")
	ObjectScript.clear_cache()
	check(ObjectScript.resolve(mesh_path) != resolved, "clear_cache makes resolve load again")
	var object_path := scratch.path_join("object.tres")
	var saved = ObjectScript.new()
	saved.mesh = load(mesh_path)
	saved.default_color = Color.RED
	check(ResourceSaver.save(saved, object_path) == OK, "test object is written")
	var loaded = ObjectScript.resolve(object_path)
	check(loaded != null and loaded.default_color == Color.RED, "an object path resolves to the object")
	var other_path := scratch.path_join("other.tres")
	ResourceSaver.save(BoxShape3D.new(), other_path)
	check(ObjectScript.resolve(other_path) == null, "a path to another resource type gives null")
	check(ObjectScript.resolve(scratch.path_join("missing.tres")) == null and ObjectScript.resolve("") == null, "a missing path and an empty path give null")
	ObjectScript.clear_cache()

	# Hooks: a subclass changes what the descriptor and draw params use.
	var tinted := TintedObject.new()
	tinted.default_color = Color.BLUE
	var tinted_descriptor: Dictionary = tinted.descriptor()
	check(tinted_descriptor.default_color == Color(0.25, 0.5, 0.75, 0.5) and tinted_descriptor.default_custom == Color(1, 2, 3, 4), "overridden hooks feed the descriptor")
	check(tinted.call("_get_draw_params").get("tag") == "tinted" and tinted.call("_get_draw_params").has("visibility_end"), "an overridden draw params hook extends the default")
	check(ObjectScript.new().call("_get_default_color") == Color.WHITE, "the default hooks return the properties")

	# build_inputs_changed: fires for build inputs, not for the rest.
	var o = ObjectScript.new()
	var r = RenderScript.new()
	var p = PhysicsScript.new()
	o.render = r
	o.physics = p
	expect_build(o, "a new mesh with other bounds", func(): o.mesh = BoxMesh.new())
	expect_no_build(o, "a material override", func(): o.material_override = StandardMaterial3D.new())
	expect_no_build(o, "an impostor material", func(): o.impostor_material = StandardMaterial3D.new())
	expect_build(o, "an impostor mesh", func(): o.impostor_mesh = BoxMesh.new())
	expect_build(o, "the impostor minimum scale", func(): o.impostor_min_scale = 1.0)
	expect_build(o, "the default colour", func(): o.default_color = Color.GREEN)
	expect_build(o, "the default custom data", func(): o.default_custom = Color(1, 0, 0, 0))
	expect_build(o, "removing the physics settings", func(): o.physics = null)
	expect_build(o, "adding physics settings", func(): o.physics = p)
	expect_build(r, "the draw mode", func(): r.draw_mode = RenderScript.DrawMode.INSTANCE)
	expect_build(r, "the batch size", func(): r.batch_size = 8.0)
	expect_build(r, "the impostor batch size", func(): r.impostor_batch_size = 32.0)
	for property in ["visibility_range_begin", "visibility_range_end", "visibility_range_margin", "shadow_range", "shadow_range_margin", "lod_bias", "extra_cull_margin", "impostor_range_end"]:
		expect_no_build(r, property, func(): r.set(property, 123.0))
	expect_no_build(r, "shadow", func(): r.shadow = RenderScript.Shadow.OFF)
	expect_no_build(r, "fade_mode", func(): r.fade_mode = RenderScript.FadeMode.SELF)
	expect_no_build(r, "layers", func(): r.layers = 6)
	expect_no_build(r, "gi_mode", func(): r.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC)
	expect_build(p, "the physics minimum scale", func(): p.min_scale = 0.3)
	expect_no_build(p, "the collision layer", func(): p.collision_layer = 4)
	expect_no_build(p, "the collider distance", func(): p.distance = 50.0)
	check(p.distance == 50.0 and not ("range" in p), "the collider distance is named distance")
	expect_build(p, "switching to SHAPES without shapes", func(): p.kind = Kind.SHAPES)
	expect_build(p, "switching from SHAPES without shapes to another kind", func(): p.kind = Kind.FIT_BOX)
	expect_no_build(p, "switching between kinds that have shapes", func(): p.kind = Kind.MESH_CONVEX)

	# Forwarding: an object passes on its sub-resources' signals, and stops after a swap.
	expect_build(o, "a build input of the render settings, seen on the object", func(): r.batch_size = 4.0)
	expect_no_build(o, "a render-only property of the render settings, seen on the object", func(): r.shadow = RenderScript.Shadow.LOW_LOD)
	expect_build(o, "a build input of the physics settings, seen on the object", func(): p.min_scale = 0.9)
	var replacement = RenderScript.new()
	o.render = replacement
	var counts := signals_of(o, func(): r.batch_size = 2.0)
	check(counts.changed == 0 and counts.build == 0, "a replaced sub-resource no longer reaches the object (%s)" % counts)
	expect_build(o, "the replacement's build input", func(): replacement.batch_size = 2.0)

	# Physics shapes for a known mesh: 2 x 4 x 2, centred at y = 3.
	var mesh := offset_box()
	var centre := Transform3D(Basis.IDENTITY, Vector3(0, 3, 0))
	var box_entries := shapes_with(Kind.FIT_BOX, mesh)
	check(box_entries.size() == 1 and box_entries[0].shape is BoxShape3D and box_entries[0].shape.size.is_equal_approx(Vector3(2, 4, 2)) and box_entries[0].transform.is_equal_approx(centre), "FIT_BOX is the bounds' box, centred on them")
	var capsule_entries := shapes_with(Kind.FIT_CAPSULE, mesh)
	check(capsule_entries.size() == 1 and capsule_entries[0].shape is CapsuleShape3D and is_equal_approx(capsule_entries[0].shape.radius, 1.0) and is_equal_approx(capsule_entries[0].shape.height, 4.0) and capsule_entries[0].transform.is_equal_approx(centre), "FIT_CAPSULE runs along Y with the horizontal radius and the full height")
	var sphere_entries := shapes_with(Kind.FIT_SPHERE, mesh)
	check(sphere_entries.size() == 1 and sphere_entries[0].shape is SphereShape3D and is_equal_approx(sphere_entries[0].shape.radius, 2.0) and sphere_entries[0].transform.is_equal_approx(centre), "FIT_SPHERE has half the largest extent as radius")
	var cylinder_entries := shapes_with(Kind.FIT_CYLINDER, mesh)
	check(cylinder_entries.size() == 1 and cylinder_entries[0].shape is CylinderShape3D and is_equal_approx(cylinder_entries[0].shape.radius, 1.0) and is_equal_approx(cylinder_entries[0].shape.height, 4.0) and cylinder_entries[0].transform.is_equal_approx(centre), "FIT_CYLINDER runs along Y with the horizontal radius and the full height")
	var convex_entries := shapes_with(Kind.MESH_CONVEX, mesh)
	check(convex_entries.size() == 1 and convex_entries[0].shape is ConvexPolygonShape3D and convex_entries[0].transform == Transform3D.IDENTITY, "MESH_CONVEX is a convex shape with the identity transform")
	var trimesh_entries := shapes_with(Kind.MESH_TRIMESH, mesh)
	check(trimesh_entries.size() == 1 and trimesh_entries[0].shape is ConcavePolygonShape3D and trimesh_entries[0].transform == Transform3D.IDENTITY, "MESH_TRIMESH is a concave shape with the identity transform")
	check(shapes_with(Kind.MESH_CONVEX, mesh)[0].shape == convex_entries[0].shape and shapes_with(Kind.MESH_TRIMESH, mesh)[0].shape == trimesh_entries[0].shape, "mesh-derived shapes are cached per mesh")
	check(shapes_with(Kind.MESH_CONVEX, offset_box())[0].shape != convex_entries[0].shape, "another mesh gets its own shape")
	for kind in [Kind.MESH_CONVEX, Kind.MESH_TRIMESH, Kind.FIT_BOX, Kind.FIT_CAPSULE, Kind.FIT_SPHERE, Kind.FIT_CYLINDER]:
		check(shapes_with(kind, null).is_empty(), "kind %d without a mesh gives no shapes" % kind)

	# SHAPES: listed shapes, parallel transforms, missing entries are the identity, mesh ignored.
	var listed = PhysicsScript.new()
	listed.kind = Kind.SHAPES
	var first := SphereShape3D.new()
	var second := BoxShape3D.new()
	var third := CapsuleShape3D.new()
	listed.shapes.assign([first, second, third])
	var moved := Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	listed.shape_transforms.assign([moved])
	var entries: Array = listed.resolve_shapes(null)
	check(entries.size() == 3 and entries[0].shape == first and entries[1].shape == second and entries[2].shape == third, "SHAPES lists the shapes in order, with or without a mesh")
	check(entries[0].transform == moved and entries[1].transform == Transform3D.IDENTITY and entries[2].transform == Transform3D.IDENTITY, "missing shape transforms are the identity")
	check(listed.resolve_shapes(mesh).size() == 3, "SHAPES ignores the mesh")
	check(listed.has_collider(), "SHAPES with shapes has a collider")

	# min_scale is a descriptor value; scale is the length of the basis Y column.
	var rule = PhysicsScript.new()
	rule.min_scale = 0.5
	var scaled := Transform3D(Basis.IDENTITY.scaled(Vector3(9, 0.4, 9)), Vector3.ZERO)
	var wide := Transform3D(Basis.IDENTITY.scaled(Vector3(0.1, 0.6, 0.1)), Vector3.ZERO)
	var gets_collider := func(t: Transform3D) -> bool: return t.basis.y.length() >= rule.min_scale
	check(not gets_collider.call(scaled) and gets_collider.call(wide), "min_scale compares the basis Y column's length")
	var with_rule = ObjectScript.new()
	with_rule.physics = rule
	check(with_rule.descriptor().collider_min_scale == 0.5, "the descriptor carries min_scale")
	rule.min_scale = -3.0
	check(rule.min_scale == 0.0, "a negative min_scale is clamped to 0 (every instance)")

	# Convex hull simplification: on by default, a shape change only, a different cached hull.
	var hull_settings = PhysicsScript.new()
	check(hull_settings.simplify_hull, "simplify_hull is on by default")
	expect_no_build(hull_settings, "simplify_hull", func(): hull_settings.simplify_hull = false)
	var sphere := SphereMesh.new()
	hull_settings.simplify_hull = true
	var simplified_points: int = hull_settings.resolve_shapes(sphere)[0].shape.points.size()
	hull_settings.simplify_hull = false
	var full_points: int = hull_settings.resolve_shapes(sphere)[0].shape.points.size()
	print("convex hull points of a SphereMesh: simplified %d, full %d" % [simplified_points, full_points])
	check(simplified_points < full_points, "a simplified hull has fewer points than the full one (%d < %d)" % [simplified_points, full_points])
	hull_settings.simplify_hull = true
	check(hull_settings.resolve_shapes(sphere)[0].shape.points.size() == simplified_points, "switching back gives the simplified hull again (per-mesh cache keyed by the option)")

	# Typed exports keep their resource type although the script names it by a preloaded constant.
	var hints := {}
	for property in ObjectScript.new().get_property_list():
		if property.name in ["render", "physics"]:
			hints[property.name] = property
	check(hints.render.hint == PROPERTY_HINT_RESOURCE_TYPE and hints.render.hint_string == "CopiaRenderSettings", "render exports CopiaRenderSettings (%s)" % hints.render.hint_string)
	check(hints.physics.hint == PROPERTY_HINT_RESOURCE_TYPE and hints.physics.hint_string == "CopiaPhysicsSettings", "physics exports CopiaPhysicsSettings (%s)" % hints.physics.hint_string)
	var typed_path := scratch.path_join("typed.tres")
	var typed = ObjectScript.new()
	typed.render = RenderScript.new()
	typed.physics = PhysicsScript.new()
	check(ResourceSaver.save(typed, typed_path) == OK, "typed object is written")
	var typed_loaded = ResourceLoader.load(typed_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(typed_loaded.render.get_script() == RenderScript and typed_loaded.physics.get_script() == PhysicsScript, "a loaded .tres keeps typed sub-resources")
	var wrong = ObjectScript.new()
	wrong.set("render", PhysicsScript.new())
	check(wrong.render == null, "the render property rejects a physics settings resource")
	DirAccess.remove_absolute(typed_path)

	test_surface_materials()

	DirAccess.remove_absolute(mesh_path)
	DirAccess.remove_absolute(object_path)
	DirAccess.remove_absolute(other_path)
	DirAccess.remove_absolute(scratch)
	if failures.is_empty():
		print("COPIA_RESOURCES_TEST PASS")
		quit(0)
	else:
		print("COPIA_RESOURCES_TEST FAIL: %d failures" % failures.size())
		for failure in failures:
			print("  - ", failure)
		quit(1)
