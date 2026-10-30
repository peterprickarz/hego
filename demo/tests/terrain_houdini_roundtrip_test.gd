## Live Houdini heightfield round-trip plus standalone transaction/preservation checks.
## Run through scripts/run_terrain_houdini_integration.py; this starts a named-pipe HAPI session.
extends SceneTree

const OWNERSHIP_SUFFIX := "__ownership"

var _failures: Array[String] = []
var _timed_out := false

func _initialize() -> void:
	call_deferred("_run")

func _watchdog() -> void:
	_timed_out = true
	push_error("Integration test exceeded its watchdog; stopping the owned HAPI session")
	var api := HEGoAPI.get_singleton()
	if api != null and api.is_session_active():
		api.stop_session()
	quit(1)

func _run() -> void:
	var watchdog := create_timer(240.0)
	watchdog.timeout.connect(_watchdog)
	var ok := await _exercise()
	var api := HEGoAPI.get_singleton()
	if api != null and api.is_session_active():
		api.stop_session()
	if _timed_out:
		return
	if ok and _failures.is_empty():
		print("HEGO_TERRAIN_HOUDINI_ROUNDTRIP_PASS: live HAPI upload/cook/fetch and atomic terrain preservation")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)

func _check(condition: bool, message: String) -> bool:
	if not condition:
		_failures.append(message)
	return condition

func _await_task(task: HEGoTask, label: String) -> Dictionary:
	if task == null:
		return {"ok": false, "error": "%s returned no task" % label}
	while task.get_status() < HEGoTask.COMPLETED and not _timed_out:
		await process_frame
	if _timed_out:
		return {"ok": false, "error": "watchdog stopped while waiting for %s" % label}
	if task.get_status() != HEGoTask.COMPLETED:
		return {"ok": false, "error": "%s failed: %s" % [label, task.get_error_message()]}
	return {"ok": true, "result": task.get_result()}

func _field(name: String, image: Image, origin: Vector3, step_x: Vector3, step_y: Vector3, attrs: Dictionary = {}) -> Dictionary:
	return {
		"name": name,
		"image": image,
		"sample_origin": origin,
		"sample_step_x": step_x,
		"sample_step_y": step_y,
		"attrs": attrs.duplicate(true),
	}

func _rf(width: int, height: int, value: float) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	image.fill(Color(value, 0.0, 0.0, 1.0))
	return image

func _put_sample(image: Image, x: int, y: int, value: float) -> void:
	image.set_pixel(x, y, Color(value, 0.0, 0.0, 1.0))

func _get_field(fields: Array, name: String) -> Dictionary:
	for field in fields:
		if String(field.get("name", "")) == name:
			return field
	return {}

## Houdini returns each explicitly-owned channel as a companion volume. Rejoin
## that volume as the channel's binary ownership image before atomic publication.
func _join_ownership_volumes(fields: Array) -> Array:
	var values: Dictionary = {}
	var ownership: Dictionary = {}
	for field in fields:
		var name := String(field.get("name", ""))
		if name.ends_with(OWNERSHIP_SUFFIX):
			if field.get("attrs", {}).get("role", "") == "ownership":
				ownership[name.trim_suffix(OWNERSHIP_SUFFIX)] = field.get("image")
		else:
			values[name] = field.duplicate(true)
	for name in values:
		if ownership.has(name):
			values[name]["ownership"] = ownership[name]
	return values.values()

