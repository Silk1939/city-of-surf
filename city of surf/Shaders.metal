//
//  Shaders.metal
//  city of surf
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"
#include "SkyCommon.h"

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
    float4 shadowCoord;
} VOut;

typedef struct
{
    float4 position [[position]];
    float3 worldPos;
} ShadowOut;

typedef struct
{
    float4 position [[position]];
    float2 uv;
} SkyOut;

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

/// Narrower lip used only for foam — geometry crest stays wider.
static float foam_crest_lip(float rz, float faceWidth)
{
    float sigma = max(faceWidth * 0.042, 0.65);
    return exp(-(rz * rz) / (2.0 * sigma * sigma));
}

static float hash21(float2 p)
{
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float valueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float3 flood_displace(float3 pos, constant FrameUniforms &frame, thread float &foam)
{
    float rz = pos.z + frame.scrollZ;
    float body = flood_body(rz, frame.waveLength);
    float lip = crest_lip(rz, frame.waveLength);
    float a = frame.waveAmplitude;
    float steep = frame.waveSteepness;

    float3 d = float3(0.0);
    d.y = a * (body * 0.88 + lip * steep * 0.72);

    float faceMask = body * (1.0 - body) * 4.0;
    d.z = -(faceMask * a * 0.42 * steep);

    float rk = (2.0 * M_PI_F) / max(frame.rippleLength, 0.001);
    float chop = frame.rippleAmplitude
        * sin(rk * pos.x * 1.3 + rk * rz * 0.7 - frame.time * 4.0)
        * (0.35 + 0.65 * body);
    d.y += chop;
    d.x += frame.rippleAmplitude * 0.15 * cos(rk * pos.x - frame.time * 3.0) * body;

    // Foam mask only — chunky hard edge is applied in waveFragment.
    float foamLip = foam_crest_lip(rz, frame.waveLength);
    foam = saturate(foamLip * 1.25 + faceMask * 0.1);
    return pos + d;
}

/// GPU-only Gerstner-like detail (visual). Amplitudes < 0.15 — never mirror into WaveField.
static float3 visual_wave_detail(float3 pos, constant FrameUniforms &frame)
{
    float t = frame.time;
    float3 d = float3(0.0);

    float k1 = 2.15;
    float a1 = 0.09;
    float p1 = pos.x * k1 + pos.z * k1 * 0.55 - t * 3.4;
    float s1 = sin(p1);
    float c1 = cos(p1);
    d.y += a1 * s1;
    d.x += a1 * 0.35 * c1;

    float k2 = 4.7;
    float a2 = 0.05;
    float p2 = pos.x * k2 * 0.65 - pos.z * k2 * 0.85 - t * 5.6;
    float s2 = sin(p2);
    float c2 = cos(p2);
    d.y += a2 * s2;
    d.z += a2 * 0.28 * c2;

    return d;
}

static float3 wave_visual_position(float3 pos, constant FrameUniforms &frame, thread float &foam)
{
    return flood_displace(pos, frame, foam) + visual_wave_detail(pos, frame);
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

static float3 wave_visual_normal(float3 pos, constant FrameUniforms &frame)
{
    float eps = 0.28;
    float foam = 0.0;
    float3 c = wave_visual_position(pos, frame, foam);
    float3 px = wave_visual_position(pos + float3(eps, 0, 0), frame, foam);
    float3 pz = wave_visual_position(pos + float3(0, 0, eps), frame, foam);
    return normalize(cross(pz - c, px - c));
}

static float2 dirToEquirect(float3 dir)
{
    float3 d = normalize(dir);
    float u = atan2(d.z, d.x) / (2.0 * M_PI_F) + 0.5;
    float v = acos(clamp(d.y, -1.0, 1.0)) / M_PI_F;
    return float2(u, v);
}

static float3 sampleEquirect(texture2d<float> tex, sampler s, float3 dir)
{
    return tex.sample(s, dirToEquirect(dir)).rgb;
}

static float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - saturate(cosTheta), 5.0);
}

static float distributionGGX(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    return a2 / max(M_PI_F * denom * denom, 1e-5);
}

