# CITY SURFER — Visual Slice Plan

Branch: `cursor/invert-steer-taller-wave-sunset`  
Audit-Datum: 2026-08-04  
Status: Phase 0 Baseline

---

## 1. Aktueller Frame Graph

```
┌─────────────────────────────────────────────────────────────┐
│  CPU: GameState.update → buildDrawList → ObjectUniforms     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  0. Frame Gate (serialisiert)                               │
│     endFrameEvent.wait(previousFrame)                       │
│     HDR slot = 0, Shadow slot = 0 (bewusst 1 Slot)          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  1. Shadow Pass                                             │
│     Target: ShadowMap 2048² depth32Float                    │
│     Draws: alle DrawItems mit castsShadow                   │
│     Pipeline: shadowPipeline (depth-only)                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  2. HDR Scene Pass                                          │
│     Target: rgba16Float sceneColor + depth32Float_stencil8  │
│     Clear: warmes Horizon-Orange                            │
│     a) Sky fullscreen (skyPipeline, no depth write)         │
│     b) Solids / Wave (solidPipeline / wavePipeline)         │
│     Lighting: Directional + IBL + PCF Shadow (solids only)  │
│     Wave: receivesShadow=false — stylized edge darkening    │
│     Kein Tonemap in Scene-Fragmenten                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Bloom Chain (OPTIONAL — aktuell AUS)                    │
│     enableBloomChain = false                                │
│     Wenn an: Extract → 3-Mip Blur → Upsample                │
│     Wenn aus: Composite bindet 1×1 blackBloomTexture,       │
│               bloomIntensity forciert auf 0                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Composite Pass                                          │
│     Input: sceneHDR (+ bloom oder schwarz)                  │
│     exposure → bloom add → ACES → saturation → vignette     │
│              → grain → drawable bgra8Unorm_srgb             │
└─────────────────────────────────────────────────────────────┘
```

Relevante Dateien: `Renderer.swift`, `HDRPipeline.swift`, `ShadowMap.swift`, `Shaders.metal`, `ArtDirection.swift`.

---

## 2. Warum `enableBloomChain` deaktiviert ist

In `Renderer.swift`:

```swift
/// Keep false until device is stable without green/white block glitches.
let enableBloomChain = false
```

Ursachen laut Code-Kommentaren und Stabilisierungshistorie:

1. **Grüne / weiße Block-Glitches** auf dem physischen Gerät beim Bloom-Pfad (Argument-Table / Residency / RT-Race vermutet).
2. Bloom erhöht die Zahl der Render-Passes und Texture-Writes stark (Extract + 3× H/V-Blur + Downsample + Upsample + Copy).
3. Stabilisierungsstrategie: erst den einfachen HDR→Composite-Pfad auf dem iPhone absichern (Phase 9), dann Bloom kontrolliert reaktivieren (Phase 10).

Pipelines und Shader für Bloom sind vorhanden und werden gebaut — nur die Runtime-Ausführung ist ausgeschaltet.

---

## 3. Warum HDR/Shadow auf 1 Slot + Frame-Serialisierung

```swift
// Single HDR/shadow slot: 3× full-res rgba16Float blew residency/memory → green blocks.
ShadowMap(..., slotCount: 1)
HDRPipeline(..., slotCount: 1)

// Serialize GPU work onto one HDR/shadow target (no in-flight RT races).
endFrameEvent.wait(untilSignaledValue: previousFrame)
hdrPipeline.setActiveSlot(0)
shadowMap.setActiveSlot(0)
```

| Thema | Erklärung |
|---|---|
| Memory | 3 In-Flight-Slots × Full-Res `rgba16Float` + Depth + Bloom-Mips sprengten das Texture-Budget und/oder die Residency-Kapazität → grüne Blöcke. |
| Race | Ein Slot darf nicht von Frame N+1 geleert/geschrieben werden, während Frame N noch sampelt. Mit 1 Slot muss der CPU-Pfad auf den vorherigen Frame warten. |
| Uniforms | `maxBuffersInFlight = 3` bleibt für Uniform-/Argument-Table-Ringpuffer; nur die Render-Targets sind auf 1 Slot begrenzt. |
| Trade-off | Stabilität vor Parallelität. Multi-Slot-HDR ist ein späterer Performance-Commit nach Phase 9/10. |

---

## 4. Object Count, Draw Calls, Texture Memory

### Geschätzter typischer Draw-Count (Steady State)

