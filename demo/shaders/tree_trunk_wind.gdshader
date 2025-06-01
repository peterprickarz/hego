shader_type spatial;
render_mode depth_draw_opaque, depth_prepass_alpha;

// Uniforms for PBR textures
uniform sampler2D ColorTexture : source_color, filter_linear_mipmap; // Base color (albedo)
uniform sampler2D NormalTexture : hint_normal, filter_linear_mipmap; // Normal map
uniform sampler2D AOTexture : hint_default_white, filter_linear_mipmap; // Ambient occlusion
uniform sampler2D RoughnessTexture : hint_roughness_r, filter_linear_mipmap; // Roughness (red channel)

// Uniform for tint color
uniform vec4 TintColor : source_color = vec4(1.0, 1.0, 1.0, 0.0); // Default to white with no tint

// Uniforms for wind animation (matching the leaves shader)
uniform vec3 WindDirection : source_color = vec3(1.0, 0.0, 0.0); // Default wind along X-axis
uniform float WindSpeed : hint_range(0.0, 10.0) = 2.0; // Speed of wind animation
uniform float WindStrength : hint_range(0.0, 1.0) = 0.2; // Strength of wind sway
uniform float WindHeightScale : hint_range(0.0, 5.0) = 1.0; // How much height affects sway

void vertex() {
    // Compute world position for wind animation
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

    // Wind animation (sway, synced with leaves)
    float wind_mask = clamp(VERTEX.y * WindHeightScale, 0.0, 1.0); // More sway at the top
    float wind_offset = sin(TIME * WindSpeed + (world_pos.x + world_pos.z)) * WindStrength * wind_mask;
    vec3 wind_displacement = WindDirection * wind_offset;

    // Apply wind displacement in world space
    world_pos += wind_displacement;

    // Convert back to object space
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;
}

void fragment() {
    // Sample PBR textures
    vec4 color_tex = texture(ColorTexture, UV);
    vec3 color = color_tex.rgb;
    vec3 normal = texture(NormalTexture, UV).rgb;
    float ao = texture(AOTexture, UV).r;
    float roughness = texture(RoughnessTexture, UV).r;

    // Mix tint color with albedo texture (using TintColor alpha to control blend)
    color = mix(color, TintColor.rgb, TintColor.a);

    // Set PBR material properties
    ALBEDO = color;
    NORMAL_MAP = normal; // Godot will handle tangent space conversion
    AO = ao;
    ROUGHNESS = roughness;
    AO_LIGHT_AFFECT = 1.0; // Enable AO effect

    // Use color texture's alpha for transparency (if any)
    ALPHA = color_tex.a;
}