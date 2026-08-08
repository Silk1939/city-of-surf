//
//  DiagnosticsHarness.swift
//  city of surfTests
//
//  Headless-Lauf des Spiels ohne Metal. Er benutzt dieselben Typen wie der Renderer
//  (GameState, ChaseCamera.follow, SurferVisual.rootTransform, FrameDiagnostics),
//  damit die Messung nicht von dem abweicht, was auf dem Gerät läuft.
//
//  Was er NICHT kann: echte GPU-Draw-Calls, gerenderte Vertices, Frame- und GPU-Zeit.
//  Diese Felder bleiben hier leer und kommen ausschließlich vom Gerätelauf.
//

import Foundation
import simd
@testable import city_of_surf

@MainActor
struct DiagnosticsHarness {

    /// iPhone 12 / 17 Portrait. Nur das Seitenverhältnis zählt für die Projektion.
    static let portraitAspect: Float = 1170.0 / 2532.0

    struct Result {
        var frames: [FrameDiagnostics]
        var last: FrameDiagnostics { frames[frames.count - 1] }
        var first: FrameDiagnostics { frames[0] }
    }

    /// Simuliert `frameCount` Frames bei 60 Hz und liefert pro Frame einen Datensatz.
    /// `steer` erlaubt es, Eingaben nachzustellen (z. B. Kurven für Befund C/H).
    static func run(
        frameCount: Int,
        aspect: Float = portraitAspect,
        steer: ((GameState, Int) -> Void)? = nil
    ) -> Result {
        let state = GameState()
        state.reset()
        var camera = ChaseCamera()
        let dt: Float = 1.0 / 60.0
        var records: [FrameDiagnostics] = []
        records.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            steer?(state, frame)
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

            let viewM = camera.viewMatrix(follow: state.surfer.position)
            let projM = camera.projectionMatrix(aspect: aspect)
            let viewProj = projM * viewM
            let playerModel = SurferVisual.rootTransform(surfer: state.surfer, rootLean: state.surfer.lean)
            let projected = DiagnosticsMath.project(state.surfer.position, viewProjection: viewProj)
            let scale = DiagnosticsMath.scale(of: playerModel)
            let eye = camera.smoothEye
            let target = state.surfer.position + camera.lookAhead

            var nonFinite: [String] = []
            if DiagnosticsMath.containsNonFinite(viewM) { nonFinite.append("view") }
            if DiagnosticsMath.containsNonFinite(projM) { nonFinite.append("projection") }
            if DiagnosticsMath.containsNonFinite(viewProj) { nonFinite.append("viewProjection") }
            if DiagnosticsMath.containsNonFinite(playerModel) { nonFinite.append("playerModel") }
            if DiagnosticsMath.containsNonFinite(state.surfer.position) { nonFinite.append("playerPosition") }
            if DiagnosticsMath.containsNonFinite(eye) { nonFinite.append("cameraEye") }

            records.append(FrameDiagnostics(
                frame: frame,
                time: state.time,
                camera: .init(
                    eye: eye,
                    forward: simd_normalize(target - eye),
                    target: target,
                    nearZ: camera.nearZ,
                    farZ: camera.farZ,
                    fovDegrees: camera.fovDegrees,
                    aspect: aspect
                ),
                player: .init(
                    position: state.surfer.position,
                    height: state.surfer.currentHeight,
                    clip: projected.clip,
                    ndc: projected.ndc,
                    inFrustum: DiagnosticsMath.inFrustum(ndc: projected.ndc),
                    // Headless: der Draw-Loop läuft nicht. `drawn` bezieht sich hier
                    // darauf, dass eine gültige Wurzeltransform existiert.
                    drawn: !DiagnosticsMath.containsNonFinite(playerModel),
                    modelScale: scale,
                    modelDeterminant: DiagnosticsMath.determinant(of: playerModel),
                    invisibleReason: DiagnosticsMath.invisibleReason(
                        clip: projected.clip, ndc: projected.ndc, drawn: true, scale: scale
                    )
                ),
                draws: .init(),
                wave: .measure(
                    wave: state.wave,
                    time: state.time,
                    scrollZ: state.scrollZ,
                    centerX: state.surfer.position.x,
                    nearZ: eye.z,
                    farZ: eye.z + 80
                ),
                coinsInsideNearPlane: CoinDiagnostics.countInsideNearPlane(
                    coins: state.coinSystem,
                    runDistance: state.runDistance,
                    wave: state.wave,
                    time: state.time,
                    scrollZ: state.scrollZ,
                    cameraEye: eye,
                    nearZ: camera.nearZ
                ),
                nonFiniteMatrices: nonFinite,
                timing: .init(cpuFrameMs: 0, gpuWaitMs: 0)
            ))
        }
        return Result(frames: records)
    }

    /// Schreibt den Lauf als JSON Lines nach tools/diagnostics/, damit die Zahlen
    /// nach dem Testlauf nachlesbar sind statt nur in der Konsole zu verpuffen.
    @discardableResult
    static func dump(_ result: Result, fileName: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flood-surfer-diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        var blob = Data()
        for record in result.frames {
            guard let line = try? encoder.encode(record) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        try? blob.write(to: url)
        print("[Harness] \(result.frames.count) Frames → \(url.path)")
        return url
    }
}
