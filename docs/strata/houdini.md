# Strata and Houdini

With the HEGo Strata bridge, an HDA cooked by a `HEGoNode3D` can read Strata layers as
heightfield inputs and write its result into a procedural layer. Typical uses are erosion
over a hand-sculpted base, mask generation (flow, slope, biomes), material distribution and
terrain-wide tinting. Everything else in the stack stays as it is: manual layers above or
below the cooked one keep their samples, and only the target layer is replaced.

## Install the bridge

You need three addons, all from the same source revision:

| Addon | Folder | Branch on the development channel |
| --- | --- | --- |
| HEGo | `addons/hego` | `release-next` |
| Strata | `addons/strata` | `strata-release-next` |
| HEGo Strata | `addons/hego_strata` | `hego-strata-release-next` |

The `release-next-bundle` branch holds all of them (plus the HEGo Terrain3D bridge) in one
tree. Enable **HEGo**, **Strata** and **HEGo Strata** under **Project Settings → Plugins**;
the bridge's plugin reports which addon is missing if one is. HEGo itself must be set up
with a working Houdini session as described in {doc}`/about/getting_started`.

The bridge adds nothing to your scene. HEGo picks up its input and output handlers
({ref}`HEGoStrataInput<class_HEGoStrataInput>` and
{ref}`HEGoStrataOutput<class_HEGoStrataOutput>`) automatically, so any `HEGoNode3D` can
cook terrain.

## How a cook works

1. **Inputs.** Each input row of the `HEGoNode3D` that names a `StrataLayer` sends that
   layer to the HDA as heightfield volumes, one per channel.
2. **Cook.** The HDA does its work in Houdini.
3. **Routing.** Every output volume that carries a `hegostrata_layer_path` attribute is
   meant for Strata. The bridge groups those volumes by the layer they name. Volumes without
   the attribute are left to HEGo's other outputs, so one HDA can produce meshes or
   Terrain3D output alongside its terrain layers.
4. **Publishing.** All target layers of one cook are published together, all or nothing.
   Each target receives the complete set of channels the HDA emitted for it, replacing its
   previous result; channels the HDA no longer emits are removed. If anything is wrong, no
   layer changes and each keeps its previous result.
5. **Saving.** With a storage directory, the new channels are written to the layer's files
   immediately. The scene references them by path, so save the scene afterwards.

Terrain cooks are explicit. A `HEGoNode3D` with a Strata input is skipped by the HEGo
panel's **Auto Cook**, and cooks only when you press **Recook** or call `cook()`. They are
also strict: an input layer that is missing or cannot be sent fails the whole cook rather
than being skipped.

## What the HDA receives

Each channel arrives as a scalar heightfield volume named after the channel, together with
a companion volume named `<channel>__ownership` on the same grid. All volumes carry these
primitive attributes:

| Attribute | Value |
| --- | --- |
| `hegostrata_role` | `value` on the channel volume; `coverage` or `ownership` on the companion |
| `hegostrata_channel` | the channel name, on both |
| `hegostrata_snapshot_mode` | `cumulative` or `raw` |
| `hegostrata_composition` | on raw values, `add` if the layer adds that channel, otherwise `replace` |
| `hegostrata_resampled_spacing` | present when the channel was resampled to a requested spacing |
| `_hego_node_path` | the source layer's node path, as on every HEGo input |

The input row's terrain options decide what is sent:

- **Cumulative** (the default) sends the terrain as composed *through* the selected layer:
  everything below it plus the layer itself, over the whole terrain. The companion is a
  fractional `coverage` mask (0 to 1) of where any layer provides data.
- **Raw** sends only that layer's own values. The companion is a binary `ownership` mask of
  the samples the layer owns. Use it to read a later hand edit, such as a building pad, as a
  constraint without baking everything below into it.
- **Channels** is a comma-separated list such as `height, rock`. Leave it blank to send
  every channel present.
- **Cumulative spacing** resamples every channel onto a grid of that many metres over the
  terrain bounds. 0 keeps the selected layer's own grid; a coarser spacing keeps a cook
  cheap when a fine manual layer sits underneath.

Each channel keeps its own grid. Read the grid size, position and orientation from the
volumes themselves rather than assuming they match one another.

## What the HDA must output

For every channel it publishes, the HDA outputs one scalar heightfield volume:

| Attribute | Value |
| --- | --- |
| `name` | the channel name, for example `height` or `flow` |
| `hegostrata_layer_path` | the target layer; write the HDA's `target_layer_path` parameter here verbatim |
| `hegostrata_channel` | the channel name again |
| `hegostrata_role` | `value` |
| `hegostrata_composition` | `replace` or `add`: how the layer composes this channel |

The bridge reads only the attribute; a string parameter called `target_layer_path` is the
convention that lets you choose the layer from the HEGo panel. Its value is saved with the
node's other parameters, so it is the only link between a `HEGoNode3D` and its layer.

A channel may use any dense, horizontal grid of finite values, with its own spacing and
orientation; each channel is stored on the grid the HDA gives it. A `height` published with
`replace` is an absolute height in metres, as in any Houdini heightfield.

Output only the volumes you mean to publish. Input volumes can carry `hegostrata_*`
attributes of their own, so delete the inputs and their `__ownership` companions before the
output rather than passing them through.

### A minimal HDA

A SOP-level HDA that publishes a modified height:

1. Add a string parameter `target_layer_path` to the HDA's interface.
2. From the first input, keep only the `height` volume, for example with a Blast node set to
   `@name=height` and *Delete Non Selected*.
