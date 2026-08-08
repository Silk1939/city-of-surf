//
//  FrameDiagnostics.swift
//  city of surf
//
//  Numerischer Beweis-Harness. Er beantwortet die Befunde der Liste ohne Bild:
//
//    Surfer fehlt        → playerInFrustum / playerDrawCalls / playerModelScale
//    keine Welle         → wave.range (max − min) liegt bei ~0, also flach
//    Coins vor der Linse → coinsInsideNearPlane > 0
//    kaputte Matrizen    → nonFiniteMatrices ist nicht leer
//
//  Jede dieser Größen ist eine reine Funktion und wird im Test-Target geprüft
//  (siehe DiagnosticsTests). Zur Laufzeit schreibt der Recorder pro Frame eine
//  Zeile JSON in die Documents des Geräts; `make pull-diagnostics` holt sie nach
//  tools/diagnostics/.
//

import Foundation
import simd

// MARK: - Datensatz

/// Ein Frame, eine Zeile JSON. Bewusst flach gehalten, damit `jq` damit arbeiten kann.
struct FrameDiagnostics: Codable {

    struct CameraInfo: Codable {
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var target: SIMD3<Float>
        var nearZ: Float
        var farZ: Float
        var fovDegrees: Float
        var aspect: Float
    }

    struct PlayerInfo: Codable {
        var position: SIMD3<Float>
        var height: Float
        /// Clip-Space des Spieler-Ursprungs, vor der Division durch w.
        var clip: SIMD4<Float>
        /// Normalized Device Coordinates. Sichtbar heißt x,y in [-1,1] und z in [0,1].
        var ndc: SIMD3<Float>
        /// Liegt der Ursprung im Frustum?
        var inFrustum: Bool
        /// Wurde tatsächlich Geometrie für den Spieler eingereiht?
        var drawn: Bool
        /// Skalierung aus der Model-Matrix des ersten Spieler-DrawItems.
        var modelScale: SIMD3<Float>
        /// Determinante derselben Matrix. 0 = entartet, negativ = gespiegelt.
        var modelDeterminant: Float
        /// Warum er nicht sichtbar ist, in Klartext — leer, wenn sichtbar.
        var invisibleReason: String
    }

    /// Draw-Calls nach Objekttyp. `instanced*` zählt Instanzen, nicht Batches.
    struct DrawCensus: Codable {
        var player: Int = 0
        var marker: Int = 0
        var water: Int = 0
        var buildings: Int = 0
        var coins: Int = 0
        var vehicles: Int = 0
        var props: Int = 0
        var fx: Int = 0
        var other: Int = 0
        var uniqueTotal: Int = 0
        var instancedBatches: Int = 0
        var instancedTotal: Int = 0
        /// True, wenn `maxObjectsPerFrame` gegriffen und Draws verschluckt hat.
        var clamped: Bool = false
    }

    /// Höhenstatistik der Wasseroberfläche im Kamerabereich.
    struct WaveStats: Codable {
        var minY: Float
        var maxY: Float
        var avgY: Float
        /// max − min. Nahe 0 heißt: flache Ebene, keine Welle (Befund B).
        var range: Float
        var samples: Int
    }

    struct Timing: Codable {
        /// Wanduhrzeit eines kompletten `draw(in:)`, inklusive Encoding.
        var cpuFrameMs: Float
        /// Zeit, die die CPU am Frame-Event auf die GPU gewartet hat.
        /// Das ist bewusst **nicht** die reine GPU-Laufzeit — die bräuchte
        /// `MTLCounterSampleBuffer`. Als Stall-Indikator reicht dieser Wert,
        /// und er verspricht nicht mehr, als er misst.
        var gpuWaitMs: Float
    }

    var frame: Int
    var time: Float
    var camera: CameraInfo
    var player: PlayerInfo
    var draws: DrawCensus
    var wave: WaveStats
    /// Coins näher an der Kamera als nearZ + 1 m — die „Nebelblasen" aus Befund C.
    var coinsInsideNearPlane: Int
    /// Namen aller Matrizen, die NaN oder Inf enthalten. Leer = sauber.
    var nonFiniteMatrices: [String]
    var timing: Timing
}

