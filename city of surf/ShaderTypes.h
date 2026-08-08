//
//  ShaderTypes.h
//  city of surf
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexFrameUniforms = 2,
    BufferIndexObjectUniforms = 3
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor = 0,
    TextureIndexDepth = 1,
    TextureIndexBloom = 2,
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix;
    simd_float3 lightDirection;
    float time;
    simd_float4 sunColorIntensity;
    simd_float4 skyAmbientColorIntensity;
    simd_float4 fogColorDensity;
    float waveAmplitude;
    float waveLength;
    float waveSpeed;
    float waveSteepness;
    float waveDirX;
    float waveDirZ;
    float rippleAmplitude;
    float rippleLength;
    float scrollZ;
    float exposure;
    simd_float3 cameraPosition;
    float cameraNear;
    /// dirX, dirZ, amplitude, wavelength for Gerstner waves 0..3
    simd_float4 gerstnerDirAmpWave0;
    simd_float4 gerstnerDirAmpWave1;
    simd_float4 gerstnerDirAmpWave2;
    simd_float4 gerstnerDirAmpWave3;
    /// steepness, speed, unused, unused for Gerstner waves 0..3
    simd_float4 gerstnerSteepSpeed0;
    simd_float4 gerstnerSteepSpeed1;
    simd_float4 gerstnerSteepSpeed2;
    simd_float4 gerstnerSteepSpeed3;
    float cameraFar;
    float foamEdgeDepth;
    float bloomThreshold;
    float bloomIntensity;
} FrameUniforms;

typedef struct
{
    matrix_float4x4 modelMatrix;
    simd_float4 color;
    float isWave;
    /// 0 default, 1 road, 2 building, 3 surfer, 4 obstacle, 5 coin
    float materialId;
    float padding1;
    float padding2;
} ObjectUniforms;

#endif /* ShaderTypes_h */
