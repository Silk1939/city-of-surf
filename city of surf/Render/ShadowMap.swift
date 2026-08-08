//
//  ShadowMap.swift
//  city of surf
//

import Metal
import simd

final class ShadowMap {
    /// One depth target per in-flight frame — avoid clearing a map another frame still samples.
    private let textures: [MTLTexture]
    let size: Int
    private(set) var lightViewProjection = matrix_identity_float4x4
    private var activeSlotIndex: Int = 0

    var texture: MTLTexture { textures[activeSlotIndex] }

    init?(device: MTLDevice, size: Int = 2048, slotCount: Int = maxBuffersInFlight) {
        self.size = size
        let slots = max(slotCount, 1)
        var built: [MTLTexture] = []
        built.reserveCapacity(slots)
        for i in 0..<slots {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: size,
                height: size,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "ShadowMap[\(i)]"
            built.append(tex)
        }
        self.textures = built
    }

    func setActiveSlot(_ index: Int) {
        let n = textures.count
        activeSlotIndex = ((index % n) + n) % n
    }

    var allTextures: [MTLTexture] { textures }

    /// Approximate bytes for all shadow slots (depth32Float).
    var approximateTextureBytes: Int {
        textures.count * size * size * 4
    }

    func updateLightMatrix(sunDirection: SIMD3<Float>, focus: SIMD3<Float>) {
        let L = simd_normalize(sunDirection)
        // Place light along sun direction looking at focus.
        let eye = focus + L * 55
        let view = Math.lookAt(eye: eye, target: focus, up: SIMD3(0, 1, 0))
        let extent: Float = 48
        let near: Float = 1
        let far: Float = 140
        let proj = Math.orthographic(
            left: -extent,
            right: extent,
            bottom: -extent,
            top: extent,
            nearZ: near,
            farZ: far
        )
        lightViewProjection = proj * view
    }

#if !targetEnvironment(simulator)
    func makeRenderPassDescriptor() -> MTL4RenderPassDescriptor {
        assert(texture.pixelFormat == .depth32Float, "Shadow map must be depth32Float")
        let rp = MTL4RenderPassDescriptor()
        // Metal 4: depth format is defined by this attachment, not the pipeline descriptor.
        rp.depthAttachment.texture = texture
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .store
        rp.depthAttachment.clearDepth = 1.0
        return rp
    }
#endif
}
