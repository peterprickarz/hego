// Copia debug views, SHADOW_RANGE: what the drawer does with a batch's or instance's shadows.
// mode 0: casts no shadows (grey). mode 1: casts at any distance (red). mode 2: a shadow range:
// red within shadow_range, yellow in the hysteresis band up to shadow_range + shadow_margin
// (the object keeps whichever state it had), blue beyond.
//
// The drawer switches a whole batch, measuring from the batch origin (the centre of its
// instances' bounds) to the store's sources with shadows. A shader cannot see the batch origin
// (in a MultiMesh, MODEL_MATRIX and NODE_POSITION_WORLD include the instance's own transform), so
// it measures from the centre of the instance's batch cell (floor(x / batch_size),
// floor(z / batch_size) in store space, as the build forms batches) at the instance's own height,
// to the camera drawing it. The whole batch then shows one state, near the boundary possibly the
// wrong one by up to half a batch. With batch_size 0 (single instances) it measures from the
// instance origin, as the drawer does.
shader_type spatial;
render_mode cull_disabled;

uniform int mode = 0;
uniform float shadow_range = 0.0;
uniform float shadow_margin = 0.0;
// Edge of a batch cell in metres; 0 measures from each instance.
uniform float batch_size = 0.0;
// World space to store space, and back.
uniform mat4 store_inverse = mat4(1.0);
uniform mat4 store_transform = mat4(1.0);

varying vec3 tint;

void vertex() {
	if (mode == 0) {
		tint = vec3(0.45);
	} else if (mode == 1) {
		tint = vec3(0.9, 0.1, 0.05);
	} else {
		vec3 origin = MODEL_MATRIX[3].xyz;
		if (batch_size > 0.0) {
			vec3 local = (store_inverse * vec4(origin, 1.0)).xyz;
			local.xz = (floor(local.xz / batch_size) + 0.5) * batch_size;
			origin = (store_transform * vec4(local, 1.0)).xyz;
		}
		float distance_to_camera = distance(origin, CAMERA_POSITION_WORLD);
		if (distance_to_camera <= shadow_range) {
			tint = vec3(0.9, 0.1, 0.05);
		} else if (distance_to_camera <= shadow_range + shadow_margin) {
			tint = vec3(0.95, 0.9, 0.1);
		} else {
			tint = vec3(0.1, 0.3, 0.95);
		}
	}
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
