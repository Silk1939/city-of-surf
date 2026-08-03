//
//  Camera.swift
//  city of surf
//
//  Stabilization: snap smoothEye on first/reset frame so we never start underwater.
//

import simd

struct ChaseCamera {
    var eyeOffset = SIMD3<Float>(0, 9.5, -14.0)
    var lookAhead = SIMD3<Float>(0, 3.5, 18)
    var smoothEye = SIMD3<Float>(0, 7, -14)
    var fovDegrees: Float = 72
    var nearZ: Float = 0.1
    var farZ: Float = 260
    private var shakeOffset = SIMD3<Float>(repeating: 0)
    private var initialized = false

    mutating func invalidate() {
        initialized = false
    }

    mutating func update(follow target: SIMD3<Float>, lean: Float, shake: Float, deltaTime: Float) {
        var desired = target + eyeOffset
        desired.x += lean * 1.2
        // Mild wipeout lift — never enough to fight the snap-above-water rule.
        desired.y += shake * 1.5

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 7)
        smoothEye += (desired - smoothEye) * blend

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

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = target + lookAhead + shakeOffset * 0.35
        return Math.lookAt(eye: eye, target: look, up: SIMD3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> matrix_float4x4 {
        Math.perspective(fovyRadians: Math.radians(fovDegrees), aspectRatio: aspect, nearZ: nearZ, farZ: farZ)
    }
}
