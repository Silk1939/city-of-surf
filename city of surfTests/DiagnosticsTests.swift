//
//  DiagnosticsTests.swift
//  city of surfTests
//
//  Eine Assertion pro Befund. Ein Schritt der Reihenfolge gilt erst als fertig,
//  wenn die zugehörige Assertion grün ist.
//
//  Stand beim Anlegen (nur Schritt 1 erledigt):
//    A  Surfer sichtbar      → ROT, Ursache wird hier gemessen
//    B  Welle nicht flach    → prüft das geteilte CPU-Höhenfeld
//    C  Coins vor der Linse  → misst den Near-Plane-Zähler
//    Matrizen endlich        → NaN/Inf-Wächter
//

import XCTest
import simd
@testable import city_of_surf

@MainActor
final class DiagnosticsTests: XCTestCase {

    /// 2 Sekunden geradeaus reichen, damit sich Kamera und Auftrieb eingeschwungen haben.
    private static let frames = 120

    private func simulate(_ n: Int = frames) -> DiagnosticsHarness.Result {
        DiagnosticsHarness.run(frameCount: n)
    }

    // MARK: - Befund A: Der Surfer muss im Bild sein

    /// Der Spieler-Ursprung muss im Frustum liegen. Schlägt fehl, solange die
    /// Kamera ihn aus dem Bild kippt.
    func testBefundA_playerOriginInsideFrustum() {
        let result = simulate()
        DiagnosticsHarness.dump(result, fileName: "befund-a.jsonl")
        let p = result.last.player
        XCTAssertTrue(
            p.inFrustum,
            """
            Spieler-Ursprung außerhalb des Frustums.
            NDC = (\(p.ndc.x), \(p.ndc.y), \(p.ndc.z))
            clip.w = \(p.clip.w)
            Grund: \(p.invisibleReason)
            Bildzeile bei 2532 px Höhe: \(DiagnosticsMath.screenY(ndcY: p.ndc.y, pixelHeight: 2532))
            """
        )
    }

    /// Schärfere Variante für Schritt 3: der Surfer soll im unteren Bilddrittel sitzen,
    /// also NDC y zwischen -0.85 und -0.15.
    func testSchritt3_playerSitsInLowerThird() {
        let p = simulate().last.player
        XCTAssertTrue(
            p.ndc.y >= -0.85 && p.ndc.y <= -0.15,
            "Spieler nicht im unteren Bilddrittel: NDC y = \(p.ndc.y) (Ziel -0.85 … -0.15)"
        )
    }

    /// Die Model-Matrix des Spielers darf weder entartet noch gespiegelt sein.
    /// Das widerlegt oder bestätigt den Kandidaten „Scale 0 / uninitialisiert".
    func testBefundA_playerModelMatrixIsSane() {
        let p = simulate().last.player
        XCTAssertGreaterThan(p.modelScale.x, 0.001, "Model-Scale X ist ~0")
        XCTAssertGreaterThan(p.modelScale.y, 0.001, "Model-Scale Y ist ~0")
        XCTAssertGreaterThan(p.modelScale.z, 0.001, "Model-Scale Z ist ~0")
        XCTAssertGreaterThan(
            abs(p.modelDeterminant), 0.001,
            "Model-Matrix ist entartet, Determinante = \(p.modelDeterminant)"
        )
    }

    // MARK: - Befund B: Es muss eine Welle geben

    /// Die geteilte Höhenfunktion muss im Kamerabereich echte Auslenkung liefern.
    /// Liegt `range` nahe 0, ist das Wasser eine flache Ebene.
    ///
    /// Wichtig: das misst `WaveField` auf der CPU, nicht die gerenderten GPU-Vertices.
    /// Grün heißt hier „die geteilte Quelle ist nicht flach", nicht „im Bild ist eine
    /// Welle zu sehen". Letzteres braucht einen Gerätescreenshot.
    func testBefundB_waveFieldIsNotFlat() {
        let w = simulate().last.wave
        XCTAssertGreaterThan(
            w.range, 0.5,
            "Höhenfeld ist praktisch flach: min=\(w.minY) max=\(w.maxY) range=\(w.range)"
        )
    }

