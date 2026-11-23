// Copia debug views, HIDDEN: the transparent next pass that marks instances drawn although
// nothing of them can be seen. Its opaque pass (copia_debug_flat.gdshader, dim grey) draws
// every instance; this pass draws, through everything, the instances whose bounds lie behind
// the opaque depth of the frame, red and half transparent, and nothing for the others.
//
// The test is per instance and conservative: the instance's mesh bounds (aabb_position,
// aabb_size), transformed by MODEL_MATRIX (which includes the MultiMesh instance transform), are
// projected to a screen rectangle and their nearest depth. The rectangle is looked up in a
// farthest-depth pyramid of this frame's opaque depth (copia_hidden_effect.gd, written just before
// the transparent pass of the same viewport) at the level where it covers at most 2 x 2 texels. The
// instance is hidden when its nearest depth is farther than the farthest depth over the
// rectangle. Depth is reversed (1 near, 0 far). An instance whose bounds cross the near plane
// counts as visible. Its own surface cannot hide it: that surface is never nearer than the
// nearest point of its bounds.
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, blend_mix, shadows_disabled, fog_disabled;

// Level 0 is half the viewport's internal resolution (each texel the farthest of 2 x 2 pixels,
// sizes rounded up); each level halves again. The texture is shared by every viewport and sized
// for the largest; a viewport uses its top-left region.
uniform sampler2D pyramid : filter_nearest, repeat_disable;
uniform vec3 aabb_position;
uniform vec3 aabb_size;
uniform vec4 hidden_color : source_color = vec4(1.0, 0.1, 0.05, 0.35);

void vertex() {
	mat4 to_clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX;
	bool visible = false;
	vec2 low = vec2(1e30);
	vec2 high = vec2(-1e30);
	float nearest = 0.0;
	for (int i = 0; i < 8; i++) {
		vec3 corner = aabb_position + aabb_size * vec3(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1));
		vec4 clip = to_clip * vec4(corner, 1.0);
		// Behind the camera, or nearer than the near plane (reversed depth: z above w).
		if (clip.w <= 0.0 || clip.z > clip.w) {
			visible = true;
			break;
		}
		vec3 ndc = clip.xyz / clip.w;
		// Screen pixels, top-left origin: SCREEN_UV = ndc.xy * 0.5 + 0.5 in Godot 4.
		vec2 pixel = (ndc.xy * 0.5 + 0.5) * VIEWPORT_SIZE;
		low = min(low, pixel);
		high = max(high, pixel);
		nearest = max(nearest, ndc.z);
	}
	bool hidden = false;
	if (!visible) {
		vec2 last = VIEWPORT_SIZE - 1.0;
		low = clamp(low, vec2(0.0), last);
		high = clamp(high, vec2(0.0), last);
		// A level whose texels (2^(level + 1) pixels) are at least as large as the rectangle:
		// it then spans at most 2 x 2 texels.
		float extent = max(high.x - low.x, high.y - low.y);
		int top = max(int(ceil(log2(max(VIEWPORT_SIZE.x, VIEWPORT_SIZE.y)))) - 1, 0);
		top = min(top, textureQueryLevels(pyramid) - 1);
		int level = clamp(int(ceil(log2(max(extent, 1.0)))) - 1, 0, top);
		int shift = level + 1;
		ivec2 a = ivec2(int(low.x) >> shift, int(low.y) >> shift);
		ivec2 b = ivec2(int(high.x) >> shift, int(high.y) >> shift);
		float farthest = min(
				min(texelFetch(pyramid, a, level).r, texelFetch(pyramid, ivec2(b.x, a.y), level).r),
				min(texelFetch(pyramid, ivec2(a.x, b.y), level).r, texelFetch(pyramid, b, level).r));
		// A small relative tolerance toward the camera keeps an instance whose nearest face
		// coincides with the depth it wrote itself from being taken for hidden.
		hidden = nearest * 1.0001 + 1e-7 < farthest;
	}
	// Visible instances collapse to a point outside the view, so they cost no fragments.
	POSITION = hidden ? PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)) : vec4(2.0, 2.0, 2.0, 1.0);
}

void fragment() {
	ALBEDO = hidden_color.rgb;
	ALPHA = hidden_color.a;
}
