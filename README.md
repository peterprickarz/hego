# HEGo Terrain3D package

This package is built from source commit 5a5c62d37983c88b68f3d167f41160caf48a8d4b. It sends Terrain3D nodes to HDAs
as heightfield inputs and turns cooked heightfields and points into Terrain3D
terrains and instances. It requires HEGo from the same source revision at
`addons/hego`, and the Terrain3D addon by TokisanGames (tested with 1.0.1),
which you install yourself at `addons/terrain_3d`. See `PACKAGE.json` for
both. It contains no native code.

# HEGo Terrain3D

The bridge between HEGo and [Terrain3D](https://github.com/TokisanGames/Terrain3D). It
requires the HEGo addon (`addons/hego`) and Terrain3D (`addons/terrain_3d`, tested with
1.0.1, installed by you); neither depends on it, and it contains no native code.

- `HEGoTerrain3DInput` sends an existing Terrain3D node to an HDA input as a heightfield:
  the regions are stitched into one grid, with per-texture weight layers and region/hole masks.
- `HEGoTerrain3DOutput` builds or updates a Terrain3D node from a cooked heightfield whose
  `height` layer carries `hegot3d_spawn_terrain`; optional `hegot3d_*` layers add masks,
  holes, texture weights and colour.
- `HEGoTerrain3DInstancer` scatters scenes through Terrain3D's instancer from points carrying
  `hegot3d_use_terrain3d_instancer`.

HEGo finds the input and output handlers through its extension points (`HEGoInputHandler`,
`HEGoOutputHandler`), so enabling the plugin is all that is needed. Terrain3D is reached only
through `ClassDB` and `Object.call`, never by class name, so the bridge loads and reports a
clear error when Terrain3D is missing. Documentation: `docs/node_reference/inputs/terrain3d_input.rst`
and `docs/node_reference/outputs/terrain3d_output.rst` in the HEGo repository.