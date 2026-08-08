//
//  FXSystem.swift
//  city of surf
//
//  Soft water spray / wake / crest mist — ellipsoids, not graybox cubes.
//  Budget-capped for 60 fps; spawn rates scale with speed, lean, contact.
//

import simd

enum FXKind: UInt8 {
    case spark = 0
    case wake = 1
    case spray = 2
    case mist = 3
    case splash = 4
}

struct FXSpark {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var maxLife: Float
    var color: SIMD4<Float>
    var scale: Float
    /// Non-uniform stretch (wake streaks vs round mist).
    var stretch: SIMD3<Float>
    var kind: FXKind
}

struct FXSystem {
    var sparks: [FXSpark] = []
    /// Soft cap — QualitySettings may lower further via prune.
    var maxParticles: Int = 160
    private var wakeAccum: Float = 0
    private var sprayAccum: Float = 0
    private var mistAccum: Float = 0

    mutating func reset() {
        sparks.removeAll(keepingCapacity: true)
        wakeAccum = 0
        sprayAccum = 0
        mistAccum = 0
    }

    mutating func spawnCoinBurst(at origin: SIMD3<Float>) {
        for i in 0..<8 {
            let a = Float(i) / 8.0 * (.pi * 2) + Float.random(in: -0.2...0.2)
            let speed = Float.random(in: 4.5...9.0)
            let s = Float.random(in: 0.10...0.18)
            append(FXSpark(
                position: origin,
                velocity: SIMD3(cos(a) * speed, Float.random(in: 5...11), sin(a) * speed * 0.35),
                life: Float.random(in: 0.35...0.55),
                maxLife: 0.55,
                color: SIMD4(1.0, 0.85 + Float.random(in: 0...0.1), 0.2, 1),
                scale: s,
                stretch: SIMD3(1, 1, 1),
                kind: .spark
            ))
        }
    }

    mutating func spawnStyleBurst(at origin: SIMD3<Float>) {
        for i in 0..<5 {
            let a = Float(i) / 5.0 * (.pi * 2)
            append(FXSpark(
                position: origin + SIMD3(0, 0.6, 0),
                velocity: SIMD3(cos(a) * 6, Float.random(in: 3...7), sin(a) * 3),
                life: 0.4,
                maxLife: 0.4,
                color: SIMD4(ArtDirection.neonCyan.x, ArtDirection.neonCyan.y, ArtDirection.neonCyan.z, 1),
                scale: 0.14,
                stretch: SIMD3(1, 1, 1),
                kind: .spark
            ))
        }
    }

    /// Continuous surfing FX: wake trail, carve spray, crest mist, landing splash.
    mutating func updateSurfing(
        deltaTime: Float,
        surfer: SurferController,
        wave: WaveField,
        time: Float,
        scrollZ: Float,
        speed: Float,
        justLanded: Bool,
        qualityScale: Float
    ) {
        let contact = surfer.waterContact
        let speedT = saturate((speed - 17) / 17)
        let leanAbs = abs(surfer.lean)
        let boardY = surfer.position.y - surfer.currentHeight * 0.5
        let boardPos = SIMD3(surfer.position.x, boardY + 0.05, surfer.position.z)

        // Wake ribbon — denser with speed.
        wakeAccum += deltaTime * (6.0 + speedT * 10.0) * contact * qualityScale
        while wakeAccum >= 1 {
            wakeAccum -= 1
            spawnWake(at: boardPos, lean: surfer.lean, speedT: speedT)
        }

        // Side spray on carve / lateral speed.
        let sprayRate = (leanAbs * 18 + abs(surfer.lateralSpeed) * 0.35) * contact * (0.55 + speedT)
        sprayAccum += deltaTime * sprayRate * qualityScale
        while sprayAccum >= 1 {
            sprayAccum -= 1
            spawnSpray(at: boardPos, lean: surfer.lean, speedT: speedT)
        }

        // Crest mist when local foam is high behind/under board.
        let foamC = wave.foam(x: surfer.x, z: 0, time: time, scrollZ: scrollZ)
        let foamBack = wave.foam(x: surfer.x, z: -1.2, time: time, scrollZ: scrollZ)
        let foamAmt = max(foamC, foamBack)
        if foamAmt > 0.28 {
            mistAccum += deltaTime * (foamAmt * 18.0) * (0.45 + contact * 0.55) * qualityScale
            while mistAccum >= 1 {
                mistAccum -= 1
                spawnMist(at: boardPos + SIMD3(
                    Float.random(in: -1.0...1.0),
                    Float.random(in: 0.35...2.0),
                    Float.random(in: -2.8...0.1)
                ), foam: foamAmt)
            }
        }

        if justLanded {
            spawnLandingSplash(at: boardPos, speedT: speedT)
        }
    }

