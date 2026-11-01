shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, skip_vertex_transform;

// Line segment with a constant width in screen pixels. Each segment is a quad of four
// vertices: VERTEX is this end, CUSTOM0.xyz the other end, CUSTOM0.w a width multiplier,
// UV.x the side (-1 or 1) and COLOR the colour.
uniform float line_px = 2.0;

varying vec4 tint;

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

void vertex() {
	vec4 a = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec4 b = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0));
	float near = 0.05;
	if (a.w < near && b.w < near) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		if (a.w < near) {
			a = mix(a, b, (near - a.w) / (b.w - a.w));
		} else if (b.w < near) {
			b = mix(b, a, (near - b.w) / (a.w - b.w));
		}
		vec2 sa = a.xy / a.w * VIEWPORT_SIZE * 0.5;
		vec2 sb = b.xy / b.w * VIEWPORT_SIZE * 0.5;
		vec2 dir = sb - sa;
		dir = length(dir) > 0.0001 ? normalize(dir) : vec2(1.0, 0.0);
		vec2 side = vec2(-dir.y, dir.x);
		a.xy += side * UV.x * line_px * CUSTOM0.w / VIEWPORT_SIZE * a.w;
		POSITION = a;
	}
	tint = vec4(srgb_to_linear(COLOR.rgb), COLOR.a);
}

void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = tint.a;
}
