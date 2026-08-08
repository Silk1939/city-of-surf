// Minimal-Shims für den macOS-Lauf. Sie ersetzen nur Typen, die im Projekt neben
// Metal- oder UIKit-Symbolen stehen und für die Kamera-/Höhenfeld-Messung
// irrelevant sind. Werte 1:1 aus dem Projekt übernommen.

import simd

/// aus InstanceStreamer.swift (steht dort neben MTKMesh)
let maxInstancesPerFrame = 512

/// aus InputHandler.swift (steht dort neben UIKit)
enum SwipeDirection {
    case up, down
}

/// aus IBLLoader.swift (steht dort neben MTLTexture) — Feldwerte identisch
struct LightingConfig {
    var sunDirection = SIMD3<Float>(0.55, 0.55, 0.45)
    var sunColor = SIMD3<Float>(1.0, 0.72, 0.4)
    var sunIntensity: Float = 2.8
    var iblIntensity: Float = 1.15
    var shadowBias: Float = 0.0025
    var specularMips: Float = 5
    var irradiancePeak: Float = 0
}
