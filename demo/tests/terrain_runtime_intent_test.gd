extends "res://tests/runtime_test_base.gd"
## Runtime freshness follows explicit HEGo intent, without starting HAPI.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene := Node3D.new(); root.add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, 2, 2); terrain.set_preview_enabled(false)
	scene.add_child(terrain); terrain.owner = scene
	var generated := StrataLayer.new(); generated.name = "Generated"; generated.procedural = true
	terrain.add_child(generated); generated.owner = scene
	var host := HEGoNode3D.new(); host.name = "Producer"; scene.add_child(host); host.owner = scene
	HEGoStrataTargets.ensure(host).targets = [{"path": "../Terrain/Generated"}]
	var baked := StrataBake.bake(terrain, {"allow_stale_procedural": true})
	check(baked.ok and not terrain.is_runtime_bake_stale(), "explicitly accepted saved procedural cache is fresh")
	var before := generated.producer_intent_revision
	var stale_notifications: Array = []
	terrain.runtime_bake_stale_changed.connect(func(stale: bool) -> void: stale_notifications.append(stale))
	host.hego_notify_cook_inputs_changed()
	check(generated.producer_intent_revision == before + 1 and terrain.runtime_bake_stale and stale_notifications == [true], "new HEGo intent invalidates and signals an already procedural-stale cache without a lazy query")
	check(StrataBake.bake(terrain, {"allow_stale_procedural": true}).ok, "new accepted cache bakes")
	generated.procedural_status = "Status display refreshed"
	check(generated.producer_intent_revision == before + 1 and not terrain.is_runtime_bake_stale(), "status refresh alone does not advance intent or invalidate a deliberately accepted cache")
	var packed := PackedScene.new()
	var scene_path := "user://runtime_intent_%d.scn" % OS.get_process_id()
	check(packed.pack(scene) == OK and ResourceSaver.save(packed, scene_path) == OK, "accepted cache scene saved")
	var loaded := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))
	root.add_child(loaded)
	var loaded_terrain: StrataTerrain3D = loaded.get_node("Terrain")
	var loaded_generated: StrataLayer = loaded_terrain.get_node("Generated")
	check(not loaded_terrain.is_runtime_bake_stale() and loaded_generated.producer_intent_revision == before + 1, "reload/status initialization preserves the accepted cache and persisted intent")
	loaded.get_node("Producer").hego_notify_cook_inputs_changed()
	check(loaded_terrain.runtime_bake_stale and loaded_generated.producer_intent_revision == before + 2, "post-load HEGo parameter/input intent eagerly invalidates the runtime bake")
	check(not HEGoAPI.get_singleton().is_session_active(), "no HAPI session was started")
	loaded.free(); scene.free()
	finish("RUNTIME_INTENT_TEST")
