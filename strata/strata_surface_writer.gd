@tool
class_name StrataSurfaceWriter
extends Node3D
## Writes a mesh into Strata's surface cache, like an Unreal Runtime Virtual Texture writer: the
## mesh is rendered top-down with a writer material (a spatial shader including
## shaders/strata_surface_writer.gdshaderinc) and composited over the terrain material in every
## cache level it touches. The terrain then shows it, and everything reading the cache (rocks,
## trees, cliffs blending into the ground) picks it up. The mesh itself is never drawn in the
## main view. See "Surface writers" in README.md.
##
## The mesh is [member mesh], or with [member source] set, every MeshInstance3D at or under that
## node (their meshes, transforms and materials; Strata hides them from the main view while it
## writes them). Writers need StrataRenderSettings.surface_cache_enabled on the terrain.

## Mesh written into the cache, placed by this node's transform.
@export var mesh: Mesh:
	set(value):
		if mesh == value: return
		if mesh != null and mesh.changed.is_connected(_queue_rebuild): mesh.changed.disconnect(_queue_rebuild)
		mesh = value
		if mesh != null: mesh.changed.connect(_queue_rebuild)
		_queue_rebuild()
## Writer material for every surface. Empty: the surface materials of the mesh (or of the
## adopted MeshInstance3D).
@export var material: Material:
	set(value):
		if material == value: return
		_watch_material(material, false)
		material = value
		_watch_material(material, true)
		_queue_rebuild()
## A MeshInstance3D, or a node whose MeshInstance3D descendants are written instead of
## [member mesh] (for example the output node of a procedural cook). Rescanned when nodes are
## added under it.
@export var source: NodePath:
	set(value):
		if source == value: return
		source = value
		_queue_rebuild()
## With [member source]: only MeshInstance3Ds whose name matches this pattern (String.match:
## * and ? wildcards) are written.
@export var source_filter := "*":
	set(value):
		if source_filter == value: return
		source_filter = value
		_queue_rebuild()
## Draw order: higher priorities are written over lower ones. Within one priority, materials
## with a higher render_priority win, then the higher geometry (seen from above).
@export_range(-64, 64, 1) var priority := 0:
	set(value):
		if priority == value: return
		priority = value
		_queue_rebuild()
## Cache outputs this writer replaces.
@export_flags("Albedo", "Normal and roughness", "AO relief and metallic") var channels := 7:
	set(value):
		if channels == value: return
		channels = value
		_queue_rebuild()

var _registry: StrataSurfaceWriterRegistry
var _entry := -1
## Per item: {instances: Array[RID], hidden: RID of the adopted MeshInstance3D instance}
var _items: Array = []
var _rebuild_queued := false
var _watched_source: Node
var _watched_materials: Array[Material] = []


func _enter_tree() -> void:
	set_notify_transform(true)
	set_process(Engine.is_editor_hint())
	_registry = StrataSurfaceWriterRegistry.shared()
	_queue_rebuild()


func _exit_tree() -> void:
	_clear()
	_watch_source(null)
	if _registry != null and _entry >= 0: _registry.remove_entry(_entry)
	_entry = -1
	_registry = null
	StrataSurfaceWriterRegistry.release_if_unused()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_VISIBILITY_CHANGED:
		_queue_rebuild()
	elif what == NOTIFICATION_PREDELETE:
		_clear()


## Rewrites this writer's area of the cache (after changing its material's parameters from a
## script: ShaderMaterial parameters do not signal a change. In the editor, parameter edits of
## the writer's materials are picked up by themselves).
func invalidate() -> void:
	if _registry != null and _entry >= 0: _registry.touch_entry(_entry)


## Re-reads the mesh, materials, transforms and adopted MeshInstance3Ds now.
func refresh() -> void:
	_rebuild_queued = false
	_rebuild()


## Global bounds of everything this writer writes (empty when nothing).
func get_written_bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for item in _collect():
		var box: AABB = (item.transform as Transform3D) * (item.mesh as Mesh).get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds


func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree(): return
	_rebuild_queued = true
	_rebuild.call_deferred()


## The meshes to write: [{mesh, transform, materials: Array (per surface, null = mesh's own), hide: RID}]
func _collect() -> Array:
	var result := []
	if not is_inside_tree() or not is_visible_in_tree(): return result
	if not source.is_empty():
		var root := get_node_or_null(source)
		var stack: Array[Node] = []
		if root != null: stack.append(root)
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and String(node.name).match(source_filter):
				var instance := node as MeshInstance3D
				var materials := []
				for surface in instance.mesh.get_surface_count():
					materials.append(material if material != null else instance.get_active_material(surface))
				result.append({"mesh": instance.mesh, "transform": instance.global_transform, "materials": materials, "hide": instance.get_instance()})
			for child in node.get_children(): stack.append(child)
	elif mesh != null:
		var materials := []
		for surface in mesh.get_surface_count():
			materials.append(material if material != null else mesh.surface_get_material(surface))
		result.append({"mesh": mesh, "transform": global_transform, "materials": materials, "hide": RID()})
	return result