static float geometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / max(NdotV * (1.0 - k) + k, 1e-5);
}

static float geometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    return geometrySchlickGGX(max(dot(N, V), 0.0), roughness)
         * geometrySchlickGGX(max(dot(N, L), 0.0), roughness);
}

static float shadowPCF(float4 shadowCoord,
                       depth2d<float> shadowMap,
                       sampler shadowSampler,
                       float constantBias,
                       float3 N,
                       float3 L)
{
    float3 proj = shadowCoord.xyz / max(shadowCoord.w, 1e-5);
    float2 uv = proj.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }
    // Slope-scaled bias: stronger when the receiver faces away from the light.
    float ndotl = saturate(dot(normalize(N), normalize(L)));
    float sinTheta = sqrt(max(1.0 - ndotl * ndotl, 0.0));
    float bias = constantBias * (1.0 + 12.0 * sinTheta);
    float depth = proj.z;
    float shadow = 0.0;
    float2 texel = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float closest = shadowMap.sample(shadowSampler, uv + float2(x, y) * texel);
            shadow += (depth - bias > closest) ? 0.0 : 1.0;
        }
    }
    return shadow / 9.0;
}

/// Push receiver along normal before light-space projection (reduces acne on slopes).
static float4 shadowCoordWithNormalOffset(float3 worldPos,
                                          float3 N,
                                          float3 L,
                                          constant FrameUniforms &frame,
                                          float baseOffset)
{
    float ndotl = saturate(dot(normalize(N), normalize(L)));
    float offset = baseOffset + (1.0 - ndotl) * baseOffset * 2.0;
    float3 biased = worldPos + normalize(N) * offset;
    return frame.lightViewProjectionMatrix * float4(biased, 1.0);
}

static float3 tonemapACES(float3 x)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

/// Warm height+distance fog → horizon orange (#FF7A3C). Never grey.
static float3 applyHorizonFog(float3 hdr, float3 worldPos, float3 cameraPos)
{
    float3 fogColor = float3(1.0, 0.478, 0.235) * 1.15;
    float dist = length(worldPos - cameraPos);
    float distFog = saturate((dist - 28.0) / 110.0);
    float heightFog = saturate(1.0 - worldPos.y / 36.0);
    float fogAmount = saturate(distFog * mix(0.45, 1.0, heightFog));
    return mix(hdr, fogColor, fogAmount);
}

static float softKneeBloomWeight(float brightness, float threshold, float knee)
{
    float soft = brightness - threshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = (soft * soft) / max(4.0 * knee, 1e-4);
    return max(soft, brightness - threshold) / max(brightness, 1e-4);
}

static float2 worldToNdc(float3 worldPos, constant FrameUniforms &frame)
{
    float4 clip = frame.viewProjectionMatrix * float4(worldPos, 1.0);
    return clip.xy / max(clip.w, 1e-5);
}

static float3 applyNormalMap(float3 N, float3 mapSample, float3 worldPos, float2 uv)
{
    float3 mapN = mapSample * 2.0 - 1.0;
    // Cheap tangent frame from derivatives
    float3 dp1 = dfdx(worldPos);
    float3 dp2 = dfdy(worldPos);
    float2 duv1 = dfdx(uv);
    float2 duv2 = dfdy(uv);
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = normalize(dp2perp * duv1.x + dp1perp * duv2.x);
    float3 B = normalize(dp2perp * duv1.y + dp1perp * duv2.y);
    float inv = rsqrt(max(dot(T, T) * dot(B, B), 1e-6));
    return normalize(float3x3(T * inv, B * inv, N) * mapN);
}