| Kategorie | Objekte (ca.) | Draw Calls |
|---|---:|---:|
| Road slabs | 5 | 5 |
| Sidewalks | 10 | 10 |
| Wave plane | 1 | 1 |
| Surfer + accents + board | 5 | 5 |
| Wake cubes | 5 | 5 |
| Coins (aktiv, voraus) | ~36–60 | 36–60 |
| Obstacles (10 × 2–5 Teile) | ~30–45 | 30–45 |
| Gebäude L/R (bis 20 Paare) | ~40 | 40 |
| Rooftop palms / tanks | ~10–20 | 10–20 |
| Sidewalk palms | 16 | 16 |
| Billboards | 8 | 8 |
| FX sparks (Burst) | 0–16 | 0–16 |
| **Summe typisch** | **~170–230** | **~170–230** |
| **Peak (viele Coins + FX)** | **~280–350** | **~280–350** |

Budget: `maxObjectsPerFrame = 420` (bereits angehoben). Jedes `DrawItem` = 1 Draw Call (kein Instancing). Shadow-Pass addiert erneut alle `castsShadow`-Items.

### Texture Memory (geschätzt, 1 Slot)

Annahme Portrait ~1170×2532 (typisches iPhone):

| Ressource | Bytes (ca.) |
|---|---:|
| HDR scene color rgba16Float | ~23.7 MB |
| HDR depth32Float_stencil8 | ~23.7 MB |
| Bloom mips + blur temps (3 levels) | ~15–16 MB (allokiert, ungenutzt wenn Bloom off) |
| Shadow 2048² depth32Float | 16 MB |
| IBL KTX + PBR 1024² (disk ~13 MB; GPU unpacked höher) | ~40–70 MB GPU |
| **Budget-Warnung** | **128 MB** (`debugTextureMemoryWarn`) |

Mit Bloom-Targets trotz `enableBloomChain=false` weiterhin allokiert — später optional lazy/skip wenn Bloom dauerhaft aus bleibt.

---

## 5. Sichtbare Graybox-Engpässe

| Element | Ist-Zustand | Problem |
|---|---|---|
| **Surfer** | Ein Quader + Neon-Accent-Boxen | Keine Silhouette, keine Pose, nicht als Surfer lesbar |
| **Board** | Skalierter Quader + Neon-Streifen | Keine Nose/Tail/Finnen, kein Deck-Muster |
| **Gebäude** | Skalierte `unitBox`-Quader, Tint-Zyklus | Manhattan-Block-Idee da, aber Silhouette = Box; keine Fassadenfamilien, Fenster nur Shader-Fake |
| **Palmen** | Trunk-Box + Frond-Box | Sofort als Graybox erkennbar |
| **Wake** | 5 Foam-Cubes | Keine Bewegungsrichtung / Spray-Energie |
| **Fahrzeuge** | Body/Cabin/Lightbar-Boxen | Richtung lesbar, aber Räder fehlen; Low-Poly-Demo-Look |
| **Barrieren / Ampeln** | Box-Komposition | Gameplay-Farbe ok, Form schwach |
| **Billboards / Tanks** | Einfache Boxen | Keine urbanen Requisiten-Details |
| **FX Sparks** | Graybox-Cubes | Akzeptabel als Platzhalter |

Stärken der Baseline (nicht zerstören): HDR+ACES Composite, Sunset-Palette, WaveField↔GPU-Sync, Chase-Camera Snap, Metal-4-Submission, Coin/Obstacle-Gameplay.

---

## Draw Budget (Phase 6 — gemessen im Code-Log)

Vor Instancing (geschätzt, Steady State):
- Unique DrawItems inkl. Coins/Road/Wake: ~170–230+ Draw Calls

Nach Instancing (`[FloodSurfer Draw]` Log):
- **Coins**, **Road slabs**, **Sidewalks**, **Wake** → wenige Instanced Batches
- Unique Draws bleiben für Surfer, Board, City, Obstacles, Palmen
- `maxObjectsPerFrame` bleibt **420** (nicht weiter erhöht)
- Instance-Budget: `maxInstancesPerFrame = 512`, Ringpuffer, keine Hot-Path-Allocs

Typische Ersparnis: ~40–70 Draw Calls (Coins allein ~36–60 → 1 Batch).


**Ziel:** Draw Calls senken bei gleichem sichtbaren Ergebnis. Budget 420 bleibt Hard Cap + Diagnose.

### Phase-6 Kandidaten (Priorität)

1. **Coins** — höchster wiederkehrender Count (~36–60), identisches Mesh → 1 instanced draw.
2. **Wake / Sparks** — kleine Counts, gleiches Mesh, kurze Lebensdauer → Instance-Buffer.
3. **Palmen (Trunk + Frond)** — 8+ Rooftop-Varianten → 2 Instanced Batches.
4. **Road / Sidewalk slabs** — periodisch, gleiches Mesh → 2 Batches.
5. **Gebäude-Körper** — nach Material/Tint batchen ODER Fassaden-Teile (Fenster-Panels) instanieren, sobald City Kit modular ist.
6. **Hindernis-Teile** — erst nach Silhouette-Upgrade; kind-spezifische Instance-Streams.

