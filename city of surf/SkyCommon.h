//
//  SkyCommon.h
//  city of surf
//
//  Shared procedural sunset sky — used by skyFragment and wave fresnel.
//  Palette: .cursor/rules/art-direction.mdc
//

#ifndef SkyCommon_h
#define SkyCommon_h

#ifdef __METAL_VERSION__

#include <metal_stdlib>
using namespace metal;

/// #FF7A3C
constant float3 kSkyHorizon = float3(1.0, 0.478, 0.235);
/// #2B3A67
constant float3 kSkyZenith = float3(0.169, 0.227, 0.404);
/// #FFE8B0
constant float3 kSunDiskColor = float3(1.0, 0.910, 0.690);
constant float kSunDiskIntensity = 12.0;

/// Analytic procedural sky for a world-space view/reflection direction.
static inline float3 evaluateProceduralSky(float3 dir,
                                           float3 lightDirection,
                                           float3 lightColor,
                                           float sunIntensity)
{
    float3 d = normalize(dir);
    float elev = saturate(d.y * 0.5 + 0.5);
    float3 col = mix(kSkyHorizon, kSkyZenith, pow(elev, 0.9));

    float3 sunDir = normalize(lightDirection);
    float sunDot = saturate(dot(d, sunDir));

    float horizonBand = saturate(1.0 - abs(d.y) * 2.4);
    float glowBand = pow(sunDot, 3.0) * 1.1 + pow(sunDot, 1.2) * 0.45;
    col = mix(col, kSkyHorizon * 1.55, saturate(horizonBand * 0.65 + glowBand * 0.55));

    float disk = pow(sunDot, 220.0);
    float softHalo = pow(sunDot, 18.0) * 2.2 + pow(sunDot, 6.0) * 0.7;
    float3 sunDisc = kSunDiskColor * kSunDiskIntensity;
    col += sunDisc * disk;
    col += sunDisc * softHalo * 0.08;
    col += lightColor * sunIntensity * softHalo * 0.15;
    return col;
}

#endif /* __METAL_VERSION__ */

#endif /* SkyCommon_h */
