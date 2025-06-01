shader_type spatial;
render_mode depth_draw_opaque, specular_schlick_ggx, depth_prepass_alpha;

// Uniforms for base colors
uniform vec4 TopColor : source_color = vec4(0.24, 0.47, 0.27, 1.0);
uniform vec4 BottomColor : source_color = vec4(0.13, 0.33, 0.25, 1.0);
uniform float ColorRamp : hint_range(0.05, 5.0) = 0.3;
uniform float ColorBlendStrength : hint_range(0.0, 1.0) = 0.5; // New uniform for blending strength

// Uniform for texture (RGB for color, alpha for transparency)
uniform sampler2D AlbedoAlpha;

// Uniforms for Fresnel effect
uniform vec4 FresnelTopColor : source_color = vec4(0.58, 0.65, 0.33, 1.0);
uniform vec4 FresnelBottomColor : source_color = vec4(0.2, 0.3, 0.1, 1.0);
uniform float FresnelStrength : hint_range(0.0, 2.0) = 0.5;

// Uniform for billboarding scale
uniform float MeshScale : hint_range(0.0, 5.0) = 0.333;

// Uniforms for scale randomization
uniform float MinScale : hint_range(0.1, 2.0) = 0.8;
uniform float MaxScale : hint_range(0.1, 2.0) = 1.2;

// Uniform for specular exponent and intensity
uniform float SpecularExponent : hint_range(1.0, 128.0) = 16.0;
uniform float SpecularIntensity : hint_range(0.0, 1.0) = 0.5;

// Uniform for ambient lighting
uniform vec3 AmbientLight : source_color = vec3(0.1, 0.1, 0.1);

// Uniforms for wind animation
uniform vec3 WindDirection : source_color = vec3(1.0, 0.0, 0.0);
uniform float WindSpeed : hint_range(0.0, 10.0) = 2.0;
uniform float WindStrength : hint_range(0.0, 1.0) = 0.2;
uniform float WindHeightScale : hint_range(0.0, 5.0) = 1.0;
uniform float WindRotationStrength : hint_range(0.0, 1.0) = 0.1;

// Varyings to pass data to fragment shader
varying float color_gradient;
varying vec3 world_original_normal;

// Simple pseudo-random function based on position
float random(vec3 pos) {
    return fract(sin(dot(pos, vec3(12.9898, 78.233, 45.164))) * 43758.5453);
}

// Function to rotate a vector around an axis by an angle
vec3 rotate_around_axis(vec3 v, vec3 axis, float angle) {
    float cos_a = cos(angle);
    float sin_a = sin(angle);
    vec3 axis_normalized = normalize(axis);
    return v * cos_a + cross(axis_normalized, v) * sin_a + axis_normalized * dot(axis_normalized, v) * (1.0 - cos_a);
}

void vertex() {
    // Store the original normal in world space for lighting and Fresnel
    world_original_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
    
    // Compute the color gradient factor based on the original vertex position
    color_gradient = clamp(VERTEX.y * ColorRamp, 0.0, 1.0);

    // Billboarding: Compute camera-facing coordinate system
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 to_camera = normalize(world_pos - camera_pos);
    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(to_camera, up));
    up = normalize(cross(right, to_camera));

    // Compute a per-quad random scale factor
    float scale_factor = mix(MinScale, MaxScale, random(floor(world_pos * 100.0) / 100.0));

    // Compute billboard offset using UVs and apply scale randomization
    vec2 uv_offset = (UV - 0.5) * MeshScale * scale_factor;
    vec3 offset = right * uv_offset.x + up * uv_offset.y;

    // Wind animation (sway)
    float wind_mask = clamp(VERTEX.y * WindHeightScale, 0.0, 1.0);
    float wind_offset = sin(TIME * WindSpeed + (world_pos.x + world_pos.z)) * WindStrength * wind_mask;
    vec3 wind_displacement = WindDirection * wind_offset;

    // Apply wind displacement in world space
    world_pos += wind_displacement;

    // Wind rotation (twist around camera-facing axis)
    float wind_rotation = sin(TIME * WindSpeed * 0.5 + (world_pos.x + world_pos.z)) * WindRotationStrength * wind_mask;
    offset = rotate_around_axis(offset, to_camera, wind_rotation);

    // Apply offset in world space and convert back to object space
    vec3 new_world_pos = world_pos + offset;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(new_world_pos, 1.0)).xyz;

    // Set NORMAL to the billboarded normal for geometry alignment
    NORMAL = (inverse(MODEL_MATRIX) * vec4(-to_camera, 0.0)).xyz;
}

void fragment() {
    // Sample texture for base color and alpha
    vec4 tex = texture(AlbedoAlpha, UV);
    vec3 albedo = tex.rgb; // Use RGB channels for base color
    float alpha = tex.a;   // Use alpha channel for transparency

    // Color gradient from BottomColor to TopColor
    float gradient_factor = clamp(color_gradient, 0.0, 1.0);
    vec3 gradient_color = mix(BottomColor.rgb, TopColor.rgb, gradient_factor);
    // Blend texture color with gradient color based on ColorBlendStrength
    albedo = mix(albedo, albedo * gradient_color, ColorBlendStrength);

    // Fresnel effect using the original normal
    vec3 view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
    float fresnel = pow(1.0 - clamp(dot(normalize(world_original_normal), view_dir), 0.0, 1.0), 3.0);

    // Interpolate between FresnelTopColor and FresnelBottomColor based on the original normal's Y component
    float fresnel_gradient = clamp((world_original_normal.y + 1.0) * 0.5, 0.0, 1.0);
    vec3 fresnel_color = mix(FresnelBottomColor.rgb, FresnelTopColor.rgb, fresnel_gradient);
    float fresnel_factor = fresnel * FresnelStrength;

    // Apply Fresnel effect differently based on normal direction
    if (world_original_normal.y >= 0.0) {
        albedo += FresnelTopColor.rgb * fresnel_factor;
    } else {
        vec3 shadow_color = mix(FresnelBottomColor.rgb, vec3(1.0), 0.2);
        albedo *= mix(vec3(1.0), shadow_color, fresnel * 0.8);
    }

    // Clamp albedo to prevent overexposure
    albedo = clamp(albedo, 0.0, 1.0);

    // Set albedo and alpha for the fragment shader
    ALBEDO = albedo;
    ALPHA = alpha;
}

void light() {
    // Use the original normal in world space for lighting calculations
    vec3 light_dir = normalize(LIGHT);
    vec3 normal = normalize(world_original_normal);

    // Diffuse lighting
    float NdotL = max(dot(normal, light_dir), 0.0);
    DIFFUSE_LIGHT = ALBEDO * LIGHT_COLOR * NdotL * ATTENUATION;

    // Add ambient light to prevent underexposure
    DIFFUSE_LIGHT += ALBEDO * AmbientLight;

    // Specular lighting (Blinn-Phong approximation with custom exponent)
    vec3 view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
    vec3 halfway_dir = normalize(light_dir + view_dir);
    float NdotH = max(dot(normal, halfway_dir), 0.0);
    float spec = pow(NdotH, SpecularExponent);
    SPECULAR_LIGHT = LIGHT_COLOR * spec * ATTENUATION * SPECULAR_AMOUNT * SpecularIntensity;
}