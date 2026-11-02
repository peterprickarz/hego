# HEGo + Strata addon bundle

This bundle contains HEGo, Strata, the HEGo Strata bridge and the HEGo Terrain3D
bridge, all from source commit e6a02e0d2b694438f1f51962ce1579915ec4922f. Copy its four directories into a Godot
project's `addons/` directory. HEGo Terrain3D also needs the Terrain3D addon
by TokisanGames (tested with 1.0.1) at `addons/terrain_3d`, which this bundle
does not include; leave `hego_terrain3d/` out if you do not use Terrain3D.
HEGo and Strata binaries have matching native build receipts; see each addon's
`native-build.json`.