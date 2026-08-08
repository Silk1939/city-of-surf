//
//  Shaders.metal
//  city of surf
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 texCoord;
    float foam;
    float materialId;
} VOut;

typedef struct
{
    float4 position [[position]];
} FullscreenOut;

static float distribution_ggx(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float ndoth = saturate(dot(N, H));
    float denominator = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / max(M_PI_F * denominator * denominator, 0.0001);
}

static float geometry_schlick_ggx(float ndot, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return ndot / max(ndot * (1.0 - k) + k, 0.0001);
}

static float geometry_smith(float3 N, float3 V, float3 L, float roughness)
{
    return geometry_schlick_ggx(saturate(dot(N, V)), roughness)
        * geometry_schlick_ggx(saturate(dot(N, L)), roughness);
}

static float3 fresnel_schlick(float cosTheta, float3 f0)
{
    return f0 + (1.0 - f0) * pow(1.0 - saturate(cosTheta), 5.0);
}

static float3 evaluate_pbr(float3 baseColor,
                           float roughness,
                           float metalness,
                           float3 N,
                           float3 V,
                           constant FrameUniforms &frame)
{
    float3 L = normalize(frame.lightDirection);
    float3 H = normalize(V + L);
    float ndotl = saturate(dot(N, L));
    float ndotv = saturate(dot(N, V));

    float3 f0 = mix(float3(0.04), baseColor, metalness);
    float3 F = fresnel_schlick(dot(H, V), f0);
    float D = distribution_ggx(N, H, roughness);
    float G = geometry_smith(N, V, L, roughness);
    float3 specular = (D * G * F) / max(4.0 * ndotv * ndotl, 0.0001);

    float3 diffuseWeight = (1.0 - F) * (1.0 - metalness);
    float3 lambert = diffuseWeight * baseColor / M_PI_F;
    float3 sunRadiance = frame.sunColorIntensity.rgb * frame.sunColorIntensity.a;
    float3 direct = (lambert + specular) * sunRadiance * ndotl;

    float skyFacing = 0.35 + 0.65 * saturate(N.y);
    float3 skyRadiance = frame.skyAmbientColorIntensity.rgb
        * frame.skyAmbientColorIntensity.a;
    float3 ambientDiffuse = baseColor * (1.0 - metalness) * skyRadiance * skyFacing;
    float3 ambientSpecular = F * skyRadiance * (0.2 + 0.3 * skyFacing);
    return direct + ambientDiffuse + ambientSpecular;
}

static float3 apply_exponential_fog(float3 color,
                                    float3 worldPos,
                                    constant FrameUniforms &frame)
{
    float distanceToCamera = length(worldPos - frame.cameraPosition);
    float fog = 1.0 - exp(-frame.fogColorDensity.a * distanceToCamera);
    return mix(color, frame.fogColorDensity.rgb, saturate(fog));
}

static float flood_body(float rz, float faceWidth)
{
    float w = max(faceWidth, 0.5);
    return 0.5 * (1.0 - tanh(rz / (w * 0.35)));
}

static float crest_lip(float rz, float faceWidth)
{
    float sigma = max(faceWidth * 0.18, 1.2);
    return exp(-(rz * rz) / (2.0 * sigma * sigma));
}

// Must match WaveField.swift
static float3 flood_displace(float3 pos, constant FrameUniforms &frame, thread float &foam)
{
    float rz = pos.z + frame.scrollZ;
    float body = flood_body(rz, frame.waveLength);
    float lip = crest_lip(rz, frame.waveLength);
    float a = frame.waveAmplitude;
    float steep = frame.waveSteepness;

    float3 d = float3(0.0);
    d.y = a * (body * 0.82 + lip * steep * 0.55);

    float faceMask = body * (1.0 - body) * 4.0;
    d.z = -(faceMask * a * 0.35 * steep);

    float rk = (2.0 * M_PI_F) / max(frame.rippleLength, 0.001);
    float chop = frame.rippleAmplitude
        * sin(rk * pos.x * 1.3 + rk * rz * 0.7 - frame.time * 4.0)
        * (0.35 + 0.65 * body);
    d.y += chop;
    d.x += frame.rippleAmplitude * 0.15 * cos(rk * pos.x - frame.time * 3.0) * body;

    foam = saturate(lip * 0.85 + faceMask * 0.55);
    return pos + d;
}

static float3 flood_normal(float3 pos, constant FrameUniforms &frame)
{
    float eps = 0.35;
    float foam = 0.0;
    float3 c = flood_displace(pos, frame, foam);
    float3 px = flood_displace(pos + float3(eps, 0, 0), frame, foam);
    float3 pz = flood_displace(pos + float3(0, 0, eps), frame, foam);
    return normalize(cross(pz - c, px - c));
}

