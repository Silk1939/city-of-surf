//
//  WaveField.swift
//  city of surf
//
//  Single flood-front height field — MUST match flood_displace() in Shaders.metal.
//
//  Gerstner-style crest pinch (steep concave face + plunging lip), canyon-wall
//  pile-up, multi-octave chop + secondary swell. `height` / `surfaceDisplacement`
//  invert the horizontal pinch so gameplay sits on the *visual* surface.
//
//  Amplitude≈8 with ChaseCamera co-scaled — wave is the star, camera frames the face.
//

import simd

struct WaveField {
    /// Tall flood crest — keep in sync with ChaseCamera eyeOffset / lookAhead.
    var amplitude: Float = 7.0
    var faceWidth: Float = 14.0
    var speed: Float = 16.0
    /// Soft enough that the face reads as a slope, not a camera-eating wall.
    var steepness: Float = 0.78
    var direction: SIMD2<Float> = SIMD2(0, 1)
    /// Visible travelling chop on the face.
    var rippleAmplitude: Float = 0.48
    var rippleLength: Float = 5.5
    /// Surfer on the front face; crest rises behind — keep eyeOffset.z behind this.
    var crestShift: Float = 3.4

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
        let sigma = max(faceWidth * 0.20, 1.2)
        return exp(-(rz * rz) / (2.0 * sigma * sigma))
    }

    /// Mirror of flood_displace() in Shaders.metal.
    func displacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let w = max(faceWidth, 0.5)
        let sigma = max(w * 0.20, 1.2)
        let a = amplitude
        let q = steepness

        let body = floodBody(rz)
        let lip = crestLip(rz)

        var d = SIMD3<Float>(0, 0, 0)

        // Base bore + raised crest
        d.y = a * (0.85 * body + 0.68 * q * lip)

        // Gerstner-style pinch toward the crest
        let pinch = (rz / sigma) * lip
        d.z -= q * sigma * 0.95 * pinch

        // Plunging throw at the very top of the lip
        d.z += q * a * 0.20 * lip * lip
        d.y += q * a * 0.12 * lip * lip

        // Pile-up against the canyon walls
        let wall = smoothstepf(4.5, 8.5, abs(x))
        d.y += a * 0.18 * wall * body

        // Secondary long swell (synced with Shaders.metal) — readable volume, not flicker
        let swellPhase = rz * (2.0 * Float.pi / 28.0) - time * 1.35
        d.y += a * 0.14 * body * sin(swellPhase)
        d.z += a * 0.04 * body * cos(swellPhase)

        // Cross-chop (different direction) — mid wavelength
        let crossPhase = (x * 0.22 + rz * 0.08) - time * 1.9
        d.y += a * 0.06 * body * sin(crossPhase)

        // Three octaves of travelling chop
        let rk = (2.0 * Float.pi) / max(rippleLength, 0.001)
        let chopAmp = rippleAmplitude * (0.30 + 0.70 * body)
        let p1 = rk * (x * 0.8 + rz * 0.6) - time * 3.1
        let p2 = rk * 0.53 * (x * -1.7 + rz * 1.3) - time * 2.3 + 1.7
        let p3 = rk * 1.90 * (x * 2.6 + rz * -0.4) - time * 4.7 + 4.1
        d.y += chopAmp * (0.50 * sin(p1) + 0.35 * sin(p2) + 0.15 * sin(p3))
        d.x += chopAmp * 0.45 * cos(p1)

        return d
    }

    /// Foam intensity 0...1 (crest lip, face whitewater, Jacobian compression).
    func foam(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let w = max(faceWidth, 0.5)
        let sigma = max(w * 0.20, 1.2)
        let body = floodBody(rz)
        let lip = crestLip(rz)
        let dpinch = (1.0 - (rz * rz) / (sigma * sigma)) * lip / sigma
        let jac = 1.0 - steepness * sigma * 0.95 * dpinch
        let faceMask = body * (1.0 - body) * 4.0
        return min(max(1.35 * lip + 0.50 * faceMask + max(0.6 - jac, 0) * 1.3, 0), 1)
    }

    /// Displacement whose displaced Z lands on `z` (visual surface).
    /// Use this for surfer / props / coins so they ride the pinched mesh.
    func surfaceDisplacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        var baseZ = z
        for _ in 0..<2 {
            let d = displacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
            baseZ = z - d.z
        }
        let d = displacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
        return SIMD3(d.x, d.y, baseZ + d.z - z)
    }

    /// Height of the *visual* surface at world (x, z).
    func height(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        surfaceDisplacement(x: x, z: z, time: time, scrollZ: scrollZ).y
    }

    func normal(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let eps: Float = 0.35
        let hL = height(x: x - eps, z: z, time: time, scrollZ: scrollZ)
        let hR = height(x: x + eps, z: z, time: time, scrollZ: scrollZ)
        let hD = height(x: x, z: z - eps, time: time, scrollZ: scrollZ)
        let hU = height(x: x, z: z + eps, time: time, scrollZ: scrollZ)
        return simd_normalize(SIMD3(hL - hR, 2.0 * eps, hD - hU))
    }

    private func smoothstepf(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
