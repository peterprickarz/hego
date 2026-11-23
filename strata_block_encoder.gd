@tool
class_name StrataBlockEncoder
extends RefCounted
## GPU block compression of regions of an RGBA8 texture array into a block-compressed texture
## array, recorded on the main RenderingDevice (call encode() on the render thread). A compute
## pass encodes one 4 x 4 block per thread into an RGBA32UI scratch texture (one texel per
## 16-byte block), then texture_copy() moves each region's blocks into the target, which Vulkan
## allows between formats of the same block size. Godot's D3D12 driver cannot create a BC
## texture that is a copy destination: check target_supported() and keep uncompressed data
## where it returns false.
##
##   BC7  RGBA. Tries mode 6 (one line, 16 levels), mode 5 (colour and alpha fitted
##        separately, in the channel rotation whose colour lies closest to a line), mode 7 (two
##        subsets with alpha) and, for opaque blocks, modes 1 and 3 (two subsets). The two-subset
##        modes fit the one partition of the first 16 that a line-fit estimate ranks best, and
##        only when that estimate leaves room to beat the best mode so far. Each fit takes the
##        principal axis and refines the endpoints by least squares (twice for modes 6 and 5,
##        once for two subsets); a texel's index comes from its projection onto the palette's
##        line. The block keeps the mode with the least squared error.
##   BC5  two source channels (encode()'s channels), each a BC4 block: endpoints searched
##        around the channel's range in the 8-level form and in the 6-level form with exact 0 and
##        255, the better one kept.

enum Format { BC7, BC5 }

const _TARGET_FORMATS := {
	Format.BC7: RenderingDevice.DATA_FORMAT_BC7_UNORM_BLOCK,
	Format.BC5: RenderingDevice.DATA_FORMAT_BC5_UNORM_BLOCK,
}

const _GLSL_COMMON := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) restrict readonly uniform image2DArray source;
layout(set = 0, binding = 1, rgba32ui) restrict writeonly uniform uimage2DArray blocks;
// Per region: first source texel (xy, a multiple of 4), source layer (z).
layout(set = 0, binding = 2, std430) restrict readonly buffer Jobs { ivec4 jobs[]; };
layout(push_constant, std430) uniform Params { ivec2 size; ivec2 channels; } params;

// The 128-bit block, written least significant bit first.
uvec4 block_bits;
int block_pos;

void put(uint value, int count) {
	if (count <= 0) { return; }
	value &= count >= 32 ? 0xFFFFFFFFu : ((1u << uint(count)) - 1u);
	int word = block_pos >> 5;
	int offset = block_pos & 31;
	block_bits[word] |= value << uint(offset);
	if (offset + count > 32) { block_bits[word + 1] |= value >> uint(32 - offset); }
	block_pos += count;
}

// The 16 texels of the block, 0..255, row by row.
vec4 px[16];

void load_block() {
	ivec3 at = ivec3(gl_GlobalInvocationID);
	ivec4 job = jobs[at.z];
	ivec2 first = job.xy + at.xy * 4;
	for (int t = 0; t < 16; t++) {
		px[t] = round(imageLoad(source, ivec3(first + ivec2(t & 3, t >> 2), job.z)) * 255.0);
	}
}
"""

const _GLSL_BC7 := """
// Subset 1 texels of the two-subset partitions (2 bits per texel, texel 0 lowest), from the BC7
// specification. The encoder considers the first 16, whose subset 1 anchor is texel 15.
const int PARTITIONS = 16;
const uint BC7_P2[16] = uint[](
	0x50505050u, 0x40404040u, 0x54545454u, 0x54505040u, 0x50404000u, 0x55545450u, 0x55545040u, 0x54504000u,
	0x50400000u, 0x55555450u, 0x55544000u, 0x54400000u, 0x55555440u, 0x55550000u, 0x55555500u, 0x55000000u);
const float BIG = 1.0e30;

// Mode 5's channel rotation: rotation r swaps alpha with channel r - 1 in the decoder.
int rotation = 0;

