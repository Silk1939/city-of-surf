# STATUS — Befundliste, Stand 08.08.2026

Zweck: in einer neuen Session ohne Vorgeschichte weiterarbeiten können.
Regeln gelten weiter: `.cursor/rules/evidence.mdc` (Beweispflicht, ein Befund pro Commit).

## Befund A ist abgeschlossen: Ursache ist Fall 4, sekundär Fall 1

Der Surfer fehlt nicht, er liegt **unter dem unteren Bildrand**. Gemessen über 120 Frames
mit dem macOS-Harness aus den echten Projektquellen, Aspect 1170/2532:

| Größe | Wert |
|---|---|
| Kamera-Y | 7.560 |
| Kamera-Pitch | −16.65° (halbes vertikales FOV: 34.04°) |
| LookAt-Punkt | (−0.036, 3.912, 9.997) |
| Surfer-Y | 3.512 |
| Wasserhöhe an Surfer-X/Z | 2.365 |
| **Surfer-Y − Wasserhöhe** | **+1.147** |
| Winkel unter der Blickachse | 44.83° bei 34.04° Grenze |
| NDC(Ursprung) | (−0.003, **−1.4716**, 0.964), clip.w = +3.268 |

Weil die Differenz Surfer-Y minus Wasserhöhe **positiv** ist (+1.147 m), sind **Fall 2
(Surfer falsch in Y verankert) und Fall 3 (unterschiedliche Y-Referenzen) widerlegt**.
Der Surfer sitzt korrekt über dem Wasser. Ursache ist **Fall 4: der LookAt-Punkt liegt
10 m vor dem Surfer und kippt ihn aus dem Bild**, sekundär **Fall 1: Augenhöhe zu hoch
bei zu flachem Pitch**.

Kontrafaktisch gemessen: `lookAhead = 0` ergibt NDC y = 0.000, `eyeOffset.y = 1.2` nur
NDC y = −1.226 (weiterhin unsichtbar). Belastbar ist daraus: die Augenhöhe allein reicht
nicht, der LookAt-Punkt ist der Haupthebel. Die lookAhead-Variante ist konstruktions-
bedingt exakt 0, ihr Δ also tautologisch — kein Beleg für einen konkreten Zielwert.

## Was geändert werden muss

`city of surf/Render/Camera.swift`
- **Zeile 17**: `var lookAhead = SIMD3<Float>(0, 0.4, 10.0)` — Haupthebel.
- **Zeile 15**: `var eyeOffset = SIMD3<Float>(0, 5.2, -2.2)` — sekundär.

Welche konkreten Werte funktionieren, ist **unbelegt, nicht gemessen**.
Verboten: konstanter Offset auf die Kameraposition, um −1.4716 wegzurechnen. Das
kaschiert die Ursache und bricht bei Sprüngen und hohen Wellen.

## Committet

| Hash | Betreff |
|---|---|
| `9185d83` | Add a red player marker cube and frame-one projection log. |
| `3e280da` | Add an evidence rule so visual claims always need proof. |
| `a9ee237` | Add a numeric frame diagnostics harness. |
| `a086f1b` | Measure why the surfer sits below the frame. |

Mit diesem Commit kommen dazu: die Kategorie-Trennung der Tests (Simulator vs. Gerät),
`DeviceEvidence.swift`, `DeviceOnlyTests.swift`, `docs/OPEN_DEVICE_CHECKS.md`, der
macOS-Messharness unter `.measure/` und diese Datei.

## Assertions

- **Grün, gelaufen**: `testUrsachenanalyseBefundA`, `testSurferIstAufWasserhoeheVerankert`
- **Rot erwartet, nicht verifiziert**: `testBefundA_playerOriginInsideFrustum`,
  `testSchritt3_playerSitsInLowerThird`
- **Nicht gelaufen**: übrige Kategorie-1-Tests und alle Kategorie-2-Tests
  (`DeviceOnlyTests`) — der Lauf wurde abgebrochen.

## Nicht erledigt

- Schritt 2 (Surfer ins Bild) und Schritt 3 (unteres Bilddrittel) — nicht begonnen.
- `make diagnostics` und `make device-diagnostics` — nicht angelegt.
- Draw-Call-Zahl des Player-Mesh und Determinante der echten DrawItem-Matrix —
  **nicht gemessen**, brauchen einen Gerätelauf. iPhone „SrTan" war offline.
- Befund C: Alpha-Blending ohne Depth-Write und Tiefensortierung der Coins bleiben
  offen, siehe `docs/OPEN_DEVICE_CHECKS.md`. Der Spawn-Test deckt nur Geometrie ab.

## Beweislage

Simulator-Screenshots sind unmöglich: das iPhoneSimulator-SDK kennt die Metal-4-Typen
nicht (`cannot find type 'MTL4RenderCommandEncoder' in scope`). Visuelle Belege kommen
nur vom Gerät, numerische aus dem Harness. Ein grüner Simulator-Test ist kein Beleg für
Geräteverhalten.

Erwartung für den ersten Gerätescreenshot mit dem Schritt-1-Marker (`make build`, dann
auf dem iPhone starten): Der rote 2-m-Würfel ist **nicht** sichtbar, seine Oberkante
landet bei px 1097 von 1024. Sichtbar wäre nur die Spitze des grünen +Y-Balkens ab
etwa px 887 am unteren Bildrand.

## Nächster Schritt

`lookAhead` in `Camera.swift` Zeile 17 so ändern, dass der Zielpunkt am Surfer statt 10 m
davor hängt, bis `testBefundA_playerOriginInsideFrustum` grün ist — eigener Commit.
