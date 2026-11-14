// Shaders da demo do host Apple (M2): cubo iluminado e UI simples (retângulo + texto de atlas).
// Compilados offline para MSL (scripts/compile-shaders.sh); sem compilador de shader em runtime (ADR 0001).

struct CubeUniforms
{
    float4x4 mvp;
    float4x4 model;
    float4 lightDirection;
    float4 baseColor;
};

ConstantBuffer<CubeUniforms> cubeUniforms;

struct CubeVertex
{
    float3 position : POSITION;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
};

struct CubeVaryings
{
    float4 position : SV_Position;
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
CubeVaryings cubeVertex(CubeVertex v)
{
    CubeVaryings o;
    o.position = mul(cubeUniforms.mvp, float4(v.position, 1.0));
    o.normal = mul((float3x3)cubeUniforms.model, v.normal);
    o.uv = v.uv;
    return o;
}

[shader("fragment")]
float4 cubeFragment(CubeVaryings i)
{
    float3 n = normalize(i.normal);
    float diffuse = max(dot(n, normalize(-cubeUniforms.lightDirection.xyz)), 0.0);
    float checker = (fmod(floor(i.uv.x * 4.0) + floor(i.uv.y * 4.0), 2.0) < 1.0) ? 1.0 : 0.82;
    float3 color = cubeUniforms.baseColor.rgb * checker * (0.28 + 0.72 * diffuse);
    return float4(color, 1.0);
}

struct UIUniforms
{
    float2 viewportSize;
};

ConstantBuffer<UIUniforms> uiUniforms;

struct UIVertex
{
    float2 position : POSITION;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

Texture2D atlas;
SamplerState atlasSampler;

struct UIVaryings
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

[shader("vertex")]
UIVaryings uiVertex(UIVertex v)
{
    UIVaryings o;
    float2 ndc = float2(v.position.x / uiUniforms.viewportSize.x * 2.0 - 1.0, 1.0 - v.position.y / uiUniforms.viewportSize.y * 2.0);
    o.position = float4(ndc, 0.0, 1.0);
    o.uv = v.uv;
    o.color = v.color;
    return o;
}

[shader("fragment")]
float4 uiFragment(UIVaryings i)
{
    float coverage = atlas.Sample(atlasSampler, i.uv).r;
    return float4(i.color.rgb, i.color.a * coverage);
}
