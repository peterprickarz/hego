# Getting started with Strata

This page takes you from an empty scene to a painted, textured terrain that you can walk on
and navigate. Nothing here needs Houdini; [Strata and Houdini](houdini.md) adds that on top.

## Requirements

- Godot 4.7 or newer.
- The Strata native library for your platform. Packages ship Linux x86_64, Windows x86_64
  and macOS (universal) builds.
- The Forward+ renderer for the textured terrain. Other renderers still show a coarse,
  vertex-coloured preview mesh, and baking, collision and navigation work everywhere.

## Install

Strata is the `addons/strata` folder. The development channel publishes it on its own
branch, `strata-release-next`, which you can add as a submodule:

```bash
git submodule add -b strata-release-next https://github.com/peterprickarz/hego.git addons/strata
```

Alternatively, take the `release-next-bundle` branch, which holds Strata, HEGo and both HEGo
bridges side by side, and copy only the folders you want into your project's `addons/`.

Then enable **Strata** under **Project Settings → Plugins**. The plugin adds the terrain
brush and the textured editor view; the node and resource types are available either way.

## Create a terrain

1. Add a **StrataTerrain3D** node to your scene.
2. Set `base_bounds`, the terrain's extent as a `Rect2` in terrain-local X and Z metres.
   The default, `Rect2(-32, -32, 64, 64)`, is a 64 m square around the node. A
   4 km island would be `Rect2(-2048, -2048, 4096, 4096)`.
3. Optionally set `storage_directory` in the *Storage* group to a project folder, such as
   `res://levels/valley/terrain`, so the terrain's data goes into
   [one file per layer](index.md#where-the-data-lives) rather than into the scene.

The textured editor view composes the terrain every `editor_compile_spacing` metres (1 m by
default) and can draw at most 4097 samples per side, so raise that spacing for terrains
larger than about 4 km.

Keep the terrain's transform to translation and rotation around Y with unit scale,
including its parents. The node shows a configuration warning otherwise, and the brush is
disabled.

## Add a layer and paint

1. Add a **StrataLayer** as a child of the terrain. New layers are manual.
2. In the inspector, open the layer's `data` resource and choose its `sample_spacing`
   (default 1 m) before you paint. The spacing is locked once the layer holds samples. Use a
   coarse spacing for broad landforms and a fine one for detail; each layer has its own.
3. Select the layer. A **Terrain brush** toolbar appears at the top of the 3D viewport.
4. Move the pointer over the terrain. A yellow ring shows the brush radius on the surface,
   with a fainter inner ring where the falloff reaches half strength. The ring turns red
   where a dab would be refused (a procedural layer, or a radius too dense for the layer's
   grid).
5. Paint with the left mouse button. Hold **Alt** to use the mouse for viewport navigation
   instead. Each stroke is one undo step (**Ctrl+Z**).

The toolbar:

| Control | What it does |
| --- | --- |
| Operation | **Raise** and **Lower** add or subtract `strength` metres at the centre, falling off smoothly to the edge. **Flatten** pulls toward the value under the point where the stroke started. **Smooth** pulls toward the average of neighbouring samples. **Erase** releases the samples, so this layer stops overriding and the layers below show through. |
| Radius | In metres, up to 4096. One dab touches at most 65,536 samples of the layer's grid; if a radius is too large for the layer's spacing, the toolbar says so and suggests a radius, or a new, coarser layer. |
| Strength | How much each dab changes. |
| Channel | The channel to paint, `height` by default. The **▾** menu next to the field lists the channels this terrain already has: `height`, the material weight channels (with their material names), the `hole` and `nav_exclusion` masks, and anything the layers hold or cook. Type a name to paint a channel that does not exist yet. |
| Show overrides | Tints in orange every sample the selected layer owns in that channel, including samples whose value happens to equal the ground below. |
| Show channel | Shows the channel's values in greyscale. The geometry is always the height. |

While a layer is selected, the viewport shows the stack up to and including that layer.
Procedural layers refuse the brush: select or add a manual layer above them.

### Replace or Add

By default a layer *replaces* each channel where it owns samples. To make it add offsets
instead, set the channel in the layer's `composition_modes` dictionary to `1` (Add; `0` is
Replace), or from a script:

```gdscript
$Terrain/Paths.set_composition(&"height", StrataLayer.Composition.ADD)
```

Decide before you paint: the stored values mean different things in the two modes. A
Replace height layer is right for things that must keep their absolute height, such as a
building pad. An Add layer is right for detail that should follow the ground, such as a
path or a ridge line on a slope that may be regenerated underneath.

### Holes and navigation exclusions

