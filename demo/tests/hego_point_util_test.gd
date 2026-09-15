## Covers the point orientation and colour maths shared by the scattering handlers.
##
## Multimesh instancing, object spawning and Terrain3D instancing each carried their own
## copy of this. Merging them is only safe if the behaviour they shared is pinned down, so
## these checks describe what the three copies agreed on: the frame built from N and up,
## the two scale attributes multiplying, the fallbacks when an attribute is missing, and
## Cd arriving as either a Color or a Vector3.
##
## Pure maths over a dictionary, so it needs no Houdini session.
extends SceneTree

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func approx(a: Vector3, b: Vector3, tolerance := 0.0001) -> bool:
	return a.distance_to(b) < tolerance


## One point carrying exactly the attributes named in [param attribs].
func point(attribs: Dictionary) -> Dictionary:
	var points := {"P": [Vector3.ZERO]}
	for key in attribs:
		points[key] = [attribs[key]]
	return points


func _initialize() -> void:
	# --- the frame built from N and up ------------------------------------
	var facing_z := point({"N": Vector3(0, 0, 1), "up": Vector3(0, 1, 0)})
	var basis := HEGoPointUtil.basis_from_point(facing_z, 0)
	check(approx(basis.z, Vector3(0, 0, 1)), "z follows N")
	check(approx(basis.y, Vector3(0, 1, 0)), "y follows up")
	check(approx(basis.x, Vector3(1, 0, 0)), "x is up crossed with N")

	var facing_x := point({"N": Vector3(1, 0, 0), "up": Vector3(0, 1, 0)})
	var turned := HEGoPointUtil.basis_from_point(facing_x, 0)
	check(approx(turned.z, Vector3(1, 0, 0)), "a point facing +x has z along +x")
	check(approx(turned.x, Vector3(0, 0, -1)), "and x along -z")

	# --- attributes that are absent fall back -----------------------------
	var bare := {"P": [Vector3.ZERO]}
	var default_basis := HEGoPointUtil.basis_from_point(bare, 0)
	check(approx(default_basis.z, HEGoPointUtil.DEFAULT_NORMAL), "a point with no N uses the default normal")
	check(approx(default_basis.y, HEGoPointUtil.DEFAULT_UP), "a point with no up uses the default up")
	check(approx(default_basis.get_scale(), Vector3.ONE), "a point with no scale attributes is unscaled")

	# --- pscale and scale multiply ----------------------------------------
	var scaled := point({"pscale": 2.0, "scale": Vector3(1, 3, 1)})
	check(approx(HEGoPointUtil.basis_from_point(scaled, 0).get_scale(), Vector3(2, 6, 2)),
		"pscale multiplies every axis of scale")

	var pscale_only := point({"pscale": 0.5})
	check(approx(HEGoPointUtil.basis_from_point(pscale_only, 0).get_scale(), Vector3(0.5, 0.5, 0.5)),
		"pscale alone scales uniformly")

	# --- collinear N and up leave no frame to build -----------------------
	var collinear := point({"N": Vector3(0, 1, 0), "up": Vector3(0, 1, 0)})
	check(HEGoPointUtil.is_orientation_collinear(collinear, 0), "N equal to up is reported collinear")
	check(approx(HEGoPointUtil.basis_from_point(collinear, 0).get_scale(), Vector3.ONE),
		"a collinear point keeps an unrotated basis rather than a degenerate one")
	check(not HEGoPointUtil.is_orientation_collinear(facing_z, 0), "a usable pair is not reported collinear")

	var opposed := point({"N": Vector3(0, 1, 0), "up": Vector3(0, -1, 0)})
	check(HEGoPointUtil.is_orientation_collinear(opposed, 0), "N opposite to up is also collinear")

	# --- transform places the point ---------------------------------------
	var placed := HEGoPointUtil.transform_from_point(facing_z, 0, Vector3(5, 6, 7))
	check(approx(placed.origin, Vector3(5, 6, 7)), "transform_from_point uses the position it is given")
	check(approx(placed.basis.z, Vector3(0, 0, 1)), "and keeps the orientation")

	# --- colour, in both shapes Houdini sends -----------------------------
	check(HEGoPointUtil.read_color(point({"Cd": Color(1, 0, 0)}), 0) == Color(1, 0, 0), "Cd as a Color is read directly")
	check(HEGoPointUtil.read_color(point({"Cd": Vector3(0, 1, 0)}), 0) == Color(0, 1, 0, 1.0), "Cd as a Vector3 becomes an opaque Color")
	check(HEGoPointUtil.read_color(bare, 0) == Color(1, 1, 1, 1), "a point with no Cd reads white")

	# --- whether colour is worth setting up at all ------------------------
	check(HEGoPointUtil.has_any_color(point({"Cd": Color(1, 0, 0)})), "points carrying Cd report colour")
	check(not HEGoPointUtil.has_any_color(bare), "points with no Cd report none")
	check(not HEGoPointUtil.has_any_color({"P": [], "Cd": []}), "an empty Cd array reports none")
	check(not HEGoPointUtil.has_any_color({"P": [Vector3.ZERO], "Cd": [null]}), "a null first entry reports none")

	# --- the attribute lists the handlers compose from --------------------
	check(HEGoPointUtil.ORIENTATION_ATTRIBS.has("N") and HEGoPointUtil.ORIENTATION_ATTRIBS.has("up")
		and HEGoPointUtil.ORIENTATION_ATTRIBS.has("pscale") and HEGoPointUtil.ORIENTATION_ATTRIBS.has("scale"),
		"the orientation list names every attribute the basis reads")
	check(not HEGoPointUtil.ORIENTATION_ATTRIBS.has(HEGoPointUtil.COLOR_ATTRIB),
		"colour is separate, so object spawning can leave it out")
	check(HEGoMultiMeshOutput.point_attribs().has(HEGoPointUtil.COLOR_ATTRIB), "multimesh output asks for colour")
	check(not HEGoObjectOutput.point_attribs().has(HEGoPointUtil.COLOR_ATTRIB), "object spawning does not")
	check(HEGoObjectOutput.point_attribs().has("hego_node_path"), "object spawning still asks for its own attributes")

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
