shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, skip_vertex_transform;

// Round marker with a constant size in screen pixels. VERTEX is the centre, UV the corner
// (-1..1), UV2.x a size multiplier and COLOR the colour.
uniform float point_px = 10.0;

varying vec2 corner;
varying vec4 tint;

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	if (clip.w <= 0.0) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		clip.xy += UV * UV2.x * point_px / VIEWPORT_SIZE * clip.w;
		POSITION = clip;
	}
	corner = UV;
	tint = vec4(srgb_to_linear(COLOR.rgb), COLOR.a);
}

void fragment() {
	float r = length(corner);
	if (r > 1.0) {
		discard;
	}
	ALBEDO = r > 0.75 ? tint.rgb * 0.3 : tint.rgb;
	ALPHA = tint.a;
}
