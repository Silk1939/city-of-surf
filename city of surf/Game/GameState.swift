//
//  GameState.swift
//  city of surf
//

import Foundation
import simd
import Combine

@MainActor
final class GameState: ObservableObject {
    @Published var score: Int = 0
    @Published var isGameOver: Bool = false
    @Published var speed: Float = 18

    let wave = WaveField()
    var surfer = SurferController()
    var obstacles = ObstacleSystem()

    private(set) var time: Float = 0
    private(set) var runDistance: Float = 0
    private(set) var scrollZ: Float = 0

    private let baseSpeed: Float = 17
    private let maxSpeed: Float = 32

    func reset() {
        time = 0
        runDistance = 0
        scrollZ = 0
        score = 0
        speed = baseSpeed
        isGameOver = false
        surfer = SurferController()
        obstacles.reset()
    }

    func steer(toWorldX x: Float) {
        guard !isGameOver else { return }
        surfer.setTargetX(x)
    }

    func handleVertical(_ direction: SwipeDirection) {
        guard !isGameOver else { return }
        switch direction {
        case .up: surfer.jump()
        case .down: surfer.duck()
        }
    }

    func update(deltaTime: Float) {
        guard !isGameOver else { return }

        time += deltaTime
        speed = min(maxSpeed, baseSpeed + runDistance * 0.011)
        runDistance += speed * deltaTime
        scrollZ = 0
        score = Int(runDistance)

        surfer.update(deltaTime: deltaTime, wave: wave, time: time, scrollZ: scrollZ)
        obstacles.update(
            deltaTime: deltaTime,
            runDistance: runDistance,
            wave: wave,
            time: time,
            scrollZ: scrollZ
        )

        if obstacles.hitsSurfer(surfer, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ) {
            isGameOver = true
        }
    }

    func fillFrameUniforms(
        _ frame: inout FrameUniforms,
        viewProjection: matrix_float4x4,
        cameraPosition: SIMD3<Float>,
        cameraNear: Float,
        cameraFar: Float
    ) {
        frame.viewProjectionMatrix = viewProjection
        frame.lightDirection = ArtDirection.sunDirection
        frame.time = time
        frame.sunColorIntensity = SIMD4<Float>(
            ArtDirection.sunColor,
            ArtDirection.sunIntensity
        )
        frame.skyAmbientColorIntensity = SIMD4<Float>(
            ArtDirection.skyAmbientColor,
            ArtDirection.skyAmbientIntensity
        )
        frame.fogColorDensity = SIMD4<Float>(
            ArtDirection.fogColor,
            ArtDirection.fogDensity
        )
        frame.waveAmplitude = wave.amplitude
        frame.waveLength = wave.wavelength
        frame.waveSpeed = wave.speed
        frame.waveSteepness = wave.steepness
        frame.waveDirX = wave.direction.x
        frame.waveDirZ = wave.direction.y
        frame.rippleAmplitude = wave.rippleAmplitude
        frame.rippleLength = wave.rippleLength
        frame.scrollZ = scrollZ
        frame.exposure = ArtDirection.exposure
        frame.cameraPosition = cameraPosition
        frame.cameraNear = cameraNear
        var dirAmp: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
        var steepSpeed: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
        wave.fillGerstnerUniforms(&dirAmp, &steepSpeed)
        frame.gerstnerDirAmpWave0 = dirAmp.0
        frame.gerstnerDirAmpWave1 = dirAmp.1
        frame.gerstnerDirAmpWave2 = dirAmp.2
        frame.gerstnerDirAmpWave3 = dirAmp.3
        frame.gerstnerSteepSpeed0 = steepSpeed.0
        frame.gerstnerSteepSpeed1 = steepSpeed.1
        frame.gerstnerSteepSpeed2 = steepSpeed.2
        frame.gerstnerSteepSpeed3 = steepSpeed.3
        frame.cameraFar = cameraFar
        frame.foamEdgeDepth = ArtDirection.Water.edgeFoamDepthMeters
        frame.bloomThreshold = ArtDirection.bloomThreshold
        frame.bloomIntensity = ArtDirection.bloomIntensity
        frame.bloomBlurDirection = .zero
        frame.bloomSoftKnee = ArtDirection.bloomSoftKnee
    }
}
