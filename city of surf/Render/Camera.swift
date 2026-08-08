//
//  Camera.swift
//  city of surf
//
//  Stabilization: snap smoothEye on first/reset frame so we never start underwater.
//  Always clear local water at the eye — never sit inside the crest wall.
//

import simd

struct ChaseCamera {
    /// Behind + above the surfer, outside the crest pile-up (co-scaled with amp≈7).
    var eyeOffset = SIMD3<Float>(0, 9.0, -10.5)
    /// Look toward the rider / down-canyon — not up the face into a teal wall.
    var lookAhead = SIMD3<Float>(0, 1.4, 7.0)
    var smoothEye = SIMD3<Float>(0, 16, -12)
    var fovDegrees: Float = 68
    var nearZ: Float = 0.1
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
            max(-1.0, min(1.0, v.x)),
            max(-1.0, min(1.0, v.y)),
            max(-1.0, min(1.0, v.z))
        )
        impulse += capped
        impulse = SIMD3(
            max(-1.5, min(1.5, impulse.x)),
            max(-1.5, min(1.5, impulse.y)),
            max(-1.5, min(1.5, impulse.z))
        )
    }

    mutating func update(
        follow target: SIMD3<Float>,
        waveHeight: Float,
        /// Water height under the intended eye XZ — used to stay above the crest.
        eyeWaterHeight: Float,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        // Follow target water, but never dunk under local crest water at the eye.
        let clearance: Float = 3.8
        let fromTarget = waveHeight + eyeOffset.y
        let fromEye = eyeWaterHeight + clearance
        desired.y = max(fromTarget, fromEye)
        desired.x += lean * 1.35
        desired.y += shake * 1.0
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 9)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 7.0)
        smoothEye += (desired - smoothEye) * blend
        // Hard clamp each frame so lag never leaves us buried in the face.
        let minEyeY = eyeWaterHeight + clearance * 0.85
        if smoothEye.y < minEyeY {
            smoothEye.y = minEyeY
        }

        let targetRoll = lean * 0.04
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 5.5)
        let speedT = saturate((speed - 17) / 17)
        let targetBoost: Float = speedT * 4.5
        speedFovBoost += (targetBoost - speedFovBoost) * min(1, deltaTime * 2.8)
        fovDegrees = 68 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake * 0.55
            shakeOffset = SIMD3(
                Float.random(in: -0.16...0.16) * s,
                Float.random(in: -0.12...0.12) * s,
                Float.random(in: -0.1...0.1) * s
            )
        } else {
            shakeOffset *= 0.65
        }
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = target + lookAhead + shakeOffset * 0.25
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
