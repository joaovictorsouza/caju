#version 450
// Triângulo de conformidade do RHI (CajuRHIConformance): NDC com y para cima, sentido anti-horário,
// sem atributos de vértice. O backend inverte o viewport para casar com o Metal.
void main() {
    const vec2 positions[3] = vec2[](vec2(-0.6, -0.6), vec2(0.6, -0.6), vec2(0.0, 0.7));
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