### Technik

- Wiederverwendbare **Ringpuffer** für Instance-Matrizen / Farben (`maxBuffersInFlight`).
- Eine `DrawItem`-Variante oder `InstancedBatch` mit `instanceCount`.
- Keine Allokation pro Frame; `reserveCapacity` + overwrite.
- Argument Tables / Residency: Instance-Buffer zur Residency hinzufügen (wie Uniforms).
- Diagnose bei Overflow: bestehende ASSERT-Meldung beibehalten, Instancing darf Counts nicht stillschweigend droppen.

### Nicht tun

- `maxObjectsPerFrame` weiter erhöhen als Ersatz.
- RealityKit / externe Character-Pipeline.
- Bloom oder Multi-Slot-HDR „nebenbei“ mitziehen.

---

## 7. Physische iPhone-Prüfkriterien (Baseline + Slice)

### Smoke (jeder Build nach Phase)

- [ ] `make device-build` erfolgreich
- [ ] Alle `[FloodSurfer Smoke] CHECK OK` inkl. `first frame presented`
- [ ] Debug-HUD: device/metal4/renderer/ktx/shadow/frame1 OK
- [ ] `texMem` unter 128 MB Warnung (oder dokumentierte Überschreitung)
- [ ] Keine Argument-Table / Residency Validation Errors

### Visuell / Stabilität

- [ ] Keine grünen Frames
- [ ] Keine weißen Frames
- [ ] Keine invertierte / auf dem Kopf stehende Ausgabe
- [ ] Keine fehlenden / flackernden Texturen
- [ ] Kamera startet und nach Reset **nicht unter Wasser**
- [ ] ≥ 5 Minuten kontinuierliches Gameplay ohne Crash / Freeze
- [ ] FPS im HUD stabil nahe 60 (Wärme dokumentieren)

### Gameplay-Invarianten (nicht regressen)

- [ ] Steer / Jump / Duck fühlen sich unverändert an
- [ ] Kollisionen (Fahrzeuge, Barrieren, Ampel-Duck) unverändert
- [ ] Coins sammelbar; Wave-Surfer-Sync sichtbar korrekt

### Visual-Slice Abnahme (Ende aller Phasen)

- [ ] Screenshot: Surfer + riesige Welle + Stadt + Sunset sofort lesbar
- [ ] Surfer keine Box; lesbare Posen beim Carven/Jump/Duck/Wipeout
- [ ] Board als Surfboard lesbar (Nose/Tail/Finnen/Neon-Deck)
- [ ] Stadt keine identischen Quader-Reihen; ≥ 6 Fassadenfamilien
- [ ] Orange↔Teal dominante Farbdramaturgie
- [ ] Hindernisse aus Gameplay-Distanz erkennbar
- [ ] Instancing aktiv für wiederkehrende Objekte; Draw Count dokumentiert
- [ ] Bloom nur nach bestandener Phase-9-Checkliste reaktiviert

---

## Phasen-Reihenfolge (Kurz)

| Phase | Fokus | Build-Gate |
|---|---|---|
| 0 | Audit + dieser Plan + device-build | ✓ erforderlich |
| 1 | Docs/Makefile Signatur-Sicherheit | device-build |
| 2 | Artikulierter Surfer + Posen | device-build |
| 3 | Procedurales Surfboard | device-build |
| 4 | Modular City Kit (6 Familien, 3 Tiefen) | device-build |
| 5 | Palmen / Hindernisse / Props | device-build |
| 6 | Instancing + Draw Budget | device-build |
| 7 | Welle skalieren + Wake | device-build |
| 8 | Kamera / Feel / HUD | device-build |
| 9 | Physical Device Checklist (ohne Bloom) | manuell Gerät |
| 10 | Bloom reaktivieren (nur nach P9 Pass) | device-build + 5 min Gerät |

---

## Offene Risiken (ehrlich)

1. Bloom + Multi-Slot-HDR haben historisch grüne Frames verursacht — nicht spekulativ „fixen“, sondern messbar reaktivieren.
2. Obstacle/Coin-Spawns nutzen `Float.random` / `Int.random` — nicht vollständig deterministisch; City-Gebäude nutzen Hash-Seeds (gut). Phase 4 muss Seeds für Stadt festhalten; Spawns ggf. später seedbar machen.
3. Externe Art-Assets (Charakter, Board, Fassaden-Texturen) fehlen — die Slice bleibt **prozedural stilisiert**, ersetzt keine Profi-Asset-Pipeline.
4. Mit 1 HDR-Slot ist CPU→GPU serialisiert; 60 fps bleibt realistisch, Headroom für schwere Bloom/Instancing-Übergänge prüfen.
5. Docs widersprechen Code (Wasser-Schatten, `showDebugHUD`, Bloom aktiv) — Phase 1 korrigiert das.