Two channels are masks rather than values:

- `hole` cuts the terrain: the cell is not drawn, has no collision and carries no
  navigation.
- `nav_exclusion` keeps the ground but removes it from navigation.

Paint them on a manual layer that uses Replace for that channel. **Raise** marks cells
(value 1), **Lower** marks them solid again (value 0), which restores ground over a hole
made by a lower layer, and **Erase** hands the decision back to the layers below. Masks are
always exactly 0 or 1; the brush falloff does not apply.

## Materials

A terrain blends up to 32 materials. Each material is a `StrataMaterial` resource, and
where each one appears is controlled by an ordinary scalar channel, one per material, that
you paint or cook like any other.

1. **Create the materials.** For each `StrataMaterial`, set:
   - `color_texture`: albedo.
   - `normal_texture`: an OpenGL-convention normal map (green up).
   - `ormh_texture`: packed ambient occlusion (R), roughness (G), metallic (B) and height
     (A, where 0.5 is neutral). The height drives height-based blending and the close-up
     displacement.
   - `uv_scale`: texture repeats per metre (0.25 repeats once every 4 m).

   The remaining settings tune the look: `triplanar_sharpness`, `displacement_strength`,
   `height_blend_contrast` and `height_blend_bias` (let one material's peaks push through
   another), and `roughness_scale` and `roughness_bias`. Material edits show immediately and
   need no bake.
2. **Assign them to the terrain.** Turn on `textured_editor_preview`, then fill
   `editor_materials` with your materials. A material's position in the list is its ID
   (0 to 31).
3. **Name a weight channel for each material.** Fill `editor_material_channels` with one
   channel name per material, in the same order, for example
   `material_sand`, `material_grass`, `material_rock`.
4. **Paint the weights.** Select a manual layer, pick the material from the brush's
   **Channel ▾** menu (it lists every material channel with its material name) and
   **Raise** it where that material should appear. Weights must stay zero or positive.

The editor composes the material channels through the stack on a 4 m grid, keeps the four
strongest materials at each point and normalizes their weights; the renderer then blends
those four using the materials' height maps. Where no material has any weight, the terrain
is left unassigned. This grid allows terrains up to 4096 m on a side.

If you compute material placement elsewhere, you can instead leave
`editor_material_channels` empty and assign precomputed control maps to
`editor_control_ids` (an RGBA8 image of four material IDs per texel) and
`editor_control_weights` (an RGBAF image of the matching weights).

### Render quality

The terrain's `render_settings` (`StrataRenderSettings`) choose the geometry density with a
`quality` preset (Performance, Balanced, High or Ultra, or Custom for your own patch
settings), the strength of the terrain-wide tint and AO map (`terrain_tint_strength`,
`terrain_ao_strength`), and how much extra geometry is added near
the camera for material displacement (*Near displacement geometry*). These settings change
only what you see; collision, navigation and the stored heights are unaffected. A bake keeps
a copy of them for the runtime renderer.

## Bake

Collision, navigation and runtime queries read the bake, so bake whenever you want them to
see your changes. There is no bake button; run it from a script. An `EditorScript` you run
with **File → Run** in the script editor works well:

```gdscript
@tool
extends EditorScript

func _run() -> void:
    var terrain := get_scene().get_node("Terrain") as StrataTerrain3D
    var options := {
        "spacing": 1.0,        # metres between baked samples
        "cell_masks": true,    # bake the hole and nav_exclusion channels
    }
    var controls := StrataMaterialControls.compose(terrain, terrain.editor_material_channels)
    if controls.get("ok", false):
        options.material_ids = controls.ids
        options.material_weights = controls.weights
    var result := StrataBake.bake(terrain, options)
    if result.ok:
        print("Baked ", result.report.resolution)
    else:
        push_warning(result.message)
```

Things to know:

- `base_bounds` must be a whole number of `spacing` intervals.
- Holes and navigation exclusions are only baked with `cell_masks`.
- A failed bake leaves the previous bake in place.
- The bake refuses procedural layers that are stale or have never been cooked. A layer
  loaded from disk counts as stale until its producer cooks again, so after reopening a
  scene either recook, or pass `"allow_stale_procedural": true` to bake the saved results
  as they are.
- With a storage directory, the bake is written to `runtime_data.res` there; otherwise it
  is saved with the scene. A bake stays current across a save and reload.