vec4 texel(int t) {
	vec4 p = px[t];
	if (rotation == 1) { return p.wyzx; }
	if (rotation == 2) { return p.xwzy; }
	if (rotation == 3) { return p.xywz; }
	return p;
}

vec4 channel_use(int first, int count) {
	return vec4(first <= 0 && 0 < first + count, first <= 1 && 1 < first + count, first <= 2 && 2 < first + count, first <= 3 && 3 < first + count);
}

// Subset 1 texels of a partition as a 16-bit mask.
uint subset1(uint partition_bits) {
	uint x = partition_bits & 0x55555555u;
	x = (x | (x >> 1u)) & 0x33333333u;
	x = (x | (x >> 2u)) & 0x0F0F0F0Fu;
	x = (x | (x >> 4u)) & 0x00FF00FFu;
	return (x | (x >> 8u)) & 0x0000FFFFu;
}

// An endpoint value of `bits` bits (p-bit included) widened to 8 bits as the decoder does.
int widen(int v, int bits) {
	v <<= 8 - bits;
	return v | (v >> bits);
}

ivec4 widen4(ivec4 v, int bits) {
	v <<= 8 - bits;
	return v | (v >> bits);
}

// The `bits`-bit value whose widened value is nearest to x; p >= 0 fixes its lowest bit.
int quantize(float x, int bits, int p) {
	int top = (1 << bits) - 1;
	int best = 0;
	float best_error = BIG;
	int q = p < 0 ? int(round(x / 255.0 * float(top))) : int(round((x / 255.0 * float(top) - float(p)) * 0.5));
	for (int d = -1; d <= 1; d++) {
		int v = p < 0 ? clamp(q + d, 0, top) : ((clamp(q + d, 0, top >> 1) << 1) | p);
		float e = abs(float(widen(v, bits)) - x);
		if (e < best_error) { best_error = e; best = v; }
	}
	return best;
}

ivec4 quantize4(vec4 x, vec4 use, int bits, int p, out float error) {
	ivec4 q = ivec4(0);
	error = 0.0;
	for (int ch = 0; ch < 4; ch++) {
		if (use[ch] == 0.0) { continue; }
		q[ch] = quantize(x[ch], bits, p);
		float d = float(widen(q[ch], bits)) - x[ch];
		error += d * d;
	}
	return q;
}

// Interpolation weight (of 64) of index k of `levels`: round(k * 64 / (levels - 1)) matches the
// specification's tables for 4, 8 and 16 levels.
int level_weight(int k, int levels) {
	int span = levels - 1;
	return (k * 128 + span) / (2 * span);
}

// The indices of the 16 texels, 4 bits each.
int get_index(uvec2 ix, int t) {
	return int((ix[t >> 3] >> uint((t & 7) * 4)) & 15u);
}

uvec2 with_index(uvec2 ix, int t, int k) {
	uint shift = uint((t & 7) * 4);
	ix[t >> 3] = (ix[t >> 3] & ~(15u << shift)) | (uint(k) << shift);
	return ix;
}

// Squared error of the texels in `mask` over the channels in `use` against the palette of
// endpoints v0, v1 (bits each). The palette lies on a line: each texel's projection picks the
// two neighbouring levels and the nearer one is kept. Writes those texels' indices.
float evaluate(uint mask, vec4 use, int bits, int levels, ivec4 v0, ivec4 v1, inout uvec2 ix) {
	ivec4 e0 = widen4(v0, bits), e1 = widen4(v1, bits);
	vec4 a = vec4(e0) * use;
	vec4 d = vec4(e1 - e0) * use;
	float dd = dot(d, d);
	float scale = dd > 0.0 ? float(levels - 1) / dd : 0.0;
	float total = 0.0;
	for (int t = 0; t < 16; t++) {
		if ((mask & (1u << uint(t))) == 0u) { continue; }
		vec4 p = texel(t) * use;
		int k = clamp(int(floor(dot(p - a, d) * scale)), 0, levels - 2);
		int w0 = level_weight(k, levels), w1 = level_weight(k + 1, levels);
		vec4 q0 = vec4(((64 - w0) * e0 + w0 * e1 + 32) >> 6) * use - p;
		vec4 q1 = vec4(((64 - w1) * e0 + w1 * e1 + 32) >> 6) * use - p;
		float d0 = dot(q0, q0), d1 = dot(q1, q1);
		total += min(d0, d1);
		ix = with_index(ix, t, d1 < d0 ? k + 1 : k);
	}
	return total;
}