    /// Die Welle muss sich auch bewegen, nicht nur einmalig ausgelenkt sein.
    func testBefundB_waveChangesOverTime() {
        let result = simulate(180)
        let early = result.frames[30].wave.avgY
        let late = result.frames[170].wave.avgY
        XCTAssertGreaterThan(
            abs(late - early), 0.01,
            "Mittlere Wellenhöhe ändert sich nicht: \(early) → \(late)"
        )
    }

    // MARK: - Befund C: Keine Coins vor der Linse

    /// Kein Coin darf näher an der Kamera liegen als Near-Plane + 1 m. Genau diese
    /// erscheinen als riesige Blasen direkt vor dem Objektiv.
    func testBefundC_noCoinsInsideNearPlane() {
        let result = simulate(300)
        let worst = result.frames.map(\.coinsInsideNearPlane).max() ?? 0
        XCTAssertEqual(
            worst, 0,
            "In mindestens einem Frame lagen \(worst) Coins innerhalb von nearZ + 1 m"
        )
    }

    // MARK: - Zahlenhygiene

    /// Keine Matrix darf NaN oder Inf enthalten — über den ganzen Lauf.
    func testMatricesStayFinite() {
        let result = simulate(300)
        let broken = result.frames.filter { !$0.nonFiniteMatrices.isEmpty }
        XCTAssertTrue(
            broken.isEmpty,
            "NaN/Inf in Frame \(broken.first?.frame ?? -1): \(broken.first?.nonFiniteMatrices ?? [])"
        )
    }

    /// Der Spieler darf niemals unter die Wasseroberfläche sacken oder wegfliegen.
    func testPlayerStaysInPlausibleRange() {
        let result = simulate(300)
        for f in result.frames {
            XCTAssertTrue(
                f.player.position.y > -5 && f.player.position.y < 60,
                "Spieler-Y außerhalb plausibler Grenzen in Frame \(f.frame): \(f.player.position.y)"
            )
            XCTAssertTrue(
                abs(f.player.position.x) < 20,
                "Spieler-X außerhalb der Straße in Frame \(f.frame): \(f.player.position.x)"
            )
        }
    }

    // MARK: - Selbsttest des Harness

    /// Wenn die Projektionsmathematik selbst falsch wäre, wären alle anderen Zahlen
    /// wertlos. Ein Punkt direkt vor der Kamera muss in der Bildmitte landen.
    func testProjectionMathIsTrustworthy() {
        let eye = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(0, 0, 10)
        let view = Math.lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
        let proj = Math.perspective(
            fovyRadians: Math.radians(60), aspectRatio: 0.5, nearZ: 0.1, farZ: 100
        )
        let centre = DiagnosticsMath.project(SIMD3(0, 0, 10), viewProjection: proj * view)
        XCTAssertEqual(centre.ndc.x, 0, accuracy: 1e-4)
        XCTAssertEqual(centre.ndc.y, 0, accuracy: 1e-4)
        XCTAssertTrue(DiagnosticsMath.inFrustum(ndc: centre.ndc))

        // Punkt hinter der Kamera: w muss negativ werden und der Grund muss das sagen.
        let behind = DiagnosticsMath.project(SIMD3(0, 0, -10), viewProjection: proj * view)
        XCTAssertLessThan(behind.clip.w, 0)
        let reason = DiagnosticsMath.invisibleReason(
            clip: behind.clip, ndc: behind.ndc, drawn: true, scale: SIMD3(1, 1, 1)
        )
        XCTAssertTrue(reason.contains("hinter der Kamera"), "Grund war: \(reason)")

        // Punkt weit unterhalb: der Grund muss „unter dem unteren Bildrand" nennen.
        let below = DiagnosticsMath.project(SIMD3(0, -40, 10), viewProjection: proj * view)
        let belowReason = DiagnosticsMath.invisibleReason(
            clip: below.clip, ndc: below.ndc, drawn: true, scale: SIMD3(1, 1, 1)
        )
        XCTAssertTrue(belowReason.contains("unter dem unteren Bildrand"), "Grund war: \(belowReason)")
    }
}
