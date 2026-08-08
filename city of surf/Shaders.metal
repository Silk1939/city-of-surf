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
    float viewDepth;
} VOut;

typedef struct
{
    float4 color [[color(0)]];
    float depthLinear [[color(1)]];
} SolidTargets;

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

static float4 gerstner_dir_amp_wave(constant FrameUniforms &frame, int index)
{
    if (index == 0) return frame.gerstnerDirAmpWave0;
    if (index == 1) return frame.gerstnerDirAmpWave1;
    if (index == 2) return frame.gerstnerDirAmpWave2;
    return frame.gerstnerDirAmpWave3;
}

static float4 gerstner_steep_speed(constant FrameUniforms &frame, int index)
{
    if (index == 0) return frame.gerstnerSteepSpeed0;
    if (index == 1) return frame.gerstnerSteepSpeed1;
    if (index == 2) return frame.gerstnerSteepSpeed2;
    return frame.gerstnerSteepSpeed3;
}

// Must match WaveField.swift
static void gerstner_accumulate(float3 pos,
                                float bodyMask,
                                constant FrameUniforms &frame,
                                thread float3 &displacement,
                                thread float3 &tx,
                                thread float3 &tz,
                                thread float &foam)
{
    const float waveCount = 4.0;
    for (int i = 0; i < 4; ++i) {
        float4 daw = gerstner_dir_amp_wave(frame, i);
        float4 ss = gerstner_steep_speed(frame, i);
        float2 dir = normalize(float2(daw.x, daw.y));
        float wavelength = max(daw.w, 0.001);
        float k = (2.0 * M_PI_F) / wavelength;
        float a = daw.z * (0.35 + 0.65 * bodyMask);
        float q = ss.x / max(k * a * waveCount, 0.001);
        float phase = k * (dir.x * pos.x + dir.y * pos.z) - ss.y * k * frame.time;
        float s = sin(phase);
        float c = cos(phase);
        float qa = q * a;

        displacement.x += dir.x * qa * c;
        displacement.y += a * s;
        displacement.z += dir.y * qa * c;

        tx.x -= dir.x * dir.x * q * a * k * s;
        tx.y += dir.x * a * k * c;
        tx.z -= dir.x * dir.y * q * a * k * s;

        tz.x -= dir.x * dir.y * q * a * k * s;
        tz.y += dir.y * a * k * c;
        tz.z -= dir.y * dir.y * q * a * k * s;

        foam += saturate(1.2 * q * a * k * abs(s)) * bodyMask;
    }
}

static float3 flood_displace(float3 pos, constant FrameUniforms &frame, thread float &foam, thread float3 &normal)
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

    float3 tx = float3(1.0, 0.0, 0.0);
    float3 tz = float3(0.0, 0.0, 1.0);
    float gerstnerFoam = 0.0;
    gerstner_accumulate(pos, body, frame, d, tx, tz, gerstnerFoam);

    float eps = 0.35;
    float yFront = a * (flood_body((pos.z + eps) + frame.scrollZ, frame.waveLength) * 0.82
                        + crest_lip((pos.z + eps) + frame.scrollZ, frame.waveLength) * steep * 0.55);
    float yBack = a * (flood_body((pos.z - eps) + frame.scrollZ, frame.waveLength) * 0.82
                       + crest_lip((pos.z - eps) + frame.scrollZ, frame.waveLength) * steep * 0.55);
    tz.y += (yFront - yBack) / (2.0 * eps);

    normal = normalize(cross(tz, tx));
    foam = saturate(lip * 0.85 + faceMask * 0.45 + gerstnerFoam * 0.75);
    return pos + d;
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
    out.viewDepth = length(world.xyz - frame.cameraPosition);

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

fragment SolidTargets solidFragment(VOut in [[stage_in]],
                                    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                                    constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 base = object.color.rgb;
    float roughness = 0.58;
    float metalness = 0.0;
    float3 emissive = float3(0.0);

    if (object.materialId > 0.5 && object.materialId < 1.5) {
        float lanes = abs(fract(in.worldPos.x / 3.2 + 0.5) - 0.5);
        float dash = step(0.5, fract(in.worldPos.z * 0.12));
        float mark = smoothstep(0.47, 0.5, lanes) * dash;
        base = mix(base, float3(0.85, 0.82, 0.55), mark * 0.55);
        roughness = 0.24;
    }
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
    else if (object.materialId > 4.5 && object.materialId < 5.5) {
        roughness = 0.22;
        metalness = 0.65;
        emissive = base * 0.15;
    }

    float3 litColor = evaluate_pbr(base, roughness, metalness, N, V, frame) + emissive;
    SolidTargets out;
    out.color = float4(apply_exponential_fog(litColor, in.worldPos, frame), 1.0);
    out.depthLinear = in.viewDepth;
    return out;
}

