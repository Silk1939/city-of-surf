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
    private var spawnCursor: Float = 12
    private let spacing: Float = 2.4

    mutating func reset() {
        coins.removeAll()
        spawnCursor = 8
        seedAhead()
    }

    private mutating func seedAhead() {
        while spawnCursor < 160 {
            spawnArc()
        }
    }

    private mutating func spawnArc() {
        if spawnCursor < 8 {
            spawnCursor = 8
        }
        let pattern = Int.random(in: 0...3)
        let count = Int.random(in: 7...12)
        let baseX = Float.random(in: -4.0...4.0)
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            let x: Float
            switch pattern {
            case 0: x = baseX
            case 1: x = baseX + sin(t * .pi * 2) * 2.4
            case 2: x = -3.8 + t * 7.6
            default: x = sin((t - 0.5) * .pi) * 3.6
            }
            coins.append(Coin(localZ: spawnCursor, x: max(-5.4, min(5.4, x))))
            spawnCursor += spacing
        }
        spawnCursor += Float.random(in: 4...10)
    }

    mutating func update(
        runDistance: Float,
        surfer: SurferController,
        wave: WaveField,
        time: Float,
        scrollZ: Float
    ) -> Int {
        var collected = 0
        let sx = surfer.x
        for i in coins.indices {
            guard coins[i].active else { continue }
            let worldZ = coins[i].localZ - runDistance
            if worldZ < -8 {
                coins[i].active = false
                continue
            }
            let dx = coins[i].x - sx
            let dz = worldZ
            // Generous XZ pickup cylinder.
            if abs(dx) < 2.3 && abs(dz) < 2.8 {
                coins[i].active = false
                collected += 1
            }
        }
        coins.removeAll { !$0.active }

        if spawnCursor < runDistance + 30 {
            spawnCursor = runDistance + 30
        }
        var guardCount = 0
        while coins.count < 36 || (coins.map(\.localZ).max() ?? 0) - runDistance < 140 {
            spawnArc()
            guardCount += 1
            if guardCount > 20 { break }
        }
        return collected
    }

    func worldPosition(for coin: Coin, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = coin.localZ - runDistance
        let bob = sin(time * 7.0 + coin.localZ) * 0.25
        let water = wave.height(x: coin.x, z: worldZ, time: time, scrollZ: scrollZ)
        return SIMD3(coin.x, water + 1.15 + bob, worldZ)
    }
}
