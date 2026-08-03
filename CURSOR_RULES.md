# Project rules — City of Surf (READ BEFORE EVERY CHANGE)

## Stack facts (do not "fix" these)
- Swift + **Metal 4** (MTL4CommandQueue, MTL4RenderPipelineDescriptor, MTL4ArgumentTable,
  MTLResidencySet). NOT RealityKit, NOT SceneKit, NOT Metal 1–3 encoders. The spec sheet
  mentioning Godot/RealityKit is OUTDATED — Metal 4 is the decided stack.
- Metal 4 is DEVICE-ONLY. Simulator paths stay behind #if !targetEnvironment(simulator).
  Never add simulator rendering fallbacks.
- MTL4RenderPipelineDescriptor has NO depthAttachmentPixelFormat — depth format comes from
  the render pass attachment. Keep it that way.
- Deployment target iOS 26.5, MTLGPUFamily.metal4, portrait only, 60 fps target.

## Invariants (breaking these = regression)
- CPU wave (WaveField.swift: displacement/floodBody/crestLip) and GPU wave
  (Shaders.metal: flood_displace/flood_body/crest_lip) MUST stay mathematically identical.
  Any change to one must be mirrored in the other in the SAME commit.
- Math.perspective uses Metal NDC z in [0,1]; skyFragment reconstructs rays via
  invViewProjectionMatrix with ndc.z = 0 / 1. Never change either without being asked.
- ChaseCamera.invalidate()/smoothEye snap on reset must survive any camera change
  (camera must never start underwater).
- No silent asset fallbacks: missing/broken assets must fail loudly (IBLLoader pattern).
- Struct layouts in ShaderTypes.h are shared CPU/GPU. When adding fields, keep 16-byte
  alignment and update BOTH sides; print sizes in Renderer init stays.
- Art direction is STYLIZED & SATURATED (docs/RENDERING.md): warm sunset vs teal water,
  chunky shapes, hard foam. "AAA" here means polish/post-fx/motion quality — NOT photoreal
  gray PBR. Palette lives in Render/ArtDirection.swift + mirrored literals in Shaders.metal.

## Workflow
- One feature per prompt. Small commits. Never refactor unrelated files.
- After every change: project must build with `make device-build`.
- Texture memory budget: 128 MB (debug HUD warns). Draw budget: maxObjectsPerFrame —
  use instancing instead of raising it blindly.
- All new tunables go into ArtDirection.swift or a config struct, not magic numbers
  scattered in the renderer.