vertex VOut waveVertex(Vertex in [[stage_in]],
                       constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                       constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]])
{
    VOut out;
    float4 worldBase = object.modelMatrix * float4(in.position, 1.0);
    float foam = 0.0;
    float3 N = float3(0, 1, 0);
    float3 displaced = flood_displace(worldBase.xyz, frame, foam, N);
    out.worldPos = displaced;
    out.position = frame.viewProjectionMatrix * float4(displaced, 1.0);
    out.normal = N;
    out.texCoord = in.texCoord;
    out.foam = foam;
    out.materialId = 0.0;
    out.viewDepth = length(displaced - frame.cameraPosition);
    return out;
}

fragment float4 waveFragment(VOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
                             constant ObjectUniforms &object [[buffer(BufferIndexObjectUniforms)]],
                             texture2d<float, access::read> opaqueDepth [[texture(TextureIndexDepth)]])
{
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition - in.worldPos);
    float3 L = normalize(frame.lightDirection);
    float ndotv = saturate(dot(N, V));
    float fresnel = pow(1.0 - ndotv, 4.5);
    fresnel = mix(0.04, 1.0, fresnel);

    float3 deep = float3(0.01, 0.08, 0.18);
    float3 mid = float3(0.04, 0.32, 0.46);
    float3 shallow = float3(0.16, 0.68, 0.78);
    float h = saturate(in.worldPos.y / max(frame.waveAmplitude, 0.001));
    float3 water = mix(deep, mid, smoothstep(0.0, 0.55, h));
    water = mix(water, shallow, smoothstep(0.55, 1.0, h));

    uint2 pixel = uint2(in.position.xy);
    float sceneDepth = opaqueDepth.read(pixel).r;
    float waterDepth = in.viewDepth;
    float edgeFoam = 1.0 - smoothstep(0.0, max(frame.foamEdgeDepth, 0.05), abs(sceneDepth - waterDepth));
    edgeFoam *= step(waterDepth, sceneDepth + 0.05);
    float foam = saturate(pow(in.foam, 1.25) * 0.95 + edgeFoam * 0.85);
    float3 foamCol = float3(0.94, 0.97, 1.0);
    water = mix(water, foamCol, foam);

    float roughness = mix(0.08, 0.62, foam);
    float3 litWater = evaluate_pbr(water, roughness, 0.0, N, V, frame);

    float3 H = normalize(L + V);
    float sunSpec = pow(saturate(dot(N, H)), 220.0) * fresnel;
    litWater += sunSpec * frame.sunColorIntensity.rgb * frame.sunColorIntensity.a * 2.4;
    litWater += fresnel
        * frame.skyAmbientColorIntensity.rgb
        * frame.skyAmbientColorIntensity.a
        * 0.85;

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
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

fragment float4 bloomExtractFragment(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float, access::read> sceneColor [[texture(TextureIndexColor)]])
{
    uint2 pixel = uint2(in.position.xy);
    // Upsample from half-res extract target by reading the matching HDR texel.
    uint2 src = uint2(float2(pixel) * float2(sceneColor.get_width(), sceneColor.get_height())
                      / float2(max(in.position.x, 1.0), max(in.position.y, 1.0)));
    // When extract runs at half resolution, map pixel center into full HDR.
    src = min(pixel * 2u, uint2(sceneColor.get_width() - 1, sceneColor.get_height() - 1));
    float3 hdr = max(sceneColor.read(src).rgb, 0.0);
    float brightness = max(max(hdr.r, hdr.g), hdr.b);
    float knee = max(frame.bloomSoftKnee, 0.001);
    float soft = brightness - frame.bloomThreshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = (soft * soft) / (4.0 * knee + 1e-4);
    float contribution = max(soft, brightness - frame.bloomThreshold) / max(brightness, 1e-4);
    return float4(hdr * saturate(contribution), 1.0);
}

fragment float4 bloomBlurHFragment(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float, access::sample> source [[texture(TextureIndexColor)]])
{
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / float2(source.get_width(), source.get_height());
    float2 texel = float2(1.0, 0.0) / float2(source.get_width(), source.get_height());
    const float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    float3 color = source.sample(linearSampler, uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        float2 offset = texel * float(i);
        color += source.sample(linearSampler, uv + offset).rgb * weights[i];
        color += source.sample(linearSampler, uv - offset).rgb * weights[i];
    }
    return float4(color, 1.0);
}

fragment float4 bloomBlurVFragment(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float, access::sample> source [[texture(TextureIndexColor)]])
{
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / float2(source.get_width(), source.get_height());
    float2 texel = float2(0.0, 1.0) / float2(source.get_width(), source.get_height());
    const float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    float3 color = source.sample(linearSampler, uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        float2 offset = texel * float(i);
        color += source.sample(linearSampler, uv + offset).rgb * weights[i];
        color += source.sample(linearSampler, uv - offset).rgb * weights[i];
    }
    return float4(color, 1.0);
}

