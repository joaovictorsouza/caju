#version 450
// Triângulo do host sem vertex buffer: posições/cores vêm de arrays constantes. Os parâmetros chegam por
// `setBytes(index: 0, stage: .vertex)`, que o backend Vulkan liga no binding 0 (ADR 0024).
layout(set = 0, binding = 0) uniform Params {
    float angle;
    float aspect;  // largura / altura
} params;
layout(location = 0) out vec3 vColor;

void main() {
    // NDC com y para cima (igual ao Metal): o vértice vermelho fica em cima.
    const vec2 positions[3] = vec2[](vec2(0.0, 0.6), vec2(-0.6, -0.5), vec2(0.6, -0.5));
    const vec3 colors[3] = vec3[](vec3(1.0, 0.2, 0.2), vec3(0.2, 1.0, 0.2), vec3(0.2, 0.4, 1.0));
    vec2 p = positions[gl_VertexIndex];
    float c = cos(params.angle);
    float s = sin(params.angle);
    vec2 q = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    q.x /= params.aspect;
    gl_Position = vec4(q, 0.0, 1.0);
    vColor = colors[gl_VertexIndex];
}
