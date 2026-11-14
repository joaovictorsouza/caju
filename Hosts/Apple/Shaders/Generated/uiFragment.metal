#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 90 "core"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 90
struct pixelInput_0
{
    float2 uv_0 [[user(TEXCOORD)]];
    float4 color_0 [[user(COLOR)]];
};


#line 90
struct KernelContext_0
{
    texture2d<float, access::sample> atlas_0;
    sampler atlasSampler_0;
};


#line 84 "demo.slang"
[[fragment]] pixelOutput_0 uiFragment(pixelInput_0 _S1 [[stage_in]], float4 position_0 [[position]], texture2d<float, access::sample> atlas_1 [[texture(0)]], sampler atlasSampler_1 [[sampler(0)]])
{

#line 84
    thread KernelContext_0 kernelContext_0;

#line 84
    (&kernelContext_0)->atlas_0 = atlas_1;

#line 84
    (&kernelContext_0)->atlasSampler_0 = atlasSampler_1;

#line 84
    pixelOutput_0 _S2 = { float4(_S1.color_0.xyz, _S1.color_0.w * ((atlas_1).sample((atlasSampler_1), (_S1.uv_0))).x) };


    return _S2;
}

