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
