extends "res://tests/runtime_test_base.gd"
## Runtime freshness follows explicit HEGo intent and changed input layers, without
## starting HAPI. The bridge's editor plugin watches HEGo nodes in the editor; here the test
## watches them itself, as a game that edits HEGo inputs at runtime would.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene := Node3D.new(); root.add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, 2, 2); terrain.set_preview_enabled(false)
	scene.add_child(terrain); terrain.owner = scene
	var generated := StrataLayer.new(); generated.name = "Generated"; generated.procedural = true
	terrain.add_child(generated); generated.owner = scene
	var host := HEGoNode3D.new(); host.name = "Producer"; scene.add_child(host); host.owner = scene
	# What a commit by this host records on the layer.
	generated.producer_path = generated.get_path_to(host); generated.producer_id = HEGoStrataOutput.producer_id(host)
	HEGoStrataOutput.watch(host)
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
	check(loaded_generated.producer_path == NodePath("../../Producer") and loaded_generated.producer_id == "Producer", "the recorded producer survives the reload")
	HEGoStrataOutput.watch(loaded.get_node("Producer"))
	loaded.get_node("Producer").hego_notify_cook_inputs_changed()
	check(loaded_terrain.runtime_bake_stale and loaded_generated.producer_intent_revision == before + 2, "post-load HEGo parameter/input intent eagerly invalidates the runtime bake")
	# A changed input layer: Strata's own poll marks the result stale and the bake with it.
	var source := StrataLayer.new(); source.name = "Source"; terrain.add_child(source); terrain.move_child(source, 0)
	source.data.set_sample(&"height", Vector2i.ZERO, 1.0)
	var snapshot := StrataProcedural.create_snapshot(source, "raw", {"channels": ["height"]})
	var image := Image.create(2, 2, false, Image.FORMAT_RF); image.fill(Color(2, 0, 0))
	var ticket := StrataProcedural.begin_transaction(host, generated.producer_id, [{"layer": generated}], [snapshot])
	check(StrataProcedural.commit_fields(ticket, [{"layer_id": generated.layer_id, "fields": [{"name": "height", "image": image, "sample_origin": Vector3.ZERO, "sample_step_x": Vector3.RIGHT, "sample_step_y": Vector3.BACK}]}]).ok and not generated.procedural_stale, "a result built from an input layer publishes")
	check(StrataBake.bake(terrain).ok and not terrain.is_runtime_bake_stale(), "the current result bakes")
	var built := generated.producer_intent_revision
	source.data.set_sample(&"height", Vector2i.ZERO, 6.0)
	await create_timer(StrataTerrain3D.SOURCE_POLL_INTERVAL * 2.0).timeout
	check(generated.procedural_stale and generated.producer_intent_revision == built + 1 and terrain.is_runtime_bake_stale(), "a changed input layer makes the result and its runtime bake stale within a few frames")
	check(not HEGoAPI.get_singleton().is_session_active(), "no HAPI session was started")
	loaded.free(); scene.free()
	finish("RUNTIME_INTENT_TEST")
