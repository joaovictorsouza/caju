/// MSL dos shaders de cena (Metal), equivalente a `Shaders/CajuRender/scene.{vert,frag}`: mesmos uniformes,
/// mesma matemática. Mantido à mão até o pipeline Slang (ADR 0001); qualquer mudança vale para os dois.
///
/// Ligações (contrato do RHI): vértice `buffer(0)` = `ObjectUniforms` (`setBytes(index: 0, stage: .vertex)`),
/// fragmento `buffer(0)` = `MaterialUniforms`, `texture(0)`/`sampler(0)` = cor base. O fluxo de vértices é o
/// `setVertexBuffer(index: 0)`, que o backend Metal põe na posição 30.
enum CajuSceneShaderMSL {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float3 position [[attribute(0)]];
            float3 normal [[attribute(1)]];
            float2 uv [[attribute(2)]];
        };

        struct ObjectUniforms {
            float4x4 viewProjection;
            float4x4 model;
            float4x4 normalMatrix;
        };

        struct MaterialUniforms {
            float4 baseColor;
            float4 emissive;
            float4 params;
            float4 lightDirection;
            float4 lightColor;
            float4 ambient;
            float4 cameraPosition;
        };

        struct VertexOut {
            float4 position [[position]];
            float3 worldPosition;
            float3 normal;
            float2 uv;
        };

        vertex VertexOut caju_scene_vs(VertexIn in [[stage_in]], constant ObjectUniforms& object [[buffer(0)]]) {
            VertexOut out;
            float4 world = object.model * float4(in.position, 1.0);
            out.worldPosition = world.xyz;
            out.normal = (object.normalMatrix * float4(in.normal, 0.0)).xyz;
            out.uv = in.uv;
            out.position = object.viewProjection * world;
            return out;
        }

        fragment float4 caju_scene_fs(
            VertexOut in [[stage_in]], constant MaterialUniforms& material [[buffer(0)]],
            texture2d<float> baseColorTexture [[texture(0)]], sampler baseColorSampler [[sampler(0)]]
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
                color += (diffuse + specular) * material.lightColor.rgb * nl;
            }
            return float4(color + material.emissive.rgb, base.a);
        }
        """
}
