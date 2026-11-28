## Licensed integration test for a texture source edited on HEGoNode3D's numbered input.
## The fixture samples artificial pixels and reports the paths received on its SOP socket.
extends SceneTree

const PANEL := preload("res://addons/hego/hego_control.tscn")
const FIXTURE := "res://tests/fixtures/hego_test_cop_texture.hda"
const OPERATOR := "Sop/hego_test_cop_texture"
const LINEAR := HEGoTextureInputNode.ENCODING_LINEAR
const SRGB := HEGoTextureInputNode.ENCODING_SRGB

var failures := 0
var api := HEGoAPI.get_singleton()


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> bool:
	if not ok:
		failures += 1
		push_error(message)
	return ok


func texture(color: Color) -> PortableCompressedTexture2D:
	var image := Image.create(3, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var value := PortableCompressedTexture2D.new()
	value.set_keep_compressed_buffer(true)
	value.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	return value


func expected_red(source: Texture2D, srgb := false) -> float:
	var pixel := source.get_image().get_pixel(0, 0)
	return pixel.srgb_to_linear().r if srgb else pixel.r


func cook_sample(host: HEGoNode3D, count: int, red: float) -> Dictionary:
	await host.cook()
	if not check(host.hego_did_last_cook_succeed(), "HEGoNode3D cooked its texture inputs"):
		return {}
	var asset := host.hego_get_asset_node()
	var names := PackedStringArray(["texture_count", "first_cop", "second_cop", "red_corner"])
	var output: HEGoPointOutput = await host.agent.task(asset.get_point_output(names))
	if not check(output != null and output.get_point_count() == 1, "SOP texture fixture produced its sample point"):
		return {}
	var values := {}
	for name in names:
		var attribute: Variant = output.get_attribute(name)
		if not check(attribute != null and attribute.size() == 1, "Missing fixture value " + name):
			return {}
		values[name] = attribute[0]
	check(values.texture_count == count, "SOP received %d points (expected %d)" % [values.texture_count, count])
	check(absf(values.red_corner - red) < 0.001, "Sampled red %f, expected %f" % [values.red_corner, red])
	return values


func edit(host: HEGoNode3D, tab: Control, first: Texture2D, second: Texture2D) -> void:
	await tab.set_selected_node(host)
	if not check(tab.input_nodes.size() == 1, "The texture fixture exposes one bottom-panel input"):
		return
	var row = tab.input_nodes[0]
	check(row.label.text == "Textures", "The panel displays the HDA's socket name")
	var lines: Node = row.get_node("TextureContainer")
	row.get_node("HBoxContainer/AddTexture").pressed.emit()
	if not check(lines.get_child_count() == 1 and row.get_textures().is_empty(), "Add Texture opens an empty source without wiring it"):
		return
	var picker := lines.get_child(0).get_node("Picker")
	if Engine.is_editor_hint():
		check(picker.is_class("EditorResourcePicker"), "The editor exposes its resource picker for the numbered input")
	if picker.has_signal("resource_changed"):
		check(picker.get("base_type") == "Texture2D", "The editor picker accepts Texture2D resources")
		picker.set("edited_resource", first)
		picker.emit_signal("resource_changed", first)
	else:
		# The editor picker is unavailable when this test runs as a headless game.
		lines.get_child(0).get_node("Remove").pressed.emit()
		row.add_texture(first)
	row.add_texture(second)
	var entries: Array = host.hego_get_input_stash()[0].textures
	check(entries.size() == 2 and entries[0].texture == first and entries[1].texture == second,
			"Edits to the panel's texture rows write both ordered resources to the HEGoNode3D stash")
	var edits := [0]
	host.cook_inputs_changed.connect(func(): edits[0] += 1)
	first.emit_changed()
	check(edits[0] == 1, "Editing a texture resource notifies the selected host once")
	var sample := await cook_sample(host, 2, expected_red(first))
	if not sample.is_empty():
		check(sample.first_cop.begins_with("/") and sample.second_cop.begins_with("/") and sample.first_cop != sample.second_cop,
				"Each texture reaches Houdini as its own point and COP path")
		var other: Image = await host.agent.task(host.hego_get_asset_node().fetch_cop_image(sample.second_cop))
		check(other != null and absf(other.get_pixel(0, 0).r - expected_red(second)) < 0.001,
				"The second path resolves to the second texture")

	var encoding: OptionButton = lines.get_child(0).get_node("Encoding")
	var encoded := encoding.get_item_index(SRGB)
	encoding.select(encoded)
	encoding.item_selected.emit(encoded)
	check(host.input_stash[0].textures[0].encoding == SRGB, "The panel commits the selected encoding")
	var updated := await cook_sample(host, 2, expected_red(first, true))
	if not sample.is_empty() and not updated.is_empty():
		check(sample.first_cop == updated.first_cop, "Changing encoding updates the same bound texture")

	lines.get_child(1).get_node("Remove").pressed.emit()
	check(host.input_stash[0].textures.size() == 1, "Removing a panel texture updates the stash")
	await cook_sample(host, 1, expected_red(first, true))
	if not sample.is_empty():
		var removed := await HEGoNodeUtil.checked_task(host, host.hego_get_asset_node().fetch_cop_image(sample.second_cop))
		check(not removed.ok, "Removing a texture from a merged socket releases its uploaded Houdini COP")

	await tab.set_selected_node(null)
	await tab.set_selected_node(host)
	entries = tab.input_nodes[0].get_textures()
	check(entries.size() == 1 and entries[0].texture == first and entries[0].encoding == SRGB,
			"Reselecting the node restores the texture and its encoding in the panel")


func start(pipe: String) -> bool:
	if not check(api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe), "Private Houdini session started"):
		return false
	var loaded: Variant = await HEGoNodeUtil.await_task(root, api.load_hda_library(FIXTURE))
	return check(loaded != null, "Loaded the texture test fixture")


