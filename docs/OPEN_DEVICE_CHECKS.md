# Offene Punkte, die nur ein Gerätelauf belegen kann

Diese Liste existiert, damit keiner der Punkte durch einen grünen Simulatorlauf
stillschweigend als erledigt gilt. **Ein übersprungener Test ist kein Beleg.**

Der Simulator kann diese Fragen nicht beantworten, weil das iPhoneSimulator-SDK die
Metal-4-Typen nicht kennt (`cannot find type 'MTL4RenderCommandEncoder' in scope`).
Dort läuft kein Renderer, also gibt es keine Draw-Calls, keine Shader-Vertices, keine
Pipeline-States und keine GPU-Zeit.

So entsteht der Beleg:

1. iPhone anschließen und entsperren
2. `make device-diagnostics`
3. Ergebnis liegt danach in `tools/diagnostics/frames.jsonl`
4. `make diagnostics` erneut laufen lassen — die Kategorie-2-Tests springen dann an

---

## Offen, sobald ein Gerät angeschlossen ist

| Punkt | Test | Befund |
|---|---|---|
| Draw-Call-Zahl des Spielers, `drawStatus == .drawn` | `testGeraet_playerHasDrawCalls` | A |
| Draw-Calls je Objekttyp, Clamping durch `maxObjectsPerFrame` | `testGeraet_drawCensusPerObjectType` | A |
| Determinante der echten `DrawItem`-Model-Matrix | `testGeraet_playerHasDrawCalls` | A |
| Frame- und GPU-Zeit gegen das 60-fps-Budget | `testGeraet_frameTimingWithinBudget` | 12 |

## Offen und auch mit Gerät noch nicht instrumentiert

Diese Punkte brauchen zusätzlich Arbeit am Renderer oder eine Xcode-Frame-Capture.
Sie stehen hier, damit die Lücke sichtbar bleibt.

### Befund B — die tatsächlich gerenderte Wellengeometrie

`FrameDiagnostics.wave` misst `WaveField` auf der CPU. Das ist laut Architekturregel
die geteilte Quelle, aber es ist **nicht** die GPU-Ausgabe. Die Tests
`testWaveFieldSourceIsNotFlat` und `testWaveFieldSourceChangesOverTime` heißen deshalb
bewusst nicht nach Befund B: grün heißt dort nur „die CPU-Quelle ist nicht flach",
niemals „im Bild ist eine Welle".

Fehlt: Rückmessung der von `flood_displace` erzeugten Vertexhöhen, per Readback-Pass
oder Frame-Capture. Alternativ ein Wireframe-Screenshot vom Gerät.

### Befund C — Depth und Blending der Coins

Der Spawn-Test `testBefundC_noCoinsInsideNearPlane` deckt **ausschließlich die
Weltposition** ab: liegt ein Coin näher an der Kamera als Near-Plane plus 1 m.

Ausdrücklich **nicht** abgedeckt und weiterhin offen:

- **Alpha-Blending ohne Depth-Write.** Ob Coins mit aktivem Blending und
  abgeschaltetem Depth-Write gezeichnet werden, steht bisher in keinem Messwert.
- **Tiefensortierung der Coins untereinander.** Ob sich überlappende Coins korrekt
  nach Tiefe staffeln, ist unbelegt.
- **Größe in Screen-Space statt Weltkoordinaten.** Die Weltposition sagt nichts
  darüber, ob die Skalierung im Shader an die Bildschirmgröße gekoppelt ist.

Belegweg: Pipeline-States pro Materialklasse in `FrameDiagnostics` mit aufzeichnen,
oder eine Xcode-Frame-Capture auswerten.

### Rein visuelle Punkte

Wellenform, Schaum, Beleuchtung, Atmosphäre und HUD-Layout kann kein Messwert
entscheiden. Dafür gilt `.cursor/rules/evidence.mdc` Abschnitt 4: vorher beschreiben,
was auf dem Bild zu sehen sein müsste, dann den Gerätescreenshot anfordern.
