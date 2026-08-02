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
    static let laneXs: [Float] = [-3.4, 0, 3.4]
    static let maxX: Float = 5.8
    static let jumpDuration: Float = 0.52
    static let jumpHeight: Float = 2.6
    static let duckDuration: Float = 0.38
    static let standingHeight: Float = 1.55

    var x: Float = 0
    var targetX: Float = 0
    var pose: SurferPose = .standing
    var poseTimer: Float = 0
    var position: SIMD3<Float> = .zero
    var radius: Float = 0.5
    var lean: Float = 0

    var currentHeight: Float {
        pose == .ducking ? Self.standingHeight * 0.42 : Self.standingHeight
    }

    mutating func setTargetX(_ value: Float) {
        targetX = max(-Self.maxX, min(Self.maxX, value))
    }

    mutating func jump() {
        guard pose == .standing else { return }
        pose = .jumping
        poseTimer = Self.jumpDuration
    }

    mutating func duck() {
        guard pose == .standing else { return }
        pose = .ducking
        poseTimer = Self.duckDuration
    }

    mutating func update(deltaTime: Float, wave: WaveField, time: Float, scrollZ: Float) {
        let follow = min(1, deltaTime * 16)
        let prevX = x
        x += (targetX - x) * follow
        let vx = (x - prevX) / max(deltaTime, 0.0001)
        lean += ((vx / 14.0) - lean) * min(1, deltaTime * 10)
        lean = max(-1, min(1, lean))

        if pose != .standing {
            poseTimer -= deltaTime
            if poseTimer <= 0 {
                pose = .standing
                poseTimer = 0
            }
        }

        let baseZ: Float = 0
        let sample = wave.displacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
        var y = sample.y + 0.4
        let h = currentHeight

        if pose == .jumping {
            let t = 1 - (poseTimer / Self.jumpDuration)
            y += sin(t * .pi) * Self.jumpHeight
        } else if pose == .ducking {
            y -= 0.3
        }

        position = SIMD3(x + sample.x * 0.15, y + h * 0.5, baseZ + sample.z * 0.1)
    }

    var collisionCenter: SIMD3<Float> { position }
    var collisionRadius: Float {
        pose == .ducking ? radius * 0.85 : radius
    }
    var collisionHalfHeight: Float { currentHeight * 0.5 }
}