func _open_houdini(source_fields: Array, snippet: String) -> Dictionary:
	var input := HEGoHeightfieldInputNode.new()
	var set_result := await _await_task(input.set_fields(source_fields, true), "upload terrain fields")
	if not set_result.ok:
		return set_result
	# The test uses identity placement; it exercises arbitrary field grids without
	# involving scene transforms, while production keeps these coordinates local.
	var transform_result := await _await_task(input.set_transform(Transform3D.IDENTITY, true), "set heightfield transform")
	if not transform_result.ok:
		return transform_result

	var wrangle := HEGoAssetNode.new()
	wrangle.op_name = "Sop/volumewrangle"
	var wrangle_result := await _await_task(wrangle.instantiate(), "instantiate Volume Wrangle")
	if not wrangle_result.ok:
		return wrangle_result
	var snippet_result := await _await_task(wrangle.set_parm("snippet", snippet), "set Volume Wrangle snippet")
	if not snippet_result.ok:
		return snippet_result
	var connection_result := await _await_task(wrangle.connect_input(input, 0), "connect heightfield input")
	if not connection_result.ok:
		return connection_result
	var invalid_connection_first := await _await_task(wrangle.connect_input(input, 100000), "reject invalid input index")
	var invalid_connection_repeat := await _await_task(wrangle.connect_input(input, 100000), "reject repeated invalid input index")
	if not _check(not invalid_connection_first.ok and not invalid_connection_repeat.ok,
			"The same invalid native input connection must fail on every request"):
		return {"ok": false, "error": "invalid input connection was reported successful"}
	var cook_result := await _await_task(wrangle.cook(), "cook Volume Wrangle")
	if not cook_result.ok or cook_result.result == null:
		return {"ok": false, "error": "Houdini Volume Wrangle did not cook successfully"}
	var fetched := await _await_task(wrangle.get_heightfield_fields(PackedStringArray()), "fetch heightfield fields")
	if not fetched.ok:
		return fetched
	if not fetched.result is Array:
		return {"ok": false, "error": "get_heightfield_fields did not return an Array"}
	return {"ok": true, "input": input, "wrangle": wrangle, "fields": fetched.result}

func _commit(host: Node, producer: String, target: StrataLayer, snapshot: Dictionary, fields: Array) -> Dictionary:
	var ticket := StrataProcedural.begin_transaction(
		host,
		producer,
		[{"layer": target, "channels": PackedStringArray(["height", "mask", "constraint"])}],
		[snapshot]
	)
	if not ticket.get("ok", false):
		return ticket
	var joined := _join_ownership_volumes(fields)
	return StrataProcedural.commit_fields(ticket, [{"layer_id": target.ensure_identity(), "fields": joined}])

func _sample_height(layer: StrataLayer, at: Vector2) -> float:
	return float(layer.sample_channel(&"height", at).get("value", 0.0))

