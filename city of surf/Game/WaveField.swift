//
//  WaveField.swift
//  city of surf
//
//  LOCKED framing preset with ChaseCamera — MUST match flood_displace() in Shaders.metal.
//
//  Do NOT raise crestShift without also widening faceWidth and keeping
//  ChaseCamera.eyeOffset.z > -crestShift (camera ahead of the lip).
//  Short face + large crestShift → flat canal. Cam in lip + steep face → cyan wall.
//
//  Preset: amp 4.5 / face 22 / steep 0.55 / crestShift 3.2
//  → surfer z=0 ≈ 3.3 m mid-face; crest ≈ 5.1 m; film ahead ≈ 0.
//

import simd

struct WaveField {
    /// Locked with ChaseCamera — readable height, not a FOV-eating wall.
    var amplitude: Float = 4.5
    /// Long face = gentle visible slope (do not shrink without moving the camera).
    var faceWidth: Float = 22.0
    var speed: Float = 16.0
    /// Soft enough that the face never fills the screen as a cyan slab.
    var steepness: Float = 0.55
    var direction: SIMD2<Float> = SIMD2(0, 1)
    var rippleAmplitude: Float = 0.35
    var rippleLength: Float = 6.0
    /// Crest lip at z≈-3.2. Camera eyeOffset.z must stay ahead (e.g. -2.2).
    var crestShift: Float = 3.2

    var wavelength: Float {
        get { faceWidth }
        set { faceWidth = newValue }
    }

    private func relativeZ(_ z: Float, scrollZ: Float) -> Float {
        z + scrollZ + crestShift
    }

    private func floodBody(_ rz: Float) -> Float {
        let w = max(faceWidth, 0.5)
        return 0.5 * (1.0 - tanh(rz / (w * 0.30)))
    }

    private func crestLip(_ rz: Float) -> Float {
        let sigma = max(faceWidth * 0.18, 1.0)
        return exp(-(rz * rz) / (2.0 * sigma * sigma))
    }

    /// Mirror of flood_displace() in Shaders.metal.
    func displacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let w = max(faceWidth, 0.5)
        let sigma = max(w * 0.18, 1.0)
        let a = amplitude
        let q = steepness

        let body = floodBody(rz)
        let lip = crestLip(rz)

        var d = SIMD3<Float>(0, 0, 0)

        // Bore + crest lip (softer throw than the cyan-wall builds).
        d.y = a * (0.82 * body + 0.90 * q * lip)

        let pinch = (rz / sigma) * lip
        d.z -= q * sigma * 0.55 * pinch

        d.z += q * a * 0.10 * lip * lip
        d.y += q * a * 0.16 * lip * lip

        let wall = smoothstepf(4.5, 8.5, abs(x))
        d.y += a * 0.10 * wall * body

        let swellPhase = rz * (2.0 * Float.pi / 24.0) - time * 1.1
        d.y += a * 0.09 * body * sin(swellPhase)

        let rk = (2.0 * Float.pi) / max(rippleLength, 0.001)
        let chopAmp = rippleAmplitude * (0.25 + 0.75 * body)
        let p1 = rk * (x * 0.8 + rz * 0.6) - time * 3.1
        let p2 = rk * 0.53 * (x * -1.7 + rz * 1.3) - time * 2.3 + 1.7
        let p3 = rk * 1.90 * (x * 2.6 + rz * -0.4) - time * 4.7 + 4.1
        d.y += chopAmp * (0.50 * sin(p1) + 0.35 * sin(p2) + 0.15 * sin(p3))
        d.x += chopAmp * 0.30 * cos(p1)

        return d
    }

    func foam(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let w = max(faceWidth, 0.5)
        let sigma = max(w * 0.18, 1.0)
        let body = floodBody(rz)
        let lip = crestLip(rz)
        let dpinch = (1.0 - (rz * rz) / (sigma * sigma)) * lip / sigma
        let jac = 1.0 - steepness * sigma * 0.55 * dpinch
        let faceMask = body * (1.0 - body) * 4.0
        return min(max(1.50 * lip + 0.42 * faceMask + max(0.5 - jac, 0) * 1.0, 0), 1)
    }

    func surfaceDisplacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        var baseZ = z
        for _ in 0..<2 {
            let d = displacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
            baseZ = z - d.z
        }
        let d = displacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
        return SIMD3(d.x, d.y, baseZ + d.z - z)
    }

    func height(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        surfaceDisplacement(x: x, z: z, time: time, scrollZ: scrollZ).y
    }

    func normal(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let eps: Float = 0.30
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