// MARK: - Reine Prüffunktionen (im Test-Target verifiziert)

enum DiagnosticsMath {

    /// Skalierung als Länge der drei Basisvektoren.
    static func scale(of m: matrix_float4x4) -> SIMD3<Float> {
        SIMD3(
            simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        )
    }

    static func determinant(of m: matrix_float4x4) -> Float {
        simd_determinant(m)
    }

    /// True, sobald irgendein Element NaN oder unendlich ist.
    static func containsNonFinite(_ m: matrix_float4x4) -> Bool {
        for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            if !c.x.isFinite || !c.y.isFinite || !c.z.isFinite || !c.w.isFinite { return true }
        }
        return false
    }

    static func containsNonFinite(_ v: SIMD3<Float>) -> Bool {
        !v.x.isFinite || !v.y.isFinite || !v.z.isFinite
    }

    /// Projiziert einen Weltpunkt. Metal-Konvention: NDC z läuft von 0 (near) bis 1 (far).
    static func project(
        _ world: SIMD3<Float>,
        viewProjection: matrix_float4x4
    ) -> (clip: SIMD4<Float>, ndc: SIMD3<Float>) {
        let clip = viewProjection * SIMD4(world.x, world.y, world.z, 1)
        guard abs(clip.w) > 1e-6 else {
            return (clip, SIMD3(repeating: .nan))
        }
        return (clip, SIMD3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w))
    }

    static func inFrustum(ndc: SIMD3<Float>) -> Bool {
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite else { return false }
        return abs(ndc.x) <= 1 && abs(ndc.y) <= 1 && ndc.z >= 0 && ndc.z <= 1
    }

    /// Klartext-Begründung, warum ein Punkt nicht im Bild landet. Leer = sichtbar.
    /// Trennt sauber zwischen „hinter der Kamera", „vor der Near-Plane", „seitlich
    /// draußen" und „über/unter dem Bildrand" — das sind vier verschiedene Ursachen.
    static func invisibleReason(clip: SIMD4<Float>, ndc: SIMD3<Float>, drawn: Bool, scale: SIMD3<Float>) -> String {
        var reasons: [String] = []
        if !drawn { reasons.append("kein DrawItem eingereiht") }
        if scale.x < 1e-4 || scale.y < 1e-4 || scale.z < 1e-4 { reasons.append("Model-Scale ~0") }
        if !ndc.x.isFinite || !ndc.y.isFinite || !ndc.z.isFinite { reasons.append("NDC ist NaN") }
        if clip.w <= 0 { reasons.append("hinter der Kamera (w<=0)") }
        if ndc.z < 0 { reasons.append("vor der Near-Plane") }
        if ndc.z > 1 { reasons.append("hinter der Far-Plane") }
        if ndc.x < -1 { reasons.append("links außerhalb") }
        if ndc.x > 1 { reasons.append("rechts außerhalb") }
        if ndc.y < -1 { reasons.append("unter dem unteren Bildrand") }
        if ndc.y > 1 { reasons.append("über dem oberen Bildrand") }
        return reasons.joined(separator: ", ")
    }

    /// Vertikale Bildposition in Pixeln für ein Bild der Höhe `pixelHeight`.
    /// Werte außerhalb 0…pixelHeight liegen außerhalb des Bildes.
    static func screenY(ndcY: Float, pixelHeight: Float) -> Float {
        (1 - (ndcY * 0.5 + 0.5)) * pixelHeight
    }
}

// MARK: - Wellenhöhe

extension FrameDiagnostics.WaveStats {

