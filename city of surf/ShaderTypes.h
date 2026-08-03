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
    BufferIndexObjectUniforms = 3,
    BufferIndexPostFXUniforms = 4
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexAlbedo      = 0,
    TextureIndexNormal      = 1,
    TextureIndexRoughness   = 2,
    TextureIndexShadow      = 3,
    TextureIndexIrradiance  = 4,
    TextureIndexSpecular    = 5,
    TextureIndexBrdfLUT     = 6,
    TextureIndexSky         = 7,
    /// Aliases for post-FX binds (same slots as albedo/normal).
    TextureIndexSceneHDR    = 0,
    TextureIndexBloom       = 1,
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix;
    matrix_float4x4 invViewProjectionMatrix;
    matrix_float4x4 lightViewProjectionMatrix;
    simd_float3 lightDirection;
    float time;
    float waveAmplitude;
    float waveLength;
    float waveSpeed;
    float waveSteepness;
    float waveDirX;
    float waveDirZ;
    float rippleAmplitude;
    float rippleLength;
    float scrollZ;
    float sunIntensity;
    simd_float3 cameraPosition;
    float iblIntensity;
    simd_float3 lightColor;
    float shadowBias;
    float specularMips;
    float _padA;
    float _padB;
    float _padC;
} FrameUniforms;

typedef struct
{
    float bloomThreshold;
    float bloomSoftKnee;
    float bloomIntensity;
    float grainAmount;
    float saturation;
    float vignetteStrength;
    float time;
    float exposure;
    simd_float2 blurDirection;
    simd_float2 texelSize;
} PostFXUniforms;

typedef struct
{
    matrix_float4x4 modelMatrix;
    simd_float4 color;
    float isWave;
    /// 0 default, 1 road/asphalt, 2 concrete (sidewalks), 3 surfer, 4 obstacle, 5 coin, 6 glass facade (buildings)
    float materialId;
    float castsShadow;
    float receivesShadow;
} ObjectUniforms;

#endif /* ShaderTypes_h */
