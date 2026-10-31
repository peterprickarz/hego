extends SceneTree
## The brush on material weight channels paints coverage, not metres. The renderer normalizes
## the strongest weights, so adding strength to one channel never converges: a material pushed
## to a raw weight of 20 by many dabs made a 0.6 dab of another material invisible. A material
## dab now moves the painted material's share toward its target and rescales the others, writes
## every material channel at the touched samples, never produces a negative weight, and leaves
## the metre semantics of every other channel alone.
var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error("MATERIAL_BRUSH: " + message)

## A constant field covering the whole 64 m terrain on a 4 m lattice.
func field(channel: StringName, value: float) -> StrataFieldData:
	var image := Image.create(17, 17, false, Image.FORMAT_RF)
	image.fill(Color(value, 0, 0))
	return StrataFieldData.from_field({"name": channel, "image": image, "sample_origin": Vector3.ZERO, "sample_step_x": Vector3(4, 0, 0), "sample_step_y": Vector3(0, 0, 4)})

func shares(terrain: StrataTerrain3D, layer: StrataLayer, point: Vector2) -> Dictionary:
	var result := {}
	var total := 0.0
	for channel in terrain.editor_material_channels:
		result[channel] = terrain.sample_channel(StringName(channel), point, layer)
		total += result[channel]
	for channel in result: result[channel] = result[channel] / total if total > 0.0 else 0.0
	return result

## Every owned material sample of the layer is finite and nonnegative.
func nonnegative(layer: StrataLayer, channels: PackedStringArray) -> bool:
	for channel in channels:
		var rect: Rect2i = layer.data.get_owned_rect(StringName(channel))
		if not rect.has_area(): continue
		var dense: Dictionary = layer.data.read_dense(StringName(channel), rect.position, rect.size)
		for y in range(rect.size.y):
			for x in range(rect.size.x):
				if dense.ownership.get_pixel(x, y).r > 0.5:
					var value: float = dense.image.get_pixel(x, y).r
					if not is_finite(value) or value < 0.0: return false
	return true

func owns_any(layer: StrataLayer, channels: PackedStringArray, index: Vector2i) -> bool:
	for channel in channels:
		if layer.data.has_sample(StringName(channel), index): return true
	return false

