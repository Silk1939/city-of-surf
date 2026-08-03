//
//  HDRPipeline.swift
//  city of surf
//
//  Offscreen rgba16Float scene + 3-mip bloom chain + memory accounting.
//

import Metal
import simd

final class HDRPipeline {
    static let bloomMipCount = 3

    private(set) var sceneColor: MTLTexture!
    private(set) var sceneDepth: MTLTexture!
    private(set) var bloomMips: [MTLTexture] = []
    private(set) var blurTemps: [MTLTexture] = []
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        // Placeholder until drawableSizeWillChange; never leave nil for residency.
        recreate(width: 64, height: 128)
    }

    /// Bytes for debug HUD texture-memory estimate (color + depth + bloom + blur temps).
    var approximateTextureBytes: Int {
        guard width > 0, height > 0 else { return 0 }
        let sceneColorBytes = width * height * 8 // rgba16Float
        let sceneDepthBytes = width * height * 8 // depth32Float_stencil8 (padded)
        var bloomBytes = 0
        var w = max(width / 2, 1)
        var h = max(height / 2, 1)
        for _ in 0..<Self.bloomMipCount {
            bloomBytes += w * h * 8 * 2 // mip + matching blur temp
            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
        return sceneColorBytes + sceneDepthBytes + bloomBytes
    }

    @discardableResult
    func recreate(width: Int, height: Int) -> Bool {
        let w = max(width, 1)
        let h = max(height, 1)
        if w == self.width, h == self.height, sceneColor != nil { return false }
        self.width = w
        self.height = h

        sceneColor = makeColor(width: w, height: h, label: "HDR.SceneColor")
        sceneDepth = makeDepth(width: w, height: h, label: "HDR.SceneDepth")

        var mips: [MTLTexture] = []
        var temps: [MTLTexture] = []
        var bw = max(w / 2, 1)
        var bh = max(h / 2, 1)
        for i in 0..<Self.bloomMipCount {
            mips.append(makeColor(width: bw, height: bh, label: "HDR.Bloom\(i)"))
            temps.append(makeColor(width: bw, height: bh, label: "HDR.BlurTemp\(i)"))
            bw = max(bw / 2, 1)
            bh = max(bh / 2, 1)
        }
        bloomMips = mips
        blurTemps = temps
        return true
    }

    var allTextures: [MTLTexture] {
        [sceneColor, sceneDepth] + bloomMips + blurTemps
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
        rp.stencilAttachment.texture = sceneDepth
        rp.stencilAttachment.loadAction = .clear
        rp.stencilAttachment.storeAction = .dontCare
        rp.stencilAttachment.clearStencil = 0
        return rp
    }

    func makeColorPassDescriptor(
        target: MTLTexture,
        loadAction: MTLLoadAction,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> MTL4RenderPassDescriptor {
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
        u._pad0 = 0
        u.blurDirection = blurDirection
        u.texelSize = texelSize
    }
}
#endif
