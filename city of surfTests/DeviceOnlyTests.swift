//
//  DeviceOnlyTests.swift
//  city of surfTests
//
//  KATEGORIE 2. Diese Tests werden auf dem Simulator übersprungen und dürfen dort
//  niemals grün erscheinen. Ein übersprungener Test ist kein Beleg, sondern die
//  Feststellung, dass an dieser Stelle nicht gemessen wurde.
//
//  Grund: Das iPhoneSimulator-SDK kennt die Metal-4-Typen nicht
//  (`cannot find type 'MTL4RenderCommandEncoder' in scope`). Im Simulator existiert
//  also kein Renderer, keine Draw-Call-Zahl, kein Shader-Vertex, kein Depth-State
//  und keine GPU-Zeit.
//
//  Belegweg: iPhone anschließen, `make device-diagnostics`, danach erneut laufen.
//  Vollständige Liste der offenen Punkte: docs/OPEN_DEVICE_CHECKS.md
//

import XCTest
@testable import city_of_surf

final class DeviceOnlyTests: XCTestCase {

    // MARK: - Draw-Calls je Objekttyp

    /// Der Spieler muss im echten Draw-Loop Geometrie einreihen.
    /// Das ist der Kandidat „Player-Mesh wird nie eingereiht" aus Befund A, und
    /// nur der Gerätelauf kann ihn abschließend widerlegen.
    func testGeraet_playerHasDrawCalls() throws {
        let frames = try requireDevice("Draw-Call-Zahl des Spielers")
        let last = frames[frames.count - 1]
        XCTAssertEqual(last.player.drawStatus, .drawn, "Spieler wurde nicht gezeichnet")
        XCTAssertGreaterThan(last.draws.player, 0, "Null Draw-Calls für den Spieler")
    }

    /// Draw-Calls je Objekttyp müssen plausibel sein und das Objekt-Limit darf
    /// nicht greifen, sonst verschluckt das Clamping stillschweigend Geometrie.
    func testGeraet_drawCensusPerObjectType() throws {
        let frames = try requireDevice("Draw-Calls je Objekttyp")
        let last = frames[frames.count - 1]
        XCTAssertFalse(last.draws.clamped, "maxObjectsPerFrame hat gegriffen, Draws gehen verloren")
        XCTAssertGreaterThan(last.draws.water, 0, "Keine Wasserfläche gezeichnet")
        XCTAssertGreaterThan(last.draws.buildings, 0, "Keine Gebäude gezeichnet")
    }

    // MARK: - Befund B auf der GPU

    /// Die vom Vertex-Shader `flood_displace` tatsächlich erzeugten Vertexhöhen.
    ///
    /// Achtung: dieser Test ist auch mit angeschlossenem Gerät noch nicht erfüllbar.
    /// `FrameDiagnostics` misst das CPU-Höhenfeld, nicht die GPU-Ausgabe. Dafür
    /// bräuchte es einen Readback-Pass oder eine Xcode-Frame-Capture. Der Test steht
    /// hier, damit die Lücke sichtbar bleibt statt vergessen zu werden.
    func testGeraet_shaderVertexHeightsAreDisplaced() throws {
        _ = try requireDevice("Vertexhöhen aus flood_displace")
        throw XCTSkip("""
        ÜBERSPRUNGEN, KEIN BELEG: Vertexhöhen aus dem Vertex-Shader.
        FrameDiagnostics misst das CPU-WaveField. Die GPU-Ausgabe von flood_displace
        ist damit NICHT belegt. Nötig wäre ein Readback-Pass oder eine
        Xcode-Frame-Capture. Siehe docs/OPEN_DEVICE_CHECKS.md.
        """)
    }

    // MARK: - Befund C auf der GPU

    /// Depth-Write und Alpha-Blending der Coins.
    ///
    /// Der Spawn-Test in DiagnosticsTests deckt ausschließlich die Weltposition ab.
    /// Ob Coins mit Alpha-Blending ohne Depth-Write gezeichnet werden und ob ihre
    /// Tiefensortierung stimmt, ist damit ausdrücklich nicht belegt.
    func testGeraet_coinDepthAndBlendState() throws {
        _ = try requireDevice("Depth-Write und Blend-State der Coins")
        throw XCTSkip("""
        ÜBERSPRUNGEN, KEIN BELEG: Depth-Write und Alpha-Blending der Coins.
        Pipeline-States stehen bisher nicht in FrameDiagnostics. Belegbar über eine
        Xcode-Frame-Capture oder indem der Renderer die Blend- und Depth-Konfiguration
        pro Materialklasse mit aufzeichnet. Siehe docs/OPEN_DEVICE_CHECKS.md.
        """)
    }

    // MARK: - Performance

    /// Frame- und GPU-Wartezeit. Ziel sind stabile 60 fps, also rund 16.7 ms.
    func testGeraet_frameTimingWithinBudget() throws {
        let frames = try requireDevice("Frame- und GPU-Zeit")
        let cpu = frames.map(\.timing.cpuFrameMs)
        let worst = cpu.max() ?? 0
        let mean = cpu.reduce(0, +) / Float(max(cpu.count, 1))
        XCTAssertLessThan(mean, 16.7, "Mittlere CPU-Framezeit \(mean) ms über dem 60-fps-Budget")
        XCTAssertLessThan(worst, 33.4, "Schlechtester Frame \(worst) ms — sichtbarer Ruckler")
    }
}
