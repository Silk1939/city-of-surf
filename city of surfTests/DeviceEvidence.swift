//
//  DeviceEvidence.swift
//  city of surfTests
//
//  Trennt Kategorie 1 von Kategorie 2.
//
//  Kategorie 1 darf auf dem Simulator gelten. Das sind Aussagen über Mathematik,
//  Höhenfeld, Spawn-Positionen und Projektion — alles, was ohne GPU entscheidbar
//  ist und wo Simulator und Gerät dasselbe Ergebnis liefern müssen.
//
//  Kategorie 2 kann der Simulator prinzipiell nicht beantworten: echte Draw-Calls,
//  die vom Vertex-Shader `flood_displace` erzeugten Vertexhöhen, Depth- und
//  Blend-Verhalten, Frame- und GPU-Zeit. Metal 4 existiert im Simulator-SDK nicht
//  (`cannot find type 'MTL4RenderCommandEncoder' in scope`), es gibt dort also
//  buchstäblich keinen Renderer.
//
//  ACHTUNG, das ist der Kern dieser Datei:
//  Ein übersprungener Test ist KEIN Beleg. Er ist die Feststellung, dass hier nicht
//  gemessen wurde. Grün wäre eine Lüge, deshalb wird übersprungen statt bestanden.
//

import XCTest
import Foundation
@testable import city_of_surf

enum DeviceEvidence {

    /// Repo-Wurzel, abgeleitet aus dem Quellpfad dieser Datei. Der Simulator läuft
    /// auf demselben Dateisystem und kann den Pfad lesen.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/city of surfTests/DeviceEvidence.swift
            .deletingLastPathComponent()     // …/city of surfTests
            .deletingLastPathComponent()     // …/city of surf (Repo)
    }

    /// Hierhin legt `make device-diagnostics` die Aufzeichnung vom Gerät.
    static var jsonlURL: URL {
        repoRoot.appendingPathComponent("tools/diagnostics/frames.jsonl")
    }

    /// Lädt die Gerätemessung, falls vorhanden.
    static func load() -> [FrameDiagnostics]? {
        guard let data = try? Data(contentsOf: jsonlURL) else { return nil }
        let decoder = JSONDecoder()
        var frames: [FrameDiagnostics] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let f = try? decoder.decode(FrameDiagnostics.self, from: Data(line)) else { continue }
            frames.append(f)
        }
        return frames.isEmpty ? nil : frames
    }
}

extension XCTestCase {

    /// Kategorie 2: verlangt eine echte Gerätemessung. Fehlt sie, wird der Test
    /// übersprungen — niemals grün, denn ohne Messung gibt es keinen Beleg.
    func requireDevice(_ what: String) throws -> [FrameDiagnostics] {
        guard let frames = DeviceEvidence.load() else {
            throw XCTSkip("""
            ÜBERSPRUNGEN, KEIN BELEG: \(what)
            Diese Zahl kann nur ein Gerätelauf liefern. Der Simulator hat keinen
            Metal-4-Renderer, also auch keine Draw-Calls, keine Shader-Vertices,
            kein Depth-/Blend-Verhalten und keine GPU-Zeit.
            So entsteht der Beleg:
              1. iPhone anschließen und entsperren
              2. make device-diagnostics
              3. Danach liegt \(DeviceEvidence.jsonlURL.path)
              4. Diesen Test erneut laufen lassen
            Solange gilt dieser Punkt als offen, nicht als bestanden.
            """)
        }
        return frames
    }
}