    /// Tastet die geteilte CPU-Höhenfunktion auf einem Raster vor der Kamera ab.
    ///
    /// Wichtig für die Beweisführung: das misst `WaveField`, also die Quelle, die laut
    /// Architekturregel identisch zum Vertex-Shader sein muss. Es misst **nicht** die
    /// tatsächlich gerenderten GPU-Vertices. Weicht das Bild davon ab, laufen CPU und
    /// Shader auseinander — und genau das wäre dann der Befund.
    static func measure(
        wave: WaveField,
        time: Float,
        scrollZ: Float,
        centerX: Float,
        nearZ: Float,
        farZ: Float,
        halfWidth: Float = 12,
        gridX: Int = 16,
        gridZ: Int = 48
    ) -> FrameDiagnostics.WaveStats {
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var sum: Float = 0
        var n = 0
        for iz in 0..<gridZ {
            let tz = Float(iz) / Float(max(gridZ - 1, 1))
            let z = nearZ + (farZ - nearZ) * tz
            for ix in 0..<gridX {
                let tx = Float(ix) / Float(max(gridX - 1, 1))
                let x = centerX - halfWidth + 2 * halfWidth * tx
                let y = wave.height(x: x, z: z, time: time, scrollZ: scrollZ)
                guard y.isFinite else { continue }
                minY = min(minY, y)
                maxY = max(maxY, y)
                sum += y
                n += 1
            }
        }
        guard n > 0 else {
            return FrameDiagnostics.WaveStats(minY: 0, maxY: 0, avgY: 0, range: 0, samples: 0)
        }
        return FrameDiagnostics.WaveStats(
            minY: minY, maxY: maxY, avgY: sum / Float(n), range: maxY - minY, samples: n
        )
    }
}

// MARK: - Coins vor der Linse

enum CoinDiagnostics {

    /// Zählt Coins, deren Mittelpunkt näher an der Kamera liegt als nearZ + `slack`.
    /// Genau diese erscheinen als riesige Blasen direkt vor dem Objektiv (Befund C).
    static func countInsideNearPlane(
        coins: CoinSystem,
        runDistance: Float,
        wave: WaveField,
        time: Float,
        scrollZ: Float,
        cameraEye: SIMD3<Float>,
        nearZ: Float,
        slack: Float = 1.0
    ) -> Int {
        let limit = nearZ + slack
        var n = 0
        for coin in coins.coins where coin.active {
            let p = coins.worldPosition(for: coin, runDistance: runDistance, wave: wave, time: time, scrollZ: scrollZ)
            if simd_distance(p, cameraEye) < limit { n += 1 }
        }
        return n
    }
}

// MARK: - Recorder

/// Schreibt pro Frame eine Zeile JSON. Puffert im Speicher und flusht gebündelt,
/// damit im Render-Loop nichts blockiert.
final class FrameDiagnosticsRecorder {

    /// Aufnahme aktiv. Aus = null Kosten außer einem Bool-Test pro Frame.
    static var enabled = true
    /// Nach so vielen Frames wird die Aufnahme beendet (10 s bei 60 fps).
    static var maxFrames = 600
    /// So oft wird auf die Platte geschrieben.
    static var flushEvery = 60

    private var pending: [FrameDiagnostics] = []
    private var written = 0
    private var finished = false
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "flood-surfer.diagnostics", qos: .utility)
    private let url: URL

    /// Zielpfad. Auf dem Gerät die Documents des Sandboxes, sonst tools/diagnostics/.
    static func defaultURL(fileName: String = "frames.jsonl") -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(fileName)
    }

    init(url: URL = FrameDiagnosticsRecorder.defaultURL()) {
        self.url = url
        pending.reserveCapacity(Self.flushEvery)
        try? FileManager.default.removeItem(at: url)
        print("[FloodSurfer Diag] recording to \(url.path)")
    }

    var outputPath: String { url.path }

    func record(_ d: FrameDiagnostics) {
        guard Self.enabled, !finished else { return }
        pending.append(d)
        written += 1
        if pending.count >= Self.flushEvery { flush() }
        if written >= Self.maxFrames {
            flush()
            finished = true
            print("[FloodSurfer Diag] \(written) frames geschrieben → \(url.path)")
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let encoder = self.encoder
        let url = self.url
        queue.async {
            var blob = Data()
            for record in batch {
                guard let line = try? encoder.encode(record) else { continue }
                blob.append(line)
                blob.append(0x0A)  // \n
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: blob)
                try? handle.close()
            } else {
                try? blob.write(to: url)
            }
        }
    }
}