    mutating func update(deltaTime: Float) {
        let dt = deltaTime
        for i in sparks.indices {
            sparks[i].life -= dt
            switch sparks[i].kind {
            case .spark:
                sparks[i].velocity.y -= 18 * dt
            case .wake:
                sparks[i].velocity *= max(0, 1 - 2.8 * dt)
                sparks[i].velocity.y -= 2.5 * dt
            case .spray:
                sparks[i].velocity.y -= 14 * dt
                sparks[i].velocity.x *= max(0, 1 - 1.2 * dt)
            case .mist:
                sparks[i].velocity.y += 0.6 * dt
                sparks[i].velocity *= max(0, 1 - 1.5 * dt)
            case .splash:
                sparks[i].velocity.y -= 16 * dt
            }
            sparks[i].position += sparks[i].velocity * dt
            // Life fade into stretch / scale handled at draw.
        }
        sparks.removeAll { $0.life <= 0 }
        if sparks.count > maxParticles {
            sparks.removeFirst(sparks.count - maxParticles)
        }
    }

    // MARK: - Spawn helpers

    private mutating func spawnWake(at origin: SIMD3<Float>, lean: Float, speedT: Float) {
        let side: Float = Float.random(in: 0...1) > 0.5 ? 1 : -1
        let life = Float.random(in: 0.35...0.65)
        let len: Float = 0.55 + speedT * 0.45
        append(FXSpark(
            position: origin + SIMD3(side * (0.22 + abs(lean) * 0.15), 0.02, -0.35),
            velocity: SIMD3(lean * 0.8 + side * 0.4, Float.random(in: 0.1...0.6), -2.2 - speedT * 2.5),
            life: life,
            maxLife: life,
            color: SIMD4(0.92, 0.97, 0.98, 1),
            scale: Float.random(in: 0.12...0.20),
            stretch: SIMD3(0.55, 0.35, len),
            kind: .wake
        ))
    }

    private mutating func spawnSpray(at origin: SIMD3<Float>, lean: Float, speedT: Float) {
        let side: Float = lean >= 0 ? 1 : -1
        let life = Float.random(in: 0.22...0.42)
        let outward = side * Float.random(in: 2.5...5.5) * (0.6 + abs(lean))
        append(FXSpark(
            position: origin + SIMD3(side * 0.35, 0.08, Float.random(in: -0.3...0.4)),
            velocity: SIMD3(
                outward + Float.random(in: -0.8...0.8),
                Float.random(in: 1.8...4.5) * (0.5 + speedT),
                Float.random(in: -1.5...0.5)
            ),
            life: life,
            maxLife: life,
            color: SIMD4(0.85, 0.95, 0.96, 1),
            scale: Float.random(in: 0.06...0.14),
            stretch: SIMD3(
                Float.random(in: 0.7...1.3),
                Float.random(in: 0.9...1.6),
                Float.random(in: 0.6...1.1)
            ),
            kind: .spray
        ))
    }

    private mutating func spawnMist(at origin: SIMD3<Float>, foam: Float) {
        let life = Float.random(in: 0.45...0.85)
        let s = Float.random(in: 0.08...0.22) * (0.7 + foam * 0.5)
        append(FXSpark(
            position: origin,
            velocity: SIMD3(
                Float.random(in: -1.2...1.2),
                Float.random(in: 0.4...2.0),
                Float.random(in: -1.8...0.4)
            ),
            life: life,
            maxLife: life,
            color: SIMD4(0.88, 0.94, 0.95, 1),
            scale: s,
            stretch: SIMD3(
                Float.random(in: 1.0...1.8),
                Float.random(in: 0.7...1.2),
                Float.random(in: 1.0...1.8)
            ),
            kind: .mist
        ))
    }

    private mutating func spawnLandingSplash(at origin: SIMD3<Float>, speedT: Float) {
        for i in 0..<10 {
            let a = Float(i) / 10.0 * (.pi * 2) + Float.random(in: -0.15...0.15)
            let spd = Float.random(in: 2.5...5.5) * (0.7 + speedT * 0.5)
            let life = Float.random(in: 0.28...0.48)
            append(FXSpark(
                position: origin + SIMD3(0, 0.1, 0),
                velocity: SIMD3(cos(a) * spd, Float.random(in: 2.5...6.0), sin(a) * spd * 0.55),
                life: life,
                maxLife: life,
                color: SIMD4(0.90, 0.96, 0.98, 1),
                scale: Float.random(in: 0.08...0.16),
                stretch: SIMD3(1.1, 1.4, 1.1),
                kind: .splash
            ))
        }
    }

    private mutating func append(_ p: FXSpark) {
        if sparks.count >= maxParticles {
            // Drop oldest mist/wake first to keep interactive spray.
            if let idx = sparks.firstIndex(where: { $0.kind == .mist || $0.kind == .wake }) {
                sparks.remove(at: idx)
            } else if !sparks.isEmpty {
                sparks.removeFirst()
            }
        }
        sparks.append(p)
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }
}
