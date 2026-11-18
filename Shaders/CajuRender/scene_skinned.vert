#version 450
// Variante com skinning (R-1b) do shader de cena. Fonte do SPIR-V embutido em Sources/CajuRender/CajuSceneShaderSPIRV.swift
// (scripts/compile-scene-shaders.sh); a versão Metal é o MSL equivalente em CajuSceneShaderMSL.swift.
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
// Segundo fluxo (R-1b): índices de junta (como float) e pesos.
layout(location = 3) in vec4 inJoints;
layout(location = 4) in vec4 inWeights;

layout(set = 0, binding = 0) uniform FrameUniforms {
    mat4 viewProjection;
} frame;

// Instancing (R-1b): uma entrada por instância no buffer do quadro; `gl_InstanceIndex` já inclui o
// `firstInstance` do draw.
struct Instance {
    mat4 model;
    mat4 normalMatrix;
    uvec4 skin;  // x = início da paleta de juntas no buffer do quadro (só malhas com skinning)
};
layout(std430, set = 0, binding = 1) readonly buffer Instances {
    Instance instances[];
};

// Paleta do quadro: pose em espaço do modelo × inverseBind, já multiplicada pelo render (ADR 0023/0027).
layout(std430, set = 0, binding = 2) readonly buffer Palette {
    mat4 joints[];
};

layout(location = 0) out vec3 vWorldPosition;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec2 vUV;

void main() {
    Instance instance = instances[gl_InstanceIndex];
    uint base = instance.skin.x;
    mat4 skin = inWeights.x * joints[base + uint(inJoints.x)] + inWeights.y * joints[base + uint(inJoints.y)]
        + inWeights.z * joints[base + uint(inJoints.z)] + inWeights.w * joints[base + uint(inJoints.w)];
    vec4 world = instance.model * (skin * vec4(inPosition, 1.0));
    vWorldPosition = world.xyz;
    vNormal = (instance.normalMatrix * (skin * vec4(inNormal, 0.0))).xyz;
    vUV = inUV;
    gl_Position = frame.viewProjection * world;
}
