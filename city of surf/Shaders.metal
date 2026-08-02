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
                       float bias)
{
    float3 proj = shadowCoord.xyz / max(shadowCoord.w, 1e-5);
    float2 uv = proj.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 1.0;
    }
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

static float3 tonemapACES(float3 x)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
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
    constexpr sampler s(s_address::repeat, t_address::clamp_to_edge, filter::linear);
    // NDC from fullscreen triangle; Metal clip space z near≈0 far≈1 — use far plane for sky ray.
    float2 ndc = in.uv * 2.0 - 1.0;
    float4 nearP = frame.invViewProjectionMatrix * float4(ndc, 0.0, 1.0);
    float4 farP  = frame.invViewProjectionMatrix * float4(ndc, 1.0, 1.0);
    float3 nearW = nearP.xyz / max(nearP.w, 1e-5);
    float3 farW  = farP.xyz / max(farP.w, 1e-5);
    float3 dir = normalize(farW - nearW);
    float3 col = sampleEquirect(sky, s, dir) * frame.iblIntensity;
    return float4(tonemapACES(col), 1.0);
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
    out.shadowCoord = frame.lightViewProjectionMatrix * world;

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

    // Road wetness boost
    if (object.materialId > 0.5 && object.materialId < 1.5) {
        float center = 1.0 - smoothstep(0.08, 0.22, abs(in.worldPos.x));
        float dash = step(0.45, fract(in.worldPos.z * 0.1));
        albedo = mix(albedo, float3(0.95, 0.9, 0.55), center * dash * 0.35);
        roughness = clamp(roughness * 0.55, 0.08, 0.7);
        metallic = 0.05;
    }

    // Glass/facade buildings (materialId 6): lean specular, keep Facade001 maps
    if (object.materialId > 5.5 && object.materialId < 6.5) {
        roughness = clamp(roughness * 0.85, 0.05, 0.55);
        metallic = 0.25;
        float facing = saturate(abs(N.x) * 0.85 + abs(N.z) * 0.85);
        float lit = step(0.4, fract(sin(dot(floor(in.worldPos.xyz * float3(0.35, 0.55, 0.35)), float3(12.1, 78.2, 45.3))) * 43758.5));
        albedo += float3(1.0, 0.82, 0.45) * lit * facing * 0.12;
    }

    // Legacy concrete building window mix (materialId 2) if still used
    if (object.materialId > 1.5 && object.materialId < 2.5) {
        float facing = saturate(abs(N.x) * 0.85 + abs(N.z) * 0.85);
        float wx = fract(in.worldPos.y * 0.55);
        float wz = fract((abs(N.x) > 0.5 ? in.worldPos.z : in.worldPos.x) * 0.35);
        float window = step(0.18, wx) * step(wx, 0.82) * step(0.2, wz) * step(wz, 0.8) * facing;
        albedo = mix(albedo, albedo * 0.15 + float3(0.05, 0.08, 0.1), window * 0.85);
        roughness = mix(roughness, 0.12, window);
        metallic = mix(metallic, 0.35, window);
    }

    // Coins / neon surfer accents stay glossy
    if (object.materialId > 4.5 && object.materialId < 5.5) {
        albedo = float3(1.0, 0.82, 0.15);
        roughness = 0.2;
        metallic = 0.85;
    } else if (object.materialId > 2.5 && object.materialId < 3.5) {
        roughness = 0.35;
        metallic = 0.15;
    } else if (object.materialId > 3.5 && object.materialId < 4.5) {
        roughness = 0.45;
        metallic = 0.2;
    }

    float shadow = 1.0;
    if (object.receivesShadow > 0.5) {
        shadow = shadowPCF(in.shadowCoord, shadowMap, shadowSampler, frame.shadowBias);
        shadow = mix(0.35, 1.0, shadow);
    }

    float3 irradiance = sampleEquirect(irradianceMap, iblSampler, N);
    float3 R = reflect(-V, N);
    float mip = roughness * max(frame.specularMips - 1.0, 1.0);
    uint layer0 = uint(floor(mip));
    uint layer1 = min(layer0 + 1, uint(max(frame.specularMips - 1.0, 0.0)));
    float mipF = fract(mip);
    float3 spec0 = specularMap.sample(iblSampler, dirToEquirect(R), layer0).rgb;
    float3 spec1 = specularMap.sample(iblSampler, dirToEquirect(R), layer1).rgb;
    float3 prefiltered = mix(spec0, spec1, mipF);
    float2 brdf = brdfLUT.sample(iblSampler, float2(max(dot(N, V), 0.0), roughness)).rg;

    float3 color = pbrLit(albedo, clamp(roughness, 0.04, 1.0), metallic, N, V, L,
                          frame.lightColor, frame.sunIntensity, shadow,
                          irradiance, prefiltered, brdf, frame.iblIntensity);

    // Fog in linear HDR (not LDR 0–1) so distant highlights aren't crushed before ACES.
    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 40.0) / 130.0);
    float3 fogCol = frame.lightColor * frame.sunIntensity * 0.45 + float3(0.35, 0.12, 0.04);
    color = mix(color, fogCol, fog * 0.55);
    // Tonemap is the only display clamp — keep linear HDR until here.
    return float4(tonemapACES(color), 1.0);
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
    out.shadowCoord = frame.lightViewProjectionMatrix * float4(displaced, 1.0);
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
    float fresnel = pow(1.0 - saturate(dot(N, V)), 2.8);

    float3 deep = float3(0.02, 0.22, 0.32);
    float3 mid = float3(0.06, 0.55, 0.62);
    float3 shallow = float3(0.25, 0.88, 0.85);
    float h = saturate(in.worldPos.y / max(frame.waveAmplitude, 0.001));
    float3 water = mix(deep, mid, smoothstep(0.0, 0.45, h));
    water = mix(water, shallow, smoothstep(0.45, 1.0, h));

    float3 foamCol = float3(0.95, 0.98, 1.0);
    float foamAmt = pow(saturate(in.foam), 1.1);
    water = mix(water, foamCol, foamAmt * 0.98);

    float shadow = shadowPCF(in.shadowCoord, shadowMap, shadowSampler, frame.shadowBias);
    shadow = mix(0.4, 1.0, shadow);

    float3 R = reflect(-V, N);
    float3 env = sampleEquirect(sky, iblSampler, R);
    float3 irr = sampleEquirect(irradianceMap, iblSampler, N);
    water = water * (0.45 + 0.55 * shadow) + fresnel * env * frame.iblIntensity * 0.65;
    water += irr * 0.12 * frame.iblIntensity;

    float ndotl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 72.0) * (0.4 + 0.6 * fresnel);
    water += spec * frame.lightColor * frame.sunIntensity * 0.35 * shadow;

    float fog = saturate((length(in.worldPos - frame.cameraPosition) - 40.0) / 140.0);
    float3 fogCol = frame.lightColor * frame.sunIntensity * 0.45 + float3(0.35, 0.12, 0.04);
    water = mix(water, fogCol, fog * 0.5);
    return float4(tonemapACES(water), 1.0);
}
