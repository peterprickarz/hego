extends SceneTree
## Focused standalone transaction regressions. No HEGo/Houdini extension needed.

var failures := 0
func _initialize() -> void: _run.call_deferred()
func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func field(value: float, ownership: Image = null) -> Dictionary:
	var image := Image.create(2, 2, false, Image.FORMAT_RF)
	image.fill(Color(value, 0.0, 0.0, 1.0))
	var result := {"name": "height", "image": image, "sample_origin": Vector3(-1.0, 0.0, -1.0), "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK}
	if ownership != null: result.ownership = ownership
	return result

func target(terrain: StrataTerrain3D, label: String) -> StrataLayer:
	var layer := StrataLayer.new()
	layer.name = label
	layer.procedural = true
	terrain.add_child(layer)
	return layer

func ticket(host: Node, targets: Array, snapshot: Dictionary) -> Dictionary:
	var declarations: Array = []
	for layer in targets: declarations.append({"layer": layer, "channels": ["height"]})
	return StrataProcedural.begin_transaction(host, "focused-test", declarations, [snapshot])

func _run() -> void:
	var scene := Node3D.new(); root.add_child(scene); current_scene = scene
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(-2.0, -2.0, 4.0, 4.0); scene.add_child(terrain)
	var source := StrataLayer.new(); terrain.add_child(source)
	source.data.set_sample(&"height", Vector2i.ZERO, 2.0)
	source.data.set_sample(&"mask", Vector2i.ZERO, 0.0)
	var selected := StrataLayer.new(); selected.data.sample_spacing = 0.5; terrain.add_child(selected)
	var a := target(terrain, "A"); var b := target(terrain, "B")
	var snapshot := StrataProcedural.create_snapshot(selected, "cumulative", {"channels": ["height"]})
	check(snapshot.ok, "Cumulative snapshot succeeds")
	var old := ticket(scene, [a], snapshot)
	var newer := ticket(scene, [a], snapshot)
	check(old.ok and newer.ok, "Overlapping generations can stage independently")
	var newer_result := StrataProcedural.commit_fields(newer, [{"layer_id": a.layer_id, "fields": [field(9.0)]}])
	check(newer_result.ok, "Newest generation publishes")
	var published: StrataFieldData = a.procedural_fields["height"]
	var published_status := a.procedural_status
	var old_result := StrataProcedural.commit_fields(old, [{"layer_id": a.layer_id, "fields": [field(1.0)]}])
	check(not old_result.ok and a.procedural_fields["height"] == published, "Late generation cannot overwrite a newer resource")
	check(not a.procedural_stale and a.procedural_status == published_status, "Late rejection cannot mark a newer success stale")
	var ownership := Image.create(2, 2, false, Image.FORMAT_RF); ownership.fill(Color(0.25, 0.0, 0.0, 1.0))
	var invalid := ticket(scene, [a], snapshot)
	var invalid_result := StrataProcedural.commit_fields(invalid, [{"layer_id": a.layer_id, "fields": [field(-5.0, ownership)]}])
	check(not invalid_result.ok and a.procedural_fields["height"] == published and a.procedural_revision == 1, "Fractional raw ownership rejects without changing the prior cache")
	var multi := ticket(scene, [a, b], snapshot)
	var atomic_failure := StrataProcedural.commit_fields(multi, [{"layer_id": a.layer_id, "fields": [field(3.0)]}, {"layer_id": b.layer_id, "fields": [field(4.0, ownership)]}])
	check(not atomic_failure.ok and a.procedural_fields["height"] == published and b.procedural_fields.is_empty(), "One malformed target prevents every target publication")
	var valid_multi := ticket(scene, [a, b], snapshot)
	var multi_result := StrataProcedural.commit_fields(valid_multi, [{"layer_id": a.layer_id, "fields": [field(5.0)]}, {"layer_id": b.layer_id, "fields": [field(13.0)]}])
	check(multi_result.ok and a.procedural_fields["height"] != b.procedural_fields["height"], "Same-name height fields publish independently to two targets")
	check(is_equal_approx(a.sample_channel(&"height", Vector2.ZERO).value, 5.0) and is_equal_approx(b.sample_channel(&"height", Vector2.ZERO).value, 13.0), "Independent same-name result values compose correctly")
	check(is_equal_approx(published.data.get_sample(&"height", Vector2i.ZERO), 9.0), "Fresh publication preserves old references for undo/readers")
	var coverage := StrataProcedural.create_snapshot(selected, "cumulative", {"channels": ["mask"]})
	check(coverage.ok and is_equal_approx(coverage.fields[1].image.get_pixel(5, 4).r, 0.5), "Cumulative custom-channel support retains fractional coverage")
	var raw_empty := StrataProcedural.create_snapshot(selected, "raw", {"channels": ["constraint"]})
	check(raw_empty.ok and raw_empty.fields[1].image.get_pixel(4, 4).r == 0.0, "Empty raw constraints export explicit zero ownership")
	var other := StrataTerrain3D.new(); other.base_bounds = terrain.base_bounds; scene.add_child(other)
	var separate := target(other, "SeparateTarget")
	var other_ticket := ticket(scene, [separate], snapshot)
	other.position.y = 3.0
	var moved := StrataProcedural.commit_fields(other_ticket, [{"layer_id": separate.layer_id, "fields": [field(6.0)]}])
	check(not moved.ok and separate.procedural_fields.is_empty(), "Moving a separate destination terrain rejects its stale cook")
	var detached_ticket := ticket(scene, [a], snapshot)
	selected.reparent(other)
	var detached := StrataProcedural.commit_fields(detached_ticket, [{"layer_id": a.layer_id, "fields": [field(99.0)]}])
	check(not detached.ok and is_equal_approx(a.sample_channel(&"height", Vector2.ZERO).value, 5.0), "Reparenting a snapshot source rejects without replacing its target")
	selected.free()
	check(not StrataProcedural.token_is_current(snapshot.token), "Deleting a captured source invalidates its read token safely")
	current_scene = null; scene.free()
	print("PROCEDURAL_TRANSACTION_TEST: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
