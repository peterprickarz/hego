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

The textured editor view is built from square regions. In the *Regions* group, `region_spacing`
sets the metres between samples (1 m by default; heights, holes and material weights are all
composed at that spacing, so a brush or mask can place a feature as narrow as one sample) and
`region_cells` the cells per region side. `region_cells` is 0 by default, which chooses the
size for you: the largest power of two up to 256 that fits the terrain, never below 16. The
default 64 m terrain at 1 m gets 64-cell regions (one region), a 4 km island 256-cell regions
(16 x 16 of them). Set a value of your own, a power of two from 16 to 4096, to override it.
Bounds that are not a multiple of the region size give a warning; the last regions then extend
past the bounds. The older `editor_compile_spacing` is an alias of `region_spacing`.

Each 256-cell region at 1 m costs about 0.9 MB of video memory with materials (height,
material IDs and weights, holes and the tint map). A terrain of up to 25 regions shows every
region in full detail. A larger one, such as the 4 km island, shows the whole terrain at once
from coarse maps (a few metres per texel, composed first, so it appears within about a second
of opening the scene or editing the stack) and adds full detail only for the 25 regions nearest
the editor camera and a quarter-resolution view for the next 256, so video memory stays at
tens of megabytes however large the terrain is. Flying the camera re-fills the detail around
it; regions you leave are released. Painting updates all three levels, and the coarse view
updates a few times a second while you drag, then settles when you release. This needs no
setting. A coarser `region_spacing` shrinks the cost by the square of the ratio; see
[limits](reference.md#limits) for what else bounds the terrain size.

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
| Operation | **Raise** and **Lower** add or subtract `strength` metres at the centre, falling off smoothly to the edge. **Flatten** pulls toward the value under the point where the stroke started. **Smooth** pulls toward the average of neighbouring samples. **Erase** releases the samples, so this layer stops overriding and the layers below show through. On a material weight channel the same operations paint coverage instead; see [Materials](#materials). |
| Radius | In metres, up to 4096. One dab touches at most 65,536 samples of the layer's grid; if a radius is too large for the layer's spacing, the toolbar says so and suggests a radius, or a new, coarser layer. |
| Strength | How much each dab changes: metres for `height` and other scalar channels, the share moved (0 to 1) for material channels. |
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
   **Raise** it where that material should appear.

On a material channel the brush paints coverage rather than metres, because only the
materials' relative weights matter. Each dab moves the painted material's share of the mix
toward 100 % (**Raise**) or 0 % (**Lower**) by `strength × falloff`, so a strength of 0.6
gives a 60 % share at the centre of the first dab and repeated dabs converge on 100 % without
ever overshooting. The other materials shrink or grow in proportion so the shares still sum
to one, **Flatten** pulls toward the share under the point where the stroke started,
**Smooth** toward the neighbours' share, and **Erase** releases every material channel of the
layer inside the dab so the materials below show through. A material dab writes all material
channels at the samples it touches, so the layer owns the complete mix there and a later
procedural recook below cannot shift it. Weights never become negative this way; a negative
weight anywhere in the stack would leave the whole terrain unassigned.

The editor composes the material channels through the stack at `region_spacing` (1 m by
default), keeps the four strongest materials at each sample and normalizes their weights; the
renderer then blends those four using the materials' height maps. Where no material has any
weight, the terrain is left unassigned.

Material placement computed outside Strata is brought in as weight channels of a layer
(a Houdini heightfield mask per material, or samples written into a manual layer), so the
same composition serves the editor, the bake and the brush. The older `editor_control_ids`
and `editor_control_weights` properties still load from existing scenes but are deprecated
and no longer drive the preview.

### Custom shader code per material

A material can carry a few lines of shader code of its own, for an effect that only that
material should have, such as a fresnel rim on wet rock or a faint glow on lava. The rest of
the terrain keeps its usual shader. Select the `StrataMaterial` and open **Custom Shader** in
the inspector:

- **Fragment Code** (`custom_fragment_code`): Godot shading language statements that adjust
  this material's surface `s` using what is known about the fragment, `c`.
- **Fragment Parameters** (`custom_fragment_parameters`): named values the code uses. Each
  name becomes a variable in the code. Editing a value updates the terrain straight away;
  editing the code recompiles the terrain shader about half a second after you stop typing.

This rim brightens the material where it is seen at a grazing angle:

```glsl
float facing = clamp(dot(s.normal, c.view), 0.0, 1.0);
s.emission += rim_color.rgb * pow(1.0 - facing, rim_power);
```

with the parameters `rim_color` (a `Color`) and `rim_power` (a `float`, for example 3.0).

The code runs before the materials are blended, so its result fades out with the material:
where the material has half the weight, half of the rim shows. `s.albedo`, `s.normal`,
`s.roughness`, `s.metallic`, `s.ao` and `s.emission` can be changed; `c.view`,
`c.position`, `c.weight` and the other fields listed in the
[reference](reference.md#custom-material-shader-code) can be read. The code is saved with
the material and works the same in the editor and in a baked runtime scene.

If the code does not compile, Godot prints the shader error, Strata names the material in
the output, and that material is drawn without its code while the others keep theirs.
Materials without code cost nothing extra; each material with code adds its own work wherever
it is one of the blended materials.

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
- With a storage directory, the bake is written there: `runtime_data.res` and a `regions/`
  folder with two files per region, `region_<i>_<j>.res` (full detail) and
  `region_<i>_<j>.lod.res` (reduced detail for distant regions). Without a storage directory
  it is saved with the scene. A bake stays current across a save and reload.
- Big terrains bake straight to disk, a batch of regions at a time (`bake_batch`, default
  32), so memory use does not grow with the terrain size. A bake that is rejected leaves the
  previous files in place. The storage directory must be a `res://` or `user://` path.

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
    navigation.track_target = navigation.get_path_to(player)   # tiles follow the player too
```

Both are ordinary nodes, so you can also add them in the editor and assign the bake file
(`runtime_data.res` in the storage directory) to their `data` property.

### Collision

Collision is built in square chunks (`chunk_cells`, default 128 cells) and only on request:

- `prepare_region(local_rect)` makes the chunks overlapping a terrain-local rectangle
  resident; `prepare_around(world_position, radius)` does the same around a point.
- `track_target` follows a node, such as the player or a vehicle, and loads the chunks
  within `track_radius` (default 96 m) whenever it enters a new chunk. The chunks it left
  behind are released, so collision exists only around the target however large the terrain.
- `max_resident_chunks` (default 64) caps how many chunks exist at once. If the radius
  needs more, the chunks farthest from the target are left out; the chunk the target
  stands on is always built. The cost of entering a chunk is a few milliseconds, paid on
  that physics frame.
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

To make navigation follow the player instead of baking a fixed area, set `track_target`
(a NodePath) and, if you want a different range, `track_radius` (default 96 m):

```gdscript
navigation.track_radius = 128.0
navigation.track_target = navigation.get_path_to(player)
```

- Whenever the target enters a new tile, the tiles within `track_radius` of that tile are
  baked, each in the background, and each appears as soon as it is ready. Tiles that
  fall more than `track_radius * 1.25` behind are removed. Standing still costs nothing.
- `max_tiles` (default 64) is the budget for tiles that exist or are being baked. When the
  radius needs more, the tiles farthest from the target are skipped or removed first; the
  tile under the target is never removed. A target that outruns the baking just gets the
  tiles around where it is now: results for tiles it already left are dropped.
- `get_stats()` reports `tracked`, `resident_tiles`, `pending_tiles` and `evictions`.
- `bake_region()` and `clear()` still work; use `bake_region()` for areas that should exist
  without a target, such as a level start. A tracked target replaces tiles it does not need
  once it moves away.

```{important}
Godot merges navigation regions on a grid that is too coarse for terrain tiles and
reports "already-merged edge" errors. Set **Project Settings →
navigation/3d/merge_rasterizer_cell_scale** to `0.01`, or call
`NavigationServer3D.map_set_merge_rasterizer_cell_scale(map, 0.01)` on a map you own.
Strata never changes your map settings. `check_merge_conflicts` turns on a check that
warns when tiles would conflict.
```

### Navigation profiles

Different populations often walk on different ground: enemies that stay inside a fungal
network, villagers that keep to footpaths, a player who can go almost anywhere. The terrain
is static, so Strata decides this once, at bake time. Each population gets a *profile*, a
walkability mask baked from the terrain's channels. A profile is never recomputed while the
game runs.

Define profiles with the `nav_profiles` bake option, a list of names and rules. A rule can
only read channels the bake keeps, so list them in `channels` too:

```gdscript
var result := StrataBake.bake(terrain, {
    "cell_masks": true,
    "channels": PackedStringArray(["footpath", "fungal"]),
    "nav_profiles": [
        {"name": &"paths_only", "rule": {"channel": "footpath", "min": 0.5}},
        {"name": &"fungal", "rule": {"all": [
            {"channel": "fungal", "min": 0.3},
            {"slope_max": 35},
        ]}},
    ],
})
```

`paths_only` is walkable where the `footpath` channel is at least 0.5. `fungal` is walkable
where the `fungal` channel is at least 0.3 and the ground is no steeper than 35 degrees. A
rule is built from a few forms (a channel range, a height range, a slope range, the
`nav_exclusion` mask, and `not`, `all` and `any` to combine them); the
[reference](reference.md#navigation-profile-rules) lists them. An invalid rule fails the
bake with a message.

Every bake also has the `default` profile, which is the `nav_exclusion` mask on its own.
Holes are blocked for every profile.

Then add one `StrataNavigation` per profile, each with its own `profile` and its own
`navigation_layers` bit:

```gdscript
func add_navigation(terrain: StrataTerrain3D, profile: StringName, layer: int) -> StrataNavigation:
    var navigation := StrataNavigation.new()
    navigation.data = terrain.runtime_data
    navigation.profile = profile
    navigation.navigation_layers = 1 << layer
    terrain.add_child(navigation)
    navigation.bake_region(Rect2(-512, -512, 1024, 1024))
    return navigation

add_navigation(terrain, &"paths_only", 1)
add_navigation(terrain, &"fungal", 2)
```

An agent chooses its population by setting `navigation_layers` on its `NavigationAgent3D` to
that bit, so its paths only use that profile's tiles. Two nodes that bake the same area for
different profiles share one navigation map; the layers keep them apart.

To steer by the channels themselves, for example to prefer the middle of a footpath, read
them with `terrain.sample_runtime_channel(&"footpath", world_position)`. It returns
`{ok, status, value, coverage}` and, like the height queries, never composes layers.

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

That binds every region at once, which is fine for a small terrain. For a large one, add a
`StrataRegionStreamer`: it draws the whole terrain from the bake's coarse maps straight
away, and keeps only the regions around the camera at full detail (nearest first, loaded in
the background from the region files, so frames never wait for the disk):

```gdscript
var streamer := StrataRegionStreamer.new()
streamer.renderer = renderer
streamer.data = terrain.runtime_data
streamer.camera = get_viewport().get_camera_3d()
add_child(streamer)
if streamer.start(terrain, terrain.editor_materials):
    terrain.set_preview_enabled(false)
    renderer.set_camera(streamer.camera)
```

The defaults suit most terrains: full detail within two and a half regions of the camera, a
cheaper level out to eight. `near_radius`, `far_radius`, `near_slots`, `far_slots` and
`loads_per_frame` tune that. A runtime scene saved with `StrataBake.save_runtime_scene()`
carries the coarse maps, so it streams the same way; ship the `regions/` folder with it when
the bake is too large to embed.

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
