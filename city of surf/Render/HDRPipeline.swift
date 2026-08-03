//
//  HDRPipeline.swift
//  city of surf
//
//  Offscreen rgba16Float scene + 3-mip bloom chain, ring-buffered per in-flight frame.
//

import Metal
import simd

final class HDRPipeline {
    static let bloomMipCount = 3

    struct Slot {
        var sceneColor: MTLTexture
        var sceneDepth: MTLTexture
        var bloomMips: [MTLTexture]
        var blurTemps: [MTLTexture]

        var allTextures: [MTLTexture] {
            [sceneColor, sceneDepth] + bloomMips + blurTemps
        }
    }

    private(set) var slots: [Slot] = []
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var activeSlotIndex: Int = 0

    private let device: MTLDevice
    private let slotCount: Int

    init(device: MTLDevice, slotCount: Int = maxBuffersInFlight) {
        self.device = device
        self.slotCount = max(slotCount, 1)
        // Placeholder until drawableSizeWillChange; never leave nil for residency.
        recreate(width: 64, height: 128)
    }

    var sceneColor: MTLTexture { slots[activeSlotIndex].sceneColor }
    var sceneDepth: MTLTexture { slots[activeSlotIndex].sceneDepth }
    var bloomMips: [MTLTexture] { slots[activeSlotIndex].bloomMips }
    var blurTemps: [MTLTexture] { slots[activeSlotIndex].blurTemps }

    func setActiveSlot(_ index: Int) {
        activeSlotIndex = ((index % slotCount) + slotCount) % slotCount
    }

    /// Bytes for debug HUD texture-memory estimate (all in-flight slots).
    var approximateTextureBytes: Int {
        guard width > 0, height > 0 else { return 0 }
        let perSlotColor = width * height * 8 // rgba16Float
        let perSlotDepth = width * height * 8 // depth32Float_stencil8 (padded)
        var bloomBytes = 0
        var w = max(width / 2, 1)
        var h = max(height / 2, 1)
        for _ in 0..<Self.bloomMipCount {
            bloomBytes += w * h * 8 * 2 // mip + matching blur temp
            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
        return (perSlotColor + perSlotDepth + bloomBytes) * slotCount
    }

    @discardableResult
    func recreate(width: Int, height: Int) -> Bool {
        let w = max(width, 1)
        let h = max(height, 1)
        if w == self.width, h == self.height, !slots.isEmpty { return false }
        self.width = w
        self.height = h

        var newSlots: [Slot] = []
        newSlots.reserveCapacity(slotCount)
        for s in 0..<slotCount {
            let sceneColor = makeColor(width: w, height: h, label: "HDR.SceneColor[\(s)]")
            let sceneDepth = makeDepth(width: w, height: h, label: "HDR.SceneDepth[\(s)]")
            var mips: [MTLTexture] = []
            var temps: [MTLTexture] = []
            var bw = max(w / 2, 1)
            var bh = max(h / 2, 1)
            for i in 0..<Self.bloomMipCount {
                mips.append(makeColor(width: bw, height: bh, label: "HDR.Bloom\(i)[\(s)]"))
                temps.append(makeColor(width: bw, height: bh, label: "HDR.BlurTemp\(i)[\(s)]"))
                bw = max(bw / 2, 1)
                bh = max(bh / 2, 1)
            }
            newSlots.append(Slot(
                sceneColor: sceneColor,
                sceneDepth: sceneDepth,
                bloomMips: mips,
                blurTemps: temps
            ))
        }
        slots = newSlots
        activeSlotIndex = min(activeSlotIndex, slotCount - 1)
        return true
    }

    var allTextures: [MTLTexture] {
        slots.flatMap(\.allTextures)
    }

#if !targetEnvironment(simulator)
    func makeScenePassDescriptor() -> MTL4RenderPassDescriptor {
        let rp = MTL4RenderPassDescriptor()
        rp.colorAttachments[0].texture = sceneColor
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        // Linear HDR clear — warm horizon so any miss still reads sunset, not black.
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.48, blue: 0.18, alpha: 1)
        rp.depthAttachment.texture = sceneDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1.0
        // No stencil ops — avoid undefined stencil paths on depth32Float_stencil8.
        return rp
    }

    func makeColorPassDescriptor(
        target: MTLTexture,
        loadAction: MTLLoadAction,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> MTL4RenderPassDescriptor {
        precondition(loadAction == .clear || loadAction == .dontCare || loadAction == .load,
                     "HDR color pass must set an explicit loadAction")
        let rp = MTL4RenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = loadAction
        rp.colorAttachments[0].storeAction = .store
        if loadAction == .clear {
            rp.colorAttachments[0].clearColor = clearColor
        }
        return rp
    }
#endif

    private func makeColor(width: Int, height: Int, label: String) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("HDRPipeline: failed to alloc \(label) \(width)x\(height)")
        }
        tex.label = label
        return tex
    }

    private func makeDepth(width: Int, height: Int, label: String) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("HDRPipeline: failed to alloc \(label) \(width)x\(height)")
        }
        tex.label = label
        return tex
    }
}

#if !targetEnvironment(simulator)
extension HDRPipeline {
    /// Post-FX constants — one CPU write per frame (triple-buffered by Renderer).
    static func fillPostFX(
        _ u: inout PostFXUniforms,
        time: Float,
        blurDirection: SIMD2<Float>,
        texelSize: SIMD2<Float>
    ) {
        u.bloomThreshold = ArtDirection.bloomThreshold
        u.bloomSoftKnee = ArtDirection.bloomSoftKnee
        u.bloomIntensity = ArtDirection.bloomIntensity
        u.grainAmount = ArtDirection.grainAmount
        u.saturation = ArtDirection.saturation
        u.vignetteStrength = ArtDirection.vignetteStrength
        u.time = time
        u.exposure = ArtDirection.exposure
        u.blurDirection = blurDirection
        u.texelSize = texelSize
    }
}
#endif
