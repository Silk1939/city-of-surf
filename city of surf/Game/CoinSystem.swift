//
//  CoinSystem.swift
//  city of surf
//

import simd

struct Coin {
    var localZ: Float
    var x: Float
    var active: Bool = true
}

struct CoinSystem {
    var coins: [Coin] = []
    private var spawnCursor: Float = 20
    private let spacing: Float = 3.2

    mutating func reset() {
        coins.removeAll()
        spawnCursor = 18
        seedAhead()
    }

    private mutating func seedAhead() {
        while spawnCursor < 220 {
            spawnArc()
        }
    }

    /// Curving coin line like the concept art.
    private mutating func spawnArc() {
        let pattern = Int.random(in: 0...3)
        let count = Int.random(in: 6...12)
        let baseLane = Float.random(in: -4.5...4.5)
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            let x: Float
            switch pattern {
            case 0: // straight
                x = baseLane
            case 1: // S-curve
                x = baseLane + sin(t * .pi * 2) * 2.8
            case 2: // sweep left->right
                x = -4.2 + t * 8.4
            default: // arc over center
                x = sin((t - 0.5) * .pi) * 4.0
            }
            coins.append(Coin(localZ: spawnCursor, x: max(-5.5, min(5.5, x))))
            spawnCursor += spacing
        }
        spawnCursor += Float.random(in: 6...16)
    }

    mutating func update(
        runDistance: Float,
        surfer: SurferController,
        wave: WaveField,
        time: Float,
        scrollZ: Float
    ) -> Int {
        var collected = 0
        for i in coins.indices {
            guard coins[i].active else { continue }
            let worldZ = coins[i].localZ - runDistance
            if worldZ < -12 {
                coins[i].active = false
                continue
            }
            let y = wave.height(x: coins[i].x, z: worldZ, time: time, scrollZ: scrollZ) + 1.3
            let pos = SIMD3(coins[i].x, y, worldZ)
            let d = simd_length(pos - surfer.collisionCenter)
            if d < 1.35 {
                coins[i].active = false
                collected += 1
            }
        }
        coins.removeAll { !$0.active }
        while coins.count < 40 || (coins.map(\.localZ).max() ?? 0) - runDistance < 160 {
            spawnArc()
        }
        return collected
    }

    func worldPosition(for coin: Coin, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = coin.localZ - runDistance
        let bob = sin(time * 6.0 + coin.localZ) * 0.2
        let y = wave.height(x: coin.x, z: worldZ, time: time, scrollZ: scrollZ) + 1.35 + bob
        return SIMD3(coin.x, y, worldZ)
    }
}