fragment float4 tonemapFragment(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    texture2d<float, access::read> sceneColor [[texture(TextureIndexColor)]],
    texture2d<float, access::sample> bloomColor [[texture(TextureIndexBloom)]])
{
    uint2 pixel = uint2(in.position.xy);
    float3 hdrColor = max(sceneColor.read(pixel).rgb * frame.exposure, 0.0);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(pixel) + 0.5) / float2(sceneColor.get_width(), sceneColor.get_height());
    float3 bloom = bloomColor.sample(linearSampler, uv).rgb * frame.bloomIntensity;
    hdrColor += bloom;
    float3 mapped = aces_filmic(hdrColor);
    float3 gammaCorrected = pow(mapped, float3(1.0 / 2.2));
    return float4(gammaCorrected, 1.0);
}

// MARK: - GPU Particles

static float particle_hash(uint x)
{
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return float(x) * (1.0 / 4294967295.0);
}

static float3 particle_rand_dir(uint seed)
{
    float a = particle_hash(seed) * 6.2831853;
    float b = particle_hash(seed + 17u) * 2.0 - 1.0;
    float r = sqrt(max(1.0 - b * b, 0.0));
    return float3(cos(a) * r, abs(b), sin(a) * r);
}

kernel void particleUpdate(
    device Particle *particles [[buffer(BufferIndexParticles)]],
    constant ParticleFrameUniforms &frame [[buffer(BufferIndexParticleFrame)]],
    uint id [[thread_position_in_grid]])
{
    uint count = uint(frame.particleCount);
    if (id >= count) return;

    Particle p = particles[id];
    if (p.life > 0.0) {
        p.life -= frame.deltaTime;
        p.velocity.y -= frame.gravity * frame.deltaTime;
        p.velocity *= max(0.0, 1.0 - frame.drag * frame.deltaTime);
        p.position += p.velocity * frame.deltaTime;
        p.color.a *= saturate(p.life * 2.0);
        if (p.life <= 0.0) {
            p.life = 0.0;
            p.size = 0.0;
        }
        particles[id] = p;
        return;
    }

    // Dead slots may be recycled for new emitters.
    float boardChance = frame.emitBoardCount / max(frame.particleCount, 1.0);
    float crestChance = frame.emitCrestCount / max(frame.particleCount, 1.0);
    float splashChance = frame.emitSplashCount / max(frame.particleCount, 1.0);
    float roll = particle_hash(id + frame.seed);

    if (roll < boardChance) {
        float3 dir = particle_rand_dir(id * 3u + frame.seed);
        p.position = frame.emitBoardPosition + float3(dir.x, 0.05, -0.4 - abs(dir.z) * 0.3) * 0.35;
        p.velocity = float3(dir.x * 1.2, 1.5 + dir.y * 1.8, -2.5 - dir.z * 1.5);
        p.life = frame.sprayLife * (0.7 + particle_hash(id + 9u) * 0.6);
        p.size = frame.spraySize;
        p.color = frame.sprayColor;
        particles[id] = p;
    } else if (roll < boardChance + crestChance) {
        float3 dir = particle_rand_dir(id * 5u + frame.seed);
        p.position = frame.emitCrestPosition + float3(dir.x, dir.y, dir.z) * 0.8;
        p.velocity = float3(dir.x * 1.4, 2.2 + dir.y * 2.0, dir.z * 1.1);
        p.life = frame.sprayLife * (0.8 + particle_hash(id + 11u) * 0.5);
        p.size = frame.spraySize * 1.15;
        p.color = frame.sprayColor;
        particles[id] = p;
    } else if (roll < boardChance + crestChance + splashChance) {
        float3 dir = particle_rand_dir(id * 7u + frame.seed);
        p.position = frame.emitSplashPosition + dir * 0.25;
        p.velocity = dir * (3.5 + particle_hash(id + 13u) * 3.0);
        p.velocity.y = abs(p.velocity.y) + 2.0;
        p.life = frame.splashLife * (0.7 + particle_hash(id + 15u) * 0.6);
        p.size = frame.splashSize;
        p.color = frame.splashColor;
        particles[id] = p;
    }
}

typedef struct
{
    float4 position [[position]];
    float2 uv;
    float4 color;
} ParticleVOut;

vertex ParticleVOut particleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    const device Particle *particles [[buffer(BufferIndexParticles)]])
{
    Particle p = particles[instanceID];
    float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    float2 corner = corners[vertexID];
    float3 toCam = normalize(frame.cameraPosition - p.position);
    float3 worldUp = float3(0, 1, 0);
    float3 right = normalize(cross(worldUp, toCam));
    if (length(right) < 1e-3) {
        right = float3(1, 0, 0);
    }
    float3 up = cross(toCam, right);
    float3 world = p.position + (right * corner.x + up * corner.y) * p.size * step(0.0, p.life);

    ParticleVOut out;
    out.position = frame.viewProjectionMatrix * float4(world, 1.0);
    out.uv = corner * 0.5 + 0.5;
    out.color = p.color;
    out.color.a *= step(0.0, p.life);
    return out;
}

fragment float4 particleFragment(ParticleVOut in [[stage_in]])
{
    float2 d = in.uv * 2.0 - 1.0;
    float alpha = saturate(1.0 - dot(d, d));
    alpha = pow(alpha, 1.4) * in.color.a;
    if (alpha < 0.02) discard_fragment();
    return float4(in.color.rgb, alpha);
}
