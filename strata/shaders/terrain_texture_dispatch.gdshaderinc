// Generated constant-index descriptor dispatch for Godot 4.4 and later (checked on 4.7.2).
// Sampler arrays are individually bound Texture2D resources. No nonuniform
// descriptor indexing is required. Derivatives are provided by the caller.
// Opt-in pixel sampling: snap to the centre of the mip-0 texel containing uv.
// The mip level comes from the caller's unsnapped derivatives (textureGrad) or
// level, so distance behaviour is unchanged. Default build: identity.
vec2 terrain_pixel_uv(vec2 uv, ivec2 size) {
#ifdef STRATA_PIXEL_SAMPLING
	vec2 dimensions = vec2(size);
	return (floor(uv * dimensions) + vec2(0.5)) / dimensions;
#else
	return uv;
#endif
}
vec4 terrain_color_grad(int id, vec2 uv, vec2 dx, vec2 dy) {
	switch (id) {
		case 0: return textureGrad(color_maps[0], terrain_pixel_uv(uv, textureSize(color_maps[0], 0)), dx, dy);
		case 1: return textureGrad(color_maps[1], terrain_pixel_uv(uv, textureSize(color_maps[1], 0)), dx, dy);
		case 2: return textureGrad(color_maps[2], terrain_pixel_uv(uv, textureSize(color_maps[2], 0)), dx, dy);
		case 3: return textureGrad(color_maps[3], terrain_pixel_uv(uv, textureSize(color_maps[3], 0)), dx, dy);
		case 4: return textureGrad(color_maps[4], terrain_pixel_uv(uv, textureSize(color_maps[4], 0)), dx, dy);
		case 5: return textureGrad(color_maps[5], terrain_pixel_uv(uv, textureSize(color_maps[5], 0)), dx, dy);
		case 6: return textureGrad(color_maps[6], terrain_pixel_uv(uv, textureSize(color_maps[6], 0)), dx, dy);
		case 7: return textureGrad(color_maps[7], terrain_pixel_uv(uv, textureSize(color_maps[7], 0)), dx, dy);
		case 8: return textureGrad(color_maps[8], terrain_pixel_uv(uv, textureSize(color_maps[8], 0)), dx, dy);
		case 9: return textureGrad(color_maps[9], terrain_pixel_uv(uv, textureSize(color_maps[9], 0)), dx, dy);
		case 10: return textureGrad(color_maps[10], terrain_pixel_uv(uv, textureSize(color_maps[10], 0)), dx, dy);
		case 11: return textureGrad(color_maps[11], terrain_pixel_uv(uv, textureSize(color_maps[11], 0)), dx, dy);
		case 12: return textureGrad(color_maps[12], terrain_pixel_uv(uv, textureSize(color_maps[12], 0)), dx, dy);
		case 13: return textureGrad(color_maps[13], terrain_pixel_uv(uv, textureSize(color_maps[13], 0)), dx, dy);
		case 14: return textureGrad(color_maps[14], terrain_pixel_uv(uv, textureSize(color_maps[14], 0)), dx, dy);
		case 15: return textureGrad(color_maps[15], terrain_pixel_uv(uv, textureSize(color_maps[15], 0)), dx, dy);
		case 16: return textureGrad(color_maps[16], terrain_pixel_uv(uv, textureSize(color_maps[16], 0)), dx, dy);
		case 17: return textureGrad(color_maps[17], terrain_pixel_uv(uv, textureSize(color_maps[17], 0)), dx, dy);
		case 18: return textureGrad(color_maps[18], terrain_pixel_uv(uv, textureSize(color_maps[18], 0)), dx, dy);
		case 19: return textureGrad(color_maps[19], terrain_pixel_uv(uv, textureSize(color_maps[19], 0)), dx, dy);
		case 20: return textureGrad(color_maps[20], terrain_pixel_uv(uv, textureSize(color_maps[20], 0)), dx, dy);
		case 21: return textureGrad(color_maps[21], terrain_pixel_uv(uv, textureSize(color_maps[21], 0)), dx, dy);
		case 22: return textureGrad(color_maps[22], terrain_pixel_uv(uv, textureSize(color_maps[22], 0)), dx, dy);
		case 23: return textureGrad(color_maps[23], terrain_pixel_uv(uv, textureSize(color_maps[23], 0)), dx, dy);
		case 24: return textureGrad(color_maps[24], terrain_pixel_uv(uv, textureSize(color_maps[24], 0)), dx, dy);
		case 25: return textureGrad(color_maps[25], terrain_pixel_uv(uv, textureSize(color_maps[25], 0)), dx, dy);
		case 26: return textureGrad(color_maps[26], terrain_pixel_uv(uv, textureSize(color_maps[26], 0)), dx, dy);
		case 27: return textureGrad(color_maps[27], terrain_pixel_uv(uv, textureSize(color_maps[27], 0)), dx, dy);
		case 28: return textureGrad(color_maps[28], terrain_pixel_uv(uv, textureSize(color_maps[28], 0)), dx, dy);
		case 29: return textureGrad(color_maps[29], terrain_pixel_uv(uv, textureSize(color_maps[29], 0)), dx, dy);
		case 30: return textureGrad(color_maps[30], terrain_pixel_uv(uv, textureSize(color_maps[30], 0)), dx, dy);
		case 31: return textureGrad(color_maps[31], terrain_pixel_uv(uv, textureSize(color_maps[31], 0)), dx, dy);
	}
	return textureGrad(color_maps[0], terrain_pixel_uv(uv, textureSize(color_maps[0], 0)), dx, dy);
}
vec4 terrain_normal_grad(int id, vec2 uv, vec2 dx, vec2 dy) {
	switch (id) {
		case 0: return textureGrad(normal_maps[0], uv, dx, dy);
		case 1: return textureGrad(normal_maps[1], uv, dx, dy);
		case 2: return textureGrad(normal_maps[2], uv, dx, dy);
		case 3: return textureGrad(normal_maps[3], uv, dx, dy);
		case 4: return textureGrad(normal_maps[4], uv, dx, dy);
		case 5: return textureGrad(normal_maps[5], uv, dx, dy);
		case 6: return textureGrad(normal_maps[6], uv, dx, dy);
		case 7: return textureGrad(normal_maps[7], uv, dx, dy);
		case 8: return textureGrad(normal_maps[8], uv, dx, dy);
		case 9: return textureGrad(normal_maps[9], uv, dx, dy);
		case 10: return textureGrad(normal_maps[10], uv, dx, dy);
		case 11: return textureGrad(normal_maps[11], uv, dx, dy);
		case 12: return textureGrad(normal_maps[12], uv, dx, dy);
		case 13: return textureGrad(normal_maps[13], uv, dx, dy);
		case 14: return textureGrad(normal_maps[14], uv, dx, dy);
		case 15: return textureGrad(normal_maps[15], uv, dx, dy);
		case 16: return textureGrad(normal_maps[16], uv, dx, dy);
		case 17: return textureGrad(normal_maps[17], uv, dx, dy);
		case 18: return textureGrad(normal_maps[18], uv, dx, dy);
		case 19: return textureGrad(normal_maps[19], uv, dx, dy);
		case 20: return textureGrad(normal_maps[20], uv, dx, dy);
		case 21: return textureGrad(normal_maps[21], uv, dx, dy);
		case 22: return textureGrad(normal_maps[22], uv, dx, dy);
		case 23: return textureGrad(normal_maps[23], uv, dx, dy);
		case 24: return textureGrad(normal_maps[24], uv, dx, dy);
		case 25: return textureGrad(normal_maps[25], uv, dx, dy);
		case 26: return textureGrad(normal_maps[26], uv, dx, dy);
		case 27: return textureGrad(normal_maps[27], uv, dx, dy);
		case 28: return textureGrad(normal_maps[28], uv, dx, dy);
		case 29: return textureGrad(normal_maps[29], uv, dx, dy);
		case 30: return textureGrad(normal_maps[30], uv, dx, dy);
		case 31: return textureGrad(normal_maps[31], uv, dx, dy);
	}
	return textureGrad(normal_maps[0], uv, dx, dy);
}
vec4 terrain_ormh_grad(int id, vec2 uv, vec2 dx, vec2 dy) {
	switch (id) {
		case 0: return textureGrad(ormh_maps[0], terrain_pixel_uv(uv, textureSize(ormh_maps[0], 0)), dx, dy);
		case 1: return textureGrad(ormh_maps[1], terrain_pixel_uv(uv, textureSize(ormh_maps[1], 0)), dx, dy);
		case 2: return textureGrad(ormh_maps[2], terrain_pixel_uv(uv, textureSize(ormh_maps[2], 0)), dx, dy);
		case 3: return textureGrad(ormh_maps[3], terrain_pixel_uv(uv, textureSize(ormh_maps[3], 0)), dx, dy);
		case 4: return textureGrad(ormh_maps[4], terrain_pixel_uv(uv, textureSize(ormh_maps[4], 0)), dx, dy);
		case 5: return textureGrad(ormh_maps[5], terrain_pixel_uv(uv, textureSize(ormh_maps[5], 0)), dx, dy);
		case 6: return textureGrad(ormh_maps[6], terrain_pixel_uv(uv, textureSize(ormh_maps[6], 0)), dx, dy);
		case 7: return textureGrad(ormh_maps[7], terrain_pixel_uv(uv, textureSize(ormh_maps[7], 0)), dx, dy);
		case 8: return textureGrad(ormh_maps[8], terrain_pixel_uv(uv, textureSize(ormh_maps[8], 0)), dx, dy);
		case 9: return textureGrad(ormh_maps[9], terrain_pixel_uv(uv, textureSize(ormh_maps[9], 0)), dx, dy);
		case 10: return textureGrad(ormh_maps[10], terrain_pixel_uv(uv, textureSize(ormh_maps[10], 0)), dx, dy);
		case 11: return textureGrad(ormh_maps[11], terrain_pixel_uv(uv, textureSize(ormh_maps[11], 0)), dx, dy);
		case 12: return textureGrad(ormh_maps[12], terrain_pixel_uv(uv, textureSize(ormh_maps[12], 0)), dx, dy);
		case 13: return textureGrad(ormh_maps[13], terrain_pixel_uv(uv, textureSize(ormh_maps[13], 0)), dx, dy);
		case 14: return textureGrad(ormh_maps[14], terrain_pixel_uv(uv, textureSize(ormh_maps[14], 0)), dx, dy);
		case 15: return textureGrad(ormh_maps[15], terrain_pixel_uv(uv, textureSize(ormh_maps[15], 0)), dx, dy);
		case 16: return textureGrad(ormh_maps[16], terrain_pixel_uv(uv, textureSize(ormh_maps[16], 0)), dx, dy);
		case 17: return textureGrad(ormh_maps[17], terrain_pixel_uv(uv, textureSize(ormh_maps[17], 0)), dx, dy);
		case 18: return textureGrad(ormh_maps[18], terrain_pixel_uv(uv, textureSize(ormh_maps[18], 0)), dx, dy);
		case 19: return textureGrad(ormh_maps[19], terrain_pixel_uv(uv, textureSize(ormh_maps[19], 0)), dx, dy);
		case 20: return textureGrad(ormh_maps[20], terrain_pixel_uv(uv, textureSize(ormh_maps[20], 0)), dx, dy);
		case 21: return textureGrad(ormh_maps[21], terrain_pixel_uv(uv, textureSize(ormh_maps[21], 0)), dx, dy);
		case 22: return textureGrad(ormh_maps[22], terrain_pixel_uv(uv, textureSize(ormh_maps[22], 0)), dx, dy);
		case 23: return textureGrad(ormh_maps[23], terrain_pixel_uv(uv, textureSize(ormh_maps[23], 0)), dx, dy);
		case 24: return textureGrad(ormh_maps[24], terrain_pixel_uv(uv, textureSize(ormh_maps[24], 0)), dx, dy);
		case 25: return textureGrad(ormh_maps[25], terrain_pixel_uv(uv, textureSize(ormh_maps[25], 0)), dx, dy);
		case 26: return textureGrad(ormh_maps[26], terrain_pixel_uv(uv, textureSize(ormh_maps[26], 0)), dx, dy);
		case 27: return textureGrad(ormh_maps[27], terrain_pixel_uv(uv, textureSize(ormh_maps[27], 0)), dx, dy);
		case 28: return textureGrad(ormh_maps[28], terrain_pixel_uv(uv, textureSize(ormh_maps[28], 0)), dx, dy);
		case 29: return textureGrad(ormh_maps[29], terrain_pixel_uv(uv, textureSize(ormh_maps[29], 0)), dx, dy);
		case 30: return textureGrad(ormh_maps[30], terrain_pixel_uv(uv, textureSize(ormh_maps[30], 0)), dx, dy);
		case 31: return textureGrad(ormh_maps[31], terrain_pixel_uv(uv, textureSize(ormh_maps[31], 0)), dx, dy);
	}
	return textureGrad(ormh_maps[0], terrain_pixel_uv(uv, textureSize(ormh_maps[0], 0)), dx, dy);
}
vec4 terrain_ormh_lod(int id, vec2 uv, float level) {
	switch (id) {
		case 0: return textureLod(ormh_maps[0], terrain_pixel_uv(uv, textureSize(ormh_maps[0], 0)), level);
		case 1: return textureLod(ormh_maps[1], terrain_pixel_uv(uv, textureSize(ormh_maps[1], 0)), level);
		case 2: return textureLod(ormh_maps[2], terrain_pixel_uv(uv, textureSize(ormh_maps[2], 0)), level);
		case 3: return textureLod(ormh_maps[3], terrain_pixel_uv(uv, textureSize(ormh_maps[3], 0)), level);
		case 4: return textureLod(ormh_maps[4], terrain_pixel_uv(uv, textureSize(ormh_maps[4], 0)), level);
		case 5: return textureLod(ormh_maps[5], terrain_pixel_uv(uv, textureSize(ormh_maps[5], 0)), level);
		case 6: return textureLod(ormh_maps[6], terrain_pixel_uv(uv, textureSize(ormh_maps[6], 0)), level);
		case 7: return textureLod(ormh_maps[7], terrain_pixel_uv(uv, textureSize(ormh_maps[7], 0)), level);
		case 8: return textureLod(ormh_maps[8], terrain_pixel_uv(uv, textureSize(ormh_maps[8], 0)), level);
		case 9: return textureLod(ormh_maps[9], terrain_pixel_uv(uv, textureSize(ormh_maps[9], 0)), level);
		case 10: return textureLod(ormh_maps[10], terrain_pixel_uv(uv, textureSize(ormh_maps[10], 0)), level);
		case 11: return textureLod(ormh_maps[11], terrain_pixel_uv(uv, textureSize(ormh_maps[11], 0)), level);
		case 12: return textureLod(ormh_maps[12], terrain_pixel_uv(uv, textureSize(ormh_maps[12], 0)), level);
		case 13: return textureLod(ormh_maps[13], terrain_pixel_uv(uv, textureSize(ormh_maps[13], 0)), level);
		case 14: return textureLod(ormh_maps[14], terrain_pixel_uv(uv, textureSize(ormh_maps[14], 0)), level);
		case 15: return textureLod(ormh_maps[15], terrain_pixel_uv(uv, textureSize(ormh_maps[15], 0)), level);
		case 16: return textureLod(ormh_maps[16], terrain_pixel_uv(uv, textureSize(ormh_maps[16], 0)), level);
		case 17: return textureLod(ormh_maps[17], terrain_pixel_uv(uv, textureSize(ormh_maps[17], 0)), level);
		case 18: return textureLod(ormh_maps[18], terrain_pixel_uv(uv, textureSize(ormh_maps[18], 0)), level);
		case 19: return textureLod(ormh_maps[19], terrain_pixel_uv(uv, textureSize(ormh_maps[19], 0)), level);
		case 20: return textureLod(ormh_maps[20], terrain_pixel_uv(uv, textureSize(ormh_maps[20], 0)), level);
		case 21: return textureLod(ormh_maps[21], terrain_pixel_uv(uv, textureSize(ormh_maps[21], 0)), level);
		case 22: return textureLod(ormh_maps[22], terrain_pixel_uv(uv, textureSize(ormh_maps[22], 0)), level);
		case 23: return textureLod(ormh_maps[23], terrain_pixel_uv(uv, textureSize(ormh_maps[23], 0)), level);
		case 24: return textureLod(ormh_maps[24], terrain_pixel_uv(uv, textureSize(ormh_maps[24], 0)), level);
		case 25: return textureLod(ormh_maps[25], terrain_pixel_uv(uv, textureSize(ormh_maps[25], 0)), level);
		case 26: return textureLod(ormh_maps[26], terrain_pixel_uv(uv, textureSize(ormh_maps[26], 0)), level);
		case 27: return textureLod(ormh_maps[27], terrain_pixel_uv(uv, textureSize(ormh_maps[27], 0)), level);
		case 28: return textureLod(ormh_maps[28], terrain_pixel_uv(uv, textureSize(ormh_maps[28], 0)), level);
		case 29: return textureLod(ormh_maps[29], terrain_pixel_uv(uv, textureSize(ormh_maps[29], 0)), level);
		case 30: return textureLod(ormh_maps[30], terrain_pixel_uv(uv, textureSize(ormh_maps[30], 0)), level);
		case 31: return textureLod(ormh_maps[31], terrain_pixel_uv(uv, textureSize(ormh_maps[31], 0)), level);
	}
	return textureLod(ormh_maps[0], terrain_pixel_uv(uv, textureSize(ormh_maps[0], 0)), level);
}
