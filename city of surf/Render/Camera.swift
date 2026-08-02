//
//  Camera.swift
//  city of surf
//

import simd

struct ChaseCamera {
    var eyeOffset = SIMD3<Float>(0, 5.2, -9.5)
    var lookAhead = SIMD3<Float>(0, 1.8, 14)
    var smoothEye = SIMD3<Float>(0, 6, -10)
    var fovDegrees: Float = 68
    var nearZ: Float = 0.1
    var farZ: Float = 260

    mutating func update(follow target: SIMD3<Float>, lean: Float, deltaTime: Float) {
        var desired = target + eyeOffset
        desired.x += lean * 1.2
        let blend = min(1, deltaTime * 7)
        smoothEye += (desired - smoothEye) * blend
    }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        Math.lookAt(eye: smoothEye, target: target + lookAhead, up: SIMD3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> matrix_float4x4 {
        Math.perspective(fovyRadians: Math.radians(fovDegrees), aspectRatio: aspect, nearZ: nearZ, farZ: farZ)
    }
}