static float3 pbrLit(float3 albedo,
                     float roughness,
                     float metallic,
                     float3 N,
                     float3 V,
                     float3 L,
                     float3 lightColor,
                     float lightIntensity,
                     float shadow,
                     float3 irradiance,
                     float3 prefiltered,
                     float2 brdf,
                     float iblIntensity)
{
    float3 H = normalize(V + L);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.0);
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    float D = distributionGGX(N, H, roughness);
    float G = geometrySmith(N, V, L, roughness);
    float3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 1e-4);
    float3 kS = F;
    float3 kD = (1.0 - kS) * (1.0 - metallic);
    float3 direct = (kD * albedo / M_PI_F + spec) * lightColor * lightIntensity * NdotL * shadow;

    float3 Famb = fresnelSchlick(NdotV, F0);
    float3 diffuseIBL = irradiance * albedo * (1.0 - metallic);
    float3 specularIBL = prefiltered * (Famb * brdf.x + brdf.y);
    float3 ambient = (diffuseIBL * (1.0 - Famb) + specularIBL) * iblIntensity;
    return direct + ambient;
}

vertex ShadowOut shadowVertex(Vertex in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                              constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    ShadowOut out;
    float4 world = object.modelMatrix * float4(in.position, 1.0);
    if (object.isWave > 0.5) {
        float foam = 0.0;
        world.xyz = flood_displace(world.xyz, frame, foam);
    }
    out.worldPos = world.xyz;
    out.position = frame.lightViewProjectionMatrix * world;
    return out;
}

fragment void shadowFragment(ShadowOut in [[stage_in]])
{
}

