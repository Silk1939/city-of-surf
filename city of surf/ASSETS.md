# ASSETS.md — Einkaufsliste für Flood Surfer

Lege fertige Dateien hier ab:

`city of surf/Assets/Models/`

Der Loader (`AssetMeshLibrary`) sucht automatisch nach diesen Dateinamen.
Fehlt eine Datei, bleibt der prozedurale Platzhalter aktiv — kein Crash, keine unsichtbaren Objekte.

## Benötigte Modelle

| Dateiname | Zweck | Stil | Ziel-Polycount | Format | Suchbegriffe |
|---|---|---|---|---|---|
| `surfer.usdz` | Spielerfigur (stehend auf Board) | Stilisierter Arcade-Charakter, klare Silhouette, keine Realscan-Haut | 3k–8k Tris | USDZ oder GLB | `stylized surfer character low poly`, `cartoon surfer game ready`, `arcade character surfboard rider` |
| `board.usdz` | Surfboard unter dem Spieler | Kurzes Shortboard, kräftige Farbe, weiche Kanten | 0.5k–2k Tris | USDZ oder GLB | `low poly surfboard`, `stylized shortboard game asset`, `arcade surf board model` |
| `coin.usdz` | Sammel-Münze | Runde Arcade-Münze mit Fase/Rim, gold/gelb | 0.4k–1.5k Tris | USDZ oder GLB | `low poly coin beveled`, `arcade token gold`, `stylized game coin rim` |
| `obstacle_cab.usdz` | Hindernis (Taxi/Cab im Flutwasser) | Lesbares Stadtauto/Cab, leicht übertrieben | 2k–6k Tris | USDZ oder GLB | `low poly taxi cab`, `stylized city car game`, `arcade taxi obstacle` |
| `building_facade.usdz` *(optional)* | Fassaden-Kit-Stück | Schmale Canyon-Fassade mit Fenster-Raster | 1k–4k Tris | USDZ oder GLB | `low poly building facade modular`, `stylized city block facade`, `arcade building kitbash` |

Optionale Texturen (gleicher Ordner, PNG):

- `surfer_albedo.png`
- `board_albedo.png`
- `coin_albedo.png`
- `obstacle_cab_albedo.png`

## Empfohlene Quellen (CC0 / kommerziell klar)

**CC0 / Public Domain**
- [Poly Haven](https://polyhaven.com/models) — CC0, eher realistisch; gut für Board/Props nach Stil-Anpassung
- [Kenney.nl](https://kenney.nl/assets) — CC0, stark stilisiert, ideal für Arcade-Silhouetten
- [Quaternius](https://quaternius.com/) — oft CC0, stilisierte Charaktere/Fahrzeuge

**Kommerziell / Game-Ready Marketplaces**
- [Fab (Unreal Marketplace)](https://www.fab.com/) — auf Lizenz „Royalty Free / Game“ achten
- [CGTrader](https://www.cgtrader.com/) / [TurboSquid](https://www.turbosquid.com/) — Filter: `game ready`, `low poly`, klare Lizenz
- [Sketchfab Store](https://sketchfab.com/store) — Download als GLB/USDZ, Lizenz prüfen

## Import-Hinweise

1. Datei exakt wie in der Tabelle benennen.
2. Nach `city of surf/Assets/Models/` kopieren (Xcode synct den Ordner über File System Sync).
3. Pivot: Board/Surfer um Ursprung, Y-up, Surfer standing height ~1.5 m.
4. Ein Material / einfache Albedo reicht für den aktuellen Graybox-PBR-Pfad.
5. App neu bauen. In den Logs erscheint bei fehlenden Assets nur eine Warning, kein Abbruch.
