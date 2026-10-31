extends SceneTree
## Dedicated artificial brush fixtures; never load or cook the island scene.

var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var terrain := StrataTerrain3D.new()
	terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(-4096, -4096, 8192, 8192)
	var layer := StrataLayer.new()
	layer.data.sample_spacing = 64.0
	terrain.add_child(layer)
	root.add_child(terrain)
	check(StrataBrush.MAX_RADIUS_METERS == 4096.0, "editor and runtime share the 4096 m radius range")
	check(StrataBrush.sample_limit_message(layer, Vector2.ZERO, 4096.0).is_empty(), "4096 m radius fits on a coarse manual grid")
	var touched := StrataBrush.apply_brush(layer, Vector2.ZERO, 4096.0, 10.0, "raise")
	check(touched > 12000 and touched < StrataBrush.MAX_CANDIDATE_SAMPLES, "terrain-scale radius authors a bounded coarse mountain footprint")
	check(is_equal_approx(terrain.sample_height(Vector2.ZERO), 10.0), "terrain-scale raise reaches its requested center height")
	check(layer.data.has_sample(&"height", Vector2i.ZERO), "large brush owns its center")
	check(StrataBrush.apply_brush(layer, Vector2.ZERO, 4096.0, 1.0, "erase") == touched, "large erase releases the complete owned footprint")
	check(layer.data.get_owned_samples(&"height").is_empty(), "large erase leaves no height ownership")

	layer.data.sample_spacing = 8.0
	check(StrataBrush.sample_limit_message(layer, Vector2.ZERO, 500.0).is_empty(), "500 m mountain radius fits an 8 m grid")
	check(StrataBrush.apply_brush(layer, Vector2.ZERO, 500.0, 2.0, "raise") > 0, "mountain radius exceeds the former 32 m and 80 m UI caps")
	layer.data.clear_channel(&"height")
	layer.data.sample_spacing = 2.0
	check(StrataBrush.sample_limit_message(layer, Vector2(0.5, 0.5), 254.0).is_empty(), "conservative radius recommendation fits at an offset grid phase")
	var revision: int = layer.data.get_revision()
	var message := StrataBrush.sample_limit_message(layer, Vector2.ZERO, 500.0)
	check(message.contains("254") and message.contains("NEW manual layer") and message.contains("No samples changed"), "dense brush reports a usable radius and a new layer spacing")
	var started := Time.get_ticks_usec()
	check(StrataBrush.apply_brush(layer, Vector2.ZERO, 500.0, 2.0, "raise") == 0, "dense fine-grid brush is rejected")
	check(Time.get_ticks_usec() - started < 500000, "dense rejection occurs before candidate iteration")
	check(layer.data.get_revision() == revision and layer.data.get_owned_samples(&"height").is_empty(), "dense rejection preserves values and ownership")

	terrain.base_bounds = Rect2(-1, -1, 2, 2)
	layer.data.sample_spacing = 1.0
	check(StrataBrush.sample_limit_message(layer, Vector2.ZERO, 1e30).is_empty(), "density guard uses the clipped finite terrain")
	check(StrataBrush.apply_brush(layer, Vector2.ZERO, 1e30, 1.0, "raise") == 9, "huge radius still applies on a tiny clipped terrain")
	layer.data.clear_channel(&"height")
	layer.data.set_sample(&"height", Vector2i.ZERO, 10.0)
	StrataBrush.apply_brush(layer, Vector2.ZERO, 2.0, 1.0, "smooth")
	check(is_zero_approx(terrain.sample_height(Vector2.ZERO)), "smoothing reads every original neighbor before any writes")
	check(layer.data.has_sample(&"height", Vector2i.ZERO), "smoothing retains explicit zero ownership")
	# Brush cursor: two bands (radius and half influence) on the surface shown for the layer.
	terrain.base_bounds = Rect2(-64, -64, 128, 128)
	layer.data.clear_channel(&"height")
	layer.data.sample_spacing = 1.0
	StrataBrush.apply_brush(layer, Vector2.ZERO, 8.0, 5.0, "raise")
	var cursor := StrataBrushCursor.new()
	terrain.add_child(cursor, false, Node.INTERNAL_MODE_BACK)
	check(not cursor.visible and cursor.get_owner() == null, "cursor starts hidden and is never owned by the scene")
	cursor.show_at(terrain, layer, Vector2.ZERO, 10.0, false, 0.5)
	var box := cursor.mesh.get_aabb()
	check(cursor.visible and cursor.mesh.get_surface_count() == 2, "cursor shows an outer and an inner band")
	check(is_equal_approx(box.size.x, 20.5) and is_equal_approx(box.size.z, 20.5), "outer band spans the brush diameter plus its width")
	check(box.end.y > 1.0 and box.position.y < 0.5, "cursor bands follow the sculpted surface through the selected layer")
	cursor.show_at(terrain, layer, Vector2.ZERO, 0.0, true)
	check(not cursor.visible, "cursor hides for an empty radius")
	cursor.show_at(terrain, layer, Vector2.ZERO, 4.0, true)
	check(cursor.visible, "blocked cursor is still drawn, in its warning colour")
	cursor.hide_cursor()
	check(not cursor.visible, "cursor hides on request")
	terrain.free()
	check(load("res://addons/strata/plugin.gd") != null, "editor brush script parses with the shared guard")
	print("Brush radius: %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)
