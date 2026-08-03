# Flood Surfer — Rendering Notes

## Art direction (target look)

**CITY SURFER** targets **stylized & saturated**, not photoreal / “premium realistic”.

Reference: concept art with sunset drama — bold orange→violet sky, chunky turquoise water, warm terracotta buildings, neon accents, readable flood-wave slope.

See [`docs/art_direction_city_surfer.png`](art_direction_city_surfer.png).

### Stabilization note (2026-08-03)

Wave defaults are intentionally **small** (`amplitude≈2.4`, `faceWidth≈9`, `steepness≈0.55`) so city / road / sky stay readable and the chase camera never starts underwater (`ChaseCamera` snaps `smoothEye` on first/reset frame).

**Do not** scale the wave back to art-ref size without also:
1. Scaling `eyeOffset` / `lookAhead` with crest height
2. Re-snapping `smoothEye` after reset
3. Verifying sky rays (`skyFragment` already uses `invViewProjectionMatrix` — keep that; never reintroduce cameraPosition-based forward hacks)

Giant wave + art polish = separate step after Device-Screenshot confirms this baseline.

| Pillar | Intent |
|---|---|
| Color | Push saturation; warm sun vs cool teal water is the signature contrast |
| Forms | Chunky shapes, hard foam edges, readable silhouettes |
| Sky | Procedural sunset gradient + sun glow; HDRI mainly for IBL/reflections |
| Water | Saturated teal/aqua; **no shadow-map receive** — soft edge darkening only |
| Buildings | Warm brick/sand/terracotta variants, lit sides warm, window glow |
| Grade | Saturation punch + warm fog + light vignette before ACES |

Palette constants live in `Render/ArtDirection.swift` (CPU) and matching literals in `Shaders.metal`.

## Stack (important)

Flood Surfer uses **Swift + Metal 4**, not RealityKit.

| Spec / RealityKit term | Metal 4 equivalent in this project |
|---|---|
| `ImageBasedLightComponent` | Offline-baked IBL maps (`irradiance_equirect`, `specular_m*`, `brdf_lut`) sampled in `Shaders.metal` |
| `DirectionalLight` | `FrameUniforms.lightDirection` / `lightColor` / `sunIntensity` from `lighting.json` |
| RealityKit shadows | Depth-only shadow map on solids; wave uses stylized edge darkening instead |
| RealityKit PhysicallyBasedMaterial | Lit materials + art-directed tints (stylized over strict PBR) |

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
2. **HDR scene** — sky + solids + wave → offscreen `.rgba16Float` (linear HDR; warm fog only, no tonemap)
3. **Bloom** — soft-knee extract (half-res) → 3-mip separable Gaussian → additive upsample
4. **Composite** — bloom add → ACES → saturation punch → vignette → film grain → drawable (`.bgra8Unorm_srgb`)

Tunables: `ArtDirection.bloomThreshold` / `bloomIntensity` / `grainAmount` / `saturation` / `vignetteStrength`.

### Metal 4 depth note

`MTL4RenderPipelineDescriptor` does **not** expose `depthAttachmentPixelFormat` / `stencilAttachmentPixelFormat`.
Depth/stencil formats come from the render-pass attachments:
- HDR scene pass: private `.depth32Float_stencil8` (`HDRPipeline`)
- Shadow pass: `.depth32Float` via `ShadowMap`
- Composite: drawable color only (no depth writes)

## IBL format

IBL maps are **linear HDR** KTX (`RGBA16F` / `RG16F` for BRDF LUT), baked by `tools/fetch_assets.py` — not 8-bit LDR PNGs.

- Sky equirect: **1024×512** RGBA16F (IBL/reflections; display sky is procedural)
- Specular roughness layers (`specular_m0…m4`): **same size** (64×32)
- PBR albedo/normal/roughness: **1024²** PNG (`runtime_resolution`)

## Device smoke

Siehe [DEVICE_SMOKE_TEST.md](DEVICE_SMOKE_TEST.md) für den ersten iPhone-Lauf (erwartete Logs, Beleuchtung, Schatten, Steuerung).

## Offene Risiken (ohne Geräte-Screenshot)

1. **Metal Validation Layer** auf Gerät noch nicht mit Shadow+Main-Pass verifiziert.
2. **Memory**: Warn-Budget **128 MB** im Debug-HUD.
3. **Sky NDC-Z**: Metal near=0/far=1 angenommen.
4. **Debug-HUD** bleibt an (`showDebugHUD`); für Release später `false` setzen.

## Key files

- `Renderer.swift` — Metal 4 submission, argument tables, residency
- `Shaders.metal` — stylized sky / water / solids / grade
- `Render/ArtDirection.swift` — named palette + lighting knobs
- `Render/IBLLoader.swift`, `Render/ShadowMap.swift`
- `ShaderTypes.h` — shared CPU/GPU uniforms
