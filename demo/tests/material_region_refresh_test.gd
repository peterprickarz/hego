extends SceneTree
## Per-dab material work of the editor preview, on small artificial layers only (no saved
## island, asset writes, HAPI or cook). A manual layer above the material producer that
## also holds material samples must not recompose the material controls when a dab paints
## another channel, and a material dab must patch only its rectangle, with exactly the IDs
## and weights a complete composition gives.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_REGION: " + message)

## A partial procedural field: covers only the lattice's lower-left part, so packed maps
## have unassigned texels (the sparse case every editor map has).
func field(channel: StringName, origin: Vector3, size: Vector2i, value: float) -> StrataFieldData:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, Color(value * (0.5 + 0.5 * sin(x * 0.7 + y * 0.3)), 0, 0))
	return StrataFieldData.from_field({"name": channel, "image": image, "sample_origin": origin, "sample_step_x": Vector3(3, 0, 0), "sample_step_y": Vector3(0, 0, 3)})

func same_maps(a: Dictionary, b: Dictionary) -> bool:
	return a.get("ok", false) and b.get("ok", false) and a.ids.get_data() == b.ids.get_data() and a.weights.get_data() == b.weights.get_data()

func run() -> void:
	var channels := PackedStringArray(["material_a", "material_b", "material_c", "material_d"])
	var terrain := StrataTerrain3D.new()
	# Non-dyadic bounds: the 4 m lattice step is not exactly representable, so a window
	# must reproduce the full lattice's sample positions bit for bit.
	terrain.base_bounds = Rect2(-10.3, 5.7, 50.6, 50.6)
	terrain.set_preview_enabled(false)
	var base := StrataLayer.new(); base.name = "Base"; terrain.add_child(base)
	base.data.set_sample(&"height", Vector2i.ZERO, 1.0)
	var distribution := StrataLayer.new(); distribution.name = "Distribution"; distribution.procedural = true; terrain.add_child(distribution)
	distribution.procedural_fields = {"material_a": field(&"material_a", Vector3(-10.3, 0, 5.7), Vector2i(10, 9), 0.7), "material_c": field(&"material_c", Vector3(-4.3, 0, 8.7), Vector2i(8, 10), 0.4)}
	var hand := StrataLayer.new(); hand.name = "Hand"; hand.data.sample_spacing = 1.0; terrain.add_child(hand)
	hand.set_composition(&"material_b", StrataLayer.Composition.ADD)
	root.add_child(terrain)
	await process_frame
	terrain.editor_material_channels = channels
	for index in range(4): terrain.editor_materials.append(StrataMaterial.new())

	# Per-channel revisions: an edit to one channel leaves the others' revisions alone.
	var data := StrataLayerData.new()
	data.set_sample(&"height", Vector2i.ZERO, 1.0)
	data.set_sample(&"material_b", Vector2i.ZERO, 0.5)
	var material_revision: int = data.get_channel_revision(&"material_b")
	var whole_revision := data.get_revision()
	data.set_sample(&"height", Vector2i.ONE, 2.0)
	check(data.get_channel_revision(&"material_b") == material_revision and data.get_revision() > whole_revision, "a height edit advances the layer revision but not a material channel's")
	data.patch_dense(&"material_b", Vector2i(2, 2), Image.create(2, 2, false, Image.FORMAT_RF))
	check(data.get_channel_revision(&"material_b") > material_revision, "a material edit advances its own channel revision")
	material_revision = data.get_channel_revision(&"material_b")
	data.clear_channel(&"height")
	check(data.get_channel_revision(&"material_b") == material_revision and data.get_channel_revision(&"height") > material_revision, "clearing one channel changes only that channel")
	var restored := StrataLayerData.new()
	restored.restore(data.snapshot())
	check(restored.get_channel_revision(&"material_b") == restored.get_revision() and restored.get_revision() > 0, "a whole-resource restore advances every channel")

	# The editor's material cache key ignores dabs on channels it does not map.
	hand.data.set_sample(&"material_b", Vector2i(3, 12), 0.3)
	var signature := StrataMaterialControls.signature(terrain, channels, hand)
	check(StrataBrush.apply_brush(hand, Vector2(4.0, 20.0), 3.0, 0.6, "raise", &"height") > 0, "height dab on the material-holding hand layer applies")
	check(signature == StrataMaterialControls.signature(terrain, channels, hand), "a height dab on a layer holding material samples leaves the material signature unchanged")
	hand.data.set_sample(&"hole", Vector2i(5, 15), 1.0)
	check(signature == StrataMaterialControls.signature(terrain, channels, hand), "a mask edit leaves the material signature unchanged")
	check(StrataBrush.apply_brush(hand, Vector2(4.0, 20.0), 3.0, 0.4, "raise", &"material_b") > 0, "material dab applies")
	check(signature != StrataMaterialControls.signature(terrain, channels, hand), "a material dab changes the material signature")

	# A window of the lattice composes and packs exactly like the same rectangle of the
	# whole map, including unassigned texels and the lattice edges.
	var full := StrataMaterialControls.compose(terrain, channels, hand)
	check(full.ok and not full.get("empty", false) and full.ids.get_size() == Vector2i(14, 14), "complete composition covers the endpoint aligned 4 m lattice")
	var unassigned := 0
	for y in range(14):
		for x in range(14):
			if full.weights.get_pixel(x, y) == Color(0, 0, 0, 0): unassigned += 1
	check(unassigned > 0 and unassigned < 196, "the fixture has both assigned and unassigned texels")
	for window in [Rect2i(0, 0, 3, 4), Rect2i(3, 2, 5, 5), Rect2i(9, 10, 5, 4), Rect2i(11, 0, 9, 20), Rect2i(-2, -3, 6, 6)]:
		var region := StrataMaterialControls.compose_region(terrain, channels, hand, window)
		var clipped: Rect2i = window.intersection(Rect2i(0, 0, 14, 14))
		check(region.get("ok", false) and region.window == clipped, "window %s composes, clipped to the lattice" % window)
		if region.get("ok", false):
			check(region.ids.get_data() == full.ids.get_region(clipped).get_data() and region.weights.get_data() == full.weights.get_region(clipped).get_data(), "window %s equals the same rectangle of the complete map" % window)
	check(not StrataMaterialControls.compose_region(terrain, channels, base, Rect2i(0, 0, 4, 4)).get("ok", true), "a cutoff with no material channel has no lattice to patch")

	# Native sparse pack and the GDScript compatibility pack give identical maps, and
	# packing only the mapped channels equals the former 32-plane padding.
	var planes: Array[Image] = []
	for channel in channels:
		var composed: Dictionary = StrataLayerData.compose_dense(StrataProcedural._capture_layers(terrain, StringName(channel), hand), StringName(channel), Vector3(-10.3, 0, 5.7), Vector3(50.6 / 13.0, 0, 0), Vector3(0, 0, 50.6 / 13.0), Vector2i(14, 14), terrain.base_bounds, false, 0.0)
		planes.append(composed.image)
	var native := StrataMaterialControls._pack_sparse(planes)
	var compat := StrataMaterialControls._pack_sparse_compat(planes)
	check(same_maps(native, compat) and native.get("empty") == compat.get("empty") and not native.has("coverage"), "native sparse pack equals the compatibility pack")
	var padded := planes.duplicate()
	while padded.size() < 32: padded.append(Image.create(14, 14, false, Image.FORMAT_RF))
	check(same_maps(native, StrataMaterialControls._pack_sparse_compat(padded)), "packing the four mapped channels equals the 32-plane padded pack")
	var two: Array[Image] = [planes[0], planes[2]]
	var two_packed := StrataMaterialControls._pack_sparse(two)
	var two_padded: Array[Image] = [planes[0], planes[2]]
	while two_padded.size() < 32: two_padded.append(Image.create(14, 14, false, Image.FORMAT_RF))
	var reference := StrataMaterialControls._pack_sparse_compat(two_padded)
	var reference_ids: PackedByteArray = reference.ids.get_data()
	for index in range(reference_ids.size()):
		if reference_ids[index] >= 2: reference_ids[index] = 0
	check(two_packed.ok and two_packed.ids.get_data() == reference_ids and two_packed.weights.get_data() == reference.weights.get_data(), "a two-material pool keeps valid IDs without padding")
	var strict: Dictionary = StrataLayerData.pack_material_weights([Image.create(2, 2, false, Image.FORMAT_RF)])
	check(not strict.ok, "the strict producer pack still rejects unassigned texels")

	# The editor bridge: a height dab reuses the cached controls; a material dab patches
	# its rectangle of the cached and renderer maps, matching a complete composition.
	var bridge := StrataEditorPreview.new()
	bridge.terrain = terrain
	terrain.preview_through_layer = hand
	check(bridge._compose_material_controls(hand) and bridge._material_full, "bridge composes the complete lattice once")
	var renderer := StrataRenderer.new()
	check(renderer.set_control_maps(bridge._material_controls.ids, bridge._material_controls.weights), "renderer accepts the composed maps")
	bridge.renderer = renderer
	var compositions: int = bridge.get_stats().material_compositions
	StrataBrush.apply_brush(hand, Vector2(20.0, 30.0), 4.0, 0.6, "lower", &"height")
	check(not bridge._compose_material_controls(hand) and bridge.get_stats().material_compositions == compositions, "a height dab does not recompose material controls")
	for dab in range(3):
		var point := Vector2(12.0 + dab * 6.0, 26.0 + dab * 3.0)
		bridge._material_patchable = bridge._material_state(hand) == bridge._material_signature
		check(bridge._material_patchable, "controls are current before material dab %d" % dab)
		check(StrataBrush.apply_brush(hand, point, 4.0, 0.7, "raise", &"material_d") > 0, "material dab %d applies" % dab)
		check(bridge._refresh_material_region(point, 4.0 + 2.0 * hand.data.sample_spacing), "material dab %d patches its rectangle" % dab)
	check(StrataBrush.apply_brush(hand, Vector2(24.0, 32.0), 3.0, 1.0, "erase", &"material_d") > 0, "material erase applies")
	bridge._material_patchable = false
	check(not bridge._refresh_material_region(Vector2(24.0, 32.0), 5.0), "a dab after which the cache was not current falls back to a complete composition")
	check(bridge._compose_material_controls(hand), "the fallback recomposes the complete map")
	renderer.set_control_maps(bridge._material_controls.ids, bridge._material_controls.weights) # as _refresh() does
	bridge._material_patchable = true
	StrataBrush.apply_brush(hand, Vector2(36.0, 12.0), 4.0, 0.7, "raise", &"material_c")
	check(bridge._refresh_material_region(Vector2(36.0, 12.0), 6.0), "a material dab after the fallback patches again")
	check(not bridge._compose_material_controls(hand) and bridge.get_stats().material_compositions == compositions + 1, "patched controls stay current: no complete recomposition per dab")
	check(bridge.get_stats().material_regions == 4, "every patching dab is counted")
	var complete := StrataMaterialControls.compose(terrain, channels, hand)
	check(same_maps(bridge._material_controls, complete), "patched cached controls equal a complete composition")
	var expected := StrataRenderer.new()
	expected.set_control_maps(complete.ids, complete.weights)
	check(renderer._control_ids.get_data() == expected._control_ids.get_data() and renderer._control_weights.get_data() == expected._control_weights.get_data(), "patched renderer maps equal set_control_maps of a complete composition")
	check(not renderer.update_control_region(complete.ids.get_region(Rect2i(0, 0, 3, 3)), complete.weights.get_region(Rect2i(0, 0, 3, 3)), Vector2i(12, 12)), "an out-of-range region is refused")
	expected.free()
	renderer.free()
	bridge.free()
	terrain.free()
	await process_frame
	print("MATERIAL_REGION checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
