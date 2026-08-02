//
//  ObstacleSystem.swift
//  city of surf
//

import simd

enum ObstacleKind: Int {
    case taxi
    case police
    case barrier
    case trafficLight
}

struct Obstacle {
    var localZ: Float
    var laneIndex: Int
    var kind: ObstacleKind
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
    private let spawnSpacing: Float = 22

    mutating func reset() {
        obstacles.removeAll()
        spawnCursor = 32
        seedAhead()
    }

    private mutating func seedAhead() {
        for _ in 0..<10 {
            spawnOne()
        }
    }

    private mutating func spawnOne() {
        let lane = Int.random(in: 0...2)
        let kinds: [ObstacleKind] = [.taxi, .taxi, .police, .barrier, .trafficLight]
        let kind = kinds.randomElement() ?? .taxi
        let size: SIMD3<Float>
        switch kind {
        case .taxi:
            size = SIMD3(2.0, 1.35, 4.2)
        case .police:
            size = SIMD3(2.1, 1.4, 4.4)
        case .barrier:
            size = SIMD3(2.4, 1.1, 0.7)
        case .trafficLight:
            size = SIMD3(0.55, 3.6, 0.55)
        }
        obstacles.append(Obstacle(localZ: spawnCursor, laneIndex: lane, kind: kind, size: size, roll: 0))
        spawnCursor += spawnSpacing + Float.random(in: -3...12)
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
            let bob = sin(time * 2.6 + obstacles[i].localZ) * 0.12
            obstacles[i].roll += deltaTime * (0.35 + bob)
            if worldZ < -22 {
                obstacles[i].active = false
            }
        }
        obstacles.removeAll { !$0.active }
        while obstacles.count < 10 {
            spawnOne()
        }
    }

    func worldPosition(for obstacle: Obstacle, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = obstacle.localZ - runDistance
        let x = obstacle.laneX
        let waterY = wave.height(x: x, z: worldZ, time: time, scrollZ: scrollZ)
        let bob = sin(time * 2.6 + obstacle.localZ) * 0.12
        let yOff: Float = obstacle.kind == .trafficLight ? obstacle.size.y * 0.35 : obstacle.size.y * 0.5
        return SIMD3(x, waterY + yOff + bob + 0.25, worldZ)
    }

    func hitsSurfer(_ surfer: SurferController, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> Bool {
        for o in obstacles where o.active {
            let pos = worldPosition(for: o, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ)
            var hx = o.size.x * 0.5 + surfer.collisionRadius
            var hy = o.size.y * 0.5 + surfer.collisionHalfHeight
            var hz = o.size.z * 0.5 + surfer.collisionRadius
            // Traffic lights: duck slips under the lamp head if crouched.
            if o.kind == .trafficLight {
                hx = 0.45 + surfer.collisionRadius
                hz = 0.45 + surfer.collisionRadius
                if surfer.pose == .ducking {
                    hy = 1.1
                    if surfer.collisionCenter.y + surfer.collisionHalfHeight < pos.y + 0.6 {
                        continue
                    }
                }
            }
            let dx = abs(pos.x - surfer.collisionCenter.x)
            let dy = abs(pos.y - surfer.collisionCenter.y)
            let dz = abs(pos.z - surfer.collisionCenter.z)
            if dx < hx && dy < hy && dz < hz {
                return true
            }
        }
        return false
    }
}
