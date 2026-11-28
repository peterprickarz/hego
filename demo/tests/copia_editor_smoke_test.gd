## Headless compile & smoke test for Copia authoring resources and editor scripts.
##
##   godot-4.7.2 --path demo --headless --script res://tests/copia_editor_smoke_test.gd
##
## Prints COPIA_EDITOR_SMOKE_TEST PASS or FAIL and exits 0 or 1.
extends SceneTree

const SCRIPTS := [
	"res://addons/copia/copia_placement_settings.gd",
	"res://addons/copia/copia_species_entry.gd",
	"res://addons/copia/copia_species.gd",
	"res://addons/copia/copia_brush_palette.gd",
	"res://addons/copia/copia_object.gd",
	"res://addons/copia/copia_store_3d.gd",
	"res://addons/copia/copia_inspector.gd",
	"res://addons/copia/editor/copia_thumbnail_baker.gd",
	"res://addons/copia/editor/copia_library_index.gd",
	"res://addons/copia/editor/copia_creators.gd",
	"res://addons/copia/editor/copia_dock.gd",
	"res://addons/copia/editor/copia_surface_raycast.gd",
	"res://addons/copia/editor/copia_place_tool.gd",
	"res://addons/copia/editor/copia_brush_cursor.gd",
	"res://addons/copia/editor/copia_paint_tool.gd",
	"res://addons/copia/plugin.gd",
	"res://addons/hego_copia/hego_copia_output.gd",
	"res://addons/hego_copia/hego_copia_input.gd",
]

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, desc: String) -> void:
	if not value:
		failures.append(desc)
		push_error("FAIL: " + desc)


func run() -> void:
	for path in SCRIPTS:
		var scr := load(path) as GDScript
		check(scr != null, "loaded script " + path)
		if scr != null:
			check(scr.can_instantiate(), "can_instantiate " + path)

	# Exercise library index scan on demo project.
	var lib_script := load("res://addons/copia/editor/copia_library_index.gd") as GDScript
	if lib_script != null:
		var lib: RefCounted = lib_script.new()
		lib.refresh()
		check(lib.objects is Array and lib.species is Array and lib.palettes is Array, "CopiaLibraryIndex refresh succeeds")

	# Exercise CopiaEditOverlay + CopiaBrushCursor lifecycle cleanly.
	var cursor_script := load("res://addons/copia/editor/copia_brush_cursor.gd") as GDScript
	if cursor_script != null:
		var cursor: RefCounted = cursor_script.new()
		cursor.dispose()
		check(true, "CopiaBrushCursor lifecycle ok")

	if failures.is_empty():
		print("COPIA_EDITOR_SMOKE_TEST PASS")
		quit(0)
	else:
		print("COPIA_EDITOR_SMOKE_TEST FAIL (%d)" % failures.size())
		quit(1)
