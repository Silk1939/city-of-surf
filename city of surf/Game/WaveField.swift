//
//  WaveField.swift
//  city of surf
//
//  Flood-front macro shape + 4 Gerstner layers — must match Shaders.metal.
//

import simd

struct WaveField {
    var amplitude: Float = 5.5
    var faceWidth: Float = 14.0
    var speed: Float = 16.0
    var steepness: Float = 0.75
    var direction: SIMD2<Float> = SIMD2(0, 1)
    var rippleAmplitude: Float = 0.12
    var rippleLength: Float = 5.5

    var wavelength: Float {
        get { faceWidth }
        set { faceWidth = newValue }
    }

    private func relativeZ(_ z: Float, scrollZ: Float) -> Float {
        z + scrollZ
    }

    private func floodBody(_ rz: Float) -> Float {
        let w = max(faceWidth, 0.5)
        return 0.5 * (1.0 - tanh(rz / (w * 0.35)))
    }

    private func crestLip(_ rz: Float) -> Float {
        let sigma = max(faceWidth * 0.18, 1.2)
        return exp(-(rz * rz) / (2.0 * sigma * sigma))
    }

    /// Must stay in sync with `gerstner_displace` in Shaders.metal.
    private func gerstnerContribution(
        x: Float,
        z: Float,
        time: Float,
        bodyMask: Float
    ) -> (displacement: SIMD3<Float>, foam: Float, normalDeriv: (dx: SIMD3<Float>, dz: SIMD3<Float>)) {
        var displacement = SIMD3<Float>.zero
        var foam: Float = 0
        var ddx = SIMD3<Float>(1, 0, 0)
        var ddz = SIMD3<Float>(0, 0, 1)
        let waveCount = Float(ArtDirection.Water.gerstner.count)

        for wave in ArtDirection.Water.gerstner {
            let dir = wave.dir
            let k = (2.0 * Float.pi) / max(wave.wavelength, 0.001)
            let a = wave.amplitude * (0.35 + 0.65 * bodyMask)
            let q = wave.steepness / max(k * a * waveCount, 0.001)
            let phase = k * (dir.x * x + dir.y * z) - wave.speed * k * time
            let s = sin(phase)
            let c = cos(phase)
            let qa = q * a

            displacement.x += dir.x * qa * c
            displacement.y += a * s
            displacement.z += dir.y * qa * c

            // Analytic Gerstner tangent basis (GPU Gems style).
            ddx.x -= dir.x * dir.x * q * a * k * s
            ddx.y += dir.x * a * k * c
            ddx.z -= dir.x * dir.y * q * a * k * s

            ddz.x -= dir.x * dir.y * q * a * k * s
            ddz.y += dir.y * a * k * c
            ddz.z -= dir.y * dir.y * q * a * k * s

            foam += saturate(1.2 * q * a * k * abs(s)) * bodyMask
        }

        return (displacement, saturate(foam), (ddx, ddz))
    }

    func displacement(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let body = floodBody(rz)
        let lip = crestLip(rz)
        let a = amplitude

        var y = a * (body * 0.82 + lip * steepness * 0.55)
        let faceMask = body * (1.0 - body) * 4.0
        let curl = faceMask * a * 0.35 * steepness
        let dz = -curl
        var dx: Float = 0

        let gerstner = gerstnerContribution(x: x, z: z, time: time, bodyMask: body)
        dx += gerstner.displacement.x
        y += gerstner.displacement.y
        return SIMD3(dx, y, dz + gerstner.displacement.z)
    }

    func height(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        displacement(x: x, z: z, time: time, scrollZ: scrollZ).y
    }

    func normal(x: Float, z: Float, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let body = floodBody(rz)
        let gerstner = gerstnerContribution(x: x, z: z, time: time, bodyMask: body)

        let eps: Float = 0.35
        let floodY: (Float, Float) -> Float = { sampleX, sampleZ in
            let sampleRZ = relativeZ(sampleZ, scrollZ: scrollZ)
            let sampleBody = floodBody(sampleRZ)
            let sampleLip = crestLip(sampleRZ)
            return amplitude * (sampleBody * 0.82 + sampleLip * steepness * 0.55)
        }
        let slopeX = (floodY(x + eps, z) - floodY(x - eps, z)) / (2 * eps)
        let slopeZ = (floodY(x, z + eps) - floodY(x, z - eps)) / (2 * eps)
        let tx = SIMD3(
            gerstner.normalDeriv.dx.x,
            gerstner.normalDeriv.dx.y + slopeX,
            gerstner.normalDeriv.dx.z
        )
        let tz = SIMD3(
            gerstner.normalDeriv.dz.x,
            gerstner.normalDeriv.dz.y + slopeZ,
            gerstner.normalDeriv.dz.z
        )
        return simd_normalize(simd_cross(tz, tx))
    }

    func crestFoam(x: Float, z: Float, time: Float, scrollZ: Float) -> Float {
        let rz = relativeZ(z, scrollZ: scrollZ)
        let body = floodBody(rz)
        let lip = crestLip(rz)
        let faceMask = body * (1.0 - body) * 4.0
        let gerstner = gerstnerContribution(x: x, z: z, time: time, bodyMask: body)
        return saturate(lip * 0.85 + faceMask * 0.45 + gerstner.foam * 0.75)
    }

    func fillGerstnerUniforms(
        _ packedDirAmpWave: inout (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>),
        _ packedSteepSpeed: inout (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    ) {
        let waves = ArtDirection.Water.gerstner
        func pack(_ index: Int) -> (SIMD4<Float>, SIMD4<Float>) {
            let wave = waves[index]
            return (
                SIMD4(wave.dir.x, wave.dir.y, wave.amplitude, wave.wavelength),
                SIMD4(wave.steepness, wave.speed, 0, 0)
            )
        }
        let w0 = pack(0)
        let w1 = pack(1)
        let w2 = pack(2)
        let w3 = pack(3)
        packedDirAmpWave = (w0.0, w1.0, w2.0, w3.0)
        packedSteepSpeed = (w0.1, w1.1, w2.1, w3.1)
    }
}
