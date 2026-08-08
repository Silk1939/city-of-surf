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

    /// Einmalige Messung: Spieler- und Kamerazustand, Clip-/NDC-Koordinate des
    /// Spieler-Ursprungs, Skalierung aus der Model-Matrix, Draw-Call-Zahl des Surfers.
    static func logPlayerProjection(
        playerPosition: SIMD3<Float>,
        playerHeight: Float,
        cameraEye: SIMD3<Float>,
        cameraTarget: SIMD3<Float>,
        nearZ: Float,
        farZ: Float,
        fovDegrees: Float,
        aspect: Float,
        viewProjection: matrix_float4x4,
        surferModelMatrix: matrix_float4x4?,
        surferDrawCalls: Int,
        markerDrawCalls: Int,
        totalUniqueDraws: Int,
        clampedDraws: Bool
    ) {
        guard logFrameOneDiagnostics, !didLogFrameOne else { return }
        didLogFrameOne = true

        func project(_ p: SIMD3<Float>) -> (clip: SIMD4<Float>, ndc: SIMD3<Float>) {
            let clip = viewProjection * SIMD4(p.x, p.y, p.z, 1)
            let w = clip.w
            guard abs(w) > 1e-6 else { return (clip, SIMD3(repeating: .nan)) }
            return (clip, SIMD3(clip.x / w, clip.y / w, clip.z / w))
        }

        let center = project(playerPosition)
        let head = project(playerPosition + SIMD3(0, playerHeight * 0.5, 0))
        let feet = project(playerPosition - SIMD3(0, playerHeight * 0.5, 0))
        let forward = simd_normalize(cameraTarget - cameraEye)

        var scaleText = "n/a (kein Surfer-DrawItem)"
        if let m = surferModelMatrix {
            let sx = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
            let sy = simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
            let sz = simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            scaleText = String(
                format: "scale=(%.3f, %.3f, %.3f) translation=(%.3f, %.3f, %.3f)",
                sx, sy, sz, t.x, t.y, t.z
            )
        }

        let onScreen = abs(center.ndc.x) <= 1 && abs(center.ndc.y) <= 1
            && center.ndc.z >= 0 && center.ndc.z <= 1

        let p = "[FloodSurfer FrameOne]"
        print("\(p) ===== Befund A: Messung, keine Vermutung =====")
        print(String(format: "\(p) player.position   = (%.3f, %.3f, %.3f)  height=%.3f",
                     playerPosition.x, playerPosition.y, playerPosition.z, playerHeight))
        print(String(format: "\(p) camera.eye        = (%.3f, %.3f, %.3f)",
                     cameraEye.x, cameraEye.y, cameraEye.z))
        print(String(format: "\(p) camera.target     = (%.3f, %.3f, %.3f)",
                     cameraTarget.x, cameraTarget.y, cameraTarget.z))
        print(String(format: "\(p) camera.forward    = (%.3f, %.3f, %.3f)",
                     forward.x, forward.y, forward.z))
        print(String(format: "\(p) near=%.3f far=%.1f fov=%.2f° aspect=%.4f",
                     nearZ, farZ, fovDegrees, aspect))
        print(String(format: "\(p) eye→player dist   = %.3f m", simd_distance(cameraEye, playerPosition)))
        print(String(format: "\(p) clip(origin)      = (%.3f, %.3f, %.3f, w=%.3f)",
                     center.clip.x, center.clip.y, center.clip.z, center.clip.w))
        print(String(format: "\(p) NDC(origin)       = (%.3f, %.3f, %.3f)",
                     center.ndc.x, center.ndc.y, center.ndc.z))
        print(String(format: "\(p) NDC(head)         = (%.3f, %.3f, %.3f)",
                     head.ndc.x, head.ndc.y, head.ndc.z))
        print(String(format: "\(p) NDC(feet)         = (%.3f, %.3f, %.3f)",
                     feet.ndc.x, feet.ndc.y, feet.ndc.z))
        print("\(p) origin im Frustum? \(onScreen)   (NDC.y < -1 = unter dem unteren Bildrand)")
        print("\(p) surfer model matrix: \(scaleText)")
        print("\(p) draw calls: surfer=\(surferDrawCalls) marker=\(markerDrawCalls) uniqueTotal=\(totalUniqueDraws) clamped=\(clampedDraws)")
        print("\(p) ==============================================")
    }
}
