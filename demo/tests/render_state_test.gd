extends SceneTree
## Graphical Forward+ lifecycle and rejected-update regressions.

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func run() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("Render state tests require graphical Forward+.")
		quit(2)
		return
	var source := StrataTerrain3D.new()
	source.base_bounds = Rect2(0, 0, 8, 8)
	root.add_child(source)
	var renderer := StrataRenderer.new()
	source.add_child(renderer)
	var material := StrataMaterial.new()
	material.displacement_strength = 8.0
	var materials: Array[StrataMaterial] = [material]
	check(renderer.configure(source, materials), "Valid small field configures")
	check(not source.is_preview_enabled(), "Successful renderer disables preview")
	var instances := renderer._patches.values()
	var field := renderer._height_texture
	renderer.cells_per_patch = 6
	check(not renderer.force_lod_update(), "Non-power-of-two cells reject")
	check(renderer._patches.values() == instances, "Rejected LOD keeps visible instances")
	renderer.cells_per_patch = 32
	source.base_bounds = Rect2(0, 0, 8, 4)
	check(not renderer.refresh_heightfield(), "Non-square bounds reject")
	check(renderer._height_texture == field and renderer._patches.values() == instances, "Rejected refresh retains coherent old field and patches")
	source.base_bounds = Rect2(1.0e8, 1.0e8, 256, 256)
	check(not renderer.refresh_heightfield(), "Local coordinates that collapse vertex spacing reject")
	check(renderer._height_texture == field and renderer._patches.values() == instances, "Precision rejection retains previous field and patches")
	source.base_bounds = Rect2(0, 0, 8, 8)
	var old_ids := renderer._control_ids_texture
	var ids := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var weights := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	ids.fill(Color(1.0 / 255.0, 0, 0, 0))
	weights.fill(Color(1, 0, 0, 0))
	check(not renderer.set_control_maps(ids, weights), "Out-of-pool ID rejects")
	ids.fill(Color(0, 0, 0, 0))
	weights.fill(Color(-1, 0, 0, 0))
	check(not renderer.set_control_maps(ids, weights), "Negative contribution rejects")
	weights.fill(Color(NAN, 0, 0, 0))
	check(not renderer.set_control_maps(ids, weights), "Nonfinite contribution rejects")
	check(renderer._control_ids_texture == old_ids, "Rejected controls retain previous textures")
	weights.fill(Color(1, 0, 0, 0))
	check(renderer.set_control_maps(ids, weights), "Valid control replacement succeeds")
	var patch: MeshInstance3D = renderer._patches.values()[0]
	var previous_bounds := patch.custom_aabb
	material.displacement_strength = 0.1
	renderer.displacement_enabled = false
	check(patch.custom_aabb == previous_bounds, "Bounds use cached shader multiplier, not edited resource")
	source.base_bounds = Rect2(-8, -8, 16, 16)
	check(renderer.refresh_heightfield(), "Valid bounds refresh succeeds")
	check(renderer._render_bounds == source.base_bounds, "Field and patches share refreshed bounds")
	check(renderer._shader_material.get_shader_parameter("field_origin") == Vector2(-8, -8), "Refreshed origin reaches shader")
	check(renderer.get_stats().height_resolution == Vector2i(17, 17), "Refreshed dimensions reach heightfield")
	# Finite composed doubles must not become infinite RF samples.
	var base := StrataLayer.new()
	source.add_child(base)
	base.data.set_sample(&"height", Vector2i.ZERO, 3.0e38)
	var add := StrataLayer.new()
	source.add_child(add)
	add.set_composition(&"height", StrataLayer.Composition.ADD)
	add.data.set_sample(&"height", Vector2i.ZERO, 3.0e38)
	field = renderer._height_texture
	check(not renderer.refresh_heightfield(), "RF overflow rejects atomically")
	check(renderer._height_texture == field, "RF overflow retains old field")
	base.free()
	add.free()
	var previous_debug := root.debug_draw
	renderer.wireframe = true
	check(root.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME, "Wireframe applies")
	source.remove_child(renderer)
	check(source.is_preview_enabled(), "Removing renderer restores preview")
	check(root.debug_draw == previous_debug, "Removing renderer restores viewport mode")
	source.add_child(renderer)
	check(not source.is_preview_enabled(), "Readding renderer disables overlapping preview")
	renderer.free()
	check(source.is_preview_enabled() and root.debug_draw == previous_debug, "Freeing renderer restores owned state")
	source.set_preview_enabled(false)
	var second := StrataRenderer.new()
	source.add_child(second)
	check(second.configure(source, materials), "Renderer accepts independently disabled preview")
	second.free()
	check(not source.is_preview_enabled(), "Cleanup preserves independently disabled preview")
	source.free()
	await process_frame
	print("Render state regressions: %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)
