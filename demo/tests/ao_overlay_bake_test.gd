extends SceneTree
## StrataAOOverlayBaker on a local RenderingDevice with small synthetic inputs: a MultiMesh source
## darkens the ground under its instances only, the same instances supplied as packed raw data
## bake the same map and report their counts, a coarse tile is rasterized finer and still returns
## a map of its own resolution, an empty input returns no image, and the overlay's mip_scale
## reaches the renderer's settings.
const TILE := Rect2(0.0, 0.0, 16.0, 16.0)
const RESOLUTION := 64  # 0.25 m per texel: not supersampled
const OPTIONS := {"rules": {}, "default": {"footprint": 2.0, "strength": 0.8}, "max_radius": 2.5, "floor": 0.3}
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

## A unit box whose AABB centre is off its origin, so the bake has to transform the centre.
func offset_box() -> ArrayMesh:
	var arrays := BoxMesh.new().get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for index in vertices.size(): vertices[index] += Vector3(0.6, 0.0, 0.3)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Instance transforms inside TILE: plain, scaled, and rotated and scaled.
func instance_transforms() -> Array[Transform3D]:
	return [
		Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, 4.0)),
		Transform3D(Basis.IDENTITY.scaled(Vector3(1.5, 1.0, 1.5)), Vector3(8.0, 0.2, 8.0)),
		Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)).scaled(Vector3(1.2, 1.0, 1.2)), Vector3(12.0, 0.0, 5.0)),
	]

## Value (0-255) of the texel that holds world point [param at] of [param rect].
func texel(image: Image, rect: Rect2, at: Vector2) -> int:
	var cell := Vector2i(((at - rect.position) / rect.size * image.get_width()).floor())
	return image.get_pixelv(cell).r8

func largest_difference(a: Image, b: Image) -> int:
	var x := a.get_data(); var y := b.get_data()
	var largest := 0
	for index in x.size(): largest = maxi(largest, absi(x[index] - y[index]))
	return largest

func histogram_total(histogram: PackedInt32Array) -> int:
	var total := 0
	for count in histogram: total += count
	return total