float consider(uint mask, vec4 use, int bits, int levels, ivec4 q0, ivec4 q1, float best, inout ivec4 v0, inout ivec4 v1, inout uvec2 ix) {
	uvec2 trial = ix;
	float e = evaluate(mask, use, bits, levels, q0, q1, trial);
	if (e < best) { best = e; v0 = q0; v1 = q1; ix = trial; }
	return best;
}

// Quantizes endpoints a, b. p-bit modes: 0 none, 1 one per endpoint, 2 one per subset. `every`
// evaluates every p-bit combination; otherwise each endpoint takes its nearer p-bit.
float try_endpoints(uint mask, vec4 use, int bits, int p_mode, int levels, vec4 a, vec4 b, float best, bool every, inout ivec4 v0, inout ivec4 v1, inout uvec2 ix) {
	float ea, eb;
	if (p_mode == 0) {
		return consider(mask, use, bits, levels, quantize4(a, use, bits, -1, ea), quantize4(b, use, bits, -1, eb), best, v0, v1, ix);
	}
	if (every) {
		int combos = p_mode == 1 ? 4 : 2;
		for (int c = 0; c < combos; c++) {
			int p0 = p_mode == 1 ? (c & 1) : c, p1 = p_mode == 1 ? (c >> 1) : c;
			best = consider(mask, use, bits, levels, quantize4(a, use, bits, p0, ea), quantize4(b, use, bits, p1, eb), best, v0, v1, ix);
		}
		return best;
	}
	float a0, a1, b0, b1;
	ivec4 qa0 = quantize4(a, use, bits, 0, a0), qa1 = quantize4(a, use, bits, 1, a1);
	ivec4 qb0 = quantize4(b, use, bits, 0, b0), qb1 = quantize4(b, use, bits, 1, b1);
	if (p_mode == 2) {
		bool one = a1 + b1 < a0 + b0;
		return consider(mask, use, bits, levels, one ? qa1 : qa0, one ? qb1 : qb0, best, v0, v1, ix);
	}
	return consider(mask, use, bits, levels, a1 < a0 ? qa1 : qa0, b1 < b0 ? qb1 : qb0, best, v0, v1, ix);
}

