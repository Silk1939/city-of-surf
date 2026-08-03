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

    // Foam: almost only a thin crest line; tiny face bleed + chunky stylized noise.
    float foamLip = foam_crest_lip(rz, frame.waveLength);
    float n0 = valueNoise(pos.xz * 0.35 + float2(frame.time * 0.55, frame.time * 0.25));
    float n1 = valueNoise(pos.xz * 0.9 + float2(-frame.time * 0.7, frame.time * 0.4));
    float chunk = step(0.42, n0 * 0.55 + n1 * 0.45);
    foam = saturate(foamLip * 1.2 + faceMask * 0.08) * mix(0.15, 1.0, chunk);
    foam = step(0.28, foam); // hard stylized foam edge
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

/// Warm distance fog in linear HDR (tonemap/grade happen in compositeFragment).
static float3 applyWarmFog(float3 hdr, float fogAmount)
{
    float3 fogWarm = float3(1.0, 0.55, 0.22) * 1.25;
    return mix(hdr, fogWarm, saturate(fogAmount));
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
    // Fullscreen triangle
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyOut out;
    out.position = float4(positions[vid], 0.999, 1.0);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 skyFragment(SkyOut in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                            texture2d<float> sky [[texture(TextureIndexSky)]])
{
    // Procedural CITY SURFER sunset — HDRI kept for IBL/reflections elsewhere.
    float2 ndc = in.uv * 2.0 - 1.0;
    float4 nearP = frame.invViewProjectionMatrix * float4(ndc, 0.0, 1.0);
    float4 farP  = frame.invViewProjectionMatrix * float4(ndc, 1.0, 1.0);
    float3 nearW = nearP.xyz / max(nearP.w, 1e-5);
    float3 farW  = farP.xyz / max(farP.w, 1e-5);
    float3 dir = normalize(farW - nearW);

    // #FF7A2F horizon → #4A3B8C zenith
    float3 horizon = float3(1.0, 0.478, 0.184);
    float3 zenith = float3(0.290, 0.231, 0.549);
    float elev = saturate(dir.y * 0.5 + 0.5);
    float3 col = mix(horizon, zenith, pow(elev, 0.85));
    // Warm haze near horizon
    col = mix(col, horizon * 1.35, saturate(1.0 - abs(dir.y) * 2.2) * 0.55);

    float3 sunDir = normalize(frame.lightDirection);
    float sunDot = saturate(dot(dir, sunDir));
    // Large soft sun disk + glow (stylized, not HDRI sun)
    float disk = pow(sunDot, 180.0);
    float glow = pow(sunDot, 12.0) * 1.8 + pow(sunDot, 4.0) * 0.55;
    float3 sunCol = frame.lightColor * frame.sunIntensity;
    col += sunCol * (disk * 6.0 + glow);
    col += float3(1.0, 0.95, 0.7) * disk * 8.0;

    return float4(applyWarmFog(col, 0.08), 1.0);
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

    // Glass/facade buildings (materialId 6): warm stylized facades + window glow
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
        // HDR emissive so bloom picks window glow.
        albedo += float3(1.0, 0.78, 0.35) * lit * window * 1.6;
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

    // Neon / boost emissives written > 1 so the bloom chain lights them up.
    if (object.materialId > 2.5 && object.materialId < 3.5) {
        float rim = pow(1.0 - saturate(dot(N, V)), 2.0);
        float3 rimCol = mix(float3(0.45, 0.98, 0.18), object.color.rgb, 0.45);
        color += rimCol * rim * 2.4;
        color += object.color.rgb * 0.45;
    }
    if (object.materialId > 4.5 && object.materialId < 5.5) {
        float pulse = 0.55 + 0.45 * sin(frame.time * 7.0 + in.worldPos.x * 2.0);
        color += object.color.rgb * pulse * 2.8;
        float rim = pow(1.0 - saturate(dot(N, V)), 1.4);
        color += float3(1.0, 0.92, 0.35) * rim * 2.6;
        float glint = pow(saturate(dot(N, normalize(L + V))), 64.0);
        color += float3(1.0, 0.95, 0.6) * glint * 4.0;
    }
    // Traffic-light / hazard / billboard neon
    if (object.materialId > 3.5 && object.materialId < 4.5) {
        float chroma = max(object.color.r, max(object.color.g, object.color.b))
                     - min(object.color.r, min(object.color.g, object.color.b));
        if (chroma > 0.35) {
            float pulse = 0.7 + 0.3 * sin(frame.time * 8.0);
            color += object.color.rgb * pulse * 2.2;
        }
    }

    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 35.0) / 120.0);
    return float4(applyWarmFog(color, fog * 0.55), 1.0);
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
    // Larger normal offset on water — large sloping face is acne-prone.
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
    constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 L = normalize(frame.lightDirection);
    float fresnel = pow(1.0 - saturate(dot(N, V)), 2.4);

    // CITY SURFER water — saturated teal/aqua (#0A6E7E / #14B8C4 / #5FE8DC)
    float3 deep = float3(0.039, 0.431, 0.494);
    float3 mid = float3(0.078, 0.722, 0.769);
    float3 shallow = float3(0.373, 0.910, 0.863);
    float h = saturate(in.worldPos.y / max(frame.waveAmplitude, 0.001));
    float3 water = mix(deep, mid, smoothstep(0.0, 0.4, h));
    water = mix(water, shallow, smoothstep(0.4, 0.95, h));

    // Chunky pure-white foam (hard edge from vertex).
    float foamAmt = step(0.5, in.foam);
    water = mix(water, float3(1.0, 1.0, 1.0), foamAmt);

    // Soft street-edge darkening (no shadow map).
    float edge = saturate((abs(in.worldPos.x) - 4.5) / 6.5);
    float edgeShade = mix(1.0, 0.78, edge * edge);

    // Orange sky fresnel on teal = reference signature contrast.
    float3 R = reflect(-V, N);
    float skyElev = saturate(R.y * 0.5 + 0.5);
    float3 skyHorizon = float3(1.0, 0.478, 0.184);
    float3 skyZenith = float3(0.290, 0.231, 0.549);
    float3 skyCol = mix(skyHorizon, skyZenith, pow(skyElev, 0.85));
    float sunDot = saturate(dot(normalize(R), L));
    skyCol += frame.lightColor * frame.sunIntensity * (pow(sunDot, 24.0) * 2.5 + pow(sunDot, 6.0) * 0.6);
    water = water * edgeShade + skyCol * fresnel * 0.55;

    // Sun glitter path down the flooded street (art-ref signature).
    float street = 1.0 - smoothstep(0.5, 4.0, abs(in.worldPos.x));
    float sparkle = hash21(floor(in.worldPos.xz * 1.8 + float2(frame.time * 3.0, 0.0)));
    float glitterPath = street * pow(saturate(dot(N, L)), 3.0);
    glitterPath *= 0.45 + 0.55 * sin(in.worldPos.z * 1.7 + frame.time * 5.0);
    glitterPath += street * pow(sunDot, 10.0) * step(0.62, sparkle) * 1.4;
    // Slightly hotter glitter so bloom catches the street path.
    water += frame.lightColor * glitterPath * frame.sunIntensity * 0.85;

    float3 irr = sampleEquirect(irradianceMap, iblSampler, N);
    irr = mix(irr, irr * float3(1.0, 0.55, 0.22) * 1.3, 0.5);
    water += irr * 0.04 * frame.iblIntensity;

    float ndotl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 48.0) * (0.35 + 0.65 * fresnel);
    water += spec * frame.lightColor * frame.sunIntensity * 0.4 * edgeShade;

    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 35.0) / 130.0);
    return float4(applyWarmFog(water, fog * 0.5), 1.0);
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
    float3 hdr = scene.sample(s, in.uv).rgb;
    hdr += bloom.sample(s, in.uv).rgb * fx.bloomIntensity;

    // Fog already applied in scene shaders — grade + tonemap here.
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
