//
//  GameState.swift
//  city of surf
//

import Foundation
import simd
import Combine

@MainActor
final class GameState: ObservableObject {
    @Published var distanceScore: Int = 0
    @Published var coins: Int = 0
    @Published var isGameOver: Bool = false
    @Published var speed: Float = 18
    @Published var justCollected: Bool = false

    /// Combined run score shown in HUD.
    var score: Int { distanceScore + coins * 10 }

    let wave = WaveField()
    var surfer = SurferController()
    var obstacles = ObstacleSystem()
    var coinSystem = CoinSystem()

    private(set) var time: Float = 0
    private(set) var runDistance: Float = 0
    private(set) var scrollZ: Float = 0
    private(set) var wipeoutShake: Float = 0
    private(set) var collectPulse: Float = 0

    private let baseSpeed: Float = 17
    private let maxSpeed: Float = 34

    func reset() {
        time = 0
        runDistance = 0
        scrollZ = 0
        distanceScore = 0
        coins = 0
        speed = baseSpeed
        isGameOver = false
        wipeoutShake = 0
        collectPulse = 0
        justCollected = false
        surfer = SurferController()
        obstacles.reset()
        coinSystem.reset()
    }

    func steer(toWorldX x: Float) {
        guard !isGameOver else { return }
        surfer.setTargetX(x)
    }

    func flick(meters: Float) {
        guard !isGameOver else { return }
        surfer.applyFlick(meters)
    }

    func handleVertical(_ direction: SwipeDirection) {
        guard !isGameOver else { return }
        switch direction {
        case .up: surfer.jump()
        case .down: surfer.duck()
        }
    }

    func update(deltaTime: Float) {
        if isGameOver {
            wipeoutShake = max(0, wipeoutShake - deltaTime * 2.5)
            return
        }

        time += deltaTime
        speed = min(maxSpeed, baseSpeed + runDistance * 0.012)
        runDistance += speed * deltaTime
        scrollZ = 0
        distanceScore = Int(runDistance)

        surfer.update(deltaTime: deltaTime, wave: wave, time: time, scrollZ: scrollZ)
        obstacles.update(
            deltaTime: deltaTime,
            runDistance: runDistance,
            wave: wave,
            time: time,
            scrollZ: scrollZ
        )

        let gained = coinSystem.update(
            runDistance: runDistance,
            surfer: surfer,
            wave: wave,
            time: time,
            scrollZ: scrollZ
        )
        if gained > 0 {
            coins += gained
            collectPulse = 1
            justCollected = true
        } else {
            justCollected = false
        }
        collectPulse = max(0, collectPulse - deltaTime * 3.5)

        if obstacles.hitsSurfer(surfer, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ) {
            isGameOver = true
            wipeoutShake = 1
        }
    }

    func fillFrameUniforms(_ frame: inout FrameUniforms, viewProjection: matrix_float4x4, cameraPosition: SIMD3<Float>) {
        frame.viewProjectionMatrix = viewProjection
        frame.lightDirection = simd_normalize(SIMD3<Float>(0.55, 0.55, 0.45))
        frame.time = time
        frame.waveAmplitude = wave.amplitude
        frame.waveLength = wave.wavelength
        frame.waveSpeed = wave.speed
        frame.waveSteepness = wave.steepness
        frame.waveDirX = wave.direction.x
        frame.waveDirZ = wave.direction.y
        frame.rippleAmplitude = wave.rippleAmplitude
        frame.rippleLength = wave.rippleLength
        frame.scrollZ = scrollZ
        frame.cameraPosition = cameraPosition
    }
}
