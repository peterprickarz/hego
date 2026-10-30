@tool
extends Node3D
## Play the saved editable scene without reloading a generated cache or HAPI.
## Editing itself uses the Godot editor plugin, not this runtime bootstrap.
## Changes only the recognized island hosts' input rows; existing fields stay cached.
@export_tool_button("Configure Stage Material Inputs", "Tools") var configure_stage_materials = _configure_stage_materials
@export_multiline var stage_material_binding_status := "Explicit input migration; no automatic cooks or scene saves"

func _configure_stage_materials() -> void:
	var result := HEGoIslandStageMaterials.migrate(self)
	stage_material_binding_status = String(result.message)
	if not result.ok: push_error(stage_material_binding_status); return
	if result.changed and Engine.is_editor_hint(): EditorInterface.mark_scene_as_unsaved()

func _ready() -> void:
	var terrain := get_node("Terrain") as StrataTerrain3D
	if terrain.get_node_or_null(HEGoIslandMaterials.LAYER) != null:
		var binding := Node.new()
		binding.set_script(load("res://island/island_material_binding.gd"))
		binding.name = "MaterialControlsBinding"
		add_child(binding, false, Node.INTERNAL_MODE_BACK)
		binding.setup(terrain)
	if Engine.is_editor_hint(): return
	var camera := get_node("Camera") as Camera3D
	var view := StrataEditorPreview.new()
	terrain.add_child(view)
	view.setup(terrain)
	view.set_camera(camera)
	for index in range(600):
		if is_instance_valid(view.renderer): break
		await get_tree().process_frame
	if camera is HEGoIslandCamera:
		camera.renderer = view.renderer