func _rebuild() -> void:
	_rebuild_queued = false
	if not is_inside_tree() or _registry == null: return
	_clear()
	_watch_source(get_node_or_null(source) if not source.is_empty() else null)
	var scenario := _registry.scenario()
	var bounds := AABB()
	var first := true
	var used: Array[Material] = []
	for item in _collect():
		var instances: Array[RID] = []
		for pass_index in StrataSurfaceWriterRegistry.PASS_COUNT:
			if (channels & (1 << pass_index)) == 0: continue
			var rid := RenderingServer.instance_create2((item.mesh as Mesh).get_rid(), scenario)
			RenderingServer.instance_set_transform(rid, item.transform)
			RenderingServer.instance_set_layer_mask(rid, 1)
			RenderingServer.instance_geometry_set_cast_shadows_setting(rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
			# Transparent writers sort back to front; the offset puts higher priorities on top.
			RenderingServer.instance_set_pivot_data(rid, float(priority) * 4096.0, false)
			for surface in (item.materials as Array).size():
				var surface_material: Material = item.materials[surface]
				if surface_material != null:
					RenderingServer.instance_set_surface_override_material(rid, surface, surface_material.get_rid())
			RenderingServer.instance_geometry_set_shader_parameter(rid, &"strata_writer_pass", pass_index)
			instances.append(rid)
		for surface_material: Variant in item.materials:
			if surface_material is Material and not used.has(surface_material): used.append(surface_material)
		var hide: RID = item.hide
		if hide.is_valid(): RenderingServer.instance_set_visible(hide, false)
		_items.append({"instances": instances, "hide": hide})
		var box: AABB = (item.transform as Transform3D) * (item.mesh as Mesh).get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	_watch_materials(used)
	if _items.is_empty():
		if _entry >= 0: _registry.remove_entry(_entry)
		_entry = -1
	elif _entry < 0:
		_entry = _registry.add_entry(bounds, used)
	else:
		_registry.update_entry(_entry, bounds, used)


func _clear() -> void:
	for item: Dictionary in _items:
		for rid: RID in item.instances: RenderingServer.free_rid(rid)
		var hide: RID = item.hide
		if hide.is_valid() and is_inside_tree():
			# Give the adopted instance back its own visibility (it may have been freed).
			RenderingServer.instance_set_visible(hide, true)
	_items = []


func _watch_source(node: Node) -> void:
	if _watched_source == node: return
	var tree := get_tree() if is_inside_tree() else null
	if tree != null:
		if _watched_source != null and tree.node_added.is_connected(_on_tree_node):
			tree.node_added.disconnect(_on_tree_node)
			tree.node_removed.disconnect(_on_tree_node)
		if node != null:
			tree.node_added.connect(_on_tree_node)
			tree.node_removed.connect(_on_tree_node)
	_watched_source = node


func _on_tree_node(node: Node) -> void:
	if is_instance_valid(_watched_source) and node is MeshInstance3D and (_watched_source == node or _watched_source.is_ancestor_of(node)):
		_queue_rebuild()


## Material edits (parameters, shader) refill the cache under this writer.
func _watch_materials(used: Array[Material]) -> void:
	var wanted: Array[Material] = used.duplicate()
	if material != null and not wanted.has(material): wanted.append(material)
	for old in _watched_materials:
		if not wanted.has(old) and is_instance_valid(old) and old.changed.is_connected(_on_material_changed):
			old.changed.disconnect(_on_material_changed)
	for new in wanted:
		if not new.changed.is_connected(_on_material_changed): new.changed.connect(_on_material_changed)
	_watched_materials = wanted


func _watch_material(value: Material, watch: bool) -> void:
	if value == null: return
	if watch and not value.changed.is_connected(_on_material_changed): value.changed.connect(_on_material_changed)
	elif not watch and value.changed.is_connected(_on_material_changed): value.changed.disconnect(_on_material_changed)


var _poll_elapsed := 0.0
var _material_signature := ""


## Editor only: material parameter edits (the inspector, tool scripts) rewrite the cache.
func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < 0.25: return
	_poll_elapsed = 0.0
	var parts := PackedStringArray()
	for watched in _watched_materials:
		var shader_material := watched as ShaderMaterial
		if shader_material == null or shader_material.shader == null: continue
		parts.append(str(shader_material.shader.get_rid().get_id()))
		for uniform in shader_material.shader.get_shader_uniform_list():
			parts.append(var_to_str(shader_material.get_shader_parameter(uniform.name)))
	var signature := str(hash("|".join(parts)))
	if signature != _material_signature:
		var first := _material_signature.is_empty()
		_material_signature = signature
		if not first: invalidate()


func _on_material_changed() -> void:
	if _registry != null and _entry >= 0: _registry.touch_entry(_entry)
