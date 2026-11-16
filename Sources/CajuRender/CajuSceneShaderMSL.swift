/// MSL dos shaders de cena (Metal), equivalente a `Shaders/CajuRender/scene.{vert,frag}`: mesmos uniformes,
/// mesma matemática. Mantido à mão até o pipeline Slang (ADR 0001); qualquer mudança vale para os dois.
///
/// Ligações (contrato do RHI): vértice `buffer(0)` = `FrameUniforms` (`setBytes(index: 0, stage: .vertex)`),
/// vértice `buffer(1)` = instâncias (`setBuffer(index: 1, stage: .vertex)`; `instance_id` inclui a base),
/// fragmento `buffer(0)` = `MaterialUniforms`, `texture(0)`/`sampler(0)` = cor base, `texture(1)`/`sampler(1)` =
/// mapa de sombra. O fluxo de vértices é o
/// `setVertexBuffer(index: 0)`, que o backend Metal põe na posição 30. Skinning (R-1b): segundo fluxo
/// `setVertexBuffer(index: 1)` (juntas e pesos) e paleta em `setBuffer(index: 2, stage: .vertex)`.
enum CajuSceneShaderMSL {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float3 position [[attribute(0)]];
            float3 normal [[attribute(1)]];
            float2 uv [[attribute(2)]];
        };

        struct FrameUniforms {
            float4x4 viewProjection;
        };

        struct Instance {
            float4x4 model;
            float4x4 normalMatrix;
            uint4 skin;
        };

        struct SkinnedVertexIn {
            float3 position [[attribute(0)]];
            float3 normal [[attribute(1)]];
            float2 uv [[attribute(2)]];
            float4 joints [[attribute(3)]];
            float4 weights [[attribute(4)]];
        };

        struct MaterialUniforms {
            float4 baseColor;
            float4 emissive;
            float4 params;
            float4 lightDirection;
            float4 lightColor;
            float4 ambient;
            float4 cameraPosition;
            float4 shadowParams;
            float4x4 lightViewProjection;
        };

        struct VertexOut {
            float4 position [[position]];
            float3 worldPosition;
            float3 normal;
            float2 uv;
        };

        vertex VertexOut caju_scene_vs(
            VertexIn in [[stage_in]], constant FrameUniforms& frame [[buffer(0)]],
            const device Instance* instances [[buffer(1)]], uint instanceID [[instance_id]]
        ) {
            VertexOut out;
            Instance instance = instances[instanceID];
            float4 world = instance.model * float4(in.position, 1.0);
            out.worldPosition = world.xyz;
            out.normal = (instance.normalMatrix * float4(in.normal, 0.0)).xyz;
            out.uv = in.uv;
            out.position = frame.viewProjection * world;
            return out;
        }

        vertex VertexOut caju_scene_skinned_vs(
            SkinnedVertexIn in [[stage_in]], constant FrameUniforms& frame [[buffer(0)]],
            const device Instance* instances [[buffer(1)]], const device float4x4* joints [[buffer(2)]],
            uint instanceID [[instance_id]]
        ) {
            VertexOut out;
            Instance instance = instances[instanceID];
            uint base = instance.skin.x;
            float4x4 skin = in.weights.x * joints[base + uint(in.joints.x)]
                + in.weights.y * joints[base + uint(in.joints.y)]
                + in.weights.z * joints[base + uint(in.joints.z)]
                + in.weights.w * joints[base + uint(in.joints.w)];
            float4 world = instance.model * (skin * float4(in.position, 1.0));
            out.worldPosition = world.xyz;
            out.normal = (instance.normalMatrix * (skin * float4(in.normal, 0.0))).xyz;
            out.uv = in.uv;
            out.position = frame.viewProjection * world;
            return out;
        }

        float caju_shadow_factor(
            constant MaterialUniforms& material, float3 worldPosition, depth2d<float> shadowMap,
            sampler shadowSampler
        ) {
            if (material.shadowParams.x < 0.5) return 1.0;
            float4 clip = material.lightViewProjection * float4(worldPosition, 1.0);
            float3 ndc = clip.xyz / clip.w;
            float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0) return 1.0;
            float texel = material.shadowParams.z;
            float lit = 0.0;
            for (int i = 0; i < 4; i++) {
                float2 offset = float2(float(i & 1) - 0.5, float(i >> 1) - 0.5) * texel;
                float stored = shadowMap.sample(shadowSampler, uv + offset);
                lit += (ndc.z - material.shadowParams.y) <= stored ? 1.0 : 0.0;
            }
            return lit * 0.25;
        }

        fragment float4 caju_scene_fs(
            VertexOut in [[stage_in]], constant MaterialUniforms& material [[buffer(0)]],
            texture2d<float> baseColorTexture [[texture(0)]], sampler baseColorSampler [[sampler(0)]],
            depth2d<float> shadowMap [[texture(1)]], sampler shadowSampler [[sampler(1)]]
        ) {
            const float PI = 3.14159265;
            float4 base = material.baseColor * baseColorTexture.sample(baseColorSampler, in.uv);
            if (material.params.z > 0.0 && base.a < material.params.z) discard_fragment();
            if (material.params.w < 0.5) {
                return float4(base.rgb + material.emissive.rgb, base.a);
            }
            float3 n = normalize(in.normal);
            float3 v = normalize(material.cameraPosition.xyz - in.worldPosition);
            float3 color = material.ambient.rgb * base.rgb;
            if (material.lightDirection.w > 0.5) {
                float3 l = normalize(material.lightDirection.xyz);
                float3 h = normalize(l + v);
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
                float3 f0 = mix(float3(0.04), base.rgb, metallic);
                float3 F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
                float3 specular = D * G * F / max(4.0 * nv * nl, 1e-4);
                float3 diffuse = (1.0 - F) * (1.0 - metallic) * base.rgb / PI;
                color += (diffuse + specular) * material.lightColor.rgb * nl
                    * caju_shadow_factor(material, in.worldPosition, shadowMap, shadowSampler);
            }
            return float4(color + material.emissive.rgb, base.a);
        }
        """
}
