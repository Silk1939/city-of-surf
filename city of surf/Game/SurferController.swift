//
//  SurferController.swift
//  city of surf
//
//  Kinematic surface ride: multi-point wave samples + damped spring buoyancy +
//  soft pitch/roll alignment. Not a full fluid sim — stable at 60 fps.
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

    /// Spring (1/s²) and damping (1/s) for vertical ride — soft, no jitter.
    static let buoyancySpring: Float = 52
    static let buoyancyDamp: Float = 14
    static let maxRideError: Float = 2.2

    var x: Float = 0
    var targetX: Float = 0
    var pose: SurferPose = .standing
    var poseTimer: Float = 0
    var position: SIMD3<Float> = .zero
    var radius: Float = 0.5
    var lean: Float = 0
    /// Board orientation following water (radians) — used by SurfboardVisual.
    var surfacePitch: Float = 0
    var surfaceRoll: Float = 0
    /// Lateral speed for spray / camera (m/s).
    private(set) var lateralSpeed: Float = 0
    /// Filtered board base Y (water contact), before jump offset.
    private var rideY: Float = 0
    private var rideVel: Float = 0
    private var rideInitialized = false
    /// Buffered vertical action while jump/duck is playing.
    private var queuedPose: SurferPose?
    private var queueTimer: Float = 0

    var currentHeight: Float {
        pose == .ducking ? Self.standingHeight * 0.42 : Self.standingHeight
    }

    /// 0…1 contact strength (0 when fully airborne mid-jump).
    var waterContact: Float {
        guard pose == .jumping else { return pose == .ducking ? 0.85 : 1.0 }
        let t = 1 - (poseTimer / Self.jumpDuration)
        // Leave / re-enter surface around takeoff and landing.
        if t < 0.12 { return 1 - t / 0.12 }
        if t > 0.78 { return (t - 0.78) / 0.22 }
        return 0
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
        let dt = max(deltaTime, 1.0 / 240.0)
        // Keep a tiny ease only if something else nudged target (flick residual).
        let follow = min(1, dt * 28)
        let prevX = x
        x += (targetX - x) * follow
        let vx = (x - prevX) / dt
        lateralSpeed = vx
        lean += ((vx / 18.0) - lean) * min(1, dt * 14)
        lean = max(-1, min(1, lean))

        if pose != .standing {
            poseTimer -= dt
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
            queueTimer = max(0, queueTimer - dt)
            if queueTimer == 0 { queuedPose = nil }
        }

        let baseZ: Float = 0
        // Multi-point samples under the board (nose / tail / rails).
        let halfW: Float = 0.42
        let halfL: Float = 0.55
        let sC = wave.surfaceDisplacement(x: x, z: baseZ, time: time, scrollZ: scrollZ)
        let hL = wave.height(x: x - halfW, z: baseZ, time: time, scrollZ: scrollZ)
        let hR = wave.height(x: x + halfW, z: baseZ, time: time, scrollZ: scrollZ)
        let hN = wave.height(x: x, z: baseZ + halfL, time: time, scrollZ: scrollZ)
        let hT = wave.height(x: x, z: baseZ - halfL, time: time, scrollZ: scrollZ)
        let avgH = (sC.y * 2.0 + hL + hR + hN + hT) / 6.0

        let targetRide = avgH + 0.36
        if !rideInitialized || !targetRide.isFinite {
            rideY = targetRide.isFinite ? targetRide : 0
            rideVel = 0
            rideInitialized = true
        }

        // Damped spring buoyancy — clamp runaway / NaN.
        var err = targetRide - rideY
        if !err.isFinite { err = 0 }
        err = max(-Self.maxRideError, min(Self.maxRideError, err))
        rideVel += err * Self.buoyancySpring * dt
        rideVel *= max(0, 1 - Self.buoyancyDamp * dt)
        if !rideVel.isFinite { rideVel = 0 }
        rideVel = max(-12, min(12, rideVel))
        rideY += rideVel * dt
        if abs(rideY - targetRide) > Self.maxRideError * 1.25 || !rideY.isFinite {
            rideY = targetRide
            rideVel = 0
        }

        // Soft pitch/roll from surface slope + carve lean.
        let targetPitch = atan2(hT - hN, halfL * 2.0)
        let targetRoll = atan2(hL - hR, halfW * 2.0) + lean * 0.38
        let pitchBlend = min(1, dt * 9)
        let rollBlend = min(1, dt * 11)
        surfacePitch += (sanitizeAngle(targetPitch) - surfacePitch) * pitchBlend
        surfaceRoll += (sanitizeAngle(targetRoll) - surfaceRoll) * rollBlend
        surfacePitch = max(-0.55, min(0.55, surfacePitch))
        surfaceRoll = max(-0.75, min(0.75, surfaceRoll))

        var y = rideY
        let h = currentHeight

        if pose == .jumping {
            let t = 1 - (poseTimer / Self.jumpDuration)
            y += sin(t * .pi) * Self.jumpHeight
            // While airborne, freeze spring so landing doesn't explode.
            if t > 0.15 && t < 0.78 {
                rideY = targetRide
                rideVel = 0
            }
        } else if pose == .ducking {
            y -= 0.3
        }

        if !y.isFinite { y = targetRide }
        position = SIMD3(x + sC.x, y + h * 0.5, baseZ + sC.z)
        if !position.x.isFinite || !position.y.isFinite || !position.z.isFinite {
            position = SIMD3(x, targetRide + h * 0.5, baseZ)
        }
    }

    private func sanitizeAngle(_ a: Float) -> Float {
        guard a.isFinite else { return 0 }
        return max(-1.2, min(1.2, a))
    }

    var collisionCenter: SIMD3<Float> { position }
    var collisionRadius: Float {
        pose == .ducking ? radius * 0.85 : radius
    }
    var collisionHalfHeight: Float { currentHeight * 0.5 }
}