vertex VOut solidVertex(Vertex in [[stage_in]],
                        constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                        constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    VOut out;
    float4 world = object.modelMatrix * float4(in.position, 1.0);
    out.worldPos = world.xyz;
    out.position = frame.viewProjectionMatrix * world;
    out.texCoord = in.texCoord;
    out.foam = 0.0;
    out.materialId = object.materialId;

    float3x3 normalMatrix = float3x3(object.modelMatrix[0].xyz,
                                     object.modelMatrix[1].xyz,
                                     object.modelMatrix[2].xyz);
    float3 lp = abs(in.position);
    float3 nLocal = float3(0, 1, 0);
    if (lp.x > lp.y && lp.x > lp.z) nLocal = float3(sign(in.position.x), 0, 0);
    else if (lp.z > lp.y && lp.z > lp.x) nLocal = float3(0, 0, sign(in.position.z));
    else nLocal = float3(0, sign(in.position.y), 0);
    out.normal = normalize(normalMatrix * nLocal);
    return out;
}

fragment float4 solidFragment(VOut in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                              constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 base = object.color.rgb;
    float roughness = 0.58;
    float metalness = 0.0;
    float3 emissive = float3(0.0);

    // Wet asphalt road with subtle lane marks.
    if (object.materialId > 0.5 && object.materialId < 1.5) {
        float lanes = abs(fract(in.worldPos.x / 3.2 + 0.5) - 0.5);
        float dash = step(0.5, fract(in.worldPos.z * 0.12));
        float mark = smoothstep(0.47, 0.5, lanes) * dash;
        base = mix(base, float3(0.85, 0.82, 0.55), mark * 0.55);
        roughness = 0.24;
    }
    // Building facades with window grid.
    else if (object.materialId > 1.5 && object.materialId < 2.5) {
        float facing = saturate(abs(N.x) * 0.85 + abs(N.z) * 0.85);
        float wx = fract(in.worldPos.y * 0.55);
        float wz = fract((abs(N.x) > 0.5 ? in.worldPos.z : in.worldPos.x) * 0.35);
        float window = step(0.18, wx) * step(wx, 0.82) * step(0.2, wz) * step(wz, 0.8);
        float lit = step(0.35, fract(sin(dot(floor(in.worldPos.xyz * float3(0.35, 0.55, 0.35)), float3(12.1, 78.2, 45.3))) * 43758.5));
        float3 glow = float3(1.0, 0.85, 0.45) * window * lit * facing * 0.55;
        base = mix(base, base * 0.22, window * facing);
        roughness = 0.76;
        emissive = glow;
    }
    else if (object.materialId > 2.5 && object.materialId < 3.5) {
        roughness = 0.42;
    }
    else if (object.materialId > 3.5 && object.materialId < 4.5) {
        roughness = 0.32;
        metalness = 0.08;
    }

    float3 litColor = evaluate_pbr(base, roughness, metalness, N, V, frame) + emissive;
    return float4(apply_exponential_fog(litColor, in.worldPos, frame), 1.0);
}

vertex VOut waveVertex(Vertex in [[stage_in]],
                       constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                       constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    VOut out;
    float4 worldBase = object.modelMatrix * float4(in.position, 1.0);
    float foam = 0.0;
    float3 displaced = flood_displace(worldBase.xyz, frame, foam);
    out.worldPos = displaced;
    out.position = frame.viewProjectionMatrix * float4(displaced, 1.0);
    out.normal = flood_normal(worldBase.xyz, frame);
    out.texCoord = in.texCoord;
    out.foam = foam;
    out.materialId = 0.0;
    return out;
}

fragment float4 waveFragment(VOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                             constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float fresnel = pow(1.0 - saturate(dot(N, V)), 3.0);

    float3 deep = float3(0.02, 0.12, 0.22);
    float3 mid = float3(0.05, 0.38, 0.48);
    float3 shallow = float3(0.18, 0.72, 0.78);
    float h = saturate(in.worldPos.y / max(frame.waveAmplitude, 0.001));
    float3 water = mix(deep, mid, smoothstep(0.0, 0.55, h));
    water = mix(water, shallow, smoothstep(0.55, 1.0, h));

    // Whitewater on the single crest lip.
    float3 foamCol = float3(0.92, 0.96, 1.0);
    water = mix(water, foamCol, pow(in.foam, 1.35) * 0.95);
    float roughness = mix(0.12, 0.68, saturate(in.foam));
    float3 litWater = evaluate_pbr(water, roughness, 0.0, N, V, frame);
    litWater += fresnel
        * frame.skyAmbientColorIntensity.rgb
        * frame.skyAmbientColorIntensity.a
        * 0.65;
    return float4(apply_exponential_fog(litWater, in.worldPos, frame), 1.0);
}

vertex FullscreenOut fullscreenVertex(uint vertexID [[vertex_id]])
{
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    FullscreenOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

static float3 aces_filmic(float3 color)
{
    // Mirrored by ArtDirection.acesTonemapped for diagnostics.
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

fragment float4 tonemapFragment(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float, access::read> sceneColor [[texture(TextureIndexColor)]])
{
    uint2 pixel = uint2(in.position.xy);
    float3 hdrColor = max(sceneColor.read(pixel).rgb * frame.exposure, 0.0);
    float3 mapped = aces_filmic(hdrColor);
    float3 gammaCorrected = pow(mapped, float3(1.0 / 2.2));
    return float4(gammaCorrected, 1.0);
}