3. Process it with any heightfield nodes, such as HeightField Erode.
4. Delete every volume you do not want to publish.
5. Route the result with an Attribute Wrangle running over **Primitives**, placed directly
   inside the HDA so it can read the HDA's parameter:

   ```c
   s@hegostrata_layer_path = chs("../target_layer_path");
   s@hegostrata_role = "value";
   s@hegostrata_channel = s@name;
   s@hegostrata_composition = "replace";
   ```

6. End in an Output node.

To publish more channels, give each its own named volume before the wrangle; the same
wrangle routes all of them.

### Advanced output

- **Partial results.** By default a volume owns its whole grid. To own only part of it, add
  a companion volume on exactly the same grid with `hegostrata_role` set to `ownership`,
  `hegostrata_channel` naming the value channel, and values of 0 or 1. Volume names ending
  in `__ownership` are reserved for such companions. `coverage` companions are accepted and
  ignored.
- **Several targets.** One cook may publish into several layers by giving volumes different
  `hegostrata_layer_path` values. Two targets can both have a `height`; the path tells them
  apart. They are still published all together or not at all.
- **An empty result.** To clear a layer deliberately, output exactly one volume for it with
  `hegostrata_role` set to `empty`, `hegostrata_empty` set to 1, the layer path, and no value
  volumes.

## Set it up in Godot

1. **Add the target layer.** Add a `StrataLayer` to the terrain at the position in the stack
   where the result belongs, and turn on `procedural`. It must be a direct child of the
   `StrataTerrain3D` and contain no painted samples.
2. **Add the HDA.** Add a `HEGoNode3D`, pick the HDA with **Select HDA** (or set
   `asset_name`) and press **Recook** once in the HEGo panel so its parameters appear. Keep
   its transform, like the terrain's, to translation and rotation around Y with unit scale.
3. **Connect the input.** In the panel's **Inputs** section, drag the source layer from the
   Scene dock onto the input's path field, or type its path. The row shows the terrain
   options: mode, channels and cumulative spacing.
4. **Name the target.** Type the procedural layer's path into the `target_layer_path`
   parameter. A path from the scene root, such as `Terrain/Erosion`, works in the editor and
   in the running scene; a path relative to the `HEGoNode3D`, such as `../Terrain/Erosion`,
   also keeps working when the scene is instanced inside another one.
5. **Cook.** Press **Recook**. The layer's `procedural_status` reports the committed result
   and where it was saved, and the viewport shows it.
6. **Save.** Save the scene. If you also painted manual layers, press **Save layers to
   storage** on the terrain.

The same from a script, using the persisted settings the panel edits:

```gdscript
var host: HEGoNode3D = $HDA/ErosionCook
host.hego_set_input_stash([{
    "inputs": ["../../Terrain/RoughBase"],
    "settings": {"terrain_mode": "cumulative", "terrain_channels": "height"},
}])
var asset := host.hego_get_asset_node()
await host.agent.task(asset.set_parm("target_layer_path", "../../Terrain/Erosion"))
host.hego_notify_cook_inputs_changed()
await host.cook()
```

Two input settings are only available from code. `terrain_channel_spacings` gives named
channels their own cumulative spacing, for example
`{"sediment": 4.0, "material_rock": 4.0}`, while the others keep the row's spacing; the
panel shows that such overrides exist and keeps them. `terrain_max_samples` raises the
input's sample budget, described in the [reference](reference.md#limits).

## After the cook

**Manual layers keep their work.** A cook replaces only its target layer. Manual layers
above it are composed on top of the new result as before: Add layers follow the new ground,
Replace layers keep their values.

**Results go stale, never silently out of date.** A cooked layer is marked stale, with the
reason in its `procedural_status`, when:

- a layer it was built from changes (checked a few times a second, in the editor and at
  runtime);
- the `HEGoNode3D`'s parameters, input rows or transform change (in the editor);
- the scene is reopened: a result loaded from disk is stale until it is cooked again.

A stale result stays visible and in use. Nothing recooks on its own, and cooking one stage
does not cook the stages that read from it: recook them yourself, in stack order. A bake
refuses stale layers unless you pass `allow_stale_procedural`.

**A layer belongs to the node that cooked it.** While that `HEGoNode3D` is in the scene,
another one cannot publish into the same layer. Renaming or deleting it releases the layer.

**A rejected cook changes nothing.** The bridge refuses a result, keeps every target's
previous content and marks the targets stale with the reason, when for example:

- `hegostrata_layer_path` names a missing layer, or one that is not procedural;
- a target is also one of the cook's inputs;
- an input layer, or the `HEGoNode3D`'s parameters, inputs or transform, changed while
  Houdini was cooking;
- the `HEGoNode3D` or the terrain is scaled, pitched or rolled;
- a volume is malformed, or the result exceeds the sample budget.

The reason is also logged as a warning in the HEGo session log under the `terrain`
category. The HEGo cook itself still succeeds, so check the layer's status.

## Example HDAs

The demo project's island ships three terrain HDAs in the repository's `otls/` folder. They
are built for the island's four materials, and make good templates for your own:

| HDA | Reads | Publishes |
| --- | --- | --- |
| `HEGo_IslandErosion` | cumulative `height`; optionally the raw `height` and `constraint` of a later hand layer, which it protects and blends toward | `height`, `erosion_delta`, `sediment`, `debris`, `flow`, `grass`, `rock`, `sand`, `scree`, plus one `material_<name>` weight per material |
| `HEGo_TerrainTint` | cumulative `height` | `terrain_tint_r`, `terrain_tint_g`, `terrain_tint_b`, `terrain_ao` |
| `HEGo_MaterialDistribution` | cumulative `height` | one `material_<name>` weight per material, summing to 1 |

Each has a `target_layer_path` parameter and routes every output as described above. They
embed a helper, `util_MaterialWeightLimit`, that limits material weights to the four
strongest per sample. [Example: Bracken Isle](example_island.md) shows them cooking a
complete island.
