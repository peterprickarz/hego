extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func layer(terrain: StrataTerrain3D, spacing: float = 1.0, origin: Vector2 = Vector2.ZERO) -> StrataLayer:
	var result := StrataLayer.new()
	result.data.sample_spacing = spacing
	result.data.grid_origin = origin
	terrain.add_child(result)
	return result

func set_field(target: StrataLayer, value: float, origin: Vector3, sx: Vector3, sy: Vector3, channel: String = "hole") -> void:
	var image := Image.create(1, 1, false, Image.FORMAT_RF)
	image.fill(Color(value, 0, 0, 1))
	target.procedural_fields = {channel: StrataFieldData.from_field({"name": channel, "image": image, "sample_origin": origin, "sample_step_x": sx, "sample_step_y": sy})}

func run() -> void:
	var terrain := StrataTerrain3D.new()
	root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(0, 0, 4, 4)
	var lower := layer(terrain, 0.1, Vector2(0.3, 0.3))
	var upper := layer(terrain, 0.1, Vector2(0.3, 0.3))
	lower.data.set_sample(&"hole", Vector2i.ZERO, 1)
	var narrow := StrataProcedural.compile_cell_masks(terrain)
	check(narrow.ok and narrow.resolution == Vector2i(5, 5) and narrow.holes.count(255) == 1 and narrow.holes[0] == 255, "a 10cm authored hole survives inside a 1m cell without touching its corners")
	check(narrow.hole_image != null and narrow.hole_image.get_format() == Image.FORMAT_L8 and narrow.hole_image.get_size() == Vector2i(4, 4), "canonical bytes and L8 images share the exact output cell lattice")
	upper.data.set_sample(&"hole", Vector2i.ZERO, 0)
	var restored := StrataProcedural.compile_cell_masks(terrain)
	check(restored.ok and restored.holes.is_empty() and restored.hole_image == null, "upper explicit Solid restores a narrow lower Hole before reduction")
	upper.data.erase_sample(&"hole", Vector2i.ZERO)
	check(StrataProcedural.compile_cell_masks(terrain).holes.count(255) == 1, "erasing Solid ownership reveals the lower Hole")
	upper.data.sample_spacing = 0.25
	upper.data.set_sample(&"hole", Vector2i.ZERO, 0)
	check(StrataProcedural.compile_cell_masks(terrain).holes.is_empty(), "a coarser explicit Solid region fully restores a finer Hole")
	upper.data.erase_sample(&"hole", Vector2i.ZERO)
	upper.data.sample_spacing = 0.05
	upper.data.set_sample(&"hole", Vector2i.ZERO, 0)
	check(StrataProcedural.compile_cell_masks(terrain).holes.count(255) == 1, "a small Solid region cannot erase unoverridden parts of a larger Hole in the same target cell")
	var cutoff := StrataProcedural.compile_cell_masks(terrain, lower)
	check(cutoff.ok and cutoff.holes.count(255) == 1 and StrataProcedural.token_is_current(cutoff.token), "mask cutoffs and read-set tokens follow the authoring layer stack")
	lower.data.set_sample(&"hole", Vector2i(1, 0), 1)
	check(not StrataProcedural.token_is_current(cutoff.token), "later categorical ownership changes invalidate the mask token")
	upper.set_composition(&"hole", StrataLayer.Composition.ADD)
	check(not StrataProcedural.compile_cell_masks(terrain).ok, "categorical Add is rejected instead of inventing binary arithmetic")
	upper.set_composition(&"hole", StrataLayer.Composition.REPLACE)
	check(not StrataProcedural.compile_cell_masks(terrain, null, 1.0, {"max_work": 1}).ok, "work exhaustion rejects the whole mask without publishing partial cells")
	terrain.free()

	terrain = StrataTerrain3D.new(); root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(0, 0, 4, 4)
	lower = layer(terrain)
	upper = layer(terrain)
	var yaw := Basis(Vector3.UP, deg_to_rad(31.0))
	var sx := yaw * Vector3(0.2, 0, 0)
	var sy := yaw * Vector3(0, 0, 0.1)
	set_field(lower, 1, Vector3(1.3, 0, 1.2), sx, sy)
	check(StrataProcedural.compile_cell_masks(terrain).holes.count(255) == 1, "rotated anisotropic categorical regions preserve narrow exclusions")
	set_field(upper, 0, Vector3(1.3, 0, 1.2), sx, sy)
	check(StrataProcedural.compile_cell_masks(terrain).holes.is_empty(), "rotated exact-overlap Solid restores before conservative cell expansion")
	upper.procedural_fields = {}
	set_field(lower, 0.75, Vector3(1.3, 0, 1.2), sx, sy)
	check(not StrataProcedural.compile_cell_masks(terrain).ok, "continuous values need explicit categorical mapping")
	var converted := StrataProcedural.compile_cell_masks(terrain, null, 1, {"continuous_channels": PackedStringArray(["hole"]), "thresholds": {"hole": 0.5}})
	check(converted.ok and converted.holes.count(255) == 1, "explicit >= threshold maps continuous Houdini samples to categorical source regions")
	var below := StrataProcedural.compile_cell_masks(terrain, null, 1, {"continuous_channels": PackedStringArray(["hole"]), "thresholds": {"hole": 0.8}})
	check(below.ok and below.holes.is_empty(), "adjustable source thresholds are applied before overlap reduction")
	upper.data.grid_origin = Vector2(1.3, 1.2)
	upper.data.set_sample(&"hole", Vector2i.ZERO, 0)
	var manual_solid := StrataProcedural.compile_cell_masks(terrain, null, 1, {"continuous_channels": PackedStringArray(["hole"]), "thresholds": {"hole": 0.0}})
	check(manual_solid.ok and manual_solid.holes.is_empty(), "continuous imported thresholds never reinterpret an upper authored binary Solid")
	upper.data.erase_sample(&"hole", Vector2i.ZERO)
	lower.procedural_fields = {}
	lower.data.set_sample(&"nav_exclusion", Vector2i(2, 1), 1)
	var navigation := StrataProcedural.compile_cell_masks(terrain)
	check(navigation.ok and navigation.holes.is_empty() and navigation.nav_exclusions.count(255) == 4, "navigation exclusion is independent and expands only to overlapping cells")
	terrain.free()

	terrain = StrataTerrain3D.new(); root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(-2, -2, 4, 4)
	lower = layer(terrain)
	# This native pixel occupies [-1,0] x [-1,0]. Touching the adjacent
	# canonical cell boundaries must not exclude their interiors.
	set_field(lower, 1, Vector3(-0.5, 0, -0.5), Vector3(-1, 0, 0), Vector3(0, 0, 1))
	var reversed := StrataProcedural.compile_cell_masks(terrain)
	check(reversed.ok and reversed.holes.count(255) == 1 and reversed.holes[5] == 255, "negative axes and negative origins preserve exact positive-area overlap without touching-cell expansion")
	reversed.hole_image.set_pixel(1, 1, Color(0, 0, 0, 1))
	check(reversed.holes[5] == 255 and lower.sample_channel(&"hole", Vector2(-0.5, -0.5)).value == 1, "returned image, canonical bytes, and authoring data are independent")
	terrain.free()

	terrain = StrataTerrain3D.new(); root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(0, 0, 2, 2)
	lower = layer(terrain, 2, Vector2(1, 1))
	upper = layer(terrain)
	lower.data.set_sample(&"hole", Vector2i.ZERO, 1)
	set_field(upper, 0, Vector3(0.5, 0, 1), Vector3(0.25, 0, 0), Vector3(0, 0, 2))
	check(not StrataProcedural.compile_cell_masks(terrain, null, 1, {"max_fragments": 1}).ok, "fragment exhaustion fails closed before an incomplete topology map is returned")
	terrain.free()

	terrain = StrataTerrain3D.new(); root.add_child(terrain); terrain.set_preview_enabled(false)
	terrain.base_bounds = Rect2(-2048, -2048, 4096, 4096)
	layer(terrain)
	var started := Time.get_ticks_usec()
	var empty := StrataProcedural.compile_cell_masks(terrain, null, 1)
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	check(empty.ok and empty.resolution == Vector2i(4097, 4097) and empty.holes.is_empty() and empty.nav_exclusions.is_empty() and empty.hole_image == null and empty.nav_exclusion_image == null, "the 4km no-hole path allocates no cell masks or textures")
	print("CELL_MASK_4KM_EMPTY cpu_ms=%.3f work=%d" % [ms, empty.report.work])
	var sparse_layer: StrataLayer = terrain.get_layers()[0]
	sparse_layer.data.sample_spacing = 0.25
	sparse_layer.data.grid_origin = Vector2(0.5, 0.5)
	sparse_layer.data.set_sample(&"hole", Vector2i.ZERO, 1)
	started = Time.get_ticks_usec()
	var sparse := StrataProcedural.compile_cell_masks(terrain, null, 1)
	ms = (Time.get_ticks_usec() - started) / 1000.0
	check(sparse.ok and sparse.holes.size() == 4096 * 4096 and sparse.holes.count(255) == 1 and sparse.nav_exclusions.is_empty(), "a sparse submeter edit compiles to the full 4km canonical lattice without per-pixel script work")
	print("CELL_MASK_4KM_SPARSE cpu_ms=%.3f work=%d bytes=%d" % [ms, sparse.report.work, sparse.holes.size()])
	terrain.free()
	if failures.is_empty():
		print("HEGO_TERRAIN_CELL_MASK_PASS")
		quit(0)
	else:
		push_error("%d canonical cell-mask checks failed" % failures.size())
		quit(1)
