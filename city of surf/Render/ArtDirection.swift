//
//  ArtDirection.swift
//  city of surf
//
//  CITY SURFER — stylized & saturated palette (not photoreal).
//  Canonical hexes: .cursor/rules/art-direction.mdc — keep Shaders.metal in sync.
//

import simd

enum ArtDirection {
    // MARK: - Sky (procedural display)
    static let skyHorizon = SIMD3<Float>(1.0, 0.478, 0.235)       // #FF7A3C
    static let skyZenith = SIMD3<Float>(0.169, 0.227, 0.404)        // #2B3A67
    static let sunDisk = SIMD3<Float>(1.0, 0.910, 0.690)            // #FFE8B0

    // MARK: - Water
    static let waterDeep = SIMD3<Float>(0.039, 0.227, 0.290)        // #0A3A4A
    static let waterMid = SIMD3<Float>(0.090, 0.500, 0.520)
    static let waterShallow = SIMD3<Float>(0.180, 0.769, 0.714)     // #2EC4B6
    static let foam = SIMD3<Float>(1.0, 0.965, 0.914)               // #FFF6E9
    /// SSS glow through crest lip (#2EC4B6 * intensity) — keep ≤1.2 to avoid blowout.
    static let crestSSSIntensity: Float = 1.05
    /// Narrow sun glitter HDR scale on water (pre-tonemap, kept modest).
    static let waterGlitterIntensity: Float = 1.15
    /// GPU-only detail wave amps (must stay small vs gameplay amplitude; not in WaveField).
    static let waterDetailAmp0: Float = 0.28
    static let waterDetailAmp1: Float = 0.14

    // MARK: - Buildings
    static let buildingSun = SIMD3<Float>(0.788, 0.635, 0.494)      // #C9A27E
    static let buildingShadow = SIMD3<Float>(0.361, 0.420, 0.522)   // #5C6B85
    static let brick = SIMD3<Float>(0.72, 0.28, 0.22)
    static let sand = buildingSun
    static let terracotta = SIMD3<Float>(0.78, 0.42, 0.28)
    static let warmCharcoal = buildingShadow
    static let sunSideWarm = SIMD3<Float>(1.0, 0.72, 0.42)
    static let neonMagenta = SIMD3<Float>(1.0, 0.243, 0.541)        // #FF3E8A
    static let neonCyan = SIMD3<Float>(0.220, 0.898, 1.0)           // #38E5FF
    static let neonGreen = neonCyan
    static let coinGold = SIMD3<Float>(1.0, 0.84, 0.15)
    static let windowGlow = SIMD3<Float>(1.0, 0.78, 0.35)
    /// Additive HDR emissive scales (linear, pre-tonemap) — bloom food.
    static let windowGlowIntensity: Float = 1.6
    static let neonEmissiveMin: Float = 1.15
    static let neonEmissiveMax: Float = 1.85

    // MARK: - Lighting / grade
    /// Slightly elevated sun — less looking straight into the disk down-canyon.
    static let sunDirection = simd_normalize(SIMD3<Float>(0.12, 0.42, 0.90))
    static let sunColor = SIMD3<Float>(1.0, 0.72, 0.42)
    static let sunIntensity: Float = 1.85
    static let iblIntensity: Float = 0.55
    /// Distance/height fog mixes toward horizon orange (never grey).
    static let fogWarm = skyHorizon
    /// Soft HDR sun disc scale in `skyFragment` / SkyCommon.h (keep in sync).
    static let sunDiskIntensity: Float = 2.0

    /// Composite: exposure → bloom add → ACES → saturation → vignette.
    static let exposure: Float = 0.48
    static let saturation: Float = 1.18
    /// Max corner darkening (0.15 = 15%).
    static let vignetteStrength: Float = 0.20
    static let bloomThreshold: Float = 1.5
    static let bloomSoftKnee: Float = 0.35
    static let bloomIntensity: Float = 0.14
    static let grainAmount: Float = 0.015

    /// Cycle warm/cool facade tints (sun vs shadow sides of the street).
    static func buildingTint(index: Int) -> SIMD3<Float> {
        let palette = [buildingSun, terracotta, sand, buildingShadow, buildingSun, brick]
        return palette[abs(index) % palette.count]
    }
}
