// Host-seitige Ursachenanalyse zu Befund A.
// Kompiliert die echten Spielquellen für macOS und spiegelt DiagnosticsHarness.run.
// Kein Metal, keine Meshes — nur Kamera, Höhenfeld, Surfer und Projektion.

import Foundation
import simd

@MainActor
func simulate(
    frames: Int,
    aspect: Float = 1170.0 / 2532.0,
    configureCamera: ((inout ChaseCamera) -> Void)? = nil
) -> (player: FrameDiagnostics.PlayerInfo, camera: FrameDiagnostics.CameraInfo) {
    let state = GameState()
    state.reset()
    var camera = ChaseCamera()
    configureCamera?(&camera)
    let dt: Float = 1.0 / 60.0

    for _ in 0..<frames {
        state.update(deltaTime: dt)
        camera.follow(
            surfer: state.surfer,
            wave: state.wave,
            time: state.time,
            scrollZ: state.scrollZ,
            shake: 0,
            speed: state.speed,
            deltaTime: dt
        )
    }

    let viewM = camera.viewMatrix(follow: state.surfer.position)
    let projM = camera.projectionMatrix(aspect: aspect)
    let vp = projM * viewM
    let eye = camera.smoothEye
    let target = state.surfer.position + camera.lookAhead
    let forward = simd_normalize(target - eye)
    let waterY = state.wave.height(
        x: state.surfer.x, z: state.surfer.position.z, time: state.time, scrollZ: state.scrollZ
    )
    // SurferVisual liegt neben MetalKit und ist hier nicht kompilierbar. Die
    // Model-Matrix prüft testBefundA_playerModelMatrixIsSane im Test-Target mit
    // der echten Funktion; hier geht es nur um Kamera und Höhenfeld.
    let model = matrix_identity_float4x4
    let scale = DiagnosticsMath.scale(of: model)
    let proj = DiagnosticsMath.project(state.surfer.position, viewProjection: vp)

    let cam = FrameDiagnostics.CameraInfo(
        eye: eye, forward: forward, target: target,
        nearZ: camera.nearZ, farZ: camera.farZ,
        fovDegrees: camera.fovDegrees, aspect: aspect,
        pitchDegrees: DiagnosticsMath.pitchDegrees(forward: forward),
        halfFovVerticalDegrees: camera.fovDegrees * 0.5
    )
    let player = FrameDiagnostics.PlayerInfo(
        position: state.surfer.position,
        height: state.surfer.currentHeight,
        clip: proj.clip,
        ndc: proj.ndc,
        inFrustum: DiagnosticsMath.inFrustum(ndc: proj.ndc),
        drawn: true,
        modelScale: scale,
        modelDeterminant: DiagnosticsMath.determinant(of: model),
        invisibleReason: DiagnosticsMath.invisibleReason(
            clip: proj.clip, ndc: proj.ndc, drawn: true, scale: scale
        ),
        waterHeight: waterY,
        heightAboveWater: state.surfer.position.y - waterY,
        angleBelowViewAxisDegrees: DiagnosticsMath.angleBelowViewAxis(
            eye: eye, target: target, point: state.surfer.position
        )
    )
    return (player, cam)
}

@MainActor
func main() {
    let n = 120
    let base = simulate(frames: n)
    let b = base.player
    let c = base.camera

    print("========== URSACHENANALYSE BEFUND A ==========")
    print(String(format: "Kamera-Y            = %.3f", c.eye.y))
    print(String(format: "Kamera-Pitch        = %.2f Grad (negativ = nach unten)", c.pitchDegrees))
    print(String(format: "halbes vert. FOV    = %.2f Grad", c.halfFovVerticalDegrees))
    print(String(format: "LookAt-Zielpunkt    = (%.3f, %.3f, %.3f)", c.target.x, c.target.y, c.target.z))
    print(String(format: "Surfer-Y            = %.3f", b.position.y))
    print(String(format: "Wasserhoehe (x,z)   = %.3f", b.waterHeight))
    print(String(format: "Surfer-Y - Wasser   = %+.3f   <<< entscheidende Zahl", b.heightAboveWater))
    print(String(format: "Winkel unter Achse  = %.2f Grad (Grenze %.2f)",
                 b.angleBelowViewAxisDegrees, c.halfFovVerticalDegrees))
    print(String(format: "NDC y               = %.4f", b.ndc.y))
    print(String(format: "clip.w              = %+.3f", b.clip.w))
    print("")
    print("Fall 2/3 (Y-Verankerung falsch): \(b.heightAboveWater > 0 ? "WIDERLEGT" : "BESTAETIGT")")
    print("")

    let noLook = simulate(frames: n) { $0.lookAhead = SIMD3(0, 0, 0) }.player
    let lowEye = simulate(frames: n) { $0.eyeOffset = SIMD3($0.eyeOffset.x, 1.2, $0.eyeOffset.z) }.player
    let both = simulate(frames: n) {
        $0.eyeOffset = SIMD3($0.eyeOffset.x, 1.2, $0.eyeOffset.z)
        $0.lookAhead = SIMD3(0, 0, 0)
    }.player

    print("--- Kontrafaktische Trennung, Wirkung in NDC y ---")
    print(String(format: "Baseline                      NDC y = %+.4f  Winkel %.1f  sichtbar=%@",
                 b.ndc.y, b.angleBelowViewAxisDegrees, b.inFrustum ? "ja" : "nein"))
    print(String(format: "nur lookAhead=0 (Fall 4 weg)  NDC y = %+.4f  d = %+.4f  Winkel %.1f  sichtbar=%@",
                 noLook.ndc.y, noLook.ndc.y - b.ndc.y, noLook.angleBelowViewAxisDegrees,
                 noLook.inFrustum ? "ja" : "nein"))
    print(String(format: "nur eyeOffset.y=1.2 (Fall 1)  NDC y = %+.4f  d = %+.4f  Winkel %.1f  sichtbar=%@",
                 lowEye.ndc.y, lowEye.ndc.y - b.ndc.y, lowEye.angleBelowViewAxisDegrees,
                 lowEye.inFrustum ? "ja" : "nein"))
    print(String(format: "beide zusammen                NDC y = %+.4f  Winkel %.1f  sichtbar=%@",
                 both.ndc.y, both.angleBelowViewAxisDegrees, both.inFrustum ? "ja" : "nein"))
    print("")
    let d4 = abs(noLook.ndc.y - b.ndc.y)
    let d1 = abs(lowEye.ndc.y - b.ndc.y)
    print("Rangfolge: " + (d4 >= d1 ? "Fall 4 wirkt staerker als Fall 1" : "Fall 1 wirkt staerker als Fall 4"))
    print("==============================================")
}

MainActor.assumeIsolated { main() }