vertex SkyOut skyVertex(uint vid [[vertex_id]])
{
    // Fullscreen triangle — depth at far plane so solid/wave win the depth test.
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyOut out;
    out.position = float4(positions[vid], 1.0, 1.0);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 skyFragment(SkyOut in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                            texture2d<float> sky [[texture(TextureIndexSky)]])
{
    // View rays via invViewProjection (Metal NDC z 0=near, 1=far).
    float2 ndc = in.uv * 2.0 - 1.0;
    float4 nearP = frame.invViewProjectionMatrix * float4(ndc, 0.0, 1.0);
    float4 farP  = frame.invViewProjectionMatrix * float4(ndc, 1.0, 1.0);
    float3 nearW = nearP.xyz / max(nearP.w, 1e-5);
    float3 farW  = farP.xyz / max(farP.w, 1e-5);
    float3 dir = normalize(farW - nearW);
    float3 col = evaluateProceduralSky(dir, frame.lightDirection, frame.lightColor, frame.sunIntensity);
    return float4(col, 1.0);
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
    out.shadowCoord = shadowCoordWithNormalOffset(
        world.xyz, out.normal, frame.lightDirection, frame, 0.06);
    return out;
}

fragment float4 solidFragment(VOut in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                              constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]],
                              texture2d<float> albedoMap [[texture(TextureIndexAlbedo)]],
                              texture2d<float> normalMap [[texture(TextureIndexNormal)]],
                              texture2d<float> roughnessMap [[texture(TextureIndexRoughness)]],
                              depth2d<float> shadowMap [[texture(TextureIndexShadow)]],
                              texture2d<float> irradianceMap [[texture(TextureIndexIrradiance)]],
                              texture2d_array<float> specularMap [[texture(TextureIndexSpecular)]],
                              texture2d<float> brdfLUT [[texture(TextureIndexBrdfLUT)]])
{
    constexpr sampler matSampler(address::repeat, filter::linear, mip_filter::linear);
    constexpr sampler iblSampler(s_address::repeat, t_address::clamp_to_edge, filter::linear);
    constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 L = normalize(frame.lightDirection);

    float2 uv = in.worldPos.xz * 0.08;
    if (abs(N.y) < 0.55) {
        uv = (abs(N.x) > abs(N.z)) ? in.worldPos.zy * 0.08 : in.worldPos.xy * 0.08;
    }

    float3 albedo = object.color.rgb;
    float roughness = 0.65;
    float metallic = 0.0;

    bool usePBR = (object.materialId > 0.5 && object.materialId < 2.5) || object.materialId > 5.5;
    if (usePBR) {
        albedo = albedoMap.sample(matSampler, uv).rgb * object.color.rgb;
        float3 nSample = normalMap.sample(matSampler, uv).rgb;
        N = applyNormalMap(N, nSample, in.worldPos, uv);
        roughness = roughnessMap.sample(matSampler, uv).r;
    }

    // Road wetness + sunset glitter path down the street center
    if (object.materialId > 0.5 && object.materialId < 1.5) {
        float center = 1.0 - smoothstep(0.08, 0.22, abs(in.worldPos.x));
        float dash = step(0.45, fract(in.worldPos.z * 0.1));
        albedo = mix(albedo, float3(0.95, 0.9, 0.55), center * dash * 0.35);
        roughness = clamp(roughness * 0.45, 0.06, 0.55);
        metallic = 0.08;
        // Warm wet reflection strip toward the sun
        float glitter = pow(saturate(dot(normalize(float3(0.0, 0.15, 1.0)), L)), 8.0) * center;
        albedo += frame.lightColor * glitter * 0.55;
    }

    // Glass/facade buildings (materialId 6): warm stylized facades + HDR window glow
    float windowEmit = 0.0;
    if (object.materialId > 5.5 && object.materialId < 6.5) {
        // Prefer art-directed tint over gray PBR albedo.
        albedo = mix(albedo, object.color.rgb, 0.82);
        roughness = clamp(roughness * 0.7, 0.12, 0.55);
        metallic = 0.08;
        float sunFacing = saturate(dot(N, L));
        // Lit sides get warm sunset wash (# sunSideWarm).
        albedo = mix(albedo, albedo * float3(1.15, 0.85, 0.55), sunFacing * 0.55);
        float facing = saturate(abs(N.x) * 0.9 + abs(N.z) * 0.9);
        float wx = fract(in.worldPos.y * 0.55);
        float wz = fract((abs(N.x) > 0.5 ? in.worldPos.z : in.worldPos.x) * 0.38);
        float window = step(0.16, wx) * step(wx, 0.84) * step(0.18, wz) * step(wz, 0.82) * facing;
        float lit = step(0.55, fract(sin(dot(floor(in.worldPos.xyz * float3(0.35, 0.55, 0.35)), float3(12.1, 78.2, 45.3))) * 43758.5));
        albedo = mix(albedo, albedo * 0.12, window * 0.9);
        windowEmit = lit * window;
    }

    // Sidewalks / concrete slabs — no building window grid.
    if (object.materialId > 1.5 && object.materialId < 2.5) {
        albedo = mix(albedo, object.color.rgb, 0.35);
        roughness = clamp(roughness * 0.9, 0.35, 0.85);
        metallic = 0.0;
    }

    // Coins — hot gold emissive disks
    if (object.materialId > 4.5 && object.materialId < 5.5) {
        albedo = object.color.rgb;
        roughness = 0.12;
        metallic = 0.95;
    } else if (object.materialId > 2.5 && object.materialId < 3.5) {
        // Surfer / board / neon — stylized, not gray PBR
        albedo = object.color.rgb;
        roughness = 0.28;
        metallic = 0.2;
    } else if (object.materialId > 3.5 && object.materialId < 4.5) {
        roughness = 0.45;
        metallic = 0.2;
        albedo = mix(albedo, object.color.rgb, 0.85);
    }

    float shadow = 1.0;
    if (object.receivesShadow > 0.5) {
        shadow = shadowPCF(in.shadowCoord, shadowMap, shadowSampler, frame.shadowBias, N, L);
        shadow = mix(0.6, 1.0, shadow);
    }

    float3 irradiance = sampleEquirect(irradianceMap, iblSampler, N);
    // Warm stylized IBL — bias cool HDRI toward sunset horizon.
    float3 warmBias = float3(1.0, 0.55, 0.22);
    irradiance = mix(irradiance, irradiance * warmBias * 1.4, 0.55);
    float3 R = reflect(-V, N);
    float mip = roughness * max(frame.specularMips - 1.0, 1.0);
    uint layer0 = uint(floor(mip));
    uint layer1 = min(layer0 + 1, uint(max(frame.specularMips - 1.0, 0.0)));
    float mipF = fract(mip);
    float3 spec0 = specularMap.sample(iblSampler, dirToEquirect(R), layer0).rgb;
    float3 spec1 = specularMap.sample(iblSampler, dirToEquirect(R), layer1).rgb;
    float3 prefiltered = mix(spec0, spec1, mipF);
    prefiltered = mix(prefiltered, prefiltered * warmBias * 1.5, 0.4);
    float2 brdf = brdfLUT.sample(iblSampler, float2(max(dot(N, V), 0.0), roughness)).rg;

    float3 color = pbrLit(albedo, clamp(roughness, 0.04, 1.0), metallic, N, V, L,
                          frame.lightColor, frame.sunIntensity, shadow,
                          irradiance, prefiltered, brdf, frame.iblIntensity);

    // HDR emissives (2–6 range) — bloom food after tonemap moves to composite.
    if (windowEmit > 0.0) {
        color += float3(1.0, 0.78, 0.35) * windowEmit * 4.0;
    }
    // Warm sunset rim on building edges (flat front-above sun).
    if (object.materialId > 5.5 && object.materialId < 6.5) {
        float rim = pow(1.0 - saturate(dot(N, V)), 2.4);
        float sunGlancing = saturate(1.0 - abs(dot(N, L)));
        color += frame.lightColor * rim * sunGlancing * frame.sunIntensity * 0.12;
    }
    if (object.materialId > 2.5 && object.materialId < 3.5) {
        float rim = pow(1.0 - saturate(dot(N, V)), 2.0);
        float3 rimCol = mix(float3(0.220, 0.898, 1.0), object.color.rgb, 0.45); // neon cyan
        color += rimCol * rim * 3.5;
        color += object.color.rgb * 2.2;
    }
    if (object.materialId > 4.5 && object.materialId < 5.5) {
        float pulse = 0.55 + 0.45 * sin(frame.time * 7.0 + in.worldPos.x * 2.0);
        color += object.color.rgb * pulse * 4.0;
        float rim = pow(1.0 - saturate(dot(N, V)), 1.4);
        color += float3(1.0, 0.92, 0.35) * rim * 3.0;
        float glint = pow(saturate(dot(N, normalize(L + V))), 64.0);
        color += float3(1.0, 0.95, 0.6) * glint * 5.5;
    }
    // Traffic-light / hazard / billboard neon (magenta/cyan sparingly)
    if (object.materialId > 3.5 && object.materialId < 4.5) {
        float chroma = max(object.color.r, max(object.color.g, object.color.b))
                     - min(object.color.r, min(object.color.g, object.color.b));
        if (chroma > 0.35) {
            float pulse = 0.7 + 0.3 * sin(frame.time * 8.0);
            color += object.color.rgb * pulse * 3.5;
        }
    }

    return float4(applyHorizonFog(color, in.worldPos, frame.cameraPosition), 1.0);
}

