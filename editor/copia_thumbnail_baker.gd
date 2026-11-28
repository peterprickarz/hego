@tool
extends RefCounted
## Offscreen SubViewport thumbnail baker with an editor-only PNG cache under
## [code]res://.godot/copia_thumbnails/[/code]. Renders [CopiaObject] meshes (including subclasses
## and per-surface materials) and 2x2 composite previews for [CopiaSpecies] in a frame-budgeted
## background queue so opening the dock never stalls the editor.

signal thumbnail_ready(resource_path: String, texture: Texture2D)

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const SpeciesScript := preload("res://addons/copia/copia_species.gd")

const CACHE_DIR := "res://.godot/copia_thumbnails"
const THUMB_SIZE := 128

var _host: Node
var _viewport: SubViewport
var _camera: Camera3D
var _mesh_instance: MeshInstance3D
var _textures := {}  # resource_path -> ImageTexture
var _queue: Array[String] = []
var _queued := {}  # resource_path -> true
var _baking := false
var _disposed := false


func _init(host: Node) -> void:
	_host = host
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


func dispose() -> void:
	_disposed = true
	_queue.clear()
	_queued.clear()
	if is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null
	_camera = null
	_mesh_instance = null


## Returns a cached [Texture2D] immediately if available in memory or on disk, otherwise queues
## baking and returns null (emitting [signal thumbnail_ready] once done).
func request_thumbnail(resource_path: String) -> Texture2D:
	if resource_path.is_empty():
		return null
	if _textures.has(resource_path):
		return _textures[resource_path]
	var cache_file := _cache_file_for(resource_path)
	if not cache_file.is_empty() and FileAccess.file_exists(cache_file):
		var img := Image.new()
		if img.load(cache_file) == OK:
			var tex := ImageTexture.create_from_image(img)
			_textures[resource_path] = tex
			return tex
	if not _queued.has(resource_path):
		_queued[resource_path] = true
		_queue.append(resource_path)
		if not _baking:
			_run_queue()
	return null


func invalidate(resource_path: String) -> void:
	_textures.erase(resource_path)
	var cache_file := _cache_file_for(resource_path)
	if not cache_file.is_empty() and FileAccess.file_exists(cache_file):
		DirAccess.remove_absolute(cache_file)


func clear_cache() -> void:
	_textures.clear()
	_queue.clear()
	_queued.clear()
	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	if DirAccess.dir_exists_absolute(abs_dir):
		for file in DirAccess.get_files_at(abs_dir):
			if file.ends_with(".png"):
				DirAccess.remove_absolute(abs_dir.path_join(file))


func _cache_file_for(resource_path: String) -> String:
	var abs_res := ProjectSettings.globalize_path(resource_path)
	if not FileAccess.file_exists(abs_res):
		return ""
	var mtime := FileAccess.get_modified_time(abs_res)
	var key := ("%s|%d|%d" % [resource_path, mtime, THUMB_SIZE]).md5_text()
	return ProjectSettings.globalize_path(CACHE_DIR).path_join(key + ".png")


func _ensure_viewport() -> bool:
	if _disposed or not is_instance_valid(_host) or not _host.is_inside_tree():
		return false
	if is_instance_valid(_viewport):
		return true
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(THUMB_SIZE, THUMB_SIZE)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_4X

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.88, 0.92)
	env.ambient_light_energy = 0.65
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_viewport.add_child(world_env)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.35
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.45
	fill.light_color = Color(0.82, 0.9, 1.0)
	fill.rotation_degrees = Vector3(-20.0, -135.0, 0.0)
	_viewport.add_child(fill)

	_camera = Camera3D.new()
	_camera.fov = 35.0
	_camera.near = 0.02
	_camera.far = 2000.0
	_camera.current = true
	_viewport.add_child(_camera)

	_mesh_instance = MeshInstance3D.new()
	_viewport.add_child(_mesh_instance)

	_host.add_child(_viewport)
	return true


func _run_queue() -> void:
	if _baking:
		return
	_baking = true
	while not _queue.is_empty() and not _disposed:
		if not _ensure_viewport():
			break
		var path: String = _queue.pop_front()
		_queued.erase(path)
		var tex := await _bake_one(path)
		if _disposed:
			break
		if tex != null:
			_textures[path] = tex
			thumbnail_ready.emit(path, tex)
	_baking = false


func _bake_one(resource_path: String) -> Texture2D:
	if not ResourceLoader.exists(resource_path):
		return null
	var res := ResourceLoader.load(resource_path)
	if res == null:
		return null
	var img: Image = null
	if is_instance_of(res, ObjectScript):
		img = await _render_object(res)
	elif is_instance_of(res, SpeciesScript):
		img = await _render_species(res)
	if img == null or _disposed:
		return null
	var cache_file := _cache_file_for(resource_path)
	if not cache_file.is_empty():
		img.save_png(cache_file)
	return ImageTexture.create_from_image(img)


func _render_object(obj: Resource) -> Image:
	if not is_instance_valid(_viewport) or obj == null:
		return null
	var mesh: Mesh = obj.get_surface_material_mesh() if obj.has_method("get_surface_material_mesh") else obj.get("mesh")
	if mesh == null:
		return null
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = obj.get("material_override")
	var aabb := mesh.get_aabb()
	var center := aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.5, 0.05)
	var half_fov := deg_to_rad(_camera.fov * 0.5)
	var dist := (radius / sin(half_fov)) * 1.08
	var dir := Vector3(0.62, 0.42, 0.66).normalized()
	_camera.near = maxf(dist * 0.02, 0.01)
	_camera.far = maxf(dist * 6.0, 50.0)
	_camera.look_at_from_position(center + dir * dist, center, Vector3.UP)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if _disposed or not is_instance_valid(_viewport):
		return null
	var tex := _viewport.get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	_mesh_instance.mesh = null
	_mesh_instance.material_override = null
	return img


func _render_species(species: Resource) -> Image:
	var entries: Array = species.get("entries") if species.get("entries") is Array else []
	var objs: Array = []
	for entry in entries:
		if entry != null and entry.get("object") != null and not objs.has(entry.object):
			objs.append(entry.object)
			if objs.size() >= 4:
				break
	if objs.is_empty():
		return null
	if objs.size() == 1:
		return await _render_object(objs[0])
	var half := THUMB_SIZE / 2
	var composite := Image.create(THUMB_SIZE, THUMB_SIZE, false, Image.FORMAT_RGBA8)
	composite.fill(Color(0, 0, 0, 0))
	var offsets := [Vector2i(0, 0), Vector2i(half, 0), Vector2i(0, half), Vector2i(half, half)]
	for i in objs.size():
		var sub := await _render_object(objs[i])
		if _disposed:
			return null
		if sub != null:
			sub.resize(half, half, Image.INTERPOLATE_LANCZOS)
			composite.blit_rect(sub, Rect2i(Vector2i.ZERO, Vector2i(half, half)), offsets[i])
	return composite
