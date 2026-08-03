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
make device-build   # expliziter Device-Build — kein Simulator
```

App aus Xcode aufs **physische iPhone** installieren. Xcode Console offen halten (`[FloodSurfer Smoke]`).

## Start-Checklist (Debug-HUD + Log)

Das Debug-HUD bleibt an (`showDebugHUD = true`), bis der erste Device-Run bestätigt ist.

| Check | HUD | Log |
|---|---|---|
| Metal Device | `device=OK` | `CHECK OK: MTLCreateSystemDefaultDevice()` |
| Metal 4 | `metal4=OK` | `CHECK OK: Metal 4 …` |
| Renderer | `renderer=OK` | `CHECK OK: Renderer initialisiert` |
| KTX geladen | `ktx=OK` | `CHECK OK: KTX/PBR geladen…` |
| IBL Peak | `iblPeak=…` | Peak aus `lighting.json` |
| Shadow Map | `shadow=OK` | `CHECK OK: Shadow Map erstellt` |
| Texture memory | `texMem≈…MB` | Warnung wenn > **128 MB** |
| Erster Frame | `frame1=OK` | `CHECK OK: first frame presented` |

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
- Surfer / Coins / Hindernisse
- HUD Distanz + Coins; Debug-Smoke unten links

## Erwartete Beleuchtung / Schatten / Welle / Steuerung

- Warmes Directional + IBL auf PBR-Flächen
- Schatten von Surfer/Gebäuden/Hindernissen auf dem Wasser
- Eine Flutfront, Surfer auf Crest
- Finger gleiten / hoch springen / runter ducken

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

## Nächster manueller Schritt

1. `make device-build`
2. App per Xcode auf iPhone installieren/starten
3. Console: alle `CHECK OK` inkl. `first frame presented`
4. HUD: alle Checks OK, kein `ERR`
5. Screenshot + kurzes Feel-Test (Steer / Jump / Duck) zurückmelden
