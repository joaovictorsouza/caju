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
    vec4 shadowParams;    // x = 1 se há sombra, y = bias de profundidade, z = 1 / tamanho do mapa
    mat4 lightViewProjection;
} material;

layout(set = 0, binding = 48) uniform texture2D baseColorTexture;
layout(set = 0, binding = 80) uniform sampler baseColorSampler;
// Mapa de sombra da luz direcional (R-1b): profundidade comparada à mão com PCF 2x2.
layout(set = 0, binding = 49) uniform texture2D shadowMap;
layout(set = 0, binding = 81) uniform sampler shadowSampler;

layout(location = 0) out vec4 outColor;

const float PI = 3.14159265;

// 1 = iluminado, 0 = na sombra. Coordenadas como no Metal: NDC com y para cima, textura com origem em cima.
float shadowFactor(vec3 worldPosition) {
    if (material.shadowParams.x < 0.5) return 1.0;
    vec4 clip = material.lightViewProjection * vec4(worldPosition, 1.0);
    vec3 ndc = clip.xyz / clip.w;
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0) return 1.0;
    float texel = material.shadowParams.z;
    float lit = 0.0;
    for (int i = 0; i < 4; i++) {
        vec2 offset = vec2(float(i & 1) - 0.5, float(i >> 1) - 0.5) * texel;
        float stored = texture(sampler2D(shadowMap, shadowSampler), uv + offset).r;
        lit += (ndc.z - material.shadowParams.y) <= stored ? 1.0 : 0.0;
    }
    return lit * 0.25;
}

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
        color += (diffuse + specular) * material.lightColor.rgb * nl * shadowFactor(vWorldPosition);
    }
    outColor = vec4(color + material.emissive.rgb, base.a);
}
