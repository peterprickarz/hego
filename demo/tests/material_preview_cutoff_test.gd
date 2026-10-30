extends SceneTree
## Small artificial scalar layers only. No saved island scene, asset writes,
## HAPI or procedural cook; exercises the editor's real composition/packing.
var checks := 0
var failures := 0
var channels := PackedStringArray(["material_a", "material_b", "material_c", "material_d"])

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_PREVIEW: " + message)

func scalar(channel: StringName, value: float) -> StrataFieldData:
	var image := Image.create(3, 3, false, Image.FORMAT_RF); image.fill(Color(value, 0, 0))
	return StrataFieldData.from_field({"name": channel, "image": image, "sample_origin": Vector3.ZERO, "sample_step_x": Vector3(4, 0, 0), "sample_step_y": Vector3(0, 0, 4)})

func contribution(packed: Dictionary, point: Vector2i, id: int) -> float:
	if not packed.get("ok", false): return -1.0
	var ids: Color = packed.ids.get_pixelv(point)
	var weights: Color = packed.weights.get_pixelv(point)
	var result := 0.0
	for slot in range(4):
		if roundi(ids[slot] * 255.0) == id: result += weights[slot]
	return result

func run() -> void:
	var terrain := StrataTerrain3D.new(); terrain.base_bounds = Rect2(0, 0, 8, 8); terrain.set_preview_enabled(false)
	var height := StrataLayer.new(); height.name = "HeightOnly"; terrain.add_child(height)
	var distribution := StrataLayer.new(); distribution.name = "Distribution"; distribution.procedural = true; terrain.add_child(distribution)
	distribution.procedural_fields = {"material_a": scalar(&"material_a", .75), "material_b": scalar(&"material_b", .25)}
	var hand := StrataLayer.new(); hand.name = "MaterialHand"; hand.data.sample_spacing = 4.0; terrain.add_child(hand)
	hand.set_composition(&"material_b", StrataLayer.Composition.ADD)
	hand.data.set_sample(&"material_b", Vector2i.ZERO, .5)
	root.add_child(terrain)
	await process_frame
	var early := StrataMaterialControls.compose(terrain, channels, height)
	check(early.ok and early.empty and early.weights.get_pixel(0, 0) == Color(0, 0, 0, 0), "a cutoff before all material stages is exactly unassigned")
	var packed := StrataMaterialControls.compose(terrain, channels, distribution)
	check(packed.ok and packed.ids.get_size() == Vector2i(3, 3), "material controls use the endpoint aligned physical 4m lattice")
	check(is_equal_approx(contribution(packed, Vector2i.ZERO, 0), .75) and is_equal_approx(contribution(packed, Vector2i.ZERO, 1), .25), "procedural fields compose at their physical coordinates in mapped ID order")
	packed = StrataMaterialControls.compose(terrain, channels)
	check(is_equal_approx(contribution(packed, Vector2i.ZERO, 0), .5) and is_equal_approx(contribution(packed, Vector2i.ZERO, 1), .5), "later material Add composes before normalization")
	hand.data.set_sample(&"material_a", Vector2i.ZERO, 0.0)
	packed = StrataMaterialControls.compose(terrain, channels)
	check(contribution(packed, Vector2i.ZERO, 0) == 0.0 and contribution(packed, Vector2i.ZERO, 1) == 1.0, "explicitly owned zero Replace erases an earlier contribution")
	check(is_equal_approx(contribution(packed, Vector2i(2, 2), 0), .75), "unowned hand samples cannot erase earlier assignments")
	distribution.enabled = false
	check(StrataMaterialControls.compose(terrain, channels, distribution).empty, "a disabled producer contributes no assignment at its cutoff")
	packed = StrataMaterialControls.compose(terrain, channels)
	check(packed.ok and contribution(packed, Vector2i.ZERO, 1) == 1.0 and packed.weights.get_pixel(2, 2) == Color(0, 0, 0, 0), "partial material ownership keeps uncovered texels exactly unassigned")
	check(distribution.procedural_fields.material_a.data.get_sample(&"material_a", Vector2i.ZERO) == .75, "sparse packing never changes the authored scalar fields")
	var zero := StrataMaterialControls.unassigned()
	var sampled := StrataRenderer.blend_control_samples(zero.ids, zero.weights, Vector2(4, 4), terrain.base_bounds)
	check(sampled.weights == PackedFloat32Array([0, 0, 0, 0]), "shader CPU reference never resurrects material zero for an unassigned lookup")
	check(StrataRenderer.height_blend_weights(Vector4.ZERO, Vector4.ONE, Vector4.ONE) == Vector4.ZERO, "height blending cannot resurrect source displacement on an unassigned surface")
	sampled = StrataRenderer.blend_control_samples(packed.ids, packed.weights, Vector2(8, 8), terrain.base_bounds)
	check(sampled.weights == PackedFloat32Array([0, 0, 0, 0]), "a fully uncovered control corner remains unassigned after interpolation")
	distribution.enabled = true
	terrain.move_child(hand, 1)
	packed = StrataMaterialControls.compose(terrain, channels)
	check(is_equal_approx(contribution(packed, Vector2i.ZERO, 0), .75), "reordering material layers changes actual composition")
	var signature := StrataMaterialControls.signature(terrain, channels)
	height.data.set_sample(&"height", Vector2i.ZERO, 19)
	check(signature == StrataMaterialControls.signature(terrain, channels), "height only brush edits leave the material cache current")
	distribution.procedural_fields.material_a.data.set_sample(&"material_a", Vector2i.ZERO, .25)
	check(signature != StrataMaterialControls.signature(terrain, channels), "field data edits invalidate materials without needing a cook revision")
	packed = StrataMaterialControls.compose(terrain, channels)
	check(is_equal_approx(contribution(packed, Vector2i.ZERO, 0), .5), "scalar edits reach the packed preview")
	signature = StrataMaterialControls.signature(terrain, channels)
	distribution.procedural_fields.material_a = scalar(&"material_a", 1.0)
	distribution.procedural_revision += 1
	check(signature != StrataMaterialControls.signature(terrain, channels), "a successful recook replacing field resources invalidates cached materials")
	packed = StrataMaterialControls.compose(terrain, channels)
	check(is_equal_approx(contribution(packed, Vector2i.ZERO, 0), .8), "recooked fields reach the selected stage without a final map binding")
	check(not StrataMaterialControls.compose(terrain, PackedStringArray(["same", "same"])).ok, "ambiguous material channel identities are rejected")
	var foreign := StrataLayer.new()
	check(not StrataMaterialControls.compose(terrain, channels, foreign).ok, "foreign cutoff cannot silently compose the complete stack")
	foreign.free()
	terrain.editor_material_channels = channels
	for index in range(4): terrain.editor_materials.append(StrataMaterial.new())
	terrain.editor_control_ids = packed.ids; terrain.editor_control_weights = packed.weights
	var saved_ids := terrain.editor_control_ids.get_data(); var saved_weights := terrain.editor_control_weights.get_data()
	var bridge := StrataEditorPreview.new(); terrain.add_child(bridge); bridge.setup(terrain)
	bridge._compose_material_controls(height)
	check(bridge._material_controls.weights.get_pixel(0, 0) == Color(0, 0, 0, 0), "editor binds composed stage controls even when saved final maps exist")
	var compiles: int = bridge.get_stats().material_compositions
	bridge._compose_material_controls(height)
	check(bridge.get_stats().material_compositions == compiles, "unchanged material inputs reuse their packed controls")
	height.data.set_sample(&"height", Vector2i.ONE, 23)
	bridge._compose_material_controls(height)
	check(bridge.get_stats().material_compositions == compiles, "height dabs do not trigger material composition")
	bridge._compose_material_controls(null)
	check(is_equal_approx(contribution(bridge._material_controls, Vector2i.ZERO, 0), .8), "returning to final layer restores the current complete enabled composition")
	check(terrain.editor_control_ids.get_data() == saved_ids and terrain.editor_control_weights.get_data() == saved_weights, "preview cutoffs never replace or mutate persisted final controls")
	terrain.editor_material_channels = PackedStringArray()
	bridge._compose_material_controls(height)
	check(bridge._material_controls.weights.get_pixel(0, 0) == Color(0, 0, 0, 0) and bridge._material_status.contains("configure ordered"), "legacy controls without provenance stay unassigned at selected stages with an explanation")
	bridge._compose_material_controls(null)
	check(bridge._material_controls.ids == terrain.editor_control_ids, "legacy final only cached controls remain compatible")
	terrain.editor_material_channels = PackedStringArray(["material_a"])
	terrain.editor_materials.resize(1)
	packed = StrataMaterialControls.compose(terrain, terrain.editor_material_channels)
	check(packed.ok and StrataRenderer._validate_control_images(packed.ids, packed.weights, 1), "generic one material mapping produces only valid pool IDs, including zero slots")
	terrain.free()
	await process_frame
	print("MATERIAL_PREVIEW checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
