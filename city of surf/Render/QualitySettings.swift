//
//  QualitySettings.swift
//  city of surf
//
//  Scalable quality knobs — defaults target 60 fps on current iPhone.
//  WaterQualityProfile centralizes wave mesh / particle budgets.
//

import Foundation

/// GPU water + FX budgets. Expensive knobs documented for device tuning.
struct WaterQualityProfile {
    /// Wave plane segments (X across canyon, Z along street). Cost: vertex displace + fill.
    var waveSegmentsX: UInt32
    var waveSegmentsZ: UInt32
    /// Soft particle multiplicity (1 = full spray/wake/mist rates).
    var particleRate: Float
    /// Hard particle cap in FXSystem.
    var maxParticles: Int
    /// Draw-scale multiplier for spray ellipsoids.
    var particleScale: Float

    /// High: readable crest + dense chop, ~160 particles.
    static let high = WaterQualityProfile(
        waveSegmentsX: 64,
        waveSegmentsZ: 400,
        particleRate: 1.0,
        maxParticles: 160,
        particleScale: 1.0
    )
    static let medium = WaterQualityProfile(
        waveSegmentsX: 40,
        waveSegmentsZ: 220,
        particleRate: 0.65,
        maxParticles: 100,
        particleScale: 0.85
    )
    static let low = WaterQualityProfile(
        waveSegmentsX: 28,
        waveSegmentsZ: 160,
        particleRate: 0.4,
        maxParticles: 64,
        particleScale: 0.7
    )
}

struct QualitySettings {
    /// Particle / spark multiplicity (1 = full FX bursts).
    var particleScale: Float = 1.0
    /// Shadow map resolution (must match ShadowMap recreation when changed).
    var shadowMapSize: Int = 2048
    /// Bloom enabled only after Phase 9 device pass — mirrors enableBloomChain.
    var bloomEnabled: Bool = false
    /// MSAA sample count for future HDR path (currently 1).
    var msaaSamples: Int = 1
    /// Cap instance stream / draw diagnostics.
    var maxInstanceBudget: Int = maxInstancesPerFrame
    /// Wave mesh + FX water budget.
    var water: WaterQualityProfile = .high

    static let high = QualitySettings()
    static let medium = QualitySettings(
        particleScale: 0.6,
        shadowMapSize: 1536,
        bloomEnabled: false,
        msaaSamples: 1,
        maxInstanceBudget: 384,
        water: .medium
    )
    static let low = QualitySettings(
        particleScale: 0.35,
        shadowMapSize: 1024,
        bloomEnabled: false,
        msaaSamples: 1,
        maxInstanceBudget: 256,
        water: .low
    )
}
