# Physical Device Checklist — CITY SURFER Visual Slice

Branch: `cursor/invert-steer-taller-wave-sunset`  
Datum: 2026-08-04

## Zweck

Abnahme des **normalen HDR-Pfads ohne Bloom** auf einem physischen iPhone, bevor Phase 10 Bloom reaktiviert.

Bloom bleibt: `enableBloomChain = false`.

## Build

```bash
make device-build
```

Ergebnis (CI/Agent, 2026-08-04): **BUILD SUCCEEDED** (generic iphoneos).  
Signatur: lokal via Keychain / `SIGN_IDENTITY` (keine persönliche Identity im Makefile-Default).

## Abnahme-Tabelle

| # | Kriterium | Ergebnis | Notizen |
|---|---|---|---|
| 1 | Keine grünen Frames | ⬜ **offen — Gerät** | Nur physisch prüfbar |
| 2 | Keine weißen Frames | ⬜ **offen — Gerät** | |
| 3 | Keine invertierte / upside-down Ausgabe | ⬜ **offen — Gerät** | |
| 4 | Keine fehlenden / flackernden Texturen | ⬜ **offen — Gerät** | KTX/PBR im Bundle vorhanden |
| 5 | Stabile Kamera Start / Reset / Wipeout | ⬜ **offen — Gerät** | Code: `ChaseCamera.invalidate` + Impulse |
| 6 | ≥ 5 Min kontinuierliches Gameplay | ⬜ **offen — Gerät** | |
| 7 | Texture Memory innerhalb 128 MB Budget | ⬜ **offen — Gerät** | HUD `texMem`; 1 HDR/Shadow-Slot |
| 8 | Stabile Bildrate (FPS dokumentieren) | ⬜ **offen — Gerät** | Ziel 60; QualitySettings vorhanden |
| 9 | Keine Argument-Table / Residency Errors | ⬜ **offen — Gerät** | Validation Layer empfohlen |
| 10 | Surfer-Silhouette + lesbare Hindernisse | ⬜ **offen — Gerät** | Prozedural artikuliert + City/Props |

**Gesamt Phase 9:** ❌ **NICHT BESTANDEN** — physischer Device-Lauf fehlt noch.

## Was der Agent verifiziert hat

- `make device-build` kompiliert und signiert erfolgreich.
- Frame Graph: Shadow → HDR Scene → Composite (Bloom aus).
- Docs stimmen mit Code überein (Wasser ohne Shadow-Receive, Bloom aus, 1 Slot, `showDebugHUD` default false).

## Was der Agent bewusst nicht behauptet

- Kein Beweis für stabile Frames auf dem iPhone.
- Kein Ersatz für professionelle externe Character-/Board-Assets — prozedurale Slice.
- Bloom wurde **nicht** reaktiviert (Phase 10 gesperrt bis diese Checkliste bestanden ist).

## Manueller Testplan (du auf dem iPhone)

1. App aus `/tmp/flood_surfer_dd/Build/Products/Debug-iphoneos/city of surf.app` installieren.
2. Console: alle `[FloodSurfer Smoke] CHECK OK` inkl. `first frame presented`.
3. Optional `showDebugHUD = true` für texMem/FPS.
4. 5 Minuten surfen: Steer / Jump / Duck / Coins / Wipeout / Reset.
5. Auf grüne/weiße Frames, Texture-Flicker, Unterwasser-Kamera achten.
6. Screenshot für Visual-Slice-Abnahme (Surfer + Welle + Stadt + Sunset).
7. Ergebnis in diese Tabelle eintragen; bei Pass → Phase 10 Bloom-Commit.

## Offene Risiken

1. City Kit + Props erhöhen Unique Draws; Instancing deckt Coins/Road/Wake ab — Device-FPS messen.
2. Welle `amplitude≈5.2` — Crest darf Obstacles nicht dauerhaft verdecken (Feel-Test).
3. Historische Bloom/Multi-Slot-Glitches — Bloom bleibt aus.
4. Obstacle/Coin Spawns nicht voll deterministisch (`Float.random`); Stadt-Hashes sind deterministisch.
