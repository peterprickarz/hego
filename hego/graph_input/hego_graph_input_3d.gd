@icon("res://addons/hego/assets/houdini.svg")
@tool
class_name HEGoGraphInput3D
extends HEGoGraph3D

## A [HEGoGraph3D] authored in the editor and fed into a [HEGoNode3D] input.
##
## Kept as its own class so scenes saved with it load unchanged. All behaviour lives in
## [HEGoGraph3D]; use that class to accept graphs from either origin.
