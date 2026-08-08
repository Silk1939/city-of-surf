//
//  Camera.swift
//  city of surf
//
//  LOCKED with WaveField framing preset:
//    crestShift 3.2 → lip at z≈-3.2
//    eyeOffset.z -2.2 → eye AHEAD of lip (must stay > -crestShift)
//    look ahead down-canyon — never skim into the face normal (cyan wall).
//

import simd

struct ChaseCamera {
    /// Co-scaled with WaveField amp≈4.5 / crestShift≈3.2. Eye-Z must stay > -crestShift.
    var eyeOffset = SIMD3<Float>(0, 5.2, -2.2)
    /// Canyon ahead, slight down — sells the descending face without FOV-eating wall.
    var lookAhead = SIMD3<Float>(0, 0.4, 10.0)
    var smoothEye = SIMD3<Float>(0, 10, -4)
    var fovDegrees: Float = 68
    var nearZ: Float = 0.12
    var farZ: Float = 320
    private var shakeOffset = SIMD3<Float>(repeating: 0)
    private var initialized = false
    private var impulse = SIMD3<Float>.zero
    private var rollBias: Float = 0
    private var speedFovBoost: Float = 0

    mutating func invalidate() {
        initialized = false
        impulse = .zero
        rollBias = 0
        speedFovBoost = 0
    }

    mutating func addImpulse(_ v: SIMD3<Float>) {
        let capped = SIMD3(
            max(-0.85, min(0.85, v.x)),
            max(-0.85, min(0.85, v.y)),
            max(-0.85, min(0.85, v.z))
        )
        impulse += capped
        impulse = SIMD3(
            max(-1.3, min(1.3, impulse.x)),
            max(-1.3, min(1.3, impulse.y)),
            max(-1.3, min(1.3, impulse.z))
        )
    }

    mutating func update(
        follow target: SIMD3<Float>,
        waveHeight: Float,
        eyeWaterHeight: Float,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        // Stay above local face water; clearance matches locked preset.
        let clearance: Float = 2.2
        desired.y = max(waveHeight + eyeOffset.y, eyeWaterHeight + clearance)
        desired.x += lean * 1.2
        desired.y += shake * 0.8
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 9)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 8)
        smoothEye += (desired - smoothEye) * blend
        let minEyeY = eyeWaterHeight + clearance
        if smoothEye.y < minEyeY {
            smoothEye.y = minEyeY
        }

        let targetRoll = lean * 0.04
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 5.5)
        let speedT = saturate((speed - 17) / 17)
        speedFovBoost += (speedT * 4.0 - speedFovBoost) * min(1, deltaTime * 2.6)
        fovDegrees = 68 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake * 0.45
            shakeOffset = SIMD3(
                Float.random(in: -0.12...0.12) * s,
                Float.random(in: -0.09...0.09) * s,
                Float.random(in: -0.07...0.07) * s
            )
        } else {
            shakeOffset *= 0.65
        }
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = target + lookAhead + shakeOffset * 0.2
        var view = Math.lookAt(eye: eye, target: look, up: SIMD3(0, 1, 0))
        if abs(rollBias) > 0.0001 {
            view = Math.rotation(radians: rollBias, axis: SIMD3(0, 0, 1)) * view
        }
        return view
    }

    func projectionMatrix(aspect: Float) -> matrix_float4x4 {
        Math.perspective(fovyRadians: Math.radians(fovDegrees), aspectRatio: aspect, nearZ: nearZ, farZ: farZ)
    }
}

extension ChaseCamera {

    /// Einziger Ort, an dem die Kamera pro Frame nachgeführt wird.
    ///
    /// Renderer und Test-Harness rufen exakt diese Funktion. Sonst würde der
    /// Harness eine Kamera messen, die es im Spiel gar nicht gibt — dieselbe Falle
    /// wie ein Höhenfeld, das CPU und Shader getrennt berechnen.
    mutating func follow(
        surfer: SurferController,
        wave: WaveField,
        time: Float,
        scrollZ: Float,
        shake: Float,
        speed: Float,
        deltaTime: Float
    ) {
        let waveY = wave.height(
            x: surfer.x,
            z: surfer.position.z,
            time: time,
            scrollZ: scrollZ
        )
        // Sample water under the chase eye so we never bury the camera in the crest.
        let eyeZ = surfer.position.z + eyeOffset.z
        let eyeX = surfer.position.x + surfer.lean * 1.35
        let eyeWaterY = wave.height(x: eyeX, z: eyeZ, time: time, scrollZ: scrollZ)
        update(
            follow: surfer.position,
            waveHeight: waveY,
            eyeWaterHeight: eyeWaterY,
            lean: surfer.lean,
            shake: shake,
            speed: speed,
            deltaTime: deltaTime
        )
    }
}
