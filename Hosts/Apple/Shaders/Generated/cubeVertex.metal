#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 14 "demo.slang"
struct cubeVertex_Result_0
{
    float4 position_0 [[position]];
    float3 normal_0 [[user(NORMAL)]];
    float2 uv_0 [[user(TEXCOORD)]];
};


#line 14
struct vertexInput_0
{
    float3 position_1 [[attribute(0)]];
    float3 normal_1 [[attribute(1)]];
    float2 uv_1 [[attribute(2)]];
};


#line 14
struct _MatrixStorage_float4x4_ColMajornatural_0
{
    array<float4, int(4)> data_0;
};


#line 14
struct CubeUniforms_natural_0
{
    _MatrixStorage_float4x4_ColMajornatural_0 mvp_0;
    _MatrixStorage_float4x4_ColMajornatural_0 model_0;
    float4 lightDirection_0;
    float4 baseColor_0;
};


#line 21
struct CubeVaryings_0
{
    float4 position_2;
    float3 normal_2;
    float2 uv_2;
};


#line 21
[[vertex]] cubeVertex_Result_0 cubeVertex(vertexInput_0 _S1 [[stage_in]], CubeUniforms_natural_0 constant* cubeUniforms_0 [[buffer(0)]])
{

#line 31
    thread CubeVaryings_0 o_0;
    (&o_0)->position_2 = (((float4(_S1.position_1, 1.0)) * (matrix<float,int(4),int(4)> (cubeUniforms_0->mvp_0.data_0[int(0)][int(0)], cubeUniforms_0->mvp_0.data_0[int(1)][int(0)], cubeUniforms_0->mvp_0.data_0[int(2)][int(0)], cubeUniforms_0->mvp_0.data_0[int(3)][int(0)], cubeUniforms_0->mvp_0.data_0[int(0)][int(1)], cubeUniforms_0->mvp_0.data_0[int(1)][int(1)], cubeUniforms_0->mvp_0.data_0[int(2)][int(1)], cubeUniforms_0->mvp_0.data_0[int(3)][int(1)], cubeUniforms_0->mvp_0.data_0[int(0)][int(2)], cubeUniforms_0->mvp_0.data_0[int(1)][int(2)], cubeUniforms_0->mvp_0.data_0[int(2)][int(2)], cubeUniforms_0->mvp_0.data_0[int(3)][int(2)], cubeUniforms_0->mvp_0.data_0[int(0)][int(3)], cubeUniforms_0->mvp_0.data_0[int(1)][int(3)], cubeUniforms_0->mvp_0.data_0[int(2)][int(3)], cubeUniforms_0->mvp_0.data_0[int(3)][int(3)]))));

#line 32
    matrix<float,int(4),int(4)>  _S2 = matrix<float,int(4),int(4)> (cubeUniforms_0->model_0.data_0[int(0)][int(0)], cubeUniforms_0->model_0.data_0[int(1)][int(0)], cubeUniforms_0->model_0.data_0[int(2)][int(0)], cubeUniforms_0->model_0.data_0[int(3)][int(0)], cubeUniforms_0->model_0.data_0[int(0)][int(1)], cubeUniforms_0->model_0.data_0[int(1)][int(1)], cubeUniforms_0->model_0.data_0[int(2)][int(1)], cubeUniforms_0->model_0.data_0[int(3)][int(1)], cubeUniforms_0->model_0.data_0[int(0)][int(2)], cubeUniforms_0->model_0.data_0[int(1)][int(2)], cubeUniforms_0->model_0.data_0[int(2)][int(2)], cubeUniforms_0->model_0.data_0[int(3)][int(2)], cubeUniforms_0->model_0.data_0[int(0)][int(3)], cubeUniforms_0->model_0.data_0[int(1)][int(3)], cubeUniforms_0->model_0.data_0[int(2)][int(3)], cubeUniforms_0->model_0.data_0[int(3)][int(3)]);
    (&o_0)->normal_2 = (((_S1.normal_1) * (matrix<float,int(3),int(3)> (_S2[int(0)].xyz, _S2[int(1)].xyz, _S2[int(2)].xyz))));
    (&o_0)->uv_2 = _S1.uv_1;

#line 34
    thread cubeVertex_Result_0 _S3;

#line 34
    (&_S3)->position_0 = o_0.position_2;

#line 34
    (&_S3)->normal_0 = o_0.normal_2;

#line 34
    (&_S3)->uv_0 = o_0.uv_2;

#line 34
    return _S3;
}