vertex VOut waveVertex(Vertex in [[stage_in]],
                       constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                       constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    VOut out;
    float4 worldBase = object.modelMatrix * float4(in.position, 1.0);
    float foam = 0.0;
    // Gameplay flood shape + GPU-only detail octaves (not in WaveField).
    float3 displaced = wave_visual_position(worldBase.xyz, frame, foam);
    out.worldPos = displaced;
    out.position = frame.viewProjectionMatrix * float4(displaced, 1.0);
    out.normal = wave_visual_normal(worldBase.xyz, frame);
    out.texCoord = in.texCoord;
    out.foam = foam;
    out.materialId = 0.0;
    out.shadowCoord = shadowCoordWithNormalOffset(
        displaced, out.normal, frame.lightDirection, frame, 0.18);
    return out;
}

fragment float4 waveFragment(VOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                             constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]],
                             depth2d<float> shadowMap [[texture(TextureIndexShadow)]],
                             texture2d<float> irradianceMap [[texture(TextureIndexIrradiance)]],
                             texture2d_array<float> specularMap [[texture(TextureIndexSpecular)]],
                             texture2d<float> brdfLUT [[texture(TextureIndexBrdfLUT)]],
                             texture2d<float> sky [[texture(TextureIndexSky)]])
{
    constexpr sampler iblSampler(s_address::repeat, t_address::clamp_to_edge, filter::linear);

    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 L = normalize(frame.lightDirection);
    float NdotV = saturate(dot(N, V));
    float fresnel = pow(1.0 - NdotV, 2.6);

    // Body: deep teal when looking steep, shallow turquoise toward lip.
    float3 deep = float3(0.039, 0.227, 0.290);      // #0A3A4A
    float3 mid = float3(0.090, 0.500, 0.520);
    float3 shallow = float3(0.180, 0.769, 0.714);   // #2EC4B6
    float h = saturate(in.worldPos.y / max(frame.waveAmplitude, 0.001));
    float3 water = mix(deep, mid, smoothstep(0.0, 0.4, h));
    water = mix(water, shallow, smoothstep(0.4, 0.95, h));
    // Grazing = orange sky reflection dominates; steep = deep teal body.
    water = mix(water, deep * 1.05, NdotV);

    float edge = saturate((abs(in.worldPos.x) - 4.5) / 6.5);
    float edgeShade = mix(1.0, 0.78, edge * edge);
    water *= edgeShade;

    // Analytic sky fresnel (shared SkyCommon) — flat look = orange, steep = teal body above.
    float3 R = reflect(-V, N);
    float3 skyCol = evaluateProceduralSky(R, frame.lightDirection, frame.lightColor, frame.sunIntensity);
    water = mix(water, skyCol, fresnel * 0.85);

    // Money-shot sun glitter: narrow HDR streak, noise breakup.
    float3 H = normalize(L + V);
    float street = 1.0 - smoothstep(0.35, 2.8, abs(in.worldPos.x));
    float glitterCore = pow(saturate(dot(N, H)), 160.0) * street;
    glitterCore += pow(saturate(dot(N, L)), 48.0) * street * 0.25;
    float sparkle = valueNoise(in.worldPos.xz * 2.4 + float2(frame.time * 4.2, -frame.time * 1.8));
    float sparkle2 = valueNoise(in.worldPos.xz * 5.5 + float2(-frame.time * 3.1, frame.time * 2.4));
    float glitterMask = smoothstep(0.55, 0.78, sparkle * 0.6 + sparkle2 * 0.4);
    float glitter = glitterCore * mix(0.15, 1.0, glitterMask);
    water += frame.lightColor * glitter * 8.0;

    // Crest lip + SSS: sun through the lip → glowing turquoise.
    float rz = in.worldPos.z + frame.scrollZ;
    float lip = crest_lip(rz, frame.waveLength);
    float throughLip = saturate(dot(V, -L));
    float sss = pow(throughLip, 2.0) * lip;
    water += float3(0.180, 0.769, 0.714) * 2.5 * sss;

    // Chunky foam: vertex mask × 2-octave hard noise clusters (#FFF6E9).
    float2 foamUV = in.worldPos.xz * 0.42 + float2(frame.time * 0.15, -frame.time * 0.55);
    float n0 = valueNoise(foamUV);
    float n1 = valueNoise(foamUV * 2.3 + float2(17.1, 9.3));
    float chunk = n0 * 0.55 + n1 * 0.45;
    float foamCluster = smoothstep(0.48, 0.55, chunk); // hard stylized edge
    float foamAmt = step(0.22, in.foam) * foamCluster;

    // Thin foam lines riding the crest, scrolling backward with time.
    float lineRz = rz - frame.time * 3.2 + sin(in.worldPos.x * 1.7) * 0.45;
    float crestLine = foam_crest_lip(lineRz, frame.waveLength);
    float lineNoise = step(0.5, valueNoise(float2(in.worldPos.x * 1.2, frame.time * 0.8)));
    float foamLines = step(0.62, crestLine) * lineNoise;

    float3 foamCol = float3(1.0, 0.965, 0.914);
    water = mix(water, foamCol, saturate(foamAmt + foamLines * 0.85));

    float3 irr = sampleEquirect(irradianceMap, iblSampler, N);
    irr = mix(irr, irr * kSkyHorizon * 1.3, 0.5);
    water += irr * 0.035 * frame.iblIntensity;

    float spec = pow(saturate(dot(N, H)), 56.0) * (0.25 + 0.75 * fresnel);
    water += spec * frame.lightColor * frame.sunIntensity * 0.35 * edgeShade;

    return float4(applyHorizonFog(water, in.worldPos, frame.cameraPosition), 1.0);
}

