shader_type spatial;
render_mode unshaded, cull_disabled;

// Uniforms for colors
uniform vec3 bottom_color : source_color = vec3(0.2, 0.4, 0.1);
uniform vec3 mid_color : source_color = vec3(0.3, 0.6, 0.2);
uniform vec3 top_color : source_color = vec3(0.4, 0.7, 0.3);
uniform float color_transition : hint_range(0.0, 2.0) = 1.0;

// Uniforms for wind
uniform float wind_strength : hint_range(0.0, 1.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform vec3 wind_direction = vec3(1.0, 0.0, 0.0);

void vertex() {
    // Wind displacement based on UV height
    float wind_factor = UV.y * wind_strength;
    vec3 wind_offset = wind_direction * sin(TIME * wind_speed + VERTEX.x + VERTEX.z) * wind_factor;
    VERTEX += wind_offset;
}

void fragment() {
    // Base color gradient based on UV.y
    float t = clamp(UV.y * color_transition, 0.0, 1.0);
    vec3 base_color;
    if (t < 0.5) {
        base_color = mix(bottom_color, mid_color, t * 2.0);
    } else {
        base_color = mix(mid_color, top_color, (t - 0.5) * 2.0);
    }

    // Fake shadow at the bottom
    float shadow_factor = 1.0 - smoothstep(0.0, 0.3, UV.y);
    base_color *= (1.0 - shadow_factor * 0.3);

    // Blend normals: terrain (up) at bottom, mesh normal at top
    vec3 terrain_normal = vec3(0.0, 1.0, 0.0); // Assuming terrain normal points up
    vec3 blended_normal = normalize(mix(terrain_normal, NORMAL, smoothstep(0.0, 1.0, UV.y)));

    // Output
    ALBEDO = base_color;
    NORMAL = blended_normal;
}