extends SceneTree
## Disposable real bottom-panel regression. No user scene/resource writes.
## Run with HOUDINI_OTLSCAN_PATH unset and a unique private named-pipe session.
var checks := 0
var failures := 0
var world: Node3D
var ui: Control

class FailedWithValidAsset extends Node:
	var stash := PackedByteArray([7, 8, 9])
	var writes := 0
	func cook() -> void: pass
	func hego_did_last_cook_succeed() -> bool: return false
	func hego_set_parm_stash(value: PackedByteArray) -> void: writes += 1; stash = value

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("EDITOR_PACKAGE_TEST: " + message)

func completed(task: HEGoTask) -> Dictionary:
	while task.get_status() < HEGoTask.COMPLETED: await process_frame
	return {"ok": task.get_status() == HEGoTask.COMPLETED, "value": task.get_result(), "message": task.get_error_message()}

func finish() -> void:
	if HEGoAPI.get_singleton().is_session_active(): HEGoAPI.get_singleton().stop_session()
	if is_instance_valid(ui): ui.queue_free()
	if is_instance_valid(world): world.queue_free()
	await process_frame
	print("EDITOR_HDA_PACKAGE_TEST checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func installed_operators() -> PackedStringArray:
	var result := PackedStringArray()
	for library in HEGoAPI.get_singleton().get_hda_libraries().values():
		for name in library.get("assets", []):
			result.append(String(name) if String(name).contains("/") else "Sop/" + String(name))
	return result

func run() -> void:
	check(not OS.has_environment("HOUDINI_OTLSCAN_PATH"), "regression must not inherit the headless launcher search path")
	check(not OS.has_environment("HOUDINI_PACKAGE_DIR"), "regression relies on the installed user package, not a package-directory environment injection")
	var api := HEGoAPI.get_singleton()
	check(not api.has_method("load_hda_library"), "original native library has no dynamic registration implementation")
	var pipe := "hego_panel_regression_%d" % OS.get_process_id()
	var started := api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe)
	check(started, "private session starts (a license failure here requires coordination, not touching the editor session)")
	if not started: await finish(); return
	check(installed_operators().has("Sop/hego_island_erosion::1.0"), "Houdini startup discovers the coarse operator before any asset creation")
	world = Node3D.new(); root.add_child(world)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(-2048, -2048, 4096, 4096); world.add_child(terrain)
	# The saved island's own rough base and coarse-cook preset, read from its storage files
	# and scene without instancing the scene.
	var rough := StrataLayer.new(); rough.name = "RoughBase"
	rough.data = (ResourceLoader.load("res://island/terrain/rough_base.res", "", ResourceLoader.CACHE_MODE_IGNORE) as StrataLayerData).duplicate(true)
	var island_state := (load("res://scenes/terrain_island.tscn") as PackedScene).get_state()
	var coarse_preset := PackedByteArray()
	for index in range(island_state.get_node_count()):
		if String(island_state.get_node_path(index)) == "./HDA/CoarseCook":
			for property in range(island_state.get_node_property_count(index)):
				if island_state.get_node_property_name(index, property) == &"parm_stash": coarse_preset = island_state.get_node_property_value(index, property)
	terrain.add_child(rough)
	var source_before := HEGoIslandMaterials.layer_content_hash(rough)
	var target := StrataLayer.new(); target.name = "CoarseErosion"; target.procedural = true; target.layer_id = "panel-test-target"; target.procedural_revision = 3
	var prior := Image.create(2, 2, false, Image.FORMAT_RF); prior.fill(Color(12, 0, 0))
	target.procedural_fields = {"height": StrataFieldData.from_field({"name": "height", "image": prior, "sample_origin": Vector3(-2048, 0, -2048), "sample_step_x": Vector3(8, 0, 0), "sample_step_y": Vector3(0, 0, 8)})}
	terrain.add_child(target)
	var group := Node3D.new(); group.name = "HDA"; world.add_child(group)
	var host := HEGoNode3D.new(); host.name = "CoarseCook"; host.asset_name = "Sop/hego_island_erosion::1.0"
	host.parm_stash = coarse_preset
	host.input_stash = [{"inputs": ["../../Terrain/RoughBase"], "settings": {"terrain_mode": "cumulative", "terrain_channels": "height"}}]
	group.add_child(host)
	var binding := HEGoStrataTargets.ensure(host); binding.producer_id = "panel-test-producer"
	binding.targets = [{"path": "../../Terrain/CoarseErosion", "channels": HEGoIslandStageMaterials.output_channels(), "required_channels": PackedStringArray(["height"])}]
	ui = (load("res://addons/hego/hego_control.tscn") as PackedScene).instantiate(); root.add_child(ui)
	await process_frame
	var panel := ui.get_node("TabContainer/HDA")
	panel.auto_start_session_toggle.button_pressed = false
	ui.set_selected_node(host)
	await process_frame
	var stash_before := host.parm_stash.duplicate()
	var target_before := HEGoIslandMaterials.layer_content_hash(target)
	host.asset_name = "Sop/hego_intentionally_nonexistent_hda::1.0"
	print("EXPECTED: nonexistent HDA must preserve the stash/cache without a secondary preset read")
	await panel._on_recook_button_pressed()
	check(not host.hego_did_last_cook_succeed() and host.parm_stash == stash_before and HEGoIslandMaterials.layer_content_hash(target) == target_before, "nonexistent HDA preserves stashed parameters and previous output")
	check(not panel._cooking and not panel.recook_button.disabled, "failed cook restores the panel buttons")
	var valid := HEGoAssetNode.new(); valid.op_name = "Sop/null"
	check((await completed(valid.instantiate())).ok and valid.get_id() >= 0, "create valid ID for failed-cook preset guard")
	var failed := FailedWithValidAsset.new(); world.add_child(failed)
	panel.hego_tool_node = failed; panel.hego_asset_node = valid
	var history_before := api.get_completed_task_history().size()
	await panel.recook()
	check(failed.writes == 0 and failed.stash == PackedByteArray([7, 8, 9]) and api.get_completed_task_history().size() == history_before, "a failed cook with a valid ID performs no preset task and never overwrites stash")
	host.asset_name = "Sop/hego_island_erosion::1.0"; host.agent.assets.clear(); panel.hego_asset_node = null
	ui.set_selected_node(host); await process_frame
	print("ACTUAL_COARSE_PANEL_COOK_BEGIN")
	await panel._on_recook_button_pressed()
	check(host.hego_did_last_cook_succeed() and not target.procedural_stale and target.procedural_revision > 3, "real bottom-panel coarse cook succeeds in the already active private session")
	check(target.procedural_fields.has("height") and target.procedural_fields.height.resolution == Vector2i(513, 513), "actual coarse result has its native 8m lattice")
	check(HEGoIslandMaterials.layer_content_hash(rough) == source_before, "cooking leaves the cloned authoritative input unchanged")
	var first = installed_operators()
	check(first.has("Sop/hego_island_erosion::1.0") and first.has("Sop/hego_terrain_tint::1.0") and first.has("Sop/hego_material_distribution::1.0"), "all three HDAs are present from the Houdini startup package")
	api.stop_session()
	check(api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe + "_second"), "restart private session")
	var renewed = installed_operators()
	check(renewed.has("Sop/hego_island_erosion::1.0") and renewed.has("Sop/hego_terrain_tint::1.0") and renewed.has("Sop/hego_material_distribution::1.0"), "Houdini processes the package again for the new session")
	await finish()
