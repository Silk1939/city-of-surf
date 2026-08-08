//
//  SurferController.swift
//  city of surf
//

import simd

enum SurferPose {
    case standing
    case jumping
    case ducking
}

struct SurferController {
    static let maxX: Float = 6.2
    static let jumpDuration: Float = 0.48
    static let jumpHeight: Float = 3.1
    static let duckDuration: Float = 0.50
    static let standingHeight: Float = 1.55
    static let queueWindow: Float = 0.14

    var x: Float = 0
    var targetX: Float = 0
    var pose: SurferPose = .standing
    var poseTimer: Float = 0
    var position: SIMD3<Float> = .zero
    var radius: Float = 0.5
    var lean: Float = 0
    /// Buffered vertical action while jump/duck is playing.
    private var queuedPose: SurferPose?
    private var queueTimer: Float = 0

    var currentHeight: Float {
        pose == .ducking ? Self.standingHeight * 0.42 : Self.standingHeight
    }

    mutating func setTargetX(_ value: Float) {
        let clamped = max(-Self.maxX, min(Self.maxX, value))
        targetX = clamped
        // Near-instant response while dragging — no sluggish drift.
        x = clamped
    }

    mutating func jump() {
        if pose == .standing {
            pose = .jumping
            poseTimer = Self.jumpDuration
            queuedPose = nil
            queueTimer = 0
            return
        }
        // Jump can cancel a duck mid-window for snappier feel.
        if pose == .ducking {
            pose = .jumping
            poseTimer = Self.jumpDuration
            queuedPose = nil
            queueTimer = 0
            return
        }
        queuedPose = .jumping
        queueTimer = Self.queueWindow
    }

    mutating func duck() {
        if pose == .standing {
            pose = .ducking
            poseTimer = Self.duckDuration
            queuedPose = nil
            queueTimer = 0
            return
        }
        queuedPose = .ducking
        queueTimer = Self.queueWindow
    }

    mutating func update(deltaTime: Float, wave: WaveField, time: Float, scrollZ: Float) {
        // Keep a tiny ease only if something else nudged target (flick residual).
        let follow = min(1, deltaTime * 28)
        let prevX = x
        x += (targetX - x) * follow
        let vx = (x - prevX) / max(deltaTime, 0.0001)
        lean += ((vx / 18.0) - lean) * min(1, deltaTime * 14)
        lean = max(-1, min(1, lean))

        if pose != .standing {
            poseTimer -= deltaTime
            if poseTimer <= 0 {
                pose = .standing
                poseTimer = 0
                if let next = queuedPose, queueTimer > 0 {
                    if next == .jumping {
                        pose = .jumping
                        poseTimer = Self.jumpDuration
                    } else if next == .ducking {
                        pose = .ducking
                        poseTimer = Self.duckDuration
                    }
                    queuedPose = nil
                    queueTimer = 0
                }
            }
        }
        if queueTimer > 0 {
            queueTimer = max(0, queueTimer - deltaTime)
            if queueTimer == 0 { queuedPose = nil }
        }

        let baseZ: Float = 0
        // Visual surface (pinch inverted) — match GPU Gerstner flood so surfer sits on the face.
        let sample = wave.surfaceDisplacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
        var y = sample.y + 0.4
        let h = currentHeight

        if pose == .jumping {
            let t = 1 - (poseTimer / Self.jumpDuration)
            y += sin(t * .pi) * Self.jumpHeight
        } else if pose == .ducking {
            y -= 0.3
        }

        position = SIMD3(x + sample.x, y + h * 0.5, baseZ + sample.z)
    }

    var collisionCenter: SIMD3<Float> { position }
    var collisionRadius: Float {
        pose == .ducking ? radius * 0.85 : radius
    }
    var collisionHalfHeight: Float { currentHeight * 0.5 }
}