The full list of options is in the [reference](reference.md#bake-options).

## Collision and navigation

`StrataCollision` and `StrataNavigation` build physics and navigation from a bake, only for
the areas you ask for. Add them as direct children of the terrain, at the identity
transform, and give them the bake:

```gdscript
extends Node3D

@onready var terrain: StrataTerrain3D = $Terrain
@onready var player: Node3D = $Player

func _ready() -> void:
    var collision := StrataCollision.new()
    collision.data = terrain.runtime_data
    terrain.add_child(collision)
    collision.track_target = collision.get_path_to(player)   # follow the player

    var navigation := StrataNavigation.new()
    navigation.data = terrain.runtime_data
    navigation.agent_radius = 0.5
    terrain.add_child(navigation)
    var result := navigation.bake_region(Rect2(-64, -64, 128, 128))   # terrain-local XZ
    if result.get("pending", false):
        result = await navigation.bake_finished
```

Both are ordinary nodes, so you can also add them in the editor and assign the bake file
(`runtime_data.res` in the storage directory) to their `data` property.

### Collision

Collision is built in square chunks (`chunk_cells`, default 128 cells) and only on request:

- `prepare_region(local_rect)` makes the chunks overlapping a terrain-local rectangle
  resident; `prepare_around(world_position, radius)` does the same around a point.
- `track_target` follows a node, such as the player or a vehicle, and loads the chunks
  within `track_radius` (default 96 m) whenever it enters a new chunk.
- `max_resident_chunks` (default 64) caps how many chunks exist at once.
- `collision_layer`, `collision_mask` and `physics_material` apply to every chunk.
- After a new bake, `replace_data(terrain.runtime_data)` rebuilds the resident chunks
  and swaps them in together.

Collision follows the baked heights and holes exactly. It ignores the camera, the render
LOD and material displacement, which are visual only.

### Navigation

`bake_region(local_rect)` bakes navigation for the tiles (`tile_cells`, default 64 cells)
overlapping a terrain-local rectangle into the world's default navigation map, so ordinary
`NavigationAgent3D` nodes can use it. Hole and `nav_exclusion` cells carry no navigation.
With `use_async` (the default) the result arrives through the `bake_finished` signal, and
all tiles of a request appear together. Set the agent with `agent_radius`, `agent_height`,
`agent_max_climb` and `agent_max_slope`, and the regions' `navigation_layers` as usual. The
navigation cell size defaults to the map's and must be at most half the bake spacing.

```{important}
Godot 4.4 merges navigation regions on a grid that is too coarse for terrain tiles and
reports "already-merged edge" errors. Set **Project Settings →
navigation/3d/merge_rasterizer_cell_scale** to `0.01`, or call
`NavigationServer3D.map_set_merge_rasterizer_cell_scale(map, 0.01)` on a map you own.
Strata never changes your map settings. `check_merge_conflicts` turns on a check that
warns when tiles would conflict.
```

## Draw the terrain in your game

The textured view in the editor is an editor tool. In a running game, the terrain shows its
simple preview mesh until you add a renderer for the bake:

```gdscript
var renderer := StrataRenderer.new()
terrain.add_child(renderer)
if renderer.configure_runtime(terrain, terrain.runtime_data, terrain.editor_materials):
    terrain.set_preview_enabled(false)
    renderer.set_camera(get_viewport().get_camera_3d())
```

The renderer takes its quality settings, material controls, holes and tint map from the
bake, and needs Forward+.

## Sample heights

- `terrain.sample_runtime_height(local_xz)` and
  `terrain.sample_runtime_height_world(world_position)` read the bake. They return
  `{status, value}`, plus the surface `position` for the world version. `status` is a
  `StrataRuntimeData.Status`: `OK`, `OUTSIDE`, `HOLE`, `ABSENT` or `NOT_RESIDENT`;
  `value` is `NAN` unless the status is `OK`. They match collision exactly.
- `terrain.sample_height(local_xz)` composes the layers directly, without a bake, and
  returns a float. It is meant for tools and editor scripts; pass a layer as the second
  argument to sample the stack only up to that layer.

## Ship a runtime-only scene

`StrataBake.save_runtime_scene()` writes the bake as a standalone scene without the
authoring layers. It loads, collides and navigates without the native extension, HEGo or
Houdini; it needs only the `StrataRuntimeData`, `StrataCollision` and `StrataNavigation`
scripts:

```gdscript
StrataBake.save_runtime_scene(terrain, "res://levels/valley_runtime.tscn", {
    "data_path": "res://levels/valley_runtime.res",   # keep the bake in its own file
    "collision": true,
    "navigation": {"agent_radius": 0.4},
})
```

The scene's root carries the bake in its `strata_runtime_data` metadata and has `Collision`
and `Navigation` children configured with the settings you pass. A stale bake cannot be
exported. Drawing it still needs a `StrataRenderer`, configured from that metadata as above.
