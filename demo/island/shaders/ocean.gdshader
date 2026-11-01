shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
varying vec3 world_position;
varying vec2 ocean_position;
void vertex() {
	ocean_position = VERTEX.xz;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(world_position.x * 0.019 + TIME * 0.3) * cos(world_position.z * 0.021 - TIME * 0.25) * 0.08;
}
void fragment() {
	float depth = textureLod(scene_depth, SCREEN_UV, 0.0).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float thickness = max(0.0, -scene.z / scene.w + VERTEX.z);
	// Fade the finite authoring seabed into deep water before its boundary.
	float border_distance = min(2048.0 - abs(ocean_position.x), 2048.0 - abs(ocean_position.y));
	thickness = max(thickness, (1.0 - smoothstep(0.0, 256.0, border_distance)) * 24.0);
	float waves = sin(world_position.x * 0.08 + TIME * 0.5) * cos(world_position.z * 0.11 - TIME * 0.4);
	float near_detail = 1.0 - smoothstep(150.0, 600.0, length(VERTEX));
	vec3 normal = normalize(vec3(waves * 0.025 * near_detail, 1.0, sin(world_position.x * 0.14 - world_position.z * 0.09 + TIME) * 0.035 * near_detail));
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);
	ALBEDO = mix(vec3(0.045, 0.22, 0.19), vec3(0.012, 0.08, 0.14), smoothstep(0.5, 10.0, thickness));
	float foam = (1.0 - smoothstep(0.2, 1.5, thickness)) * (0.5 + 0.5 * sin(world_position.x * 0.6 + world_position.z * 0.31 + TIME));
	ALBEDO = mix(ALBEDO, vec3(0.55, 0.68, 0.59), foam * 0.4);
	ROUGHNESS = 0.17;
	SPECULAR = 0.6;
	ALPHA = 1.0;
}
