extends "res://tests/runtime_test_base.gd"
## Runs in the runtime-only project (no native extension, HEGo or Houdini):
## the exported scene's macro map loads, validates, binds and samples exactly
## as it did in the authoring project.

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(not ClassDB.class_exists("StrataLayerData"), "runtime-only project has no native terrain extension")
	var scene := ResourceLoader.load("res://export/macro_level.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := scene.instantiate() if scene != null else null
	var data: StrataRuntimeData = instance.get_meta("strata_runtime_data") if instance != null else null
	check(data != null and data.validate().ok, "exported macro runtime data loads and validates")
	var probe: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://export/macro_probe.json"))
	if data != null and probe is Dictionary:
		var bounds := Rect2(probe.bounds[0], probe.bounds[1], probe.bounds[2], probe.bounds[3])
		check(data.has_macro() and data.get_macro_bounds() == bounds and data.get_macro_binding().ok, "macro map and exact bounds survive the runtime-only load")
		check(data.render_settings != null and data.render_settings.has_method("parameters"), "baked render settings load in the runtime-only project")
		for sample in probe.samples:
			var result := data.sample_macro(Vector2(sample[0], sample[1]))
			check(result.status == StrataRuntimeData.Status.OK, "probe %s is inside the macro bounds" % [sample])
			for c in range(3): near(result.tint[c], sample[2 + c], 0.000001, "probe %s tint %d" % [sample, c])
			near(result.ao, sample[5], 0.000001, "probe %s ao" % [sample])
	if instance != null: instance.free()
	finish("RUNTIME_MACRO_ROUNDTRIP_TEST")
