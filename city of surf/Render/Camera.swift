//
//  Camera.swift
//  city of surf
//
//  Stabilization: snap smoothEye on first/reset frame so we never start underwater.
//  Crest framing: sit above local water, pull back so the flood face reads as a wall.
//

import simd

struct ChaseCamera {
    /// Co-scaled with WaveField.amplitude≈8 — pulled back to keep crest wall in frame.
    var eyeOffset = SIMD3<Float>(0, 7.2, -7.0)
    /// Look closer / slightly down so FOV catches the steep face behind the surfer.
    var lookAhead = SIMD3<Float>(0, 0.15, 4.8)
    var smoothEye = SIMD3<Float>(0, 14, -10)
    var fovDegrees: Float = 70
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
        // Soft clamp — avoid motion-sickness spikes.
        let capped = SIMD3(
            max(-1.2, min(1.2, v.x)),
            max(-1.2, min(1.2, v.y)),
            max(-1.2, min(1.2, v.z))
        )
        impulse += capped
        impulse = SIMD3(
            max(-1.8, min(1.8, impulse.x)),
            max(-1.8, min(1.8, impulse.y)),
            max(-1.8, min(1.8, impulse.z))
        )
    }

    mutating func update(
        follow target: SIMD3<Float>,
        waveHeight: Float,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        // Follow the water surface (not surfer head) so crest framing stays readable.
        desired.y = waveHeight + eyeOffset.y
        desired.x += lean * 1.55
        // Mild wipeout lift — never enough to fight the snap-above-water rule.
        desired.y += shake * 1.2
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 9)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        // Slightly softer lag than before — readable but not nauseating.
        let blend = min(1, deltaTime * 6.2)
        smoothEye += (desired - smoothEye) * blend

        // Subtle carve roll + speed FOV window (presentation only).
        let targetRoll = lean * 0.055
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 5.5)
        let speedT = saturate((speed - 17) / 17)
        let targetBoost: Float = speedT * 5.5
        speedFovBoost += (targetBoost - speedFovBoost) * min(1, deltaTime * 2.8)
        fovDegrees = 70 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake * 0.7
            shakeOffset = SIMD3(
                Float.random(in: -0.22...0.22) * s,
                Float.random(in: -0.16...0.16) * s,
                Float.random(in: -0.12...0.12) * s
            )
        } else {
            shakeOffset *= 0.65
        }
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = target + lookAhead + shakeOffset * 0.28
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
