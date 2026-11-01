extends SceneTree
## Exact raw transport + boundary acceptance setup. No HAPI session or cache writes.
const TRANSITION = preload("res://island/island_transition.gd")
var failures := 0
var checks := 0
func _initialize() -> void: run.call_deferred()
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures += 1; push_error(message)
func measurements(mean: float, p95: float, maximum: float, edges: int = 8) -> Dictionary:
	return {"ok": true, "edges": edges, "mean_step_m": mean, "p95_step_m": p95, "max_step_m": maximum}
func acceptance_policy_tests() -> void:
	var baseline := measurements(2.0, 4.0, 6.0)
	var runtime_baseline := measurements(2.5, 6.0, 7.7)
	var smooth := measurements(0.1, 0.2, 0.3)
	var runtime_smooth := measurements(0.5, 0.8, 1.0)
	var hashes := {"manual_fine_sha256": "a".repeat(64), "building_sha256": "b".repeat(64)}
	var fresh := TRANSITION.acceptance_policy(baseline, smooth, runtime_baseline, runtime_smooth, hashes)
	check(fresh.ok and fresh.mode == "fresh_improvement", "A new improved transition passes the original gate")
	var prior := {"before": baseline, "after": smooth, "runtime_before": runtime_baseline, "runtime_after": runtime_smooth, "protected_layers_identical": true, "detail_only": true, "source_generation": "original-unblended"}
	prior.merge(hashes)
	var repeated := TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, prior)
	check(repeated.ok and repeated.mode == "previously_accepted" and repeated.current_mean_step_reduction == 0.0, "An unchanged accepted result passes without inventing fresh improvement")
	check(repeated.reference_baseline.authoring == baseline and repeated.reference_baseline.runtime == runtime_baseline and repeated.reference_baseline.source_generation == "original-unblended", "Repeat retains the explicit original baseline")
	var next_prior := prior.duplicate(true)
	next_prior.before = smooth; next_prior.runtime_before = runtime_smooth
	next_prior.reference_baseline = repeated.reference_baseline
	check(TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, next_prior).ok, "Further repetitions do not ratchet the baseline toward the smooth result")
	check(TRANSITION.acceptance_policy(smooth, measurements(0.11, 0.21, 0.31), runtime_smooth, measurements(0.51, 0.81, 1.02), hashes, prior).ok, "Width retuning can retain comparably good residuals")
	check(not TRANSITION.acceptance_policy(smooth, measurements(0.5, 0.6, 1.0), runtime_smooth, measurements(1.1, 1.4, 2.0), hashes, prior).ok, "Material regression fails even if it still beats the original cliff baseline")
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes).ok, "An already smooth surface cannot claim an initial improvement without prior evidence")
	var changed_hashes := hashes.duplicate(); changed_hashes.building_sha256 = "c".repeat(64)
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, changed_hashes, prior).ok, "Changed manual inputs cannot reuse prior acceptance")
	check(not TRANSITION.acceptance_policy(measurements(0.11, 0.2, 0.3), measurements(0.11, 0.2, 0.3), runtime_smooth, runtime_smooth, hashes, prior).ok, "Prior evidence must match current measured geometry")
	var invalid := prior.duplicate(true); invalid.protected_layers_identical = false
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, invalid).ok, "Unproven manual preservation cannot bypass the fresh gate")
	invalid = prior.duplicate(true); invalid.after.mean_step_m = NAN
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, invalid).ok, "Nonfinite prior evidence cannot authorize repeats")
	invalid = prior.duplicate(true); invalid.reference_baseline = {"authoring": {"ok": true}, "runtime": runtime_baseline}
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, invalid).ok, "Malformed reference evidence cannot bypass the fresh gate")
	invalid = prior.duplicate(true); invalid.before = smooth; invalid.runtime_before = runtime_smooth
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, invalid).ok, "Prior evidence must itself prove an accepted result against its baseline")
	check(not TRANSITION.acceptance_policy(smooth, smooth, runtime_smooth, runtime_smooth, hashes, []).ok, "Malformed prior payload is rejected safely")
	repeated.reference_baseline.authoring.mean_step_m = 99.0
	check(baseline.mean_step_m == 2.0 and prior.before.mean_step_m == 2.0, "Returned reference evidence cannot alias accepted inputs")