func _exercise() -> bool:
	# Fail before connecting to Houdini if the runner accidentally staged the
	# tracked old HEGo binary or an incompatible prototype extension.
	if not _check(ClassDB.class_exists("HEGoHeightfieldInputNode"), "HEGoHeightfieldInputNode is not registered"):
		return false
	if not _check(ClassDB.class_exists("StrataLayerData"), "StrataLayerData is not registered"):
		return false
	var input_probe: Object = ClassDB.instantiate("HEGoHeightfieldInputNode")
	if not _check(input_probe != null and input_probe.has_method("set_fields"), "Staged HEGo library has no set_fields() API; refusing a false-pass against an old binary"):
		return false
	if not _check(ClassDB.class_exists("HEGoAssetNode") and ClassDB.instantiate("HEGoAssetNode").has_method("get_heightfield_fields"), "Staged HEGo library has no strict heightfield-field fetch API"):
		return false
	if not _check(load("res://addons/strata/strata_procedural.gd") is Script, "StrataProcedural script was not imported"):
		return false

	var api := HEGoAPI.get_singleton()
	var pipe := "terrain_proto_%d" % OS.get_process_id()
	if not _check(api.start_session(HEGoAPI.SESSION_NAMED_PIPE, pipe), "Could not start owned named-pipe Houdini session"):
		return false

	var terrain := StrataTerrain3D.new()
	terrain.name = "RoundtripTerrain"
	terrain.base_bounds = Rect2(-3.0, -2.0, 6.0, 4.0)
	terrain.preview_spacing = 1.0
	terrain.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(31.0)), Vector3(10.0, 0.0, -8.0))
	root.add_child(terrain)
	var base := StrataLayer.new(); base.name = "CoarseBase"; terrain.add_child(base)
	var coarse := StrataLayer.new(); coarse.name = "ProceduralCoarse"; coarse.procedural = true; terrain.add_child(coarse)
	var fine := StrataLayer.new(); fine.name = "ManualFine"; fine.set_composition(&"height", StrataLayer.Composition.ADD); terrain.add_child(fine)
	var detail := StrataLayer.new(); detail.name = "ProceduralDetail"; detail.procedural = true; detail.set_composition(&"height", StrataLayer.Composition.REPLACE); terrain.add_child(detail)
	var building := StrataLayer.new(); building.name = "ManualBuildingFlatten"; terrain.add_child(building)
	var host := Node.new(); host.name = "IntegrationHost"; root.add_child(host)
	for layer in [base, coarse, fine, detail, building]:
		layer.ensure_identity()

	base.data.sample_spacing = 1.0
	base.data.grid_origin = Vector2(-3.0, -2.0)
	for y in range(5):
		for x in range(7):
			base.data.set_sample(&"height", Vector2i(x, y), 10.0 + x + 10.0 * y)
			base.data.set_sample(&"mask", Vector2i(x, y), 1.0)
			base.data.set_sample(&"constraint", Vector2i(x, y), 4.0 if x == 3 and y == 2 else 0.0)
	var before_base := base.data.snapshot()
	var coarse_input := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	if not _check(coarse_input.get("ok", false), "Could not snapshot coarse base: %s" % coarse_input.get("message", "")):
		return false
	var uploaded := await _open_houdini(coarse_input.fields, "@height += 10.0;")
	if not _check(uploaded.get("ok", false), "Coarse HAPI round-trip failed: %s" % uploaded.get("error", "")):
		return false
	var coarse_height := _get_field(uploaded.fields, "height")
	var coarse_mask := _get_field(uploaded.fields, "mask")
	var source_height := _get_field(coarse_input.fields, "height")
	if not _check(not coarse_height.is_empty() and not coarse_mask.is_empty(), "Houdini did not return both height and mask fields"):
		return false
	if not _check(coarse_height.image.get_size() == Vector2i(7, 5), "Rectangular 7x5 field dimensions changed in Houdini"):
		return false
	if not _check(coarse_height.sample_origin.is_equal_approx(source_height.sample_origin)
			and coarse_height.sample_step_x.is_equal_approx(source_height.sample_step_x)
			and coarse_height.sample_step_y.is_equal_approx(source_height.sample_step_y), "Houdini changed the sample-center origin or basis"):
		return false
	if not _check(source_height.sample_origin.x < 0.0 and source_height.sample_origin.z < 0.0, "Fixture did not exercise a negative offset grid"):
		return false
	var samples_match := true
	for y in range(5):
		for x in range(7):
			samples_match = samples_match and is_equal_approx(coarse_height.image.get_pixel(x, y).r, source_height.image.get_pixel(x, y).r + 10.0)
			samples_match = samples_match and is_equal_approx(coarse_mask.image.get_pixel(x, y).r, 1.0)
	if not _check(samples_match, "Asymmetric HAPI height ramp changed sample ordering/values or the mask channel"):
		return false
	if not _check(is_equal_approx(coarse_height.image.get_pixel(3, 2).r, 43.0), "Houdini Volume Wrangle did not add 10 to the ramp center"):
		return false
	var committed := _commit(host, "coarse-generator", coarse, coarse_input, uploaded.fields)
	if not _check(committed.get("ok", false), "Could not atomically publish procedural coarse result: %s" % committed.get("message", "")):
		return false
	if not _check(is_equal_approx(_sample_height(coarse, Vector2(0, 0)), 43.0), "Coarse procedural layer did not compose at the offset grid center"):
		return false
	if not _check(base.data.snapshot() == before_base, "Procedural commit modified the manual coarse base"):
		return false
	var old_coarse_field: StrataFieldData = coarse.procedural_fields["height"]

	# Fine manual ownership must be separate and continue to compose on a
	# procedural recook, even if the brush delta is explicitly owned at 0.
	fine.data.sample_spacing = 1.0
	fine.data.grid_origin = Vector2(-3.0, -2.0)
	fine.data.set_sample(&"height", Vector2i(3, 2), 3.0)
	fine.data.set_sample(&"height", Vector2i(4, 2), 0.0)
	if not _check(fine.data.has_sample(&"height", Vector2i(4, 2)), "Same-value manual fine touch lost explicit ownership"):
		return false
	var fine_snapshot := StrataProcedural.create_snapshot(fine, "raw", {"channels": PackedStringArray(["height"])})
	if not _check(fine_snapshot.get("ok", false) and fine_snapshot.fields.size() == 2, "Raw snapshot omitted manual values or ownership mask"):
		return false
	var fine_raw_value: Dictionary = fine_snapshot.fields[0]
	var fine_raw_ownership: Dictionary = fine_snapshot.fields[1]
	if not _check(fine_raw_value.image.get_size() == Vector2i(2, 1) and fine_raw_value.sample_origin.is_equal_approx(Vector3(0, 0, 0)), "Raw snapshot did not crop to the two explicitly owned samples at their physical offset"):
		return false
	if not _check(is_equal_approx(fine_raw_value.image.get_pixel(0, 0).r, 3.0) and is_zero_approx(fine_raw_value.image.get_pixel(1, 0).r)
			and is_equal_approx(fine_raw_ownership.image.get_pixel(0, 0).r, 1.0) and is_equal_approx(fine_raw_ownership.image.get_pixel(1, 0).r, 1.0), "Raw values/ownership changed for the explicit fine samples"):
		return false

	# A second procedural stage consumes the cumulative stack through the manual
	# fine layer (height base + coarse replacement + fine Add), then replaces its
	# own complete height result. This is a deterministic operation check, not an
	# erosion or production terrain algorithm.
	var detail_input := StrataProcedural.create_snapshot(fine, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	if not _check(detail_input.get("ok", false), "Could not snapshot through manual fine layer: %s" % detail_input.get("message", "")):
		return false
	var detail_cook := await _open_houdini(detail_input.fields, "@height += 2.0;")
	if not _check(detail_cook.get("ok", false), "Detail HAPI round-trip failed: %s" % detail_cook.get("error", "")):
		return false
	var detail_height := _get_field(detail_cook.fields, "height")
	if not _check(not detail_height.is_empty() and is_equal_approx(detail_height.image.get_pixel(3, 2).r, 48.0), "Detail stage did not consume the raw later fine constraint / expected cumulative height"):
		return false
	var detail_commit := _commit(host, "detail-generator", detail, detail_input, detail_cook.fields)
	if not _check(detail_commit.get("ok", false), "Detail stage commit failed: %s" % detail_commit.get("message", "")):
		return false
	if not _check(is_equal_approx(_sample_height(detail, Vector2(0, 0)), 48.0), "Detail result did not replace its complete target field"):
		return false

	# Manual building/flatten is another Replace layer and remains independent of
	# either producer's output.
	building.data.sample_spacing = 1.0
	building.data.grid_origin = Vector2(-3.0, -2.0)
	building.data.set_sample(&"height", Vector2i(1, 1), 4.0)
	var building_revision := building.data.get_revision()
	if not _check(is_equal_approx(_sample_height(building, Vector2(-2, -1)), 4.0) and building.data.get_revision() == building_revision, "Manual building layer did not retain its flatten sample"):
		return false

	# Cook the coarse producer again from a new source field, then re-commit. A
	# manual fine delta and explicit zero ownership must stay untouched.
	var recook_input := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	var recook := await _open_houdini(recook_input.fields, "@height += 20.0;")
	if not _check(recook.get("ok", false), "Procedural recook failed: %s" % recook.get("error", "")):
		return false
	var old_detail_revision := detail.procedural_revision
	var recook_commit := _commit(host, "coarse-generator", coarse, recook_input, recook.fields)
	if not _check(recook_commit.get("ok", false), "Procedural recook commit failed: %s" % recook_commit.get("message", "")):
		return false
	var recooked_coarse_field: StrataFieldData = coarse.procedural_fields["height"]
	if not _check(recooked_coarse_field != old_coarse_field and is_equal_approx(old_coarse_field.data.get_sample(&"height", Vector2i(3, 2)), 43.0)
			and is_equal_approx(recooked_coarse_field.data.get_sample(&"height", Vector2i(3, 2)), 53.0), "Replacing a procedural result mutated an older FieldData reference instead of publishing a new snapshot"):
		return false
	if not _check(is_equal_approx(_sample_height(fine, Vector2(0, 0)), 3.0) and fine.data.has_sample(&"height", Vector2i(4, 2)), "Procedural recook erased manual fine delta or same-value ownership"):
		return false
	if not _check(is_equal_approx(terrain.sample_height(Vector2(0, 0), fine), 56.0), "Manual fine Add did not remain layered over the recooked base"):
		return false
	if not _check(detail.procedural_revision == old_detail_revision, "Changing the upstream layer silently recooked downstream detail"):
		return false
	var recooked_detail_input := StrataProcedural.create_snapshot(fine, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	var recooked_detail := await _open_houdini(recooked_detail_input.fields, "@height += 2.0;")
	if not _check(recooked_detail.get("ok", false), "Downstream procedural refresh failed: %s" % recooked_detail.get("error", "")):
		return false
	var refresh_commit := _commit(host, "detail-generator", detail, recooked_detail_input, recooked_detail.fields)
	if not _check(refresh_commit.get("ok", false) and is_equal_approx(_sample_height(detail, Vector2(0, 0)), 58.0), "Downstream result did not refresh from the later manual constraint"):
		return false
	if not _check(is_equal_approx(_sample_height(building, Vector2(-2, -1)), 4.0), "Procedural recook changed manual building flatten"):
		return false

	# Revision/token checking: an edit between HAPI cook and publication rejects
	# the entire result, leaving the last complete procedural cache untouched.
	var stale_input := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height", "mask"])})
	var stale_cook := await _open_houdini(stale_input.fields, "@height += 1.0;")
	if not _check(stale_cook.get("ok", false), "Stale-input HAPI cook failed before the rejection check"):
		return false
	var stale_ticket := StrataProcedural.begin_transaction(host, "coarse-generator", [{"layer": coarse, "channels": PackedStringArray(["height", "mask"])}], [stale_input])
	if not _check(stale_ticket.get("ok", false), "Could not begin stale-input transaction"):
		return false
	var published_before := _sample_height(coarse, Vector2(0, 0))
	var published_revision := coarse.procedural_revision
	var published_field_ref: StrataFieldData = coarse.procedural_fields["height"]
	base.data.set_sample(&"height", Vector2i(3, 2), 11.0)
	var stale_result := StrataProcedural.commit_fields(stale_ticket, [{"layer_id": coarse.ensure_identity(), "fields": _join_ownership_volumes(stale_cook.fields)}])
	if not _check(not stale_result.get("ok", true), "Stale result was published instead of rejected"):
		return false
	if not _check(coarse.procedural_fields["height"] == published_field_ref and is_equal_approx(_sample_height(coarse, Vector2(0, 0)), published_before) and coarse.procedural_revision == published_revision, "Rejected stale result partially replaced the previous cache or invalidated its FieldData reference"):
		return false
	base.data.set_sample(&"height", Vector2i(3, 2), 33.0)

	# Multi-target publication must validate all target results before changing
	# either layer. Explicit-empty is also tested as an intentional complete result.
	var reject_a := StrataLayer.new(); reject_a.procedural = true; terrain.add_child(reject_a)
	var reject_b := StrataLayer.new(); reject_b.procedural = true; terrain.add_child(reject_b)
	var empty_snapshot := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height"])})
	var multi_ticket := StrataProcedural.begin_transaction(host, "atomic-reject-fixture", [
		{"layer": reject_a, "channels": PackedStringArray(["height"])},
		{"layer": reject_b, "channels": PackedStringArray(["height"])},
	], [empty_snapshot])
	if not _check(multi_ticket.get("ok", false), "Could not begin two-target atomicity transaction"):
		return false
	var empty_result := StrataProcedural.commit_fields(multi_ticket, [{"layer_id": reject_a.ensure_identity(), "fields": [], "explicit_empty": true}])
	if not _check(not empty_result.get("ok", true), "Partial multi-target result was not rejected"):
		return false
	if not _check(reject_a.procedural_fields.is_empty() and reject_b.procedural_fields.is_empty(), "Multi-target rejection partially published an explicit-empty result"):
		return false

	# Optional result channels may disappear on a complete replacement; required
	# omissions reject, while an explicit-empty marker clears the whole cache.
	var optional_target := StrataLayer.new(); optional_target.name = "OptionalChannelTarget"; optional_target.procedural = true; terrain.add_child(optional_target)
	var optional_declaration := {"layer": optional_target, "channels": PackedStringArray(["height", "mask"]), "required_channels": PackedStringArray(["height"])}
	var optional_height := _field("height", _rf(2, 2, 7.0), Vector3(-1, 0, -1), Vector3.RIGHT, Vector3(0, 0, 1), {"role": "value"})
	var optional_mask := _field("mask", _rf(2, 2, 1.0), Vector3(-1, 0, -1), Vector3.RIGHT, Vector3(0, 0, 1), {"role": "value"})
	var optional_snapshot := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height"])})
	var optional_ticket := StrataProcedural.begin_transaction(host, "optional-channel-fixture", [optional_declaration], [optional_snapshot])
	var optional_first := StrataProcedural.commit_fields(optional_ticket, [{"layer_id": optional_target.ensure_identity(), "fields": [optional_height, optional_mask]}])
	if not _check(optional_first.get("ok", false) and optional_target.procedural_fields.size() == 2, "Initial optional-channel result did not publish its complete channel set"):
		return false
	var old_optional_height: StrataFieldData = optional_target.procedural_fields["height"]
	var optional_revision := optional_target.procedural_revision
	var omitted_snapshot := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height"])})
	var omitted_ticket := StrataProcedural.begin_transaction(host, "optional-channel-fixture", [optional_declaration], [omitted_snapshot])
	var replacement_height := _field("height", _rf(2, 2, 9.0), Vector3(-1, 0, -1), Vector3.RIGHT, Vector3(0, 0, 1), {"role": "value"})
	var omitted_result := StrataProcedural.commit_fields(omitted_ticket, [{"layer_id": optional_target.ensure_identity(), "fields": [replacement_height]}])
	if not _check(omitted_result.get("ok", false) and optional_target.procedural_fields.size() == 1 and not optional_target.procedural_fields.has("mask"), "Omitted optional mask channel was not removed by complete replacement"):
		return false
	if not _check(optional_target.procedural_fields["height"] != old_optional_height and is_equal_approx(old_optional_height.data.get_sample(&"height", Vector2i.ZERO), 7.0)
			and is_equal_approx(optional_target.procedural_fields["height"].data.get_sample(&"height", Vector2i.ZERO), 9.0), "Optional replacement mutated an older cache reference"):
		return false
	var missing_required_snapshot := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height"])})
	var missing_required_ticket := StrataProcedural.begin_transaction(host, "optional-channel-fixture", [optional_declaration], [missing_required_snapshot])
	var missing_required := StrataProcedural.commit_fields(missing_required_ticket, [{"layer_id": optional_target.ensure_identity(), "fields": [optional_mask]}])
	if not _check(not missing_required.get("ok", true) and optional_target.procedural_revision == optional_revision + 1 and is_equal_approx(_sample_height(optional_target, Vector2(-1, -1)), 9.0), "Missing required height channel was accepted or replaced the prior result"):
		return false
	var empty_snapshot_for_target := StrataProcedural.create_snapshot(base, "cumulative", {"channels": PackedStringArray(["height"])})
	var explicit_empty_ticket := StrataProcedural.begin_transaction(host, "optional-channel-fixture", [optional_declaration], [empty_snapshot_for_target])
	var explicit_empty := StrataProcedural.commit_fields(explicit_empty_ticket, [{"layer_id": optional_target.ensure_identity(), "fields": [], "explicit_empty": true}])
	if not _check(explicit_empty.get("ok", false) and optional_target.procedural_fields.is_empty(), "Explicit-empty result did not clear the optional cache"):
		return false

	# Two targets may each return the ordinary channel name `height`. Routing is
	# keyed by the declared target path and stable layer ID, not a global name map.
	var multi_a := StrataLayer.new(); multi_a.name = "MultiRouteA"; multi_a.procedural = true; terrain.add_child(multi_a)
	var multi_b := StrataLayer.new(); multi_b.name = "MultiRouteB"; multi_b.procedural = true; terrain.add_child(multi_b)
	var multi_host := Node3D.new(); multi_host.name = "MultiRouteHost"; multi_host.transform = terrain.transform; root.add_child(multi_host)
	var multi_declarations := [
		{"path": String(multi_host.get_path_to(multi_a)), "channels": PackedStringArray(["height"])},
		{"path": String(multi_host.get_path_to(multi_b)), "channels": PackedStringArray(["height"])},
	]
	var multi_state := await HEGoStrataOutput.prepare(multi_host, [], multi_declarations, "duplicate-height-route")
	if not _check(multi_state.get("ok", false), "Could not bind two-target same-channel route fixture"):
		return false
	var multi_field_a := _field("height", _rf(2, 2, 8.0), Vector3(-1, 0, -1), Vector3.RIGHT, Vector3(0, 0, 1), {
		"hegostrata_layer_path": multi_declarations[0].path, "hegostrata_role": "value", "hegostrata_channel": "height",
	})
	var multi_field_b := _field("height", _rf(2, 2, 12.0), Vector3(-1, 0, -1), Vector3.RIGHT, Vector3(0, 0, 1), {
		"hegostrata_layer_path": multi_declarations[1].path, "hegostrata_role": "value", "hegostrata_channel": "height",
	})
	multi_field_a["coordinate_space"] = "sop_local"
	multi_field_b["coordinate_space"] = "sop_local"
	var routed_multi := HEGoStrataOutput.route_fields(multi_host, multi_state, [multi_field_a, multi_field_b])
	var committed_multi := StrataProcedural.commit_fields(multi_state.ticket, routed_multi.results) if routed_multi.get("ok", false) else routed_multi
	if not _check(committed_multi.get("ok", false) and is_equal_approx(_sample_height(multi_a, Vector2.ZERO), 8.0)
			and is_equal_approx(_sample_height(multi_b, Vector2.ZERO), 12.0), "Same-name height volumes did not route independently to their two procedural targets"):
		return false

	# A later raw constraint channel is transported by name and remains separate
	# from cumulative height composition, alongside mask and binary ownership.
	var constraint_snapshot := StrataProcedural.create_snapshot(base, "raw", {"channels": PackedStringArray(["height", "mask", "constraint"])})
	if not _check(constraint_snapshot.get("ok", false), "Raw later constraint snapshot failed"):
		return false
	var raw_height := _get_field(constraint_snapshot.fields, "height")
	var raw_ownership := _get_field(constraint_snapshot.fields, "height" + OWNERSHIP_SUFFIX)
	var raw_mask := _get_field(constraint_snapshot.fields, "mask")
	var raw_constraint := _get_field(constraint_snapshot.fields, "constraint")
	if not _check(not raw_height.is_empty() and not raw_ownership.is_empty() and not raw_mask.is_empty() and not raw_constraint.is_empty(), "Raw fields omitted height, mask, constraint or ownership"):
		return false
	if not _check(raw_ownership.attrs.role == "ownership", "Raw ownership field lost its explicit role"):
		return false
	var raw_roundtrip := await _open_houdini(constraint_snapshot.fields, "@height += 0.0;")
	if not _check(raw_roundtrip.get("ok", false), "Raw constraint/mask native round-trip failed: %s" % raw_roundtrip.get("error", "")):
		return false
	var returned_constraint := _get_field(raw_roundtrip.fields, "constraint")
	if not _check(not returned_constraint.is_empty() and is_equal_approx(returned_constraint.image.get_pixel(3, 2).r, 4.0), "Raw native round-trip changed or dropped the later constraint channel"):
		return false
	if not _check(not _get_field(raw_roundtrip.fields, "mask").is_empty(), "Raw native round-trip dropped mask"):
		return false

	# Exercise the actual HEGoNode3D.cook orchestration: the terrain source is
	# uploaded by its input agent, and returned volume primitive attributes route
	# both fields to the predeclared target in one atomic commit.
	var host_target := StrataLayer.new()
	host_target.name = "HostCookOutput"
	host_target.procedural = true
	terrain.add_child(host_target)
	host_target.ensure_identity()
	var host_script := load("res://addons/hego/HEGoNode3D.gd") as Script
	if not _check(host_script != null, "HEGoNode3D script did not load"):
		return false
	var cook_host: Variant = host_script.new()
	cook_host.name = "LiveHoudiniHost"
	cook_host.asset_name = "Sop/attribwrangle"
	cook_host.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-17.0)), Vector3(15.0, 2.0, 3.0))
	root.add_child(cook_host)
	var cook_binding := HEGoStrataTargets.ensure(cook_host)
	cook_binding.producer_id = "terrain-integration-host"
	var target_path := String(cook_host.get_path_to(host_target))
	var input_path := String(cook_host.get_path_to(fine))
	var host_targets: Array[Dictionary] = [{"path": target_path, "channels": PackedStringArray(["height", "mask"])}]
	cook_binding.targets = host_targets
	cook_host.hego_set_input_stash([{
		"inputs": [input_path],
		"settings": {"terrain_mode": "cumulative", "terrain_channels": PackedStringArray(["height", "mask"])},
	}])
	var route_snippet := "s@hegostrata_layer_path = \"%s\";" % target_path
	var host_asset: HEGoAssetNode = cook_host.agent.asset(cook_host.asset_name)
	var host_instantiated: bool = await cook_host.agent.instantiate(host_asset)
	if not _check(host_instantiated, "Could not instantiate built-in SOP through HEGoNode3D's asset agent"):
		return false
	var route_set := await _await_task(host_asset.set_parms_batch({"class": 1, "snippet": route_snippet}), "set primitive routing attributes")
	if not _check(route_set.ok, "Could not set primitive routing attributes: %s" % route_set.get("error", "")):
		return false
	await cook_host.cook()
	if not _check(host_target.procedural_revision == 1 and not host_target.procedural_stale, "HEGoNode3D.cook did not atomically publish routed output: %s" % host_target.procedural_status):
		return false
	if not _check(is_equal_approx(_sample_height(host_target, Vector2(0, 0)), 56.0), "HEGoNode3D.cook output did not include the manual fine input stack"):
		return false
	var routed_height: StrataFieldData = host_target.procedural_fields["height"]
	var routed_local_center := routed_height.physical_position(Vector2(3.0, 2.0))
	var routed_world_center := terrain.to_global(routed_local_center)
	if not _check(routed_world_center.is_equal_approx(terrain.to_global(Vector3.ZERO)), "Translated/yawed terrain and separate HEGo host transforms produced the wrong numeric output position: %s" % str(routed_world_center)):
		return false
	var host_published_revision := host_target.procedural_revision
	var host_published_value := _sample_height(host_target, Vector2(0, 0))
	var host_field_ref: StrataFieldData = host_target.procedural_fields["height"]
	var invalid_merge := HEGoMergeNode.new()
	var invalid_merge_instance := await _await_task(invalid_merge.instantiate(), "instantiate merge for failure propagation")
	if not _check(invalid_merge_instance.ok, "Could not instantiate native merge failure fixture"):
		return false
	var invalid_merge_connection := await _await_task(invalid_merge.connect_inputs([null]), "reject null merge input")
	if not _check(not invalid_merge_connection.ok, "Native merge accepted a null input row"):
		return false
	if not _check(host_target.procedural_fields["height"] == host_field_ref
			and host_target.procedural_revision == host_published_revision
			and is_equal_approx(_sample_height(host_target, Vector2(0, 0)), host_published_value),
			"A rejected native merge connection changed the last published terrain cache"):
		return false
	var host_input_names := await _await_task(host_asset.get_input_names(), "read host input count")
	if not _check(host_input_names.ok and host_input_names.result is PackedStringArray, "Could not read the host HDA input count"):
		return false
	var input_names: PackedStringArray = host_input_names.result
	var extra_mesh := MeshInstance3D.new()
	extra_mesh.name = "UnexpectedExtraInput"
	extra_mesh.mesh = BoxMesh.new()
	root.add_child(extra_mesh)
	var input_rows: Array = [{"inputs": [input_path], "settings": {"terrain_mode": "cumulative", "terrain_channels": PackedStringArray(["height", "mask"])}}]
	while input_rows.size() <= input_names.size(): input_rows.append({"inputs": [], "settings": {}})
	input_rows.append({"inputs": [String(cook_host.get_path_to(extra_mesh))], "settings": {}})
	cook_host.hego_set_input_stash(input_rows)
	await cook_host.cook()
	if not _check(host_target.procedural_fields["height"] == host_field_ref and host_target.procedural_revision == host_published_revision
			and host_target.procedural_stale and is_equal_approx(_sample_height(host_target, Vector2(0, 0)), host_published_value), "An incompatible extra input row changed the previous host cache"):
		return false
	cook_host.hego_set_input_stash([{"inputs": [input_path], "settings": {"terrain_mode": "cumulative", "terrain_channels": PackedStringArray(["height", "mask"])}}])
	var invalid_route := route_snippet.replace(target_path, "../RoundtripTerrain/MissingTarget")
	var invalid_set := await _await_task(host_asset.set_parms_batch({"class": 1, "snippet": invalid_route}), "set deliberately invalid output route")
	if not _check(invalid_set.ok, "Could not set rejected route fixture"):
		return false
	await cook_host.cook()
	if not _check(host_target.procedural_fields["height"] == host_field_ref and host_target.procedural_revision == host_published_revision and is_equal_approx(_sample_height(host_target, Vector2(0, 0)), host_published_value), "Rejected host cook partially replaced its previous procedural cache"):
		return false
	if not _check(host_target.procedural_stale and host_target.procedural_status.contains("unbound"), "Invalid HAPI route did not leave the target stale with a useful status"):
		return false

	print("HAPI_TERRAIN_FIELD_LAYOUT ", coarse_height.resolution, " origin=", coarse_height.sample_origin, " x=", coarse_height.sample_step_x, " y=", coarse_height.sample_step_y)
	print("HAPI_TERRAIN_FIELD_CHANNELS ", uploaded.fields.map(func(field: Dictionary) -> String: return String(field.get("name", ""))))
	return true
