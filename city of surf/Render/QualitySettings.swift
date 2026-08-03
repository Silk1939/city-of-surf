//
//  QualitySettings.swift
//  city of surf
//
//  Scalable quality knobs — defaults target 60 fps on current iPhone.
//

import Foundation

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

    static let high = QualitySettings()
    static let medium = QualitySettings(
        particleScale: 0.6,
        shadowMapSize: 1536,
        bloomEnabled: false,
        msaaSamples: 1,
        maxInstanceBudget: 384
    )
    static let low = QualitySettings(
        particleScale: 0.35,
        shadowMapSize: 1024,
        bloomEnabled: false,
        msaaSamples: 1,
        maxInstanceBudget: 256
    )
}