func run() -> void:
	var pipe := "hego_texture_input_scene_%d" % OS.get_process_id()
	if not await start(pipe):
		quit(1)
		return
	var host := HEGoNode3D.new()
	host.asset_name = OPERATOR
	root.add_child(host)
	current_scene = host
	await cook_sample(host, 0, 1.0)
	var panel := PANEL.instantiate()
	root.add_child(panel)
	var tab = panel.get_node("TabContainer/HDA")
	tab.auto_recook_toggle.set_pressed_no_signal(false)
	var first := texture(Color(0.5, 0.25, 0.75, 1.0))
	var second := texture(Color(0.8, 0.7, 0.4, 0.6))
	await edit(host, tab, first, second)
	var path := "user://hego_texture_input_%d.tscn" % OS.get_process_id()
	var saved := PackedScene.new()
	check(saved.pack(host) == OK and ResourceSaver.save(saved, path) == OK, "Texture input resources can be saved with the scene")
	await tab.set_selected_node(null)
	check(await host.agent.release(), "Releases the host's live texture and geometry nodes")
	panel.free()
	current_scene = null
	host.free()
	if api.is_session_active():
		api.stop_session()
	if await start(pipe + "_fresh"):
		var reloaded: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		host = reloaded.instantiate() as HEGoNode3D
		root.add_child(host)
		current_scene = host
		await cook_sample(host, 1, expected_red(first, true))
		host.agent.set_input(0, second)
		await cook_sample(host, 1, expected_red(second))
		host.agent.set_input(0, {"texture": null, "encoding": LINEAR})
		await host.cook()
		check(not host.hego_did_last_cook_succeed(), "A broken texture reference fails the cook")
		host.agent.set_input(0, second)
		await cook_sample(host, 1, expected_red(second))
		host.agent.set_input(0, null)
		await cook_sample(host, 0, 1.0)
		await host.agent.release()
		current_scene = null
		host.free()
		api.stop_session()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	api.clear_completed_task_history()
	if failures == 0:
		print("HEGO_TEXTURE_INPUT_SCENE_PASS")
	quit(0 if failures == 0 else 1)
