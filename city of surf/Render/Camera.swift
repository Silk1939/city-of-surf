//
//  Camera.swift
//  city of surf
//

import simd

enum ChaseCameraTuning {
    static let eyeOffset = SIMD3<Float>(0, 4.5, -9.0)
    static let lookAheadDistance: Float = 12
    static let lookTargetHeight: Float = 2.0
    static let steeringLookOffset: Float = 2.5
    static let positionResponse: Float = 6
    static let lookResponse: Float = 8
    static let baseFovDegrees: Float = 60
    static let maxFovIncreaseDegrees: Float = 6
    static let baseSpeed: Float = 17
    static let maxSpeed: Float = 32
    static let fovResponse: Float = 5
    static let nearZ: Float = 0.1
    static let farZ: Float = 260
}

struct ChaseCamera {
    private(set) var smoothEye = SIMD3<Float>.zero
    private(set) var smoothLookTarget = SIMD3<Float>.zero
    private(set) var smoothFovDegrees = ChaseCameraTuning.baseFovDegrees
    private var hasSnappedToTarget = false

    mutating func update(
        follow target: SIMD3<Float>,
        steering: Float,
        speed: Float,
        deltaTime: Float
    ) {
        let desiredEye = target + ChaseCameraTuning.eyeOffset
        let desiredLookTarget = target + SIMD3<Float>(
            steering * ChaseCameraTuning.steeringLookOffset,
            ChaseCameraTuning.lookTargetHeight,
            ChaseCameraTuning.lookAheadDistance
        )
        let speedRange = ChaseCameraTuning.maxSpeed - ChaseCameraTuning.baseSpeed
        let speedFactor = simd_clamp(
            (speed - ChaseCameraTuning.baseSpeed) / speedRange,
            0,
            1
        )
        let desiredFov = ChaseCameraTuning.baseFovDegrees
            + speedFactor * ChaseCameraTuning.maxFovIncreaseDegrees

        guard hasSnappedToTarget else {
            smoothEye = desiredEye
            smoothLookTarget = desiredLookTarget
            smoothFovDegrees = desiredFov
            hasSnappedToTarget = true
            return
        }

        smoothEye += (desiredEye - smoothEye)
            * smoothingFactor(response: ChaseCameraTuning.positionResponse, deltaTime: deltaTime)
        smoothLookTarget += (desiredLookTarget - smoothLookTarget)
            * smoothingFactor(response: ChaseCameraTuning.lookResponse, deltaTime: deltaTime)
        smoothFovDegrees += (desiredFov - smoothFovDegrees)
            * smoothingFactor(response: ChaseCameraTuning.fovResponse, deltaTime: deltaTime)
    }

    func viewMatrix() -> matrix_float4x4 {
        Math.lookAt(eye: smoothEye, target: smoothLookTarget, up: SIMD3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> matrix_float4x4 {
        Math.perspective(
            fovyRadians: Math.radians(smoothFovDegrees),
            aspectRatio: aspect,
            nearZ: ChaseCameraTuning.nearZ,
            farZ: ChaseCameraTuning.farZ
        )
    }

    private func smoothingFactor(response: Float, deltaTime: Float) -> Float {
        1 - exp(-response * max(deltaTime, 0))
    }
}
