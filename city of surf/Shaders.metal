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
    float3 L = normalize(frame.lightDirection);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float ndotl = saturate(dot(N, L));
    float3 base = object.color.rgb;

    // Wet asphalt road with subtle lane marks.
    if (object.materialId > 0.5 && object.materialId < 1.5) {
        float lanes = abs(fract(in.worldPos.x / 3.2 + 0.5) - 0.5);
        float dash = step(0.5, fract(in.worldPos.z * 0.12));
        float mark = smoothstep(0.47, 0.5, lanes) * dash;
        base = mix(base, float3(0.85, 0.82, 0.55), mark * 0.55);
        base *= 0.75 + 0.25 * ndotl;
        float wet = pow(1.0 - saturate(dot(N, V)), 3.0);
        base += wet * float3(0.08, 0.1, 0.12);
    }
    // Building facades with window grid.
    else if (object.materialId > 1.5 && object.materialId < 2.5) {
        float facing = saturate(abs(N.x) * 0.85 + abs(N.z) * 0.85);
        float wx = fract(in.worldPos.y * 0.55);
        float wz = fract((abs(N.x) > 0.5 ? in.worldPos.z : in.worldPos.x) * 0.35);
        float window = step(0.18, wx) * step(wx, 0.82) * step(0.2, wz) * step(wz, 0.8);
        float lit = step(0.35, fract(sin(dot(floor(in.worldPos.xyz * float3(0.35, 0.55, 0.35)), float3(12.1, 78.2, 45.3))) * 43758.5));
        float3 glow = float3(1.0, 0.85, 0.45) * window * lit * facing * 0.55;
        base = mix(base * (0.35 + 0.65 * ndotl), base * 0.25, window * facing);
        base += glow;
        float rim = pow(1.0 - saturate(dot(N, V)), 2.5);
        base += rim * float3(0.15, 0.18, 0.25) * facing;
    }
    else {
        float3 H = normalize(L + V);
        float spec = pow(saturate(dot(N, H)), 48.0);
        base = base * (0.3 + 0.7 * ndotl) + spec * 0.25;
    }

    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 40.0) / 130.0);
    float3 fogCol = float3(0.35, 0.42, 0.55);
    base = mix(base, fogCol, fog);
    return float4(base, 1.0);
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
    float3 L = normalize(frame.lightDirection);
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
    water += fresnel * float3(0.45, 0.55, 0.65);

    float ndotl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 96.0) * (0.35 + 0.65 * fresnel);
    water = water * (0.4 + 0.6 * ndotl) + spec * float3(0.9, 0.95, 1.0);

    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 35.0) / 120.0);
    water = mix(water, float3(0.35, 0.42, 0.55), fog);
    return float4(water, 1.0);
}
