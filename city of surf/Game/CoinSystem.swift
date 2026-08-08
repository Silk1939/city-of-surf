//
//  CoinSystem.swift
//  city of surf
//

import simd

struct Coin {
    var localZ: Float
    var laneIndex: Int
    var active: Bool = true

    var laneX: Float { SurferController.laneXs[laneIndex] }
}

struct CoinSystem {
    var coins: [Coin] = []
    private var spawnCursor: Float = 20
    private let spawnSpacing: Float = 16

    mutating func reset() {
        coins.removeAll()
        spawnCursor = 18
        for _ in 0..<10 { spawnOne() }
    }

    private mutating func spawnOne() {
        let lane = Int.random(in: 0...2)
        coins.append(Coin(localZ: spawnCursor, laneIndex: lane))
        spawnCursor += spawnSpacing + Float.random(in: -3...6)
    }

    mutating func update(runDistance: Float, surfer: SurferController) -> Int {
        var collected = 0
        for i in coins.indices {
            guard coins[i].active else { continue }
            let worldZ = coins[i].localZ - runDistance
            if worldZ < -15 {
                coins[i].active = false
                continue
            }
            let dx = abs(coins[i].laneX - surfer.position.x)
            let dz = abs(worldZ - surfer.position.z)
            if dx < 0.9 && dz < 1.1 {
                coins[i].active = false
                collected += 1
            }
        }
        coins.removeAll { !$0.active }
        while coins.count < 10 { spawnOne() }
        return collected
    }

    func worldPosition(for coin: Coin, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = coin.localZ - runDistance
        let x = coin.laneX
        let waterY = wave.height(x: x, z: worldZ, time: time, scrollZ: scrollZ)
        return SIMD3(x, waterY + 1.1, worldZ)
    }
}
