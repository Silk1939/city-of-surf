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
        // Visual surface (pinch inverted) so props ride the Gerstner flood with the mesh.
        let sample = wave.surfaceDisplacement(x: x, z: worldZ, time: time, scrollZ: scrollZ)
        let bob = sin(time * 2.6 + obstacle.localZ) * 0.12
        let yOff: Float = obstacle.kind == .trafficLight ? obstacle.size.y * 0.35 : obstacle.size.y * 0.5
        return SIMD3(x + sample.x, sample.y + yOff + bob + 0.25, worldZ + sample.z)
    }

    /// Half-extents in world XZ after the render yaw (cars are rotated 90°).
    private func worldHalfExtents(_ o: Obstacle) -> (Float, Float, Float) {
        switch o.kind {
        case .taxi, .police:
            // Match visual cabin roof (~body 1.15 + cabin 0.9 → ~1.3 half from center).
            return (o.size.z * 0.45, 1.15, o.size.x * 0.45)
        case .barrier:
            return (o.size.x * 0.5, o.size.y * 0.5, o.size.z * 0.5)
        case .trafficLight:
            // Collide only with the signal head (not the pole) — duck is real geometry.
            return (0.45, 0.7, 0.4)
        }
    }

    private func collisionCenter(for o: Obstacle, base: SIMD3<Float>) -> SIMD3<Float> {
        switch o.kind {
        case .trafficLight:
            // Head sits ~1.7 above pole origin used for rendering.
            return SIMD3(base.x, base.y + 1.7, base.z)
        default:
            return base
        }
    }

    func hitsSurfer(_ surfer: SurferController, runDistance: Float, wave: WaveField, time: Float, scrollZ: Float) -> Bool {
        let sMinY = surfer.collisionCenter.y - surfer.collisionHalfHeight
        let sMaxY = surfer.collisionCenter.y + surfer.collisionHalfHeight

        for o in obstacles where o.active {
            let base = worldPosition(for: o, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ)
            let pos = collisionCenter(for: o, base: base)
            let (hx, hy, hz) = worldHalfExtents(o)
            let oMinY = pos.y - hy
            let oMaxY = pos.y + hy

            // Jump clear: surfer entirely above obstacle.
            if sMinY > oMaxY + 0.08 {
                continue
            }
            // Duck under traffic-light head — true clearance, not an immunity flag.
            if o.kind == .trafficLight, surfer.pose == .ducking, sMaxY < oMinY + 0.12 {
                continue
            }

            let dx = abs(pos.x - surfer.collisionCenter.x)
            let dz = abs(pos.z - surfer.collisionCenter.z)
            let yOverlap = sMinY < oMaxY && sMaxY > oMinY
            if dx < hx + surfer.collisionRadius && dz < hz + surfer.collisionRadius && yOverlap {
                return true
            }
        }
        return false
    }
}