// Endpoints for the texels of `mask` over channels [first, first + count): the principal axis
// through their mean, then `refits` least-squares refits on the chosen indices. `every_pbit`
// searches every p-bit combination on the last refit.
float fit(uint mask, int first, int count, int bits, int p_mode, int levels, int refits, bool every_pbit, out ivec4 v0, out ivec4 v1, inout uvec2 ix) {
	v0 = ivec4(0); v1 = ivec4(0);
	vec4 use = channel_use(first, count);
	vec4 mean = vec4(0.0), lo = vec4(255.0), hi = vec4(0.0);
	float n = 0.0;
	for (int t = 0; t < 16; t++) {
		if ((mask & (1u << uint(t))) == 0u) { continue; }
		vec4 p = texel(t);
		mean += p; lo = min(lo, p); hi = max(hi, p); n += 1.0;
	}
	if (n == 0.0) { return 0.0; }
	mean /= n;
	vec4 axis = (hi - lo) * use;
	if (count > 1) {
		mat4 covariance = mat4(0.0);
		for (int t = 0; t < 16; t++) {
			if ((mask & (1u << uint(t))) == 0u) { continue; }
			vec4 d = (texel(t) - mean) * use;
			covariance += outerProduct(d, d);
		}
		for (int i = 0; i < 8; i++) {
			vec4 next = covariance * axis;
			if (dot(next, next) < 1.0e-8) { break; }
			axis = next / length(next);
		}
	}
	if (dot(axis, axis) < 1.0e-8) { axis = use; }
	axis = normalize(axis);
	float t_lo = BIG, t_hi = -BIG;
	for (int t = 0; t < 16; t++) {
		if ((mask & (1u << uint(t))) == 0u) { continue; }
		float s = dot((texel(t) - mean) * use, axis);
		t_lo = min(t_lo, s); t_hi = max(t_hi, s);
	}
	vec4 a = clamp(mean + axis * t_lo, vec4(0.0), vec4(255.0));
	vec4 b = clamp(mean + axis * t_hi, vec4(0.0), vec4(255.0));
	float best = try_endpoints(mask, use, bits, p_mode, levels, a, b, BIG, every_pbit && refits == 0, v0, v1, ix);
	for (int iteration = 0; iteration < refits && best > 0.0; iteration++) {
		float s00 = 0.0, s01 = 0.0, s11 = 0.0;
		vec4 r0 = vec4(0.0), r1 = vec4(0.0);
		for (int t = 0; t < 16; t++) {
			if ((mask & (1u << uint(t))) == 0u) { continue; }
			float w = float(level_weight(get_index(ix, t), levels)) / 64.0;
			vec4 p = texel(t);
			s00 += (1.0 - w) * (1.0 - w); s01 += (1.0 - w) * w; s11 += w * w;
			r0 += (1.0 - w) * p; r1 += w * p;
		}
		float det = s00 * s11 - s01 * s01;
		if (abs(det) < 1.0e-6) { break; }
		a = clamp((s11 * r0 - s01 * r1) / det, vec4(0.0), vec4(255.0));
		b = clamp((s00 * r1 - s01 * r0) / det, vec4(0.0), vec4(255.0));
		best = try_endpoints(mask, use, bits, p_mode, levels, a, b, best, every_pbit && iteration == refits - 1, v0, v1, ix);
	}
	return best;
}

// The anchor texel's index must have its top bit clear: swap the subset's endpoints otherwise.
void fix_anchor(uint mask, int anchor, int index_bits, inout ivec4 v0, inout ivec4 v1, inout uvec2 ix) {
	int top = (1 << index_bits) - 1;
	if (get_index(ix, anchor) <= (top >> 1)) { return; }
	ivec4 swap = v0; v0 = v1; v1 = swap;
	uvec2 flip = uvec2(0u);
	for (int t = 0; t < 16; t++) {
		if ((mask & (1u << uint(t))) != 0u) { flip[t >> 3] |= uint(top) << uint((t & 7) * 4); }
	}
	ix ^= flip;
}

// The block's texel mean and the sum of the outer products of the texels about it.
vec4 block_mean;
mat4 block_squares;

// Error estimate for fitting a set of texels (sum and sum of outer products about the block mean,
// count n) with a palette on one line, over the channels in `use`: their distance from the
// principal line, which no such palette beats, plus `quantization` times their spread along it.
float line_estimate(mat4 squares, vec4 sum, float n, vec4 use, float quantization) {
	if (n < 2.0) { return 0.0; }
	mat4 c = matrixCompMult(squares - outerProduct(sum, sum) / n, outerProduct(use, use));
	vec4 diagonal = vec4(c[0][0], c[1][1], c[2][2], c[3][3]);
	float trace = diagonal.x + diagonal.y + diagonal.z + diagonal.w;
	float top = max(max(diagonal.x, diagonal.y), max(diagonal.z, diagonal.w));
	if (top <= 0.0) { return 0.0; }
	vec4 axis = diagonal.x == top ? c[0] : (diagonal.y == top ? c[1] : (diagonal.z == top ? c[2] : c[3]));
	for (int i = 0; i < 2; i++) {
		vec4 next = c * axis;
		float length2 = dot(next, next);
		if (length2 < 1.0e-8) { break; }
		axis = next * inversesqrt(length2);
	}
	float length2 = dot(axis, axis);
	float along = length2 > 0.0 ? dot(axis, c * axis) / length2 : 0.0;
	return max(trace - along, 0.0) + quantization * along;
}

