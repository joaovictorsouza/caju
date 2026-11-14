#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 21 "demo.slang"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 21
struct pixelInput_0
{
    float3 normal_0 [[user(NORMAL)]];
    float2 uv_0 [[user(TEXCOORD)]];
};


#line 21
struct _MatrixStorage_float4x4_ColMajornatural_0
{
    array<float4, int(4)> data_0;
};


#line 21
struct CubeUniforms_natural_0
{
    _MatrixStorage_float4x4_ColMajornatural_0 mvp_0;
    _MatrixStorage_float4x4_ColMajornatural_0 model_0;
    float4 lightDirection_0;
    float4 baseColor_0;
};


#line 1059 "core"
struct KernelContext_0
{
    CubeUniforms_natural_0 constant* cubeUniforms_0;
};


#line 39 "demo.slang"
[[fragment]] pixelOutput_0 cubeFragment(pixelInput_0 _S1 [[stage_in]], float4 position_0 [[position]], CubeUniforms_natural_0 constant* cubeUniforms_1 [[buffer(0)]])
{

#line 39
    thread KernelContext_0 kernelContext_0;

#line 39
    (&kernelContext_0)->cubeUniforms_0 = cubeUniforms_1;


    float _S2 = max(dot(normalize(_S1.normal_0), normalize(- cubeUniforms_1->lightDirection_0.xyz)), 0.0);
    float _S3 = floor(_S1.uv_0.x * 4.0) + floor(_S1.uv_0.y * 4.0);

#line 43
    float checker_0;

#line 43
    if(((((_S3) < 0.0) ? -fmod(-(_S3),abs((2.0))) : fmod((_S3),abs((2.0))))) < 1.0)
    {

#line 43
        checker_0 = 1.0;

#line 43
    }
    else
    {

#line 43
        checker_0 = 0.81999999284744263;

#line 43
    }

#line 43
    pixelOutput_0 _S4 = { float4((&kernelContext_0)->cubeUniforms_0->baseColor_0.xyz * float3(checker_0)  * float3((0.2800000011920929 + 0.72000002861022949 * _S2)) , 1.0) };

    return _S4;
}

