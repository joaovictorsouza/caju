#version 450
layout(location = 0) in vec3 vWorldPosition;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec2 vUV;

layout(set = 0, binding = 16) uniform MaterialUniforms {
    vec4 baseColor;
    vec4 emissive;
    vec4 params;          // metálico, rugosidade, corte de alfa, modelo (0 unlit, 1 PBR)
    vec4 lightDirection;  // direção PARA a luz (normalizada); w = 1 se há luz
    vec4 lightColor;      // cor × intensidade
    vec4 ambient;
    vec4 cameraPosition;
} material;

layout(set = 0, binding = 48) uniform texture2D baseColorTexture;
layout(set = 0, binding = 80) uniform sampler baseColorSampler;

layout(location = 0) out vec4 outColor;

const float PI = 3.14159265;

void main() {
    vec4 base = material.baseColor * texture(sampler2D(baseColorTexture, baseColorSampler), vUV);
    if (material.params.z > 0.0 && base.a < material.params.z) discard;
    if (material.params.w < 0.5) {
        outColor = vec4(base.rgb + material.emissive.rgb, base.a);
        return;
    }
    vec3 n = normalize(vNormal);
    vec3 v = normalize(material.cameraPosition.xyz - vWorldPosition);
    vec3 color = material.ambient.rgb * base.rgb;
    if (material.lightDirection.w > 0.5) {
        vec3 l = normalize(material.lightDirection.xyz);
        vec3 h = normalize(l + v);
        float nl = max(dot(n, l), 0.0);
        float nv = max(dot(n, v), 1e-4);
        float nh = max(dot(n, h), 0.0);
        float vh = max(dot(v, h), 0.0);
        float metallic = clamp(material.params.x, 0.0, 1.0);
        float roughness = clamp(material.params.y, 0.04, 1.0);
        float a = roughness * roughness;
        float a2 = a * a;
        float d = nh * nh * (a2 - 1.0) + 1.0;
        float D = a2 / (PI * d * d);
        float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        float G = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
        vec3 f0 = mix(vec3(0.04), base.rgb, metallic);
        vec3 F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        vec3 specular = D * G * F / max(4.0 * nv * nl, 1e-4);
        vec3 diffuse = (1.0 - F) * (1.0 - metallic) * base.rgb / PI;
        color += (diffuse + specular) * material.lightColor.rgb * nl;
    }
    outColor = vec4(color + material.emissive.rgb, base.a);
}