func run() -> void:
	var channels := PackedStringArray(["material_a", "material_b", "material_c", "material_d"])
	var terrain := StrataTerrain3D.new()
	terrain.base_bounds = Rect2(0, 0, 64, 64)
	terrain.set_preview_enabled(false)
	var base := StrataLayer.new(); base.name = "Base"; terrain.add_child(base)
	base.data.set_sample(&"height", Vector2i.ZERO, 1.0)
	# The procedural mix a user hit: one material's raw weight far above the others.
	var distribution := StrataLayer.new(); distribution.name = "Distribution"; distribution.procedural = true; terrain.add_child(distribution)
	distribution.procedural_fields = {"material_a": field(&"material_a", 20.0), "material_c": field(&"material_c", 0.4)}
	var hand := StrataLayer.new(); hand.name = "Hand"; hand.data.sample_spacing = 1.0; terrain.add_child(hand)
	root.add_child(terrain)
	await process_frame
	var centre := Vector2(32.0, 32.0)
	var index := Vector2i(32, 32)

	# Without a material mapping a channel named like a material keeps the metre semantics.
	check(not StrataBrush.is_material_channel(hand, &"material_b"), "no material channels configured: not a material channel")
	check(StrataBrush.apply_brush(hand, centre, 6.0, 0.6, "raise", &"material_b") > 0, "metre dab applies without a mapping")
	check(is_equal_approx(terrain.sample_channel(&"material_b", centre, hand), 0.6), "without a mapping Raise adds the strength")
	check(StrataBrush.apply_brush(hand, centre, 6.0, 1.0, "erase", &"material_b") > 0, "metre erase applies")
	terrain.editor_material_channels = channels

	check(StrataBrush.is_material_channel(hand, &"material_b") and not StrataBrush.is_material_channel(hand, &"height"), "material channels are the terrain's editor_material_channels")
	check(StrataBrush.written_channels(hand, &"material_b") == Array(Array(channels), TYPE_STRING_NAME, "", null), "a material dab writes every material channel")
	check(StrataBrush.written_channels(hand, &"height") == Array([&"height"], TYPE_STRING_NAME, "", null), "a height dab writes its own channel")

	# Raise paints coverage: one 0.6 dab gives a 60 % share at the centre whatever the raw
	# weights below, and the other materials keep their proportions in the remaining 40 %.
	var before := shares(terrain, hand, centre)
	check(before.material_b == 0.0 and before.material_a > 0.97, "the procedural mix is almost entirely material_a")
	var touched := StrataBrush.apply_brush(hand, centre, 6.0, 0.6, "raise", &"material_b")
	check(touched > 0, "material raise applies")
	var after := shares(terrain, hand, centre)
	check(absf(after.material_b - 0.6) < 1e-4, "one 0.6 dab makes a 60 %% share at the centre, got %.4f" % after.material_b)
	check(absf(after.material_a / after.material_c - 50.0) < 1e-2, "the other materials keep their proportions")
	var raw_total := 0.0
	for channel in channels: raw_total += terrain.sample_channel(StringName(channel), centre, hand)
	check(absf(raw_total - 1.0) < 1e-5, "painted samples carry a normalized mix, got total %.4f" % raw_total)
	check(owns_any(hand, channels, index) and hand.data.has_sample(&"material_a", index) and hand.data.has_sample(&"material_d", index), "the layer owns every material channel at the touched samples")
	var edge := shares(terrain, hand, centre + Vector2(4.0, 0.0))
	check(edge.material_b > 0.0 and edge.material_b < after.material_b, "the falloff paints less toward the edge")
	check(nonnegative(hand, channels), "no negative weights after Raise")

	# Repeated dabs converge on 1 and never exceed it.
	for i in range(2): StrataBrush.apply_brush(hand, centre, 6.0, 0.6, "raise", &"material_b")
	var repeated := shares(terrain, hand, centre)
	check(absf(repeated.material_b - (1.0 - 0.4 * 0.4 * 0.4)) < 1e-4, "three dabs give 1 - 0.4^3, got %.4f" % repeated.material_b)
	for i in range(20): StrataBrush.apply_brush(hand, centre, 6.0, 1.0, "raise", &"material_b")
	var saturated := shares(terrain, hand, centre)
	check(saturated.material_b <= 1.0 + 1e-6 and saturated.material_b > 0.9999, "a saturated material stays at a 100 %% share")
	check(nonnegative(hand, channels), "no negative weights after saturation")

	# Lower removes the material; the others return in proportion.
	check(StrataBrush.apply_brush(hand, centre, 6.0, 1.0, "lower", &"material_b") > 0, "material lower applies")
	var lowered := shares(terrain, hand, centre)
	check(lowered.material_b < 1e-6, "a full-strength Lower removes the material at the centre")
	check(lowered.material_a > 0.97, "after Lower the mix below shows again")
	check(nonnegative(hand, channels), "no negative weights after Lower")

	# Flatten pulls toward the share where the stroke started; Smooth keeps weights valid.
	StrataBrush.apply_brush(hand, centre, 6.0, 0.5, "raise", &"material_b")
	var target := StrataBrush.flatten_target(hand, &"material_b", centre)
	check(absf(target - 0.5) < 1e-4, "flatten_target is the material's share, got %.4f" % target)
	check(is_equal_approx(StrataBrush.flatten_target(hand, &"height", centre), terrain.sample_channel(&"height", centre, hand)), "flatten_target of a scalar channel is its composed value")
	StrataBrush.apply_brush(hand, centre + Vector2(3.0, 0.0), 6.0, 1.0, "flatten", &"material_b", target)
	check(absf(shares(terrain, hand, centre + Vector2(3.0, 0.0)).material_b - target) < 1e-4, "Flatten reaches the recorded share")
	check(StrataBrush.apply_brush(hand, centre, 6.0, 0.5, "smooth", &"material_b") > 0, "material smooth applies")
	check(nonnegative(hand, channels), "no negative weights after Flatten and Smooth")
	var composed := StrataMaterialControls.compose(terrain, channels, hand)
	check(composed.get("ok", false) and not composed.get("empty", false), "the painted stack composes and packs")

	# Erase on a material channel releases every material channel of the layer there.
	check(StrataBrush.apply_brush(hand, centre, 12.0, 1.0, "erase", &"material_b") > 0, "material erase applies")
	check(not owns_any(hand, channels, index) and not owns_any(hand, channels, index + Vector2i(3, 0)), "Erase releases all material channels inside the dab")
	check(shares(terrain, hand, centre).material_a > 0.97, "after Erase the procedural mix shows through")

	# Undo records cover every written channel and restore the complete mix.
	var grid := StrataBrush.candidate_grid(hand, centre, 6.0)
	var records: Array = []
	for written in StrataBrush.written_channels(hand, &"material_d"): records.append(StrataBrush.begin_record(hand.data, written, grid))
	StrataBrush.apply_brush(hand, centre, 6.0, 0.8, "raise", &"material_d")
	var kept: Array = []
	for record in records:
		if StrataBrush.finish_record(hand.data, record): kept.append(record)
	check(kept.size() == 4, "a material dab on a fresh spot records all four channels, got %d" % kept.size())
	StrataBrush.restore_records(hand.data, kept, "before")
	check(not owns_any(hand, channels, index), "undo releases every channel the dab wrote")
	StrataBrush.restore_records(hand.data, kept, "after")
	check(absf(shares(terrain, hand, centre).material_d - 0.8) < 1e-4, "redo restores the painted share")
	StrataBrush.restore_records(hand.data, kept, "before")

	# An Add-mode channel stores the difference to the stack below; the composed share is the same.
	hand.set_composition(&"material_b", StrataLayer.Composition.ADD)
	StrataBrush.apply_brush(hand, centre, 6.0, 0.6, "raise", &"material_b")
	check(absf(shares(terrain, hand, centre).material_b - 0.6) < 1e-4, "an Add-mode material channel reaches the same share")
	check(nonnegative(hand, channels), "no negative weights with Add composition")

	# Other channels keep their metre semantics on the same layer.
	var height_before := terrain.sample_channel(&"height", centre, hand)
	check(StrataBrush.apply_brush(hand, centre, 6.0, 2.0, "raise", &"height") > 0, "height dab applies beside material samples")
	check(is_equal_approx(terrain.sample_channel(&"height", centre, hand) - height_before, 2.0), "Raise still adds metres to height")

	terrain.free()
	await process_frame
	print("MATERIAL_BRUSH checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