// The partition whose two subsets best suit lines of 4 levels (which leave about 1/9 of the
// spread along each line) over the channels in `use`, and its estimate.
int best_partition(vec4 use, out float estimate) {
	estimate = BIG;
	int best = 0;
	for (int part = 0; part < PARTITIONS; part++) {
		uint m1 = subset1(BC7_P2[part]);
		vec4 s1 = vec4(0.0);
		mat4 q1 = mat4(0.0);
		for (int t = 0; t < 16; t++) {
			if ((m1 & (1u << uint(t))) == 0u) { continue; }
			vec4 x = (px[t] - block_mean) * use;
			s1 += x; q1 += outerProduct(x, x);
		}
		float n1 = float(bitCount(m1));
		float e = line_estimate(q1, s1, n1, use, 1.0 / 9.0) + line_estimate(block_squares - q1, -s1, 16.0 - n1, use, 1.0 / 9.0);
		if (e < estimate) { estimate = e; best = part; }
	}
	return best;
}

float best_error;
uvec4 best_block;

void keep(float error) {
	if (error < best_error) { best_error = error; best_block = block_bits; }
}

void begin(int mode) {
	block_bits = uvec4(0u);
	block_pos = 0;
	put(1u << uint(mode), mode + 1);
}

// Endpoint fields (ep: per endpoint, subset by subset), p-bits and indices of the modes with
// one index set.
void put_endpoints(ivec4 ep[4], int endpoints, int colour_bits, int alpha_bits, int p_mode) {
	int shift = p_mode == 0 ? 0 : 1;
	for (int ch = 0; ch < 3; ch++) {
		for (int e = 0; e < endpoints; e++) { put(uint(ep[e][ch] >> shift), colour_bits); }
	}
	for (int e = 0; e < endpoints && alpha_bits > 0; e++) { put(uint(ep[e].w >> shift), alpha_bits); }
	if (p_mode == 1) { for (int e = 0; e < endpoints; e++) { put(uint(ep[e].x & 1), 1); } }
	if (p_mode == 2) { for (int e = 0; e < endpoints; e += 2) { put(uint(ep[e].x & 1), 1); } }
}

void put_indices(uvec2 ix, int index_bits, int anchor1) {
	for (int t = 0; t < 16; t++) { put(uint(get_index(ix, t)), index_bits - ((t == 0 || t == anchor1) ? 1 : 0)); }
}

void mode6() {
	ivec4 v0, v1;
	uvec2 ix = uvec2(0u);
	float e = fit(0xFFFFu, 0, 4, 8, 1, 16, 2, true, v0, v1, ix);
	fix_anchor(0xFFFFu, 0, 4, v0, v1, ix);
	begin(6);
	put_endpoints(ivec4[4](v0, v1, ivec4(0), ivec4(0)), 2, 7, 7, 1);
	put_indices(ix, 4, -1);
	keep(e);
}

void mode5(int r) {
	rotation = r;
	ivec4 c0, c1, a0, a1;
	uvec2 colour = uvec2(0u), alpha = uvec2(0u);
	float e = fit(0xFFFFu, 0, 3, 7, 0, 4, 2, false, c0, c1, colour);
	if (e < best_error) { e += fit(0xFFFFu, 3, 1, 8, 0, 4, 2, false, a0, a1, alpha); }
	rotation = 0;
	if (e >= best_error) { return; }
	fix_anchor(0xFFFFu, 0, 2, c0, c1, colour);
	fix_anchor(0xFFFFu, 0, 2, a0, a1, alpha);
	begin(5);
	put(uint(r), 2);
	put_endpoints(ivec4[4](ivec4(c0.xyz, a0.w), ivec4(c1.xyz, a1.w), ivec4(0), ivec4(0)), 2, 7, 8, 0);
	put_indices(colour, 2, -1);
	put_indices(alpha, 2, -1);
	keep(e);
}

