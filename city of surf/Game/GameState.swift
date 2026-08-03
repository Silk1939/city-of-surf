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
    @Published var collectPulse: Float = 0
    /// Internal combo for bonus scoring — not shown on HUD during stabilization.
    private(set) var combo: Int = 0
    private(set) var stylePulse: Float = 0
    private(set) var speed: Float = 18

    // Device smoke / first-run diagnostics (updated by GVC + Renderer).
    // Keep showDebugHUD=false after confirmed device smoke; set true for Metal diagnostics.
    @Published var showDebugHUD: Bool = false
    @Published var debugMetalDeviceOK: Bool = false
    @Published var debugMetal4OK: Bool = false
    @Published var debugRendererReady: Bool = false
    @Published var debugKTXLoaded: Bool = false
    @Published var debugIBLPeak: Float = 0
    @Published var debugShadowActive: Bool = false
    @Published var debugFirstFrameOK: Bool = false
    @Published var debugFPS: Int = 0
    @Published var debugTextureMemoryMB: Float = 0
    @Published var debugTextureMemoryWarn: Bool = false
    @Published var debugLastError: String = ""
    @Published var debugPlatformNote: String = "device"

    /// Combined run score shown in HUD.
    var score: Int { distanceScore + coins * 10 + bonusScore }

    let wave = WaveField()
    var surfer = SurferController()
    var obstacles = ObstacleSystem()
    var coinSystem = CoinSystem()
    var fx = FXSystem()

    private(set) var time: Float = 0
    private(set) var runDistance: Float = 0
    private(set) var scrollZ: Float = 0
    private(set) var wipeoutShake: Float = 0
    private(set) var bonusScore: Int = 0
    private var comboTimer: Float = 0
    private var lastStyleObstacleZ: Float = -9999

    let baseSpeed: Float = 17
    let maxSpeed: Float = 34

    func reset() {
        time = 0
        runDistance = 0
        scrollZ = 0
        distanceScore = 0
        coins = 0
        bonusScore = 0
        combo = 0
        comboTimer = 0
        speed = baseSpeed
        isGameOver = false
        wipeoutShake = 0
        collectPulse = 0
        stylePulse = 0
        lastStyleObstacleZ = -9999
        surfer = SurferController()
        obstacles.reset()
        coinSystem.reset()
        fx.reset()
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
        fx.update(deltaTime: deltaTime)
        if stylePulse > 0 {
            stylePulse = max(0, stylePulse - deltaTime * 2.8)
        }

        if isGameOver {
            wipeoutShake = max(0, wipeoutShake - deltaTime * 2.5)
            return
        }

        time += deltaTime
        speed = min(maxSpeed, baseSpeed + runDistance * 0.012)
        runDistance += speed * deltaTime
        scrollZ = 0
        distanceScore = Int(runDistance)

        if comboTimer > 0 {
            comboTimer -= deltaTime
            if comboTimer <= 0 {
                combo = 0
                comboTimer = 0
            }
        }

        surfer.update(deltaTime: deltaTime, wave: wave, time: time, scrollZ: scrollZ)
        obstacles.update(
            deltaTime: deltaTime,
            runDistance: runDistance,
            wave: wave,
            time: time,
            scrollZ: scrollZ
        )

        // Collision before coin collect — no score pulse on the wipeout frame.
        if obstacles.hitsSurfer(surfer, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ) {
            isGameOver = true
            wipeoutShake = 1
            combo = 0
            comboTimer = 0
            return
        }

        rewardStyleClears()

        let gained = coinSystem.update(
            runDistance: runDistance,
            surfer: surfer,
            wave: wave,
            time: time,
            scrollZ: scrollZ
        )
        if gained > 0 {
            coins += gained
            combo += gained
            comboTimer = 2.2
            let multiplier = 1 + min(combo, 12) / 4
            bonusScore += gained * multiplier
            collectPulse = 1
            fx.spawnCoinBurst(at: surfer.position + SIMD3(0, 0.8, 0.4))
        } else if collectPulse > 0 {
            collectPulse = max(0, collectPulse - deltaTime * 3.5)
        }
    }

    /// Jump-over / duck-under near-miss → neon flash + style points.
    private func rewardStyleClears() {
        guard surfer.pose == .jumping || surfer.pose == .ducking else { return }
        let sMinY = surfer.collisionCenter.y - surfer.collisionHalfHeight
        let sMaxY = surfer.collisionCenter.y + surfer.collisionHalfHeight

        for o in obstacles.obstacles where o.active {
            if abs(o.localZ - lastStyleObstacleZ) < 0.01 { continue }
            let pos = obstacles.worldPosition(
                for: o,
                runDistance: runDistance,
                wave: wave,
                time: time,
                scrollZ: scrollZ
            )
            let dx = abs(pos.x - surfer.collisionCenter.x)
            let dz = abs(pos.z - surfer.collisionCenter.z)
            guard dx < 3.2 && dz < 1.8 else { continue }

            var cleared = false
            if o.kind == .trafficLight, surfer.pose == .ducking {
                // Head is above pole origin — ducking under it.
                if sMaxY < pos.y + 1.0 && dz < 1.2 {
                    cleared = true
                }
            } else if surfer.pose == .jumping, o.kind != .trafficLight {
                let roof = pos.y + (o.kind == .barrier ? 0.6 : 1.2)
                if sMinY > roof - 0.15 {
                    cleared = true
                }
            }

            if cleared {
                lastStyleObstacleZ = o.localZ
                bonusScore += 15
                stylePulse = 1
                fx.spawnStyleBurst(at: pos)
                break
            }
        }
    }

    func fillFrameUniforms(
        _ frame: inout FrameUniforms,
        viewProjection: matrix_float4x4,
        invViewProjection: matrix_float4x4,
        lightViewProjection: matrix_float4x4,
        cameraPosition: SIMD3<Float>,
        lighting: LightingConfig
    ) {
        frame.viewProjectionMatrix = viewProjection
        frame.invViewProjectionMatrix = invViewProjection
        frame.lightViewProjectionMatrix = lightViewProjection
        frame.lightDirection = ArtDirection.sunDirection
        frame.lightColor = ArtDirection.sunColor
        frame.sunIntensity = ArtDirection.sunIntensity
        frame.iblIntensity = ArtDirection.iblIntensity
        frame.shadowBias = lighting.shadowBias
        frame.specularMips = lighting.specularMips
        frame.time = time
        frame.waveAmplitude = wave.amplitude
        frame.waveLength = wave.wavelength
        frame.waveSpeed = wave.speed
        frame.waveSteepness = wave.steepness
        frame.waveDirX = wave.direction.x
        frame.waveDirZ = wave.direction.y
        frame.rippleAmplitude = wave.rippleAmplitude
        frame.rippleLength = wave.rippleLength
        // Keep GPU flood_displace in sync with WaveField.relativeZ (includes crestShift).
        frame.scrollZ = scrollZ + wave.crestShift
        frame.cameraPosition = cameraPosition
    }
}
