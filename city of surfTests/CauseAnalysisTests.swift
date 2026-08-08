//
//  CauseAnalysisTests.swift
//  city of surfTests
//
//  Ursachenanalyse zu Befund A: NDC y = -1.47 ist kein Feinjustierungsproblem.
//  Der Test entscheidet zwischen vier Fällen, statt einen davon zu vermuten:
//
//    1  Kamera zu hoch oder blickt zu flach.
//    2  Surfer in Y falsch verankert (z. B. auf y=0 statt auf Wasserhöhe).
//    3  Kamera und Surfer nutzen unterschiedliche Y-Referenzen.
//    4  Der Kamera-Zielpunkt ist ein anderer Punkt als der Surfer.
//
//  Fall 2 und 3 wären an `heightAboveWater` erkennbar: stark negativ hieße, der
//  Surfer steckt unter Wasser und die Kamera ist unschuldig.
//  Fall 1 und 4 werden kontrafaktisch getrennt: einzelne Kameraparameter werden
//  abgeschaltet, und der Effekt wird in NDC-Einheiten beziffert.
//
//  Dieser Test verändert nichts. Er misst und schreibt das Ergebnis in die Konsole.
//

import XCTest
import simd
@testable import city_of_surf

@MainActor
final class CauseAnalysisTests: XCTestCase {

    private static let frames = 120

    /// Misst die Verankerung und beziffert den Anteil jeder Ursache in NDC-Einheiten.
    /// Das Ergebnis landet zusätzlich als Textdatei, weil der Konsolen-Output eines
    /// Testlaufs im xcodebuild-Log nicht auftaucht.
    func testUrsachenanalyseBefundA() {
        let baseline = DiagnosticsHarness.run(frameCount: Self.frames)
        let b = baseline.last

        // --- Fall 4: Zielpunkt liegt nicht auf dem Surfer ---
        // lookAhead.z = 10 zielt 10 m vor den Surfer. Kontrafaktisch: direkt auf ihn.
        let noLookAhead = DiagnosticsHarness.run(frameCount: Self.frames) { cam in
            cam.lookAhead = SIMD3(0, 0, 0)
        }.last
        let deltaCase4 = noLookAhead.player.ndc.y - b.player.ndc.y

        // --- Fall 1: Kamera zu hoch / zu flach ---
        // eyeOffset.y = 5.2 über Wasser bei nur 2.2 m Abstand nach hinten.
        // Kontrafaktisch: Auge auf Surferhöhe absenken, lookAhead unverändert.
        let lowEye = DiagnosticsHarness.run(frameCount: Self.frames) { cam in
            cam.eyeOffset = SIMD3(cam.eyeOffset.x, 1.2, cam.eyeOffset.z)
        }.last
        let deltaCase1 = lowEye.player.ndc.y - b.player.ndc.y

        // --- Beide zusammen ---
        let both = DiagnosticsHarness.run(frameCount: Self.frames) { cam in
            cam.eyeOffset = SIMD3(cam.eyeOffset.x, 1.2, cam.eyeOffset.z)
            cam.lookAhead = SIMD3(0, 0, 0)
        }.last

        // Fall 2/3: der Surfer wird in SurferController auf avgH + 0.36 + halbe
        // Körperhöhe gesetzt, die Kamera auf waveHeight + eyeOffset.y. Beide lesen
        // dasselbe Höhenfeld. Positive Differenz = Surfer sitzt über Wasser.
        let anchoredCorrectly = b.player.heightAboveWater > 0

        var out: [String] = []
        func line(_ s: String) { out.append(s) }

        line("========== URSACHENANALYSE BEFUND A ==========")
        line(String(format: "Kamera-Y            = %.3f", b.camera.eye.y))
        line(String(format: "Kamera-Pitch        = %.2f Grad (negativ = nach unten)", b.camera.pitchDegrees))
        line(String(format: "halbes vert. FOV    = %.2f Grad", b.camera.halfFovVerticalDegrees))
        line(String(format: "LookAt-Zielpunkt    = (%.3f, %.3f, %.3f)",
                    b.camera.target.x, b.camera.target.y, b.camera.target.z))
        line(String(format: "Surfer-Y            = %.3f", b.player.position.y))
        line(String(format: "Wasserhoehe (x,z)   = %.3f", b.player.waterHeight))
        line(String(format: "Surfer-Y - Wasser   = %+.3f   <<< entscheidende Zahl", b.player.heightAboveWater))
        line(String(format: "Winkel unter Achse  = %.2f Grad (Grenze %.2f)",
                    b.player.angleBelowViewAxisDegrees, b.camera.halfFovVerticalDegrees))
        line(String(format: "NDC y               = %.4f", b.player.ndc.y))
        line(String(format: "clip.w              = %+.3f", b.player.clip.w))
        line("")
        line("Fall 2/3 (Y-Verankerung falsch): \(anchoredCorrectly ? "WIDERLEGT" : "BESTAETIGT")")
        line("")
        line("--- Kontrafaktische Trennung, Wirkung in NDC y ---")
        line(String(format: "Baseline                      NDC y = %+.4f  Winkel %.1f",
                    b.player.ndc.y, b.player.angleBelowViewAxisDegrees))
        line(String(format: "nur lookAhead=0 (Fall 4 weg)  NDC y = %+.4f  d = %+.4f  Winkel %.1f",
                    noLookAhead.player.ndc.y, deltaCase4, noLookAhead.player.angleBelowViewAxisDegrees))
        line(String(format: "nur eyeOffset.y=1.2 (Fall 1)  NDC y = %+.4f  d = %+.4f  Winkel %.1f",
                    lowEye.player.ndc.y, deltaCase1, lowEye.player.angleBelowViewAxisDegrees))
        line(String(format: "beide zusammen                NDC y = %+.4f  Winkel %.1f",
                    both.player.ndc.y, both.player.angleBelowViewAxisDegrees))
        line("")
        line("sichtbar? baseline=\(b.player.inFrustum) lookAhead0=\(noLookAhead.player.inFrustum) lowEye=\(lowEye.player.inFrustum) beide=\(both.player.inFrustum)")
        line("Rangfolge: " + (abs(deltaCase4) >= abs(deltaCase1)
                              ? "Fall 4 wirkt staerker als Fall 1"
                              : "Fall 1 wirkt staerker als Fall 4"))
        line("==============================================")

        let text = out.joined(separator: "\n")
        print("\n" + text + "\n")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flood-surfer-diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("cause-analysis.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Der Test dokumentiert; die Bewertung steht in der Datei.
        // Einzige harte Zusage: die Messung selbst ist brauchbar.
        XCTAssertTrue(b.player.waterHeight.isFinite)
        XCTAssertTrue(b.player.heightAboveWater.isFinite)
        XCTAssertTrue(b.camera.pitchDegrees.isFinite)
    }

    /// Fall 2/3 als eigene Assertion: der Surfer muss über der Wasseroberfläche
    /// sitzen, die dasselbe Höhenfeld liefert, das auch die Kamera liest.
    func testSurferIstAufWasserhoeheVerankert() {
        let result = DiagnosticsHarness.run(frameCount: 300)
        for f in result.frames {
            XCTAssertGreaterThan(
                f.player.heightAboveWater, 0,
                "Surfer unter Wasser in Frame \(f.frame): y=\(f.player.position.y) Wasser=\(f.player.waterHeight)"
            )
        }
    }
}
