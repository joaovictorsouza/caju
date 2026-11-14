#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 55 "demo.slang"
struct uiVertex_Result_0
{
    float4 position_0 [[position]];
    float2 uv_0 [[user(TEXCOORD)]];
    float4 color_0 [[user(COLOR)]];
};


#line 55
struct vertexInput_0
{
    float2 position_1 [[attribute(0)]];
    float2 uv_1 [[attribute(1)]];
    float4 color_1 [[attribute(2)]];
};


#line 48
struct UIUniforms_0
{
    float2 viewportSize_0;
};


#line 65
struct UIVaryings_0
{
    float4 position_2;
    float2 uv_2;
    float4 color_2;
};


#line 65
[[vertex]] uiVertex_Result_0 uiVertex(vertexInput_0 _S1 [[stage_in]], UIUniforms_0 constant* uiUniforms_0 [[buffer(1)]])
{

#line 75
    thread UIVaryings_0 o_0;

    (&o_0)->position_2 = float4(float2(_S1.position_1.x / uiUniforms_0->viewportSize_0.x * 2.0 - 1.0, 1.0 - _S1.position_1.y / uiUniforms_0->viewportSize_0.y * 2.0), 0.0, 1.0);
    (&o_0)->uv_2 = _S1.uv_1;
    (&o_0)->color_2 = _S1.color_1;

#line 79
    thread uiVertex_Result_0 _S2;

#line 79
    (&_S2)->position_0 = o_0.position_2;

#line 79
    (&_S2)->uv_0 = o_0.uv_2;

#line 79
    (&_S2)->color_0 = o_0.color_2;

#line 79
    return _S2;
}

