# Flood Surfer — Rendering Notes

## Stack (important)

Flood Surfer uses **Swift + Metal 4**, not RealityKit.

| Spec / RealityKit term | Metal 4 equivalent in this project |
|---|---|
| `ImageBasedLightComponent` | Offline-baked IBL maps (`irradiance_equirect`, `specular_m*`, `brdf_lut`) sampled in `Shaders.metal` |
| `DirectionalLight` | `FrameUniforms.lightDirection` / `lightColor` / `sunIntensity` from `lighting.json` |
| RealityKit shadows | Depth-only shadow map pass (`ShadowMap.swift`) sampled on water + lit surfaces |
| RealityKit PhysicallyBasedMaterial | Cook–Torrance PBR fragment with ambientCG albedo/normal/roughness |

Metal 4 is **device-only**. The Simulator cannot run the game.

## Asset pipeline

```
make fetch-assets   # tools/fetch_assets.py + tools/assets.json
```

- Downloads Poly Haven HDRI (`sunset_jhbcentral`) and ambientCG materials (asphalt, concrete, glass facade).
- Bakes IBL maps into `city of surf/Resources/Lighting/`.
- Licenses logged in `CREDITS.md` (CC0).

## Frame graph

1. **Shadow pass** — buildings, surfer, obstacles → 2048² `.depth32Float` texture
2. **Sky** — HDR equirect background (`sky_equirect.ktx`, rgba16f)
3. **Color pass** — PBR solids + flood wave with IBL fresnel + shadow receive on water

### Metal 4 depth note

`MTL4RenderPipelineDescriptor` does **not** expose `depthAttachmentPixelFormat` / `stencilAttachmentPixelFormat`.
Depth/stencil formats come from the render-pass attachments:
- Main `MTKView` pass: `.depth32Float_stencil8`
- Shadow pass: `.depth32Float` via `ShadowMap`

## IBL format

IBL maps are **linear HDR** KTX (`RGBA16F` / `RG16F` for BRDF LUT), baked by `tools/fetch_assets.py` — not 8-bit LDR PNGs.

## Device smoke

Siehe [DEVICE_SMOKE_TEST.md](DEVICE_SMOKE_TEST.md) für den ersten iPhone-Lauf (erwartete Logs, Beleuchtung, Schatten, Steuerung).

## Offene Risiken (ohne Geräte-Screenshot)

1. **Metal Validation Layer** auf Gerät noch nicht mit Shadow+Main-Pass verifiziert (Depth-Formate kommen aus Pass-Attachments; Pipeline deklariert sie in Metal 4 nicht).
2. **Specular-Array-Upsample**: kleinere Mips werden nearest-upsampled auf m0-Größe — funktional korrekt, aber weicher als echte Prefilter-Auflösung.
3. **Memory**: 2K PBR-Maps + 2K HDR Sky können auf älteren Mid-Range-Geräten Jetsam riskieren.
4. **Sky NDC-Z**: Metal near=0/far=1 angenommen; bei abweichendem Projection-Setup Ray prüfen.
5. **Debug-HUD** bleibt an (`showDebugHUD`); für Release später `false` setzen.

## Key files

- `Renderer.swift` — Metal 4 submission, argument tables, residency
- `Shaders.metal` — PBR / IBL / wave / sky / shadow
- `Render/IBLLoader.swift`, `Render/ShadowMap.swift`
- `ShaderTypes.h` — shared CPU/GPU uniforms
