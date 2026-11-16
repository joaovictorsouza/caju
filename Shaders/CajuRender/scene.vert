#version 450
// Shader de cena da R-1a (unlit e PBR simples). Fonte do SPIR-V embutido em Sources/CajuRender/CajuSceneShaderSPIRV.swift
// (scripts/compile-scene-shaders.sh); a versão Metal é o MSL equivalente em CajuSceneShaderMSL.swift.
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;

layout(set = 0, binding = 0) uniform ObjectUniforms {
    mat4 viewProjection;
    mat4 model;
    mat4 normalMatrix;
} object;

layout(location = 0) out vec3 vWorldPosition;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec2 vUV;

void main() {
    vec4 world = object.model * vec4(inPosition, 1.0);
    vWorldPosition = world.xyz;
    vNormal = (object.normalMatrix * vec4(inNormal, 0.0)).xyz;
    vUV = inUV;
    gl_Position = object.viewProjection * world;
}