// Two-subset modes: 7 (RGBA, 5-bit + p-bit endpoints), 3 (RGB, 7 + p), 1 (RGB, 6 + shared p).
// Skipped unless the partition's estimate is well below the best error so far.
void two_subsets(int mode, int part, float estimate) {
	if (estimate * 0.75 >= best_error) { return; }
	int count = mode == 7 ? 4 : 3;
	int bits = mode == 7 ? 6 : (mode == 3 ? 8 : 7);
	int p_mode = mode == 1 ? 2 : 1;
	int index_bits = mode == 1 ? 3 : 2;
	uint m1 = subset1(BC7_P2[part]);
	uint m0 = 0xFFFFu & ~m1;
	ivec4 v0, v1, v2, v3;
	uvec2 ix = uvec2(0u);
	float e = fit(m0, 0, count, bits, p_mode, 1 << index_bits, 1, false, v0, v1, ix);
	if (e >= best_error) { return; }
	e += fit(m1, 0, count, bits, p_mode, 1 << index_bits, 1, false, v2, v3, ix);
	if (e >= best_error) { return; }
	fix_anchor(m0, 0, index_bits, v0, v1, ix);
	fix_anchor(m1, 15, index_bits, v2, v3, ix);
	begin(mode);
	put(uint(part), 6);
	put_endpoints(ivec4[4](v0, v1, v2, v3), 4, bits - 1, mode == 7 ? 5 : 0, p_mode);
	put_indices(ix, index_bits, 15);
	keep(e);
}

void main() {
	if (any(greaterThanEqual(ivec2(gl_GlobalInvocationID.xy), params.size))) { return; }
	load_block();
	block_mean = vec4(0.0);
	for (int t = 0; t < 16; t++) { block_mean += px[t]; }
	block_mean /= 16.0;
	block_squares = mat4(0.0);
	for (int t = 0; t < 16; t++) { vec4 d = px[t] - block_mean; block_squares += outerProduct(d, d); }
	best_error = BIG;
	best_block = uvec4(0u);
	mode6();
	// Mode 5 fits the rotation whose three colour channels lie closest to a line: the colour
	// error cannot be smaller than that distance, and the rest of the error hardly depends on the
	// rotation.
	if (best_error > 0.0) {
		int chosen = 0;
		float least = BIG;
		for (int r = 0; r < 4; r++) {
			vec4 use = vec4(1.0);
			use[(r + 3) % 4] = 0.0;
			float e = line_estimate(block_squares, vec4(0.0), 16.0, use, 0.0);
			if (e < least) { least = e; chosen = r; }
		}
		if (least < best_error) { mode5(chosen); }
	}
	if (best_error > 0.0) {
		float estimate;
		int part = best_partition(vec4(1.0), estimate);
		two_subsets(7, part, estimate);
	}
	bool opaque = true;
	for (int t = 0; t < 16; t++) { opaque = opaque && px[t].w == 255.0; }
	if (opaque && best_error > 0.0) {
		float estimate;
		int part = best_partition(vec4(1.0, 1.0, 1.0, 0.0), estimate);
		two_subsets(3, part, estimate);
		two_subsets(1, part, estimate);
	}
	imageStore(blocks, ivec3(gl_GlobalInvocationID), best_block);
}
"""

const _GLSL_BC5 := """
// The level of BC4 endpoints e0, e1 (8-level form when e0 > e1) nearest to v, as its index, and
// its squared error. The levels are evenly spaced between the endpoints, so the nearest is v's
// rounded position between them (or, in the 6-level form, 0 or 255 when nearer).
int bc4_index(float v, int e0, int e1, out float error) {
	if (e0 > e1) {
		int position = clamp(int(round((v - float(e1)) * 7.0 / float(e0 - e1))), 0, 7);
		float d = float(position * e0 + (7 - position) * e1) / 7.0 - v;
		error = d * d;
		return position == 7 ? 0 : (position == 0 ? 1 : 8 - position);
	}
	int position = e1 > e0 ? clamp(int(round((v - float(e0)) * 5.0 / float(e1 - e0))), 0, 5) : 0;
	float d = float((5 - position) * e0 + position * e1) / 5.0 - v;
	error = d * d;
	int k = position == 0 ? 0 : (position == 5 ? 1 : position + 1);
	float low = v * v, high = (255.0 - v) * (255.0 - v);
	if (low < error) { error = low; k = 6; }
	if (high < error) { error = high; k = 7; }
	return k;
}

