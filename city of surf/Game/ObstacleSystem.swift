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
    var x: Float
    var kind: ObstacleKind
    var size: SIMD3<Float>
    var roll: Float
    var active: Bool = true
}

struct ObstacleSystem {
    var obstacles: [Obstacle] = []
    private var spawnCursor: Float = 40
    private let spawnSpacing: Float = 22

    mutating func reset() {
        obstacles.removeAll()
        spawnCursor = 30
        seedAhead()
    }

    private mutating func seedAhead() {
        for _ in 0..<10 {
            spawnOne()
        }
    }

    private mutating func spawnOne() {
        // Never spawn behind / on top of the player.
        if spawnCursor < 35 {
            spawnCursor = 35
        }
        let kinds: [ObstacleKind] = [.taxi, .taxi, .police, .barrier, .trafficLight]
        let kind = kinds.randomElement() ?? .taxi
        let size: SIMD3<Float>
        switch kind {
        case .taxi:
            size = SIMD3(2.0, 1.35, 4.2)
        case .police:
            size = SIMD3(2.1, 1.4, 4.4)
        case .barrier:
            size = SIMD3(2.6, 1.0, 0.7)
        case .trafficLight:
            size = SIMD3(0.55, 3.6, 0.55)
        }
        let x = Float.random(in: -5.0...5.0)
        obstacles.append(Obstacle(localZ: spawnCursor, x: x, kind: kind, size: size, roll: 0))
        spawnCursor += spawnSpacing + Float.random(in: 0...10)
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
            obstacles[i].roll += deltaTime * 0.4
            if worldZ < -24 {
                obstacles[i].active = false
            }
        }
        obstacles.removeAll { !$0.active }

        // Keep spawn cursor ahead of the player.
        if spawnCursor < runDistance + 40 {
            spawnCursor = runDistance + 40
        }
        while obstacles.count < 10 {
            spawnOne()
        }
    }

    func worldPosition(for obstacle: Obstacle, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> SIMD3<Float> {
        let worldZ = obstacle.localZ - runDistance
        let x = obstacle.x
        let waterY = wave.height(x: x, z: worldZ, time: time, scrollZ: scrollZ)
        let bob = sin(time * 2.6 + obstacle.localZ) * 0.12
        let yOff: Float = obstacle.kind == .trafficLight ? obstacle.size.y * 0.35 : obstacle.size.y * 0.5
        return SIMD3(x, waterY + yOff + bob + 0.25, worldZ)
    }

    /// Half-extents in world XZ after the render yaw (cars are rotated 90°).
    private func worldHalfExtents(_ o: Obstacle) -> (Float, Float, Float) {
        switch o.kind {
        case .taxi, .police:
            // Visual: yaw 90° turns model (w,h,l)=(2,1.15,4) into ~4 wide (X) by ~2 deep (Z).
            return (o.size.z * 0.45, o.size.y * 0.48, o.size.x * 0.45)
        case .barrier:
            return (o.size.x * 0.5, o.size.y * 0.5, o.size.z * 0.5)
        case .trafficLight:
            return (0.4, o.size.y * 0.45, 0.4)
        }
    }

    func hitsSurfer(_ surfer: SurferController, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> Bool {
        let sMinY = surfer.collisionCenter.y - surfer.collisionHalfHeight
        let sMaxY = surfer.collisionCenter.y + surfer.collisionHalfHeight

        for o in obstacles where o.active {
            let pos = worldPosition(for: o, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ)
            let (hx, hy, hz) = worldHalfExtents(o)
            let oMinY = pos.y - hy
            let oMaxY = pos.y + hy

            // Jump clear: surfer entirely above obstacle.
            if sMinY > oMaxY + 0.05 {
                continue
            }
            // Duck under traffic lights.
            if o.kind == .trafficLight, surfer.pose == .ducking, sMaxY < oMinY + 1.2 {
                continue
            }

            let dx = abs(pos.x - surfer.x)
            let dz = abs(pos.z) // surfer near z=0
            let yOverlap = sMinY < oMaxY && sMaxY > oMinY
            if dx < hx + surfer.collisionRadius && dz < hz + surfer.collisionRadius && yOverlap {
                return true
            }
        }
        return false
    }
}
