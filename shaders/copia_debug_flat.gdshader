// Copia debug views: one flat colour, lit so shapes read. Used by the HIGHLIGHT view, by the
// LOD view for meshes without LODs and for impostors, and as the opaque pass of the HIDDEN view.
// Both faces are drawn, as foliage cards usually are.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 color : source_color = vec3(0.1, 0.8, 0.1);

void fragment() {
	ALBEDO = color;
	ROUGHNESS = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
