//
//  Camera.swift
//  city of surf
//
//  Hero flood framing: sit HIGH above the crest pile-up and look DOWN the face
//  at the surfer — never skim horizontally into the wall (that reads as a flat cyan slab).
//

import simd

struct ChaseCamera {
    /// High above crest, modest pullback — crestShift≈4 → lip near z≈-4.
    var eyeOffset = SIMD3<Float>(0, 13.5, -8.0)
    /// Look down at the rider / face (negative Y), not into the sun disk.
    var lookAhead = SIMD3<Float>(0, -2.2, 5.5)
    var smoothEye = SIMD3<Float>(0, 18, -10)
    var fovDegrees: Float = 62
    var nearZ: Float = 0.15
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
            max(-0.8, min(0.8, v.x)),
            max(-0.8, min(0.8, v.y)),
            max(-0.8, min(0.8, v.z))
        )
        impulse += capped
        impulse = SIMD3(
            max(-1.2, min(1.2, impulse.x)),
            max(-1.2, min(1.2, impulse.y)),
            max(-1.2, min(1.2, impulse.z))
        )
    }

    mutating func update(
        follow target: SIMD3<Float>,
        waveHeight: Float,
        /// Water height under the intended eye XZ — stay clearly above the lip.
        eyeWaterHeight: Float,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        // Always clear the crest by a wide margin — hero shot from above the lip.
        let clearance: Float = 5.5
        let fromTarget = waveHeight + eyeOffset.y
        let fromEye = eyeWaterHeight + clearance
        desired.y = max(fromTarget, fromEye)
        desired.x += lean * 1.1
        desired.y += shake * 0.8
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 9)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 7.5)
        smoothEye += (desired - smoothEye) * blend
        let minEyeY = eyeWaterHeight + clearance
        if smoothEye.y < minEyeY {
            smoothEye.y = minEyeY
        }

        let targetRoll = lean * 0.035
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 5)
        let speedT = saturate((speed - 17) / 17)
        let targetBoost: Float = speedT * 3.5
        speedFovBoost += (targetBoost - speedFovBoost) * min(1, deltaTime * 2.5)
        fovDegrees = 62 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake * 0.45
            shakeOffset = SIMD3(
                Float.random(in: -0.12...0.12) * s,
                Float.random(in: -0.1...0.1) * s,
                Float.random(in: -0.08...0.08) * s
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
