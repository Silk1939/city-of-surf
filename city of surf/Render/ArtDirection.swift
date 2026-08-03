//
//  ArtDirection.swift
//  city of surf
//
//  CITY SURFER — stylized & saturated palette (not photoreal).
//  Keep shader literals in Shaders.metal aligned when tuning.
//

import simd

enum ArtDirection {
    // MARK: - Sky (procedural display)
    static let skyHorizon = SIMD3<Float>(1.0, 0.478, 0.184)      // #FF7A2F
    static let skyZenith = SIMD3<Float>(0.290, 0.231, 0.549)       // #4A3B8C
    static let sunDisk = SIMD3<Float>(1.0, 0.95, 0.65)

    // MARK: - Water
    static let waterDeep = SIMD3<Float>(0.039, 0.431, 0.494)       // #0A6E7E
    static let waterMid = SIMD3<Float>(0.078, 0.722, 0.769)        // #14B8C4
    static let waterShallow = SIMD3<Float>(0.373, 0.910, 0.863)    // #5FE8DC
    static let foamWhite = SIMD3<Float>(1.0, 1.0, 1.0)

    // MARK: - Buildings (warm variants)
    static let brick = SIMD3<Float>(0.72, 0.28, 0.22)
    static let sand = SIMD3<Float>(0.82, 0.68, 0.48)
    static let terracotta = SIMD3<Float>(0.78, 0.42, 0.28)
    static let warmCharcoal = SIMD3<Float>(0.28, 0.26, 0.30)
    static let sunSideWarm = SIMD3<Float>(1.0, 0.72, 0.42)
    static let neonGreen = SIMD3<Float>(0.45, 0.98, 0.18)
    static let coinGold = SIMD3<Float>(1.0, 0.84, 0.15)

    // MARK: - Lighting / grade
    static let sunDirection = simd_normalize(SIMD3<Float>(0.35, 0.55, 0.55))
    static let sunColor = SIMD3<Float>(1.0, 0.62, 0.28)
    static let sunIntensity: Float = 2.6
    static let iblIntensity: Float = 0.85
    static let fogWarm = SIMD3<Float>(1.0, 0.55, 0.22)
    /// Post composite (ACES after bloom). Keep in sync with `compositeFragment`.
    static let saturation: Float = 1.22
    static let vignetteStrength: Float = 0.28
    static let bloomThreshold: Float = 1.2
    static let bloomSoftKnee: Float = 0.5
    static let bloomIntensity: Float = 0.35
    static let grainAmount: Float = 0.015
    static let windowGlow = SIMD3<Float>(1.0, 0.78, 0.35)

    /// Cycle warm building tints (left/right facades).
    static func buildingTint(index: Int) -> SIMD3<Float> {
        let palette = [brick, sand, terracotta, warmCharcoal, sand, brick]
        return palette[abs(index) % palette.count]
    }
}
