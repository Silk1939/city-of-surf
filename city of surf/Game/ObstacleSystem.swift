//
//  ObstacleSystem.swift
//  city of surf
//

import simd

struct Obstacle {
    var localZ: Float
    var laneIndex: Int
    var size: SIMD3<Float>
    var roll: Float
    var active: Bool = true

    var laneX: Float {
        SurferController.laneXs[laneIndex]
    }
}

struct ObstacleSystem {
    var obstacles: [Obstacle] = []
    private var spawnCursor: Float = 40
    private let spawnSpacing: Float = 28

    mutating func reset() {
        obstacles.removeAll()
        spawnCursor = 35
        seedAhead()
    }

    private mutating func seedAhead() {
        for _ in 0..<8 {
            spawnOne()
        }
    }

    private mutating func spawnOne() {
        let lane = Int.random(in: 0...2)
        let size = SIMD3<Float>(
            Float.random(in: 1.4...2.2),
            Float.random(in: 1.2...2.0),
            Float.random(in: 2.0...3.5)
        )
        obstacles.append(Obstacle(localZ: spawnCursor, laneIndex: lane, size: size, roll: 0))
        spawnCursor += spawnSpacing + Float.random(in: -4...10)
    }

    mutating func update(
        deltaTime: Float,
        runDistance: Float,
        wave: WaveField,
        time: Float,
        scrollZ: Float
    ) {
        for i in obstacles.indices {
            guard obstacles[i].active else { continue }
            let worldZ = obstacles[i].localZ - runDistance
            let x = obstacles[i].laneX
            let waterY = wave.height(x: x, z: worldZ, time: time, scrollZ: scrollZ)
            // Buoyancy: rest on water with a slight rock.
            let bob = sin(time * 3.0 + obstacles[i].localZ) * 0.15
            obstacles[i].roll += deltaTime * (0.6 + bob)
            _ = waterY + bob
            // Recycle when behind camera.
            if worldZ < -20 {
                obstacles[i].active = false
            }
        }

        obstacles.removeAll { !$0.active }
        while obstacles.count < 8 {
            spawnOne()
        }
    }

    func worldPosition(for obstacle: Obstacle, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = obstacle.localZ - runDistance
        let x = obstacle.laneX
        let waterY = wave.height(x: x, z: worldZ, time: time, scrollZ: scrollZ)
        let bob = sin(time * 3.0 + obstacle.localZ) * 0.15
        return SIMD3(x, waterY + obstacle.size.y * 0.5 + bob + 0.2, worldZ)
    }

    func hitsSurfer(_ surfer: SurferController, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> Bool {
        for o in obstacles where o.active {
            let pos = worldPosition(for: o, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ)
            // Skip if ducking under tall-ish obstacles when jump would be needed — graybox: any overlap counts unless ducking and obstacle is "high" only... keep simple AABB.
            let dx = abs(pos.x - surfer.collisionCenter.x)
            let dy = abs(pos.y - surfer.collisionCenter.y)
            let dz = abs(pos.z - surfer.collisionCenter.z)
            let hx = o.size.x * 0.5 + surfer.collisionRadius
            let hy = o.size.y * 0.5 + surfer.collisionHalfHeight
            let hz = o.size.z * 0.5 + surfer.collisionRadius
            if dx < hx && dy < hy && dz < hz {
                // Ducking can slip under if obstacle bottom is high — graybox: ducking reduces height so may miss.
                return true
            }
        }
        return false
    }
}
