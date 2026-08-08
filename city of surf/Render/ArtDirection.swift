//
//  ArtDirection.swift
//  city of surf
//

import simd

enum ArtDirection {
    static let sunDirection = simd_normalize(SIMD3<Float>(0.35, 0.22, 0.91))
    static let sunColor = SIMD3<Float>(1.0, 0.81, 0.44)
    static let sunIntensity: Float = 4.0

    static let skyAmbientColor = SIMD3<Float>(0.024, 0.042, 0.135)
    static let skyAmbientIntensity: Float = 2.4

    static let fogColor = SIMD3<Float>(1.0, 0.195, 0.045)
    static let fogDensity: Float = 0.011

    static let exposure: Float = 1.0
    static let acesA: Float = 2.51
    static let acesB: Float = 0.03
    static let acesC: Float = 2.43
    static let acesD: Float = 0.59
    static let acesE: Float = 0.14
    static let displayGamma: Float = 2.2

    static let bloomThreshold: Float = 1.05
    static let bloomIntensity: Float = 0.55
    static let bloomSoftKnee: Float = 0.45

    enum Water {
        static let deepColor = SIMD3<Float>(0.01, 0.08, 0.18)
        static let midColor = SIMD3<Float>(0.04, 0.32, 0.46)
        static let shallowColor = SIMD3<Float>(0.16, 0.68, 0.78)
        static let foamColor = SIMD3<Float>(0.94, 0.97, 1.0)
        static let fresnelBias: Float = 0.04
        static let fresnelPower: Float = 4.5
        static let sunSpecPower: Float = 220
        static let sunSpecIntensity: Float = 2.4
        static let crestFoamStrength: Float = 0.95
        static let edgeFoamStrength: Float = 0.85
        static let edgeFoamDepthMeters: Float = 1.35
        static let roughnessClear: Float = 0.08
        static let roughnessFoam: Float = 0.62

        /// Four Gerstner layers: direction.xz, amplitude, wavelength, steepness, speed.
        static let gerstner: [(dir: SIMD2<Float>, amplitude: Float, wavelength: Float, steepness: Float, speed: Float)] = [
            (simd_normalize(SIMD2(0.18, 0.98)), 0.28, 11.0, 0.55, 1.35),
            (simd_normalize(SIMD2(-0.55, 0.84)), 0.16, 6.5, 0.42, 1.85),
            (simd_normalize(SIMD2(0.72, 0.69)), 0.10, 3.8, 0.35, 2.40),
            (simd_normalize(SIMD2(-0.22, 0.98)), 0.06, 2.2, 0.28, 3.10)
        ]
    }

    static func exponentialFogFactor(distance: Float) -> Float {
        1 - exp(-fogDensity * max(distance, 0))
    }

    static func acesTonemapped(_ hdrColor: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = hdrColor * exposure
        let exposed = SIMD3<Float>(
            max(scaled.x, 0),
            max(scaled.y, 0),
            max(scaled.z, 0)
        )
        let numerator = exposed * (acesA * exposed + SIMD3<Float>(repeating: acesB))
        let denominator = exposed * (acesC * exposed + SIMD3<Float>(repeating: acesD))
            + SIMD3<Float>(repeating: acesE)
        let mapped = simd_clamp(numerator / denominator, .zero, SIMD3<Float>(repeating: 1))
        let inverseGamma = 1 / displayGamma
        return SIMD3<Float>(
            pow(mapped.x, inverseGamma),
            pow(mapped.y, inverseGamma),
            pow(mapped.z, inverseGamma)
        )
    }
}