// MARK: - Post-FX (fullscreen triangle → bloom + composite)

typedef struct
{
    float4 position [[position]];
    float2 uv;
} PostOut;

vertex PostOut postVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    PostOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 bloomExtractFragment(PostOut in [[stage_in]],
                                     constant PostFXUniforms &fx [[buffer(BufferIndexPostFXUniforms)]],
                                     texture2d<float> scene [[texture(TextureIndexSceneHDR)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 c = scene.sample(s, in.uv).rgb;
    float brightness = max(c.r, max(c.g, c.b));
    float w = softKneeBloomWeight(brightness, fx.bloomThreshold, fx.bloomSoftKnee);
    return float4(c * w, 1.0);
}

fragment float4 bloomBlurFragment(PostOut in [[stage_in]],
                                  constant PostFXUniforms &fx [[buffer(BufferIndexPostFXUniforms)]],
                                  texture2d<float> src [[texture(TextureIndexBloom)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // 9-tap separable Gaussian.
    float weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float2 step = fx.blurDirection * fx.texelSize;
    float3 c = src.sample(s, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        float2 d = step * float(i);
        c += src.sample(s, in.uv + d).rgb * weights[i];
        c += src.sample(s, in.uv - d).rgb * weights[i];
    }
    return float4(c, 1.0);
}

fragment float4 bloomDownsampleFragment(PostOut in [[stage_in]],
                                        texture2d<float> src [[texture(TextureIndexBloom)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // 4-tap box downsample.
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(s, in.uv + float2(-0.5, -0.5) * texel).rgb;
    c += src.sample(s, in.uv + float2( 0.5, -0.5) * texel).rgb;
    c += src.sample(s, in.uv + float2(-0.5,  0.5) * texel).rgb;
    c += src.sample(s, in.uv + float2( 0.5,  0.5) * texel).rgb;
    return float4(c * 0.25, 1.0);
}

fragment float4 bloomUpsampleFragment(PostOut in [[stage_in]],
                                      texture2d<float> low [[texture(TextureIndexBloom)]],
                                      texture2d<float> high [[texture(TextureIndexSceneHDR)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 a = high.sample(s, in.uv).rgb;
    float3 b = low.sample(s, in.uv).rgb;
    return float4(a + b, 1.0);
}

fragment float4 postCopyFragment(PostOut in [[stage_in]],
                                 texture2d<float> src [[texture(TextureIndexBloom)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(src.sample(s, in.uv).rgb, 1.0);
}

fragment float4 compositeFragment(PostOut in [[stage_in]],
                                  constant PostFXUniforms &fx [[buffer(BufferIndexPostFXUniforms)]],
                                  texture2d<float> scene [[texture(TextureIndexSceneHDR)]],
                                  texture2d<float> bloom [[texture(TextureIndexBloom)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 hdr = scene.sample(s, in.uv).rgb * fx.exposure;
    hdr += bloom.sample(s, in.uv).rgb * fx.bloomIntensity;
    // Guard non-resident / bad samples (NaN/Inf → green/white garbage on device).
    hdr = select(hdr, float3(0.0), isnan(hdr) || isinf(hdr));
    hdr = clamp(hdr, float3(0.0), float3(24.0));

    // ACES filmic → saturation punch (~1.1) → subtle vignette (max ~15% corners).
    float3 mapped = tonemapACES(hdr);
    float luma = dot(mapped, float3(0.2126, 0.7152, 0.0722));
    mapped = mix(float3(luma), mapped, fx.saturation);

    float2 ndc = in.uv * 2.0 - 1.0;
    float r2 = dot(ndc, ndc);
    float vig = saturate(1.0 - r2 * 0.55);
    mapped *= mix(1.0 - fx.vignetteStrength, 1.0, vig);

    float grain = (hash21(in.uv * float2(scene.get_width(), scene.get_height()) + fx.time * 37.0) - 0.5)
                * fx.grainAmount;
    mapped += grain;

    return float4(saturate(mapped), 1.0);
}