func run() -> void:
	create_timer(120.0).timeout.connect(func() -> void: push_error("AO overlay bake test watchdog"); quit(1))
	if DisplayServer.get_name() == "headless" or not StrataAOOverlayBaker.available():
		push_error("Use a graphical run (the baker needs a local RenderingDevice)"); quit(2); return
	var mesh := offset_box()
	var aabb := mesh.get_aabb()
	var transforms := instance_transforms()

	# (1) A MultiMeshInstance3D source with the default rule.
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size(): multimesh.set_instance_transform(index, transforms[index])
	var source := MultiMeshInstance3D.new()
	source.multimesh = multimesh
	var collected := StrataAOOverlayBaker.collect([source], OPTIONS, TILE)
	check(int(collected.instances) == transforms.size(), "collect() gathers every instance")
	var band := 2.0 * float(OPTIONS.max_radius)
	var mesh_bake := StrataAOOverlayBaker.bake(TILE, RESOLUTION, collected, PackedFloat32Array(), OPTIONS, band)
	check(mesh_bake.ok and mesh_bake.get("image") is Image, "A mesh source bakes an image")
	if not (mesh_bake.get("image") is Image):
		print("AO_OVERLAY_BAKE_TEST failures=", failures); quit(1); return
	var image: Image = mesh_bake.image
	check(image.get_width() == RESOLUTION and image.get_height() == RESOLUTION and image.get_format() == Image.FORMAT_R8, "The map is an R8 image of the requested resolution")
	var under: Array[int] = []
	for xform in transforms:
		var centre := xform * aabb.get_center()
		under.append(texel(image, TILE, Vector2(centre.x, centre.z)))
	var far := texel(image, TILE, Vector2(15.8, 15.8))
	print("AO mesh: under instances %s, far %d, edge blobs %d" % [str(under), far, mesh_bake.edges.size() / 4])
	check(under.all(func(value: int) -> bool: return value < 160), "Ground under every instance is clearly occluded")
	check(far == 255, "Ground far from every instance is unoccluded")
	# Instances 0 (4 m from an edge) and 2 (4 m from the far x edge) lie within the 5 m band.
	check(mesh_bake.edges.size() == 8, "Two instances near the tile's edges give edge blobs")

	# (2) The same instances as packed raw data, plus one outside the tile and one of an object
	# with strength 0. The origin entry is subtracted from each instance origin.
	var origin := Vector3(2.0, 0.5, 1.0)
	var raw_transforms := PackedFloat32Array()
	var objects := PackedInt32Array()
	var placed: Array[Transform3D] = transforms.duplicate()
	placed.append(Transform3D(Basis.IDENTITY, Vector3(30.0, 0.0, 30.0)))
	placed.append(Transform3D(Basis.IDENTITY, Vector3(10.0, 0.0, 12.0)))
	for index in placed.size():
		var basis := placed[index].basis
		var at := placed[index].origin - origin
		raw_transforms.append_array([basis.x.x, basis.x.y, basis.x.z, basis.y.x, basis.y.y, basis.y.z, basis.z.x, basis.z.y, basis.z.z, at.x, at.y, at.z])
		objects.append(1 if index == placed.size() - 1 else 0)
	var centre := aabb.get_center()
	var half := maxf(aabb.size.x, aabb.size.z) * 0.5
	var rules := PackedFloat32Array([origin.x, origin.y, origin.z, 0.0,
		centre.x, centre.y, centre.z, half, 0.0, 2.0, 0.8, 0.0,
		centre.x, centre.y, centre.z, half, 0.0, 2.0, 0.0, 0.0])
	var raw := {"transforms": raw_transforms, "objects": objects, "rules": rules, "count": placed.size(), "key_names": PackedStringArray(["box"])}
	var raw_bake := StrataAOOverlayBaker.bake(TILE, RESOLUTION, {}, PackedFloat32Array(), OPTIONS, band, raw)
	check(raw_bake.ok and raw_bake.get("image") is Image, "Raw instances bake an image")
	if raw_bake.get("image") is Image:
		var difference := largest_difference(image, raw_bake.image)
		print("AO raw: largest difference %d, owned %d, by key %s, edge blobs %d" % [difference, int(raw_bake.get("raw_owned", -1)), str(raw_bake.get("raw_by_key")), raw_bake.edges.size() / 4])
		check(difference <= 1, "Raw instances bake the same map as the MultiMesh")
	check(int(raw_bake.get("raw_owned", -1)) == transforms.size(), "raw_owned counts the instances inside the tile only")
	check(raw_bake.get("raw_by_key") == {"box": transforms.size()}, "raw_by_key counts them under their key name")
	check(raw_bake.get("edges", PackedFloat32Array()).size() == mesh_bake.edges.size(), "Raw instances near the edges give the same edge blobs")
	var bad := raw.duplicate()
	var bad_rules := rules.duplicate()
	bad_rules[11] = 3.0
	bad.rules = bad_rules
	check(not StrataAOOverlayBaker.bake(TILE, RESOLUTION, {}, PackedFloat32Array(), OPTIONS, 0.0, bad).ok, "A key index outside key_names is rejected")

	# (3) A coarse tile (4 m per texel) is rasterized finer and box-filtered down.
	var coarse_rect := Rect2(0.0, 0.0, 64.0, 64.0)
	var coarse := StrataAOOverlayBaker.bake(coarse_rect, 16, collected, PackedFloat32Array(), OPTIONS)
	check(coarse.ok and coarse.get("image") is Image, "A coarse tile bakes an image")
	if coarse.get("image") is Image:
		var coarse_image: Image = coarse.image
		var stats := StrataAOOverlayBaker.histogram_stats(coarse.histogram)
		print("AO coarse: %dx%d, histogram total %d, min %.3f" % [coarse_image.get_width(), coarse_image.get_height(), histogram_total(coarse.histogram), stats.min])
		check(coarse_image.get_width() == 16 and coarse_image.get_height() == 16 and not coarse_image.has_mipmaps(), "The coarse map has the requested resolution and no mipmaps")
		check(histogram_total(coarse.histogram) == 16 * 16, "The coarse histogram counts every texel once")
		check(stats.min < 1.0, "Occlusion survives the box filter")

	# (4) Nothing to bake.
	var empty := StrataAOOverlayBaker.bake(TILE, RESOLUTION, {}, PackedFloat32Array(), OPTIONS)
	var histogram: PackedInt32Array = empty.get("histogram", PackedInt32Array())
	check(empty.ok and empty.get("image", 0) == null, "An empty input returns ok without an image")
	check(histogram.size() == 256 and histogram[255] == RESOLUTION * RESOLUTION and histogram_total(histogram) == RESOLUTION * RESOLUTION, "An empty input's histogram is all unoccluded")

	# (5) mip_scale reaches the renderer, directly and through StrataAOOverlay.
	var layer := Image.create(4, 4, false, Image.FORMAT_R8); layer.fill(Color.WHITE)
	var layer_images: Array[Image] = [layer]
	var layers := Texture2DArray.new(); layers.create_from_images(layer_images)
	var table := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_R8))
	var renderer := StrataRenderer.new()
	check(renderer.set_ao_overlay(layers, table, Vector2.ZERO, Vector2(16.0, 16.0), {"mip_scale": 4.0}), "set_ao_overlay accepts a Texture2DArray")
	check(is_equal_approx(float(renderer.get_ao_overlay().get("mip_scale", 0.0)), 4.0), "set_ao_overlay keeps mip_scale")
	renderer.set_ao_overlay(layers, table, Vector2.ZERO, Vector2(16.0, 16.0), {"mip_scale": 0.25})
	check(is_equal_approx(float(renderer.get_ao_overlay().get("mip_scale", 0.0)), 1.0), "mip_scale below 1 is raised to 1")
	var terrain := StrataTerrain3D.new()
	var bound := StrataRenderer.new()
	terrain.add_child(bound)
	var overlay := StrataAOOverlay.new()
	overlay.terrain = terrain
	overlay.mip_scale = 8.0
	overlay._layers = layers
	overlay._table_texture = table
	overlay._bind()
	check(is_equal_approx(float(bound.get_ao_overlay().get("mip_scale", 0.0)), 8.0), "StrataAOOverlay passes mip_scale to the terrain's renderers")
	overlay.slots = overlay.slots + 1
	check(overlay._layers == null and bound.get_ao_overlay().is_empty(), "Changing slots releases the layer array")
	overlay.free(); terrain.free(); renderer.free()
	source.free()

	print("AO_OVERLAY_BAKE_TEST failures=", failures)
	quit(0 if failures == 0 else 1)
