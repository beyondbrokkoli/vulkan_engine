#version 460

// The same Unified VRAM Arena (Read-Only here)
layout(std430, binding = 0) readonly buffer MegaBuffer {
    float data[];
};

// The same 64-Byte Router Matrix
layout(push_constant) uniform PushConstants {
    uint pos_x_idx;
    uint pos_y_idx;
    uint pos_z_idx;
    uint particle_count;
    float dt;
} pc;

layout(location = 0) out vec4 fragColor;

void main() {
    uint id = gl_VertexIndex;

    // Pull offsets directly from VRAM
    float x = data[pc.pos_x_idx + id];
    float y = data[pc.pos_y_idx + id];
    float z = data[pc.pos_z_idx + id];

    // Hardcoded Camera & Projection
    float aspect = 1280.0 / 720.0;
    float fov = 1.0; // Approx 90 degrees
    float zNear = 0.1;

    // Reverse-Z Projection Math (Z is inverted)
    gl_Position = vec4((x / aspect) * fov, y * fov, zNear / z, z);
    
    // Size of the point on screen (Your device features enabled this!)
    gl_PointSize = 1.5; 

    // Generate a color based on world position
    vec3 color = normalize(abs(vec3(x, y, z - 200.0))) + vec3(0.2);
    fragColor = vec4(color, 1.0); // Pass to Fragment Shader
}
