//
//  HeroWaveOverhangTests.swift
//  city of surfTests
//
//  Der Beleg für Schritt 1: die Lippe der Hero-Wave hängt wirklich über.
//
//  Kategorie 1 — reine CPU-Mathematik aus `WaveProfile.h`, kein Renderer, keine GPU.
//  Darf deshalb im Simulator laufen und gilt dort auch als Beleg.
//
//  Messverfahren: die Profilkurve wird fein abgetastet, auf die Ebene (Welt-z, y)
//  projiziert und mit Senkrechten geschnitten. Ein Höhenfeld liefert pro Senkrechter
//  genau 1 Schnitt. Eine echte Barrel liefert 3: Flanke, Lippenunterseite,
//  Lippenoberseite. Die Assertion verlangt >= 3.
//

import XCTest
import simd
@testable import city_of_surf

final class HeroWaveOverhangTests: XCTestCase {

    /// Abtastpunkte entlang der Profilkurve.
    private static let samples = 8000
    /// Kandidaten-Senkrechte über die z-Spanne der Kurve.
    private static let verticals = 2000

    /// Schnitte einer Senkrechten bei `z0` mit dem Streckenzug. Halboffenes
    /// Intervall, damit ein exakt getroffener Stützpunkt nicht doppelt zählt.
    private func crossings(_ curve: [SIMD2<Float>], at z0: Float) -> [Float] {
        var hits: [Float] = []
        for i in 0..<(curve.count - 1) {
            let a = curve[i], b = curve[i + 1]
            guard (a.x <= z0 && z0 < b.x) || (b.x <= z0 && z0 < a.x) else { continue }
            let f = (z0 - a.x) / (b.x - a.x)
            hits.append(a.y + f * (b.y - a.y))
        }
        return hits.sorted()
    }

    /// Maximale Schnittzahl über alle Senkrechten, plus die Senkrechte, an der sie auftritt.
    private func worstVertical(_ curve: [SIMD2<Float>]) -> (count: Int, z: Float, heights: [Float]) {
        let zMin = curve.map(\.x).min()!
        let zMax = curve.map(\.x).max()!
        var best = (count: 0, z: zMin, heights: [Float]())
        for j in 1..<Self.verticals {
            let z0 = zMin + (zMax - zMin) * Float(j) / Float(Self.verticals)
            let hits = crossings(curve, at: z0)
            if hits.count > best.count { best = (hits.count, z0, hits) }
        }
        return best
    }

    /// Breite des z-Bands, in dem mehr als eine Oberflächenhöhe existiert — das ist
    /// die Überhangtiefe in Metern.
    private func overhangBand(_ curve: [SIMD2<Float>], minimumCrossings: Int) -> Float {
        let zMin = curve.map(\.x).min()!
        let zMax = curve.map(\.x).max()!
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for j in 1..<Self.verticals {
            let z0 = zMin + (zMax - zMin) * Float(j) / Float(Self.verticals)
            guard crossings(curve, at: z0).count >= minimumCrossings else { continue }
            lo = min(lo, z0)
            hi = max(hi, z0)
        }
        return hi >= lo ? hi - lo : 0
    }

    func testLippeHaengtUeber_MindestensDreiSchnitteProSenkrechter() {
        let profile = HeroWave.sampledWorldProfile(samples: Self.samples)
        // Projektion auf (Welt-z, y). v ist konstant, x trägt in Schritt 1 nichts bei.
        let curve = profile.map { SIMD2($0.z, $0.y) }

        let worst = worstVertical(curve)
        let overhang = overhangBand(curve, minimumCrossings: 2)
        let tubeBand = overhangBand(curve, minimumCrossings: 3)

        let crest = curve.max { $0.y < $1.y }!
        let tip = curve.last!
        // Wie weit die Lippenspitze in z über den vordersten Punkt der Flanke hinausragt.
        let tipReach = abs(tip.x - curve.map(\.x).min()!)

        var out: [String] = []
        func line(_ s: String) { out.append(s) }

        line("========== UEBERHANG-NACHWEIS HERO-WAVE ==========")
        line(String(format: "thetaMax        = %.1f Grad", HeroWave.defaultThetaMaxDegrees))
        line(String(format: "waveHeight      = %.2f m   barrelRadius = %.2f m",
                    HeroWave.defaultWaveHeight, HeroWave.defaultBarrelRadius))
        line(String(format: "footLength      = %.2f m   breakPhase   = %.2f",
                    HeroWave.defaultFootLength, HeroWave.defaultBreakPhase))
        line(String(format: "heightScale     = %.6f (Rohkurve -> waveHeight)", HeroWave.defaultHeightScale))
        line(String(format: "Abtastpunkte    = %d, Senkrechte = %d", Self.samples, Self.verticals))
        line("")
        line(String(format: "Kamm            = (z %.3f, y %.3f)", crest.x, crest.y))
        line(String(format: "Lippenspitze    = (z %.3f, y %.3f)", tip.x, tip.y))
        line(String(format: "Schnitte max    = %d bei z = %.3f", worst.count, worst.z))
        line("Hoehen dort     = " + worst.heights.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        line(String(format: "Ueberhangtiefe  = %.3f m (z-Band mit >1 Oberflaechenhoehe)", overhang))
        line(String(format: "Roehrenband     = %.3f m (z-Band mit >=3 Schnitten)", tubeBand))
        line(String(format: "Lippenreichweite= %.3f m (Spitze bis vorderster Flankenpunkt)", tipReach))
        line("")

        // Gegenprobe: der vom Zielbild geschaetzte Wurfwinkel reicht nicht. Unter 270 Grad
        // bleibt cos(theta) negativ, die Lippe dreht nie nach vorn ab, es gibt nur 2 Schnitte.
        line("--- Gegenprobe ueber thetaMax ---")
        for theta in [Float(230), 270, 280, 300, 330] {
            let c = HeroWave.sampledWorldProfile(samples: 2000, thetaMaxDegrees: theta)
                .map { SIMD2($0.z, $0.y) }
            let w = worstVertical(c)
            line(String(format: "thetaMax %5.1f Grad -> max %d Schnitte, Ueberhang %.3f m",
                        theta, w.count, overhangBand(c, minimumCrossings: 2)))
        }
        line("==================================================")

        let text = out.joined(separator: "\n")
        print("\n" + text + "\n")
        // Fester Host-Pfad: der Simulator sieht absolute Pfade des Macs, der
        // Container-tmp aus NSTemporaryDirectory() wäre von außen nicht auffindbar.
        let dir = URL(fileURLWithPath: "/tmp/flood-surfer-diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("hero-wave-overhang.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertGreaterThanOrEqual(
            worst.count, 3,
            "Die Lippe haengt nicht ueber: hoechstens \(worst.count) Schnitte pro Senkrechter. "
            + "1 = Hoehenfeld, 2 = Ueberhang ohne geschlossene Roehre, >=3 = Barrel."
        )
        XCTAssertGreaterThan(
            overhang, 0,
            "Kein z-Band mit mehr als einer Oberflaechenhoehe — die Kurve ist ein Hoehenfeld."
        )
    }
}
