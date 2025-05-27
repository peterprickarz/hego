shader_type spatial;
render_mode cull_disabled, depth_draw_always;

// Uniforms for wind control
uniform float wind_speed = 1.0;
uniform float wind_strength = 0.1;
uniform vec2 wind_direction = vec2(1.0, 0.0);

// Vertex shader
void vertex() {
    // Use COLOR for vertex color
    // Pass it to the fragment shader (already done implicitly)
    
    // Simple wind animation based on vertex position and time
    float wind_offset = sin(TIME * wind_speed + VERTEX.x + VERTEX.z) * wind_strength;
    // Apply wind effect mainly to upper vertices (based on Y position)
    VERTEX.x += wind_offset * VERTEX.y * wind_direction.x;
    VERTEX.z += wind_offset * VERTEX.y * wind_direction.y;
}

// Fragment shader
void fragment() {
    // Use vertex color as albedo
    ALBEDO = COLOR.rgb;
    
    // Basic material properties
    METALLIC = 0.0;
    ROUGHNESS = 0.8;
    SPECULAR = 0.2;
}