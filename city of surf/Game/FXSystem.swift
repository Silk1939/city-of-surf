//
//  FXSystem.swift
//  city of surf
//
//  Lightweight stylized sparks / bursts (graybox cubes).
//

import simd

struct FXSpark {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var maxLife: Float
    var color: SIMD4<Float>
    var scale: Float
}

struct FXSystem {
    var sparks: [FXSpark] = []

    mutating func reset() {
        sparks.removeAll(keepingCapacity: true)
    }

    mutating func spawnCoinBurst(at origin: SIMD3<Float>) {
        for i in 0..<10 {
            let a = Float(i) / 10.0 * (.pi * 2) + Float.random(in: -0.2...0.2)
            let speed = Float.random(in: 4.5...9.0)
            sparks.append(FXSpark(
                position: origin,
                velocity: SIMD3(cos(a) * speed, Float.random(in: 5...11), sin(a) * speed * 0.35),
                life: Float.random(in: 0.35...0.55),
                maxLife: 0.55,
                color: SIMD4(1.0, 0.85 + Float.random(in: 0...0.1), 0.2, 1),
                scale: Float.random(in: 0.18...0.32)
            ))
        }
    }

    mutating func spawnStyleBurst(at origin: SIMD3<Float>) {
        for i in 0..<6 {
            let a = Float(i) / 6.0 * (.pi * 2)
            sparks.append(FXSpark(
                position: origin + SIMD3(0, 0.6, 0),
                velocity: SIMD3(cos(a) * 6, Float.random(in: 3...7), sin(a) * 3),
                life: 0.4,
                maxLife: 0.4,
                color: SIMD4(ArtDirection.neonGreen.x, ArtDirection.neonGreen.y, ArtDirection.neonGreen.z, 1),
                scale: 0.22
            ))
        }
    }

    mutating func update(deltaTime: Float) {
        for i in sparks.indices {
            sparks[i].life -= deltaTime
            sparks[i].velocity.y -= 18 * deltaTime
            sparks[i].position += sparks[i].velocity * deltaTime
        }
        sparks.removeAll { $0.life <= 0 }
    }
}