func run() -> void:
	acceptance_policy_tests()
	var terrain := StrataTerrain3D.new()
	terrain._preview_enabled = false
	terrain.base_bounds = Rect2(-4.0, -4.0, 8.0, 8.0)
	root.add_child(terrain)
	var layers: Array[StrataLayer] = []
	for label in ["RoughBase", "CoarseErosion", "ManualFine", "DetailErosion", "BuildingFlatten"]:
		var layer := StrataLayer.new(); layer.name = label; terrain.add_child(layer); layers.append(layer)
	var image := Image.create(9, 9, false, Image.FORMAT_RF); image.fill(Color(10.0, 0.0, 0.0, 1.0))
	layers[0].data.grid_origin = Vector2(-4.0, -4.0)
	check(layers[0].data.replace_dense(&"height", Vector2i.ZERO, image), "Flat lower fixture")
	var manual := layers[4]
	manual.data.sample_spacing = 0.25
	manual.data.set_sample(&"height", Vector2i(-3, 2), 0.0)
	manual.data.set_sample(&"height", Vector2i(-2, 2), 2.0)
	manual.data.set_sample(&"height", Vector2i(-3, 3), 3.0)
	manual.data.set_sample(&"height", Vector2i(-2, 3), 4.0)
	manual.data.set_sample(&"constraint", Vector2i(1, -1), 0.0)
	var before := TRANSITION.manual_hash(manual)
	var snapshot := HEGoStrataInput.snapshot(manual, {"terrain_mode": "raw", "terrain_channels": "height,constraint", "terrain_compact_empty": true})
	check(snapshot.ok and snapshot.fields.size() == 4, "Raw input carries height and constraint with two ownership companions")
	var fields := {}
	for field in snapshot.fields: fields[field.name] = field
	check(fields.keys() == ["height", "height__ownership", "constraint", "constraint__ownership"], "Stable explicit volume names")
	check(fields.height.image.get_size() == Vector2i(2, 2) and fields.constraint.image.get_size() == Vector2i.ONE, "Channels retain independent compact rectangles")
	check(fields.height.sample_origin == Vector3(-0.75, 0.0, 0.5) and fields.height.sample_step_x == Vector3(0.25, 0.0, 0.0) and fields.height.sample_step_y == Vector3(0.0, 0.0, 0.25), "Negative-index quarter-metre native basis remains exact")
	check(fields.constraint.sample_origin == Vector3(0.25, 0.0, -0.25), "Constraint uses its own physical origin")
	check(fields.height.image.get_pixel(0, 0).r == 0.0 and fields.height__ownership.image.get_pixel(0, 0).r == 1.0, "Defined zero height remains owned")
	check(fields.constraint.image.get_pixel(0, 0).r == 0.0 and fields.constraint__ownership.image.get_pixel(0, 0).r == 1.0, "Defined zero protection stays distinct from no ownership")
	check(fields.height.image.get_pixel(1, 1).r == 4.0, "Authored falloff values remain raw, with no generic feathering")
	check(TRANSITION.manual_hash(manual) == before, "Snapshot does not alter values, modes or ownership")
	fields.height.image.set_pixel(0, 0, Color(123.0, 0.0, 0.0, 1.0))
	check(manual.data.get_sample(&"height", Vector2i(-3, 2)) == 0.0 and TRANSITION.manual_hash(manual) == before, "Export images are independent of authored storage")
	var metrics := TRANSITION.boundary_metrics(terrain, manual)
	check(metrics.ok and metrics.edges == 8 and is_equal_approx(metrics.mean_step_m, 7.75) and is_equal_approx(metrics.max_step_m, 10.0), "Acceptance measures actual exposed native boundaries including zero, not a guessed footprint")
	var compiled := StrataProcedural.compile_heightfield(terrain, null, 0.25)
	var grid_metrics := TRANSITION.compiled_boundary_metrics(manual, compiled)
	check(grid_metrics.ok and grid_metrics.edges == 8 and is_equal_approx(grid_metrics.mean_step_m, 7.75) and is_equal_approx(grid_metrics.max_step_m, 10.0), "Compiled boundary metric reads actual mesh vertex heights independently of the authoring sampler")
	var showcase: Node3D = load("res://island/island_showcase.gd").new()
	showcase.terrain = terrain
	showcase.hosts = [HEGoNode3D.new(), HEGoNode3D.new()]
	showcase._contract = {"operator": "Sop/test"}
	showcase._configure_hosts()
	var configured: Dictionary = showcase.hosts[1].input_stash[1].settings
	check(configured.terrain_channels == "height,constraint" and configured.terrain_mode == "raw" and configured.terrain_compact_empty, "Detail host requests exact raw targets alongside protection")
	manual.data.clear_channel(&"constraint")
	showcase._configure_hosts()
	check(not showcase.hosts[1].input_stash[1].inputs.is_empty(), "Owned height connects even without constraint values")
	var no_constraint := HEGoStrataInput.snapshot(manual, configured)
	check(no_constraint.ok and no_constraint.fields[2].image.get_size() == Vector2i.ONE and no_constraint.fields[3].image.get_pixel(0, 0).r == 0.0, "Absent optional constraint exports compact zero ownership")
	manual.data.clear_channel(&"height")
	manual.data.set_sample(&"constraint", Vector2i.ZERO, 1.0)
	showcase._configure_hosts()
	check(not showcase.hosts[1].input_stash[1].inputs.is_empty(), "Constraint-only inputs remain connected for erosion protection")
	manual.data.clear_channel(&"constraint")
	showcase._configure_hosts()
	check(showcase.hosts[1].input_stash[1].inputs.is_empty(), "No owned height or constraint disconnects the optional input")
	for host in showcase.hosts: host.free()
	showcase.free()
	check(not HEGoAPI.get_singleton().is_session_active(), "Transport acceptance does not start Houdini")
	terrain.free()
	print("ISLAND_TRANSITION_INPUT_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