float bc4_error(float v[16], int e0, int e1) {
	float total = 0.0;
	for (int t = 0; t < 16; t++) {
		float e;
		bc4_index(v[t], e0, e1, e);
		total += e;
	}
	return total;
}

// One channel's BC4 block: endpoints searched around the range in the 8-level form, and around
// the range of the values strictly between 0 and 255 in the 6-level form.
void bc4(float v[16]) {
	float lo = 255.0, hi = 0.0, inner_lo = 255.0, inner_hi = 0.0;
	for (int t = 0; t < 16; t++) {
		lo = min(lo, v[t]); hi = max(hi, v[t]);
		if (v[t] > 0.0 && v[t] < 255.0) { inner_lo = min(inner_lo, v[t]); inner_hi = max(inner_hi, v[t]); }
	}
	int best_e0 = int(lo), best_e1 = int(lo);
	float best = bc4_error(v, best_e0, best_e1);
	if (best > 0.0 && hi > lo) {
		for (int d0 = -2; d0 <= 2; d0++) {
			for (int d1 = -2; d1 <= 2; d1++) {
				int e0 = clamp(int(hi) + d0, 0, 255), e1 = clamp(int(lo) + d1, 0, 255);
				if (e0 <= e1) { continue; }
				float e = bc4_error(v, e0, e1);
				if (e < best) { best = e; best_e0 = e0; best_e1 = e1; }
			}
		}
	}
	if (best > 0.0 && inner_hi >= inner_lo) {
		for (int d0 = -2; d0 <= 2; d0++) {
			for (int d1 = -2; d1 <= 2; d1++) {
				int e0 = clamp(int(inner_lo) + d0, 0, 255), e1 = clamp(int(inner_hi) + d1, 0, 255);
				if (e0 > e1) { continue; }
				float e = bc4_error(v, e0, e1);
				if (e < best) { best = e; best_e0 = e0; best_e1 = e1; }
			}
		}
	}
	put(uint(best_e0), 8);
	put(uint(best_e1), 8);
	for (int t = 0; t < 16; t++) {
		float e;
		put(uint(bc4_index(v[t], best_e0, best_e1, e)), 3);
	}
}

