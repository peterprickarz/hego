// Copia debug views, BATCHES: a random colour per batch.
//
// A shader cannot tell which MultiMesh it belongs to (in a MultiMesh, MODEL_MATRIX and
// NODE_POSITION_WORLD both include the instance's own transform), so the batch is found the way
// the build forms it: an instance belongs to the batch cell floor(x / batch_size),
// floor(z / batch_size) of its origin in store space, and an impostor to its far cell
// (batch_size is then the store's impostor_cell_size). With batch_size 0 (DrawMode.INSTANCE)
// every instance gets its own colour. object_seed separates the batches of different objects in
// the same cell, which are separate MultiMeshes.
shader_type spatial;
render_mode cull_disabled;

// Edge of a batch cell in metres; 0 colours each instance.
uniform float batch_size = 0.0;
// World space to store space.
uniform mat4 store_inverse = mat4(1.0);
uniform int object_seed = 0;

varying vec3 batch_color;

uint hash_u(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

vec3 hue(float h) {
	return clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

void vertex() {
	vec3 origin = (store_inverse * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	// Per instance: origins on a 0.25 m lattice, so float noise does not change the colour.
	ivec3 cell = ivec3(floor(origin * 4.0 + 0.5));
	if (batch_size > 0.0) {
		cell = ivec3(int(floor(origin.x / batch_size)), 0, int(floor(origin.z / batch_size)));
	}
	uint h = hash_u(uint(cell.x) ^ hash_u(uint(cell.y) ^ hash_u(uint(cell.z) ^ hash_u(uint(object_seed)))));
	float value = 0.55 + 0.4 * float((h >> 24u) & 255u) / 255.0;
	batch_color = mix(vec3(1.0), hue(float(h & 65535u) / 65536.0), 0.8) * value;
}

void fragment() {
	ALBEDO = batch_color;
	ROUGHNESS = 1.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
