//
//  Camera.swift
//  city of surf
//
//  Stabilization: snap smoothEye on first/reset frame so we never start underwater.
//

import simd

struct ChaseCamera {
    /// Co-scaled with WaveField.amplitude≈5.2 — stays above crest on snap.
    var eyeOffset = SIMD3<Float>(0, 14.5, -18.0)
    var lookAhead = SIMD3<Float>(0, 5.5, 22)
    var smoothEye = SIMD3<Float>(0, 12, -18)
    var fovDegrees: Float = 72
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
        impulse += v
    }

    mutating func update(
        follow target: SIMD3<Float>,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        desired.x += lean * 1.4
        // Mild wipeout lift — never enough to fight the snap-above-water rule.
        desired.y += shake * 1.5
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 8)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 7)
        smoothEye += (desired - smoothEye) * blend

        // Subtle carve roll + speed FOV window (presentation only).
        let targetRoll = lean * 0.045
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 6)
        let speedT = saturate((speed - 17) / 17)
        let targetBoost: Float = speedT * 6
        speedFovBoost += (targetBoost - speedFovBoost) * min(1, deltaTime * 3)
        fovDegrees = 72 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake
            shakeOffset = SIMD3(
                Float.random(in: -0.35...0.35) * s,
                Float.random(in: -0.25...0.25) * s,
                Float.random(in: -0.2...0.2) * s
            )
        } else {
            shakeOffset *= 0.7
        }
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = target + lookAhead + shakeOffset * 0.35
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