void main() {
	if (any(greaterThanEqual(ivec2(gl_GlobalInvocationID.xy), params.size))) { return; }
	load_block();
	block_bits = uvec4(0u);
	block_pos = 0;
	for (int c = 0; c < 2; c++) {
		float v[16];
		for (int t = 0; t < 16; t++) { v[t] = px[t][params.channels[c]]; }
		bc4(v);
	}
	imageStore(blocks, ivec3(gl_GlobalInvocationID), block_bits);
}
"""

var _pipelines := {}
var _shaders := {}
var _scratch := RID()
var _scratch_size := Vector2i.ZERO
var _scratch_layers := 0
var _jobs := RID()
var _jobs_capacity := 0
var _rd: RenderingDevice


## Whether [param rd] can create a texture array of [param format] that is sampled and a copy
## destination (false on Godot's D3D12 driver).
static func target_supported(rd: RenderingDevice, format: Format) -> bool:
	if rd == null: return false
	var description := RDTextureFormat.new()
	description.format = _TARGET_FORMATS[format]
	description.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	description.width = 4
	description.height = 4
	description.array_layers = 1
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if not rd.texture_is_format_supported_for_usage(description.format, description.usage_bits): return false
	var texture := rd.texture_create(description, RDTextureView.new(), [])
	if not texture.is_valid(): return false
	rd.free_rid(texture)
	return true


## The RenderingDevice format of a target of [param format].
static func target_format(format: Format) -> int:
	return _TARGET_FORMATS[format]


## Render thread: records the encoding of regions of [param source] (RGBA8 texture array with
## storage usage) into [param target] (texture array of target_format(), copy destination).
## Every region is [param blocks] blocks (4 x 4 texels) in size; [param regions] holds per region
## [source layer, first source texel (Vector2i, multiples of 4), target layer, first target texel
## (Vector2i, multiples of 4)]. BC5 takes the source channels [param channels] (0 R .. 3 A).
## False when the pipeline could not be made.
func encode(rd: RenderingDevice, format: Format, source: RID, target: RID, blocks: Vector2i, regions: Array, channels := Vector2i(0, 1)) -> bool:
	if regions.is_empty() or blocks.x <= 0 or blocks.y <= 0: return true
	if _rd != null and _rd != rd: free_resources()
	_rd = rd
	var pipeline := _pipeline(format)
	if not pipeline.is_valid(): return false
	_ensure_scratch(blocks, regions.size())
	_ensure_jobs(regions.size())
	var data := PackedByteArray()
	data.resize(regions.size() * 16)
	for i in regions.size():
		var region: Array = regions[i]
		var origin: Vector2i = region[1]
		data.encode_s32(i * 16, origin.x); data.encode_s32(i * 16 + 4, origin.y)
		data.encode_s32(i * 16 + 8, int(region[0]))
	rd.buffer_update(_jobs, 0, data.size(), data)
	var uniforms: Array[RDUniform] = [_image_uniform(0, source), _image_uniform(1, _scratch), _buffer_uniform(2, _jobs)]
	var uniform_set := UniformSetCacheRD.get_cache(_shaders[format], 0, uniforms)
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, blocks.x); push.encode_s32(4, blocks.y)
	push.encode_s32(8, channels.x); push.encode_s32(12, channels.y)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(blocks.x / 8.0), ceili(blocks.y / 8.0), regions.size())
	rd.compute_list_end()
	for i in regions.size():
		var region: Array = regions[i]
		var at: Vector2i = region[3]
		# The extent is in source texels: one per block.
		rd.texture_copy(_scratch, target, Vector3.ZERO, Vector3(at.x, at.y, 0), Vector3(blocks.x, blocks.y, 1), 0, 0, i, int(region[2]))
	return true


## Render thread: frees the pipelines and scratch resources.
func free_resources() -> void:
	if _rd == null: return
	for rid: RID in [_scratch, _jobs]:
		if rid.is_valid(): _rd.free_rid(rid)
	for format: int in _shaders:
		if (_shaders[format] as RID).is_valid(): _rd.free_rid(_shaders[format])
	_scratch = RID(); _jobs = RID()
	_scratch_size = Vector2i.ZERO; _scratch_layers = 0; _jobs_capacity = 0
	_shaders.clear(); _pipelines.clear()


func _pipeline(format: Format) -> RID:
	if _pipelines.has(format) and (_pipelines[format] as RID).is_valid(): return _pipelines[format]
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = _GLSL_COMMON + (_GLSL_BC7 if format == Format.BC7 else _GLSL_BC5)
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("StrataBlockEncoder: %s shader: %s" % [Format.keys()[format], spirv.compile_error_compute])
		return RID()
	var shader := _rd.shader_create_from_spirv(spirv, "StrataBlockEncoder %s" % Format.keys()[format])
	_shaders[format] = shader
	_pipelines[format] = _rd.compute_pipeline_create(shader)
	return _pipelines[format]


func _ensure_scratch(blocks: Vector2i, layers: int) -> void:
	if _scratch.is_valid() and _scratch_size.x >= blocks.x and _scratch_size.y >= blocks.y and _scratch_layers >= layers: return
	if _scratch.is_valid(): _rd.free_rid(_scratch)
	_scratch_size = Vector2i(maxi(blocks.x, _scratch_size.x), maxi(blocks.y, _scratch_size.y))
	_scratch_layers = maxi(nearest_po2(layers), _scratch_layers)
	var description := RDTextureFormat.new()
	description.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT
	description.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	description.width = _scratch_size.x
	description.height = _scratch_size.y
	description.array_layers = _scratch_layers
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_scratch = _rd.texture_create(description, RDTextureView.new(), [])


func _ensure_jobs(count: int) -> void:
	if _jobs.is_valid() and _jobs_capacity >= count: return
	if _jobs.is_valid(): _rd.free_rid(_jobs)
	_jobs_capacity = maxi(nearest_po2(count), 16)
	_jobs = _rd.storage_buffer_create(_jobs_capacity * 16)


func _image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
