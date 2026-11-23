// Copia debug views, LOD: the mesh LOD Godot drew. The debug mesh (copia_debug.gd) holds one
// copy of the vertices per level with the level in UV2.x, and each LOD's indices point at its
// own copy, so the level Godot selects is the level that is drawn.
// 0 green, 1 yellow, 2 orange, 3 red, 4 magenta, 5 and above purple.
shader_type spatial;
render_mode cull_disabled;

varying flat int level;

void vertex() {
	level = int(UV2.x + 0.5);
}

void fragment() {
	vec3 colors[6] = vec3[](
		vec3(0.1, 0.8, 0.1),
		vec3(0.95, 0.9, 0.1),
		vec3(1.0, 0.5, 0.05),
		vec3(0.9, 0.1, 0.05),
		vec3(0.95, 0.15, 0.85),
		vec3(0.45, 0.15, 0.85));
	ALBEDO = colors[clamp(level, 0, 5)];
	ROUGHNESS = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
