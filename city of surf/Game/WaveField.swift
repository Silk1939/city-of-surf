//
//  WaveField.swift
//  city of surf
//
//  Single flood-front height field — must match Shaders.metal.
//
//  Stabilization baseline (2026-08-03): keep camera / city / sky readable.
//  Giant art-ref wave comes later with matching camera + sky steps.
//

import simd

struct WaveField {
    var amplitude: Float = 2.4
    var faceWidth: Float = 9.0
    var speed: Float = 16.0
    var steepness: Float = 0.55
    var direction: SIMD2<Float> = SIMD2(0, 1)
    var rippleAmplitude: Float = 0.12
    var rippleLength: Float = 5.0
    /// Crest alignment relative to surfer; 0 = crest at player Z.
    var crestShift: Float = 0

    var wavelength: Float {
        get { faceWidth }
        set { faceWidth = newValue }
    }

    private func relativeZ(_ z: Float, scrollZ: Float) -> Float {
        z + scrollZ + crestShift
    }

    private func floodBody(_ rz: Float) -> Float {
        let w = max(faceWidth, 0.5)
        return 0.5 * (1.0 - tanh(rz / (w * 0.35)))
    }

    private func crestLip(_ rz: Float) -> Float {
        let sigma = max(faceWidth * 0.18, 1.2)
        return exp(-(rz * rz) / (2.0 * sigma * sigma))
    }

    func displacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let body = floodBody(rz)
        let lip = crestLip(rz)
        let a = amplitude

        var y = a * (body * 0.88 + lip * steepness * 0.72)
        let faceMask = body * (1.0 - body) * 4.0
        let curl = faceMask * a * 0.42 * steepness
        let dz = -curl
        var dx: Float = 0

        let rk = (2.0 * Float.pi) / max(rippleLength, 0.001)
        let chop = rippleAmplitude * sin(rk * x * 1.3 + rk * rz * 0.7 - time * 4.0)
            * (0.35 + 0.65 * body)
        y += chop
        dx += rippleAmplitude * 0.15 * cos(rk * x - time * 3.0) * body

        return SIMD3(dx, y, dz)
    }

    func height(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        displacement(x: x, z: z, time: time, scrollZ: scrollZ).y
    }

    func normal(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let eps: Float = 0.35
        let hL = height(x: x - eps, z: z, time: time, scrollZ: scrollZ)
        let hR = height(x: x + eps, z: z, time: time, scrollZ: scrollZ)
        let hD = height(x: x, z: z - eps, time: time, scrollZ: scrollZ)
        let hU = height(x: x, z: z + eps, time: time, scrollZ: scrollZ)
        return simd_normalize(SIMD3(hL - hR, 2.0 * eps, hD - hU))
    }
}
