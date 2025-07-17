# HEGo - Houdini Engine in Godot
 
Welcome to the hego repository. This is an open source Houdini Engine integration into Godot as a c++ [GDextension](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/what_is_gdextension.html)

There's also a [houdini2godot](https://github.com/Mandrake0/houdini2godot) plugin made by [Mandrake0](https://github.com/Mandrake0) which allows to export Godot scenes directly from Houdini.

Check the [wiki](https://github.com/peterprickarz/hego/wiki) and/or this [introduction video](https://youtu.be/cviGlmKmFQ8) to get started

This is in heavy WIP and in an early stage.

I'm taking quite a different approach compared to the offical Houdini Engine plugins(Unreal, Unity, Maya etc), as I mostly focus on keeping interaction with Houdini scriptable, and mainly focus on building a nice API to be used via GDScript. However, there is also a default HEGoNode3D, which comes with basic support for generating Meshes, Instances via MultiMeshInstance and spawning other node types/instancing scenes.

Currently, this is built for Houdini 20.5.487, and Godot 4.2.2 stable, but should be upwards compatible on the Godot side. When submitting pull requests, please stick to those versions for now.

If you have any questions or problems, feel free to message me on [X](https://x.com/prickarz) where I will try to help as much as I can.

Big thanks to https://ambientcg.com/ and https://freestylized.com/ for providing CC0 textures I used in the demo project.
