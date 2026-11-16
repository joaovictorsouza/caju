#version 450
layout(set = 0, binding = 16) uniform Params { vec4 tint; } params;
layout(set = 0, binding = 17) readonly buffer Data { vec4 values[]; } data;
layout(set = 0, binding = 48) uniform texture2D albedo;
layout(set = 0, binding = 80) uniform sampler albedoSampler;
layout(set = 0, binding = 49) uniform sampler2D combined;
layout(location = 0) out vec4 outColor;
void main() {
    outColor = params.tint * texture(sampler2D(albedo, albedoSampler), vec2(0.5)) + texture(combined, vec2(0.5)) + data.values[0];
}
