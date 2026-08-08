//
//  DebugMarkers.swift
//  city of surf
//
//  Schritt 1 der Befund-Reihenfolge: ein roter Platzhalterwürfel (2 m hoch) plus
//  Achsenkreuz exakt am Spieler-Ursprung. Der Marker geht durch dieselbe Pipeline,
//  dasselbe Material (3 = Surfer/Neon) und denselben Draw-Loop wie der Surfer.
//
//  Damit trennt ein einziger Build zwei Fehlerklassen:
//    Marker unsichtbar  → Pipeline / Kamera / Matrix ist schuld.
//    Marker sichtbar    → das Surfer-Modell (Mesh, Pose, Skalierung) ist schuld.
//
//  Zusätzlich liefert `logPlayerProjection` die Messwerte aus Befund A zu Frame 1.
//

import MetalKit
import simd

enum DebugMarkers {

    // MARK: - Tuning (Teil 5: alle Werte an einer Stelle)

    /// Master-Schalter für den Schritt-1-Marker. Auf `false` = komplett aus, kein Draw-Call.
    static var showPlayerMarker = true
    /// Frame-1-Diagnose aus Befund A in die Konsole schreiben.
    static var logFrameOneDiagnostics = true

    /// Höhe des roten Würfels in Metern (Vorgabe: 2 m).
    static let cubeHeight: Float = 2.0
    /// Kantenlänge in X/Z. Schmaler als hoch, damit das Achsenkreuz lesbar bleibt.
    static let cubeWidth: Float = 0.9
    /// Länge der Achsenbalken ab Ursprung, in Metern.
    static let axisLength: Float = 2.0
    /// Dicke der Achsenbalken in Metern.
    static let axisThickness: Float = 0.08

    private static let cubeColor = SIMD4<Float>(1.0, 0.05, 0.05, 1)
    private static let axisColorX = SIMD4<Float>(1.0, 0.15, 0.15, 1)  // +X rot
    private static let axisColorY = SIMD4<Float>(0.15, 1.0, 0.20, 1)  // +Y grün
    private static let axisColorZ = SIMD4<Float>(0.20, 0.45, 1.0, 1)  // +Z blau

    // MARK: - Draw

    /// Hängt Würfel + Achsenkreuz an die Draw-Liste. `position` ist der Spieler-Ursprung
    /// (Kollisionsmittelpunkt), damit der Marker exakt dort steht, wo der Surfer steht.
    static func appendPlayerMarker(
        to items: inout [DrawItem],
        box: MTKMesh,
        position: SIMD3<Float>
    ) {
        func marker(_ model: matrix_float4x4, _ color: SIMD4<Float>) {
            items.append(DrawItem(
                mesh: box,
                modelMatrix: model,
                color: color,
                isWave: false,
                materialId: 3,          // gleiche Material-Route wie der Surfer
                castsShadow: false,
                receivesShadow: false
            ))
        }

        let origin = Math.translation(position)

        // Roter Würfel, zentriert auf dem Spieler-Ursprung.
        marker(origin * Math.scale(SIMD3(cubeWidth, cubeHeight, cubeWidth)), cubeColor)

        // Achsenkreuz: je ein Balken vom Ursprung in +X / +Y / +Z.
        let half = axisLength * 0.5
        let t = axisThickness
        marker(
            origin * Math.translation(SIMD3(half, 0, 0)) * Math.scale(SIMD3(axisLength, t, t)),
            axisColorX
        )
        marker(
            origin * Math.translation(SIMD3(0, half, 0)) * Math.scale(SIMD3(t, axisLength, t)),
            axisColorY
        )
        marker(
            origin * Math.translation(SIMD3(0, 0, half)) * Math.scale(SIMD3(t, t, axisLength)),
            axisColorZ
        )
    }

    // MARK: - Frame-1-Diagnose (Befund A)

    private static var didLogFrameOne = false

    /// Schreibt den ersten Messdatensatz lesbar in die Konsole. Die vollständigen
    /// Werte jedes Frames landen als JSON beim `FrameDiagnosticsRecorder`.
    static func logFrameOnce(_ d: FrameDiagnostics) {
        guard logFrameOneDiagnostics, !didLogFrameOne else { return }
        didLogFrameOne = true

        let p = "[FloodSurfer FrameOne]"
        let c = d.camera
        let pl = d.player
        print("\(p) ===== Messung, keine Vermutung =====")
        print(String(format: "\(p) player.position  = (%.3f, %.3f, %.3f)  height=%.3f",
                     pl.position.x, pl.position.y, pl.position.z, pl.height))
        print(String(format: "\(p) camera.eye       = (%.3f, %.3f, %.3f)", c.eye.x, c.eye.y, c.eye.z))
        print(String(format: "\(p) camera.forward   = (%.3f, %.3f, %.3f)", c.forward.x, c.forward.y, c.forward.z))
        print(String(format: "\(p) camera.target    = (%.3f, %.3f, %.3f)", c.target.x, c.target.y, c.target.z))
        print(String(format: "\(p) near=%.3f far=%.1f fov=%.2f° aspect=%.4f",
                     c.nearZ, c.farZ, c.fovDegrees, c.aspect))
        print(String(format: "\(p) clip(origin)     = (%.3f, %.3f, %.3f, w=%.3f)",
                     pl.clip.x, pl.clip.y, pl.clip.z, pl.clip.w))
        print(String(format: "\(p) NDC(origin)      = (%.3f, %.3f, %.3f)", pl.ndc.x, pl.ndc.y, pl.ndc.z))
        print("\(p) inFrustum=\(pl.inFrustum) drawStatus=\(pl.drawStatus.rawValue)")
        print(String(format: "\(p) modelScale       = (%.3f, %.3f, %.3f) det=%.4f",
                     pl.modelScale.x, pl.modelScale.y, pl.modelScale.z, pl.modelDeterminant))
        print("\(p) invisibleReason  = \(pl.invisibleReason.isEmpty ? "— (sichtbar)" : pl.invisibleReason)")
        print("\(p) draws: player=\(d.draws.player) marker=\(d.draws.marker) water=\(d.draws.water) buildings=\(d.draws.buildings) coins=\(d.draws.coins) vehicles=\(d.draws.vehicles) fx=\(d.draws.fx) unique=\(d.draws.uniqueTotal) clamped=\(d.draws.clamped)")
        print(String(format: "\(p) wave: min=%.3f max=%.3f avg=%.3f range=%.3f (n=%d)",
                     d.wave.minY, d.wave.maxY, d.wave.avgY, d.wave.range, d.wave.samples))
        print("\(p) coinsInsideNearPlane = \(d.coinsInsideNearPlane)")
        print("\(p) nonFiniteMatrices    = \(d.nonFiniteMatrices.isEmpty ? "keine" : d.nonFiniteMatrices.joined(separator: ", "))")
        print("\(p) ====================================")
    }
}
