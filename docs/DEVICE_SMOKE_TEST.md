# Device Smoke Test — Flood Surfer (Metal 4)

Kurzcheck für den **ersten Lauf auf einem echten iPhone**.

**Simulator zählt nicht** als erfolgreicher Metal-4-Test.

## Zielgerät / Feature-Set

| Einstellung | Wert |
|---|---|
| Deployment Target | **iOS 26.5** (`IPHONEOS_DEPLOYMENT_TARGET`) |
| Metal Feature | **`MTLGPUFamily.metal4`** (`supportsFamily(.metal4)`) |
| Build destination | `generic/platform=iOS` (iphoneos) |
| Make target | `make device-build` (oder `make build`) |

```bash
make fetch-assets   # falls Lighting/*.ktx fehlen
export SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"  # lokal, nicht im Repo
make device-build   # expliziter Device-Build — kein Simulator
```

App aus Xcode aufs **physische iPhone** installieren. Xcode Console offen halten (`[FloodSurfer Smoke]`).

## Stabilisierungs-Stand (Code-Wahrheit)

Diese Werte müssen mit dem Code übereinstimmen — nicht mit älteren Wunsch-Docs:

| Thema | Ist-Zustand | Quelle |
|---|---|---|
| **Bloom** | **Deaktiviert** (`enableBloomChain = false`) — Pipelines existieren, werden aber nicht ausgeführt; Composite bindet schwarze 1×1-Bloom-Textur und setzt `bloomIntensity = 0`. Ziel: keine grünen/weißen Block-Glitches. | `Renderer.swift` |
| **HDR / Shadow Slots** | **1 Slot** je (`HDRPipeline(slotCount: 1)`, `ShadowMap(slotCount: 1)`). GPU-Frames werden über `endFrameEvent` **serialisiert**, damit derselbe RT nicht von zwei Frames gleichzeitig genutzt wird. | `Renderer.swift` |
| **Wasser + Schatten** | Wasser **empfängt keine Shadow Map** (`receivesShadow = false` auf dem Wave-DrawItem). Nur stilisiertes Edge-Darkening. Solids (Gebäude, Surfer, Hindernisse) casten/empfangen Schatten. | `Renderer.swift`, `docs/RENDERING.md` |
| **`showDebugHUD`** | Standard in `GameState` ist **`false`**. Wird nur bei Startfehler (`failStart`) auf `true` gesetzt. Für Metal-Diagnose manuell aktivieren. | `GameState.swift`, `GameViewController.swift` |

## Start-Checklist (Log + optional Debug-HUD)

Für den ersten Device-Run Debug-HUD manuell anschalten (`gameState.showDebugHUD = true`) oder die Console-Logs prüfen.

| Check | HUD (wenn an) | Log |
|---|---|---|
| Metal Device | `device=OK` | `CHECK OK: MTLCreateSystemDefaultDevice()` |
| Metal 4 | `metal4=OK` | `CHECK OK: Metal 4 …` |
| Renderer | `renderer=OK` | `CHECK OK: Renderer initialisiert` |
| KTX geladen | `ktx=OK` | `CHECK OK: KTX/PBR geladen…` |
| IBL Peak | `iblPeak=…` | Peak aus `lighting.json` |
| Shadow Map | `shadow=OK` | `CHECK OK: Shadow Map erstellt` |
| Texture memory | `texMem≈…MB` | Warnung wenn > **128 MB** |
| Erster Frame | `frame1=OK` | `CHECK OK: first frame presented` |
| Bloom | — | Init-Log: `bloomChain=false` |

Bei Fehler: `ERR: …` im HUD **und** `CHECK FAIL: …` im Device-Log (konkrete Ursache, keine generische Meldung).

## Asset-Größen (Runtime)

Nach `make fetch-assets` (`runtime_resolution: 1024`):

| Asset | Größe / Format |
|---|---|
| PBR maps (albedo/normal/roughness) | **1024²** PNG |
| `sky_equirect.ktx` | **1024×512** RGBA16F |
| `irradiance_equirect.ktx` | 32×16 RGBA16F |
| `specular_m0…m4.ktx` | **je 64×32** RGBA16F (gleiche Größe, Roughness 0…1) |
| `brdf_lut.ktx` | 128² RG16F |

Texture-Memory-Warnung im Debug-HUD: **> 128 MB**.

## Erwartetes Startbild

- Sunset-Himmel, türkise Welle, Facade-Gebäude, Asphalt-Straße, Beton-Gehwege
- Surfer / Coins / Hindernisse (aktuell noch teilweise Graybox-Silhouetten)
- HUD Distanz + Coins; Debug-Smoke nur wenn `showDebugHUD = true`
- Composite ohne Bloom-Glow (Sonne/Coins/Fenster wirken ohne Soft-Bloom)

## Erwartete Beleuchtung / Schatten / Welle / Steuerung

- Warmes Directional + IBL auf PBR-Flächen
- Schatten von Surfer/Gebäuden/Hindernissen auf **Straße / Solids** — **nicht** auf dem Wasser (Wasser: Soft Edge Darkening)
- Eine Flutfront, Surfer auf Crest
- Finger gleiten / hoch springen / runter ducken
- Kamera snappt beim Start/Reset oberhalb der Welle (`ChaseCamera.invalidate`)

## Inverse View-Projection (offen — nicht ändern ohne Capture)

Statisch geprüft:

- `Math.perspective` folgt der **Metal-Konvention NDC-Z near→0, far→1**
- `skyFragment` rekonstruiert Rays mit `invViewProjectionMatrix` und `ndc.z = 0` / `1`

**Risiko:** Wenn die Perspektivmatrix oder der Depth-Range je geändert wird, kann der Sky-Ray falsch liegen. **Keine Änderung** ohne Device-Screenshot oder Metal Frame Capture. Dann erst Sky vs. Chase-Cam-Richtung vergleichen.

## Typische Fehler

| Symptom | Bedeutung |
|---|---|
| `MTLCreateSystemDefaultDevice() = nil` | Kein Metal |
| `supportsFamily(.metal4)=false` | Gerät / OS zu alt |
| `Simulator-Build — kein gültiger Metal-4-Test` | Falsche Destination |
| `Asset fehlt: *.ktx` | Bundle ohne Lighting — `make fetch-assets`, Clean |
| `Falsches Pixel-Format` | LDR/alte Assets |
| `texMem≈… WARN` | Speicherbudget > 128 MB — Jetsam-Risiko |
| `frame1` bleibt `…` | Draw kommt nicht (Drawable/Pause) |
| `SIGN_IDENTITY is not set` | Codesign: lokale Env setzen (siehe Makefile) |
| Grüne/weiße Blöcke | Historisch bei Bloom / Multi-Slot-HDR — Bloom bleibt aus bis Phase 9 bestanden |

## Nächster manueller Schritt

1. `export SIGN_IDENTITY="…"` (lokal)
2. `make device-build`
3. App per Xcode auf iPhone installieren/starten
4. Console: alle `CHECK OK` inkl. `first frame presented`
5. Optional HUD: Checks OK, kein `ERR`
6. Screenshot + kurzes Feel-Test (Steer / Jump / Duck) zurückmelden
