//
//  ParticleSystem.swift
//  city of surf
//
//  Particle state lives in a shared Metal buffer. Simulation currently runs on
//  the CPU with the same rules as `particleUpdate` in Shaders.metal so the
//  arcade spray path stays reliable on the Metal 4 render queue. The compute
//  kernel remains available for a later MTL4 compute wiring pass.
//

import Metal
import simd

struct ParticleEmitRequest {
    var boardPosition: SIMD3<Float> = .zero
    var boardCount: Float = 0
    var crestPosition: SIMD3<Float> = .zero
    var crestCount: Float = 0
    var splashPosition: SIMD3<Float> = .zero
    var splashCount: Float = 0
}

final class ParticleSystem {
    let maxParticles = ArtDirection.Particles.maxCount
    let particleBuffer: MTLBuffer
    private var seed: UInt32 = 1
    private var pendingSplash: (position: SIMD3<Float>, count: Float)?

    init?(device: MTLDevice) {
        let particleBytes = MemoryLayout<Particle>.stride * maxParticles
        guard let particles = device.makeBuffer(length: particleBytes, options: .storageModeShared) else {
            return nil
        }
        particleBuffer = particles
        particleBuffer.label = "Particles"
        clearParticles()
    }

    func clearParticles() {
        let pointer = particleBuffer.contents().bindMemory(to: Particle.self, capacity: maxParticles)
        for i in 0..<maxParticles {
            pointer[i].life = 0
            pointer[i].size = 0
            pointer[i].position = .zero
            pointer[i].velocity = .zero
            pointer[i].color = .zero
        }
    }

    func triggerSplash(at position: SIMD3<Float>) {
        pendingSplash = (position, Float(ArtDirection.Particles.splashBurst))
    }

    func update(deltaTime: Float, emit: ParticleEmitRequest) {
        seed &+= 0x9E3779B9
        var emitState = emit
        if let splash = pendingSplash {
            emitState.splashPosition = splash.position
            emitState.splashCount = splash.count
            pendingSplash = nil
        }

        let particles = particleBuffer.contents().bindMemory(to: Particle.self, capacity: maxParticles)
        let boardChance = emitState.boardCount / Float(maxParticles)
        let crestChance = emitState.crestCount / Float(maxParticles)
        let splashChance = emitState.splashCount / Float(maxParticles)
        let gravity = ArtDirection.Particles.gravity
        let drag = ArtDirection.Particles.drag

        for id in 0..<maxParticles {
            var p = particles[id]
            if p.life > 0 {
                p.life -= deltaTime
                p.velocity.y -= gravity * deltaTime
                p.velocity *= max(0, 1 - drag * deltaTime)
                p.position += p.velocity * deltaTime
                p.color.w *= min(max(p.life * 2, 0), 1)
                if p.life <= 0 {
                    p.life = 0
                    p.size = 0
                }
                particles[id] = p
                continue
            }

            let roll = hashFloat(UInt32(id) &+ seed)
            if roll < boardChance {
                let dir = randDir(UInt32(id) &* 3 &+ seed)
                p.position = emitState.boardPosition + SIMD3(dir.x, 0.05, -0.4 - abs(dir.z) * 0.3) * 0.35
                p.velocity = SIMD3(dir.x * 1.2, 1.5 + dir.y * 1.8, -2.5 - dir.z * 1.5)
                p.life = ArtDirection.Particles.sprayLife * (0.7 + hashFloat(UInt32(id) &+ 9) * 0.6)
                p.size = ArtDirection.Particles.spraySize
                p.color = ArtDirection.Particles.sprayColor
                particles[id] = p
            } else if roll < boardChance + crestChance {
                let dir = randDir(UInt32(id) &* 5 &+ seed)
                p.position = emitState.crestPosition + dir * 0.8
                p.velocity = SIMD3(dir.x * 1.4, 2.2 + dir.y * 2.0, dir.z * 1.1)
                p.life = ArtDirection.Particles.sprayLife * (0.8 + hashFloat(UInt32(id) &+ 11) * 0.5)
                p.size = ArtDirection.Particles.spraySize * 1.15
                p.color = ArtDirection.Particles.sprayColor
                particles[id] = p
            } else if roll < boardChance + crestChance + splashChance {
                let dir = randDir(UInt32(id) &* 7 &+ seed)
                p.position = emitState.splashPosition + dir * 0.25
                var velocity = dir * (3.5 + hashFloat(UInt32(id) &+ 13) * 3.0)
                velocity.y = abs(velocity.y) + 2
                p.velocity = velocity
                p.life = ArtDirection.Particles.splashLife * (0.7 + hashFloat(UInt32(id) &+ 15) * 0.6)
                p.size = ArtDirection.Particles.splashSize
                p.color = ArtDirection.Particles.splashColor
                particles[id] = p
            }
        }
    }

    private func hashFloat(_ x: UInt32) -> Float {
        var v = x ^ (x >> 16)
        v &*= 0x7feb352d
        v ^= v >> 15
        v &*= 0x846ca68b
        v ^= v >> 16
        return Float(v) / Float(UInt32.max)
    }

    private func randDir(_ seed: UInt32) -> SIMD3<Float> {
        let a = hashFloat(seed) * 6.2831853
        let b = hashFloat(seed &+ 17) * 2 - 1
        let r = sqrt(max(1 - b * b, 0))
        return SIMD3(cos(a) * r, abs(b), sin(a) * r)
    }
}
