//
//  Renderer.swift
//  city of surf
//

import Metal
import MetalKit
import ModelIO
import simd
import QuartzCore

let maxBuffersInFlight = 3
let maxObjectsPerFrame = 420

nonisolated enum RendererError: Error {
    case badVertexDescriptor
    case pipeline
}

struct DrawItem {
    var mesh: MTKMesh
    var modelMatrix: matrix_float4x4
    var color: SIMD4<Float>
    var isWave: Bool
    var materialId: Float
    var castsShadow: Bool = false
    var receivesShadow: Bool = true
}

final class Renderer: NSObject, MTKViewDelegate {

    /// Last failed init reason for on-screen error (no silent black frame).
    private(set) static var lastInitError: String?

    let device: MTLDevice
    weak var gameState: GameState?

#if !targetEnvironment(simulator)
    let commandQueue: MTL4CommandQueue
    let commandBuffer: MTL4CommandBuffer
    let commandAllocators: [MTL4CommandAllocator]
    var residencySet: MTLResidencySet
    let vertexArgumentTable: MTL4ArgumentTable
    let fragmentArgumentTable: MTL4ArgumentTable
#endif

    let endFrameEvent: MTLSharedEvent
    var frameIndex = 0

    var frameUniformBuffer: MTLBuffer
    var objectUniformBuffer: MTLBuffer
    var solidPipeline: MTLRenderPipelineState
    var wavePipeline: MTLRenderPipelineState
    var shadowPipeline: MTLRenderPipelineState
    var skyPipeline: MTLRenderPipelineState
    var bloomExtractPipeline: MTLRenderPipelineState
    var bloomBlurPipeline: MTLRenderPipelineState
    var bloomDownsamplePipeline: MTLRenderPipelineState
    var bloomUpsamplePipeline: MTLRenderPipelineState
    var postCopyPipeline: MTLRenderPipelineState
    var compositePipeline: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var skyDepthState: MTLDepthStencilState
    var postDepthState: MTLDepthStencilState

    var uniformBufferIndex = 0
    var objectDrawCount = 0
    var postFXUniformBuffer: MTLBuffer
    var hdrPipeline: HDRPipeline!

    var camera = ChaseCamera()
    var aspect: Float = 1
    var ibl: IBLTextures!
    var shadowMap: ShadowMap!

    let unitBox: MTKMesh
    let waveMesh: MTKMesh
    let surferMesh: MTKMesh
    let coinMesh: MTKMesh

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var fpsAccum: Float = 0
    private var fpsFrames: Int = 0
    private var waveShapeLogAccum: Float = 0
    private var lastWasGameOver = false

    @MainActor
    init?(metalKitView: MTKView, gameState: GameState) {
#if targetEnvironment(simulator)
        Self.lastInitError = "Simulator: Metal 4 wird nicht unterstützt."
        return nil
#else
        func fail(_ message: String) {
            Self.lastInitError = message
            print("Renderer.init FAIL: \(message)")
        }

        Self.lastInitError = nil
        guard let device = metalKitView.device else {
            fail("Kein MTLDevice an MTKView")
            return nil
        }
        self.device = device
        self.gameState = gameState

        guard let queue = device.makeMTL4CommandQueue() else {
            fail("makeMTL4CommandQueue fehlgeschlagen")
            return nil
        }
        self.commandQueue = queue
        // Metal 4: one long-lived reusable command buffer; memory comes from per-frame allocators.
        guard let cmdBuf = device.makeCommandBuffer() else {
            fail("makeCommandBuffer fehlgeschlagen")
            return nil
        }
        self.commandBuffer = cmdBuf

        var allocators: [MTL4CommandAllocator] = []
        for i in 0..<maxBuffersInFlight {
            guard let a = device.makeCommandAllocator() else {
                fail("makeCommandAllocator[\(i)] fehlgeschlagen")
                return nil
            }
            allocators.append(a)
        }
        self.commandAllocators = allocators

        let argTableDesc = MTL4ArgumentTableDescriptor()
        argTableDesc.maxBufferBindCount = 5
        guard let vat = try? device.makeArgumentTable(descriptor: argTableDesc) else {
            fail("vertexArgumentTable fehlgeschlagen")
            return nil
        }
        self.vertexArgumentTable = vat
        argTableDesc.maxTextureBindCount = 8
        guard let fat = try? device.makeArgumentTable(descriptor: argTableDesc) else {
            fail("fragmentArgumentTable fehlgeschlagen (maxTextureBindCount=8)")
            return nil
        }
        self.fragmentArgumentTable = fat

        guard let sharedEvent = device.makeSharedEvent() else {
            fail("makeSharedEvent fehlgeschlagen")
            return nil
        }
        self.endFrameEvent = sharedEvent
        frameIndex = maxBuffersInFlight
        self.endFrameEvent.signaledValue = UInt64(frameIndex - 1)

        let frameSize = alignedSize(MemoryLayout<FrameUniforms>.size) * maxBuffersInFlight
        let objectSize = alignedSize(MemoryLayout<ObjectUniforms>.size) * maxObjectsPerFrame * maxBuffersInFlight
        let postFXSize = alignedSize(MemoryLayout<PostFXUniforms>.size) * maxBuffersInFlight
        guard let fb = device.makeBuffer(length: frameSize, options: .storageModeShared),
              let ob = device.makeBuffer(length: objectSize, options: .storageModeShared),
              let pb = device.makeBuffer(length: postFXSize, options: .storageModeShared) else {
            fail("Uniform-Buffer Alloc fehlgeschlagen (frame=\(frameSize) object=\(objectSize) postFX=\(postFXSize))")
            return nil
        }
        frameUniformBuffer = fb
        frameUniformBuffer.label = "FrameUniforms"
        objectUniformBuffer = ob
        objectUniformBuffer.label = "ObjectUniforms"
        postFXUniformBuffer = pb
        postFXUniformBuffer.label = "PostFXUniforms"

        // Struct layout smoke (CPU/GPU must match ShaderTypes.h).
        let fu = MemoryLayout<FrameUniforms>.size
        let ou = MemoryLayout<ObjectUniforms>.size
        let pu = MemoryLayout<PostFXUniforms>.size
        print("Renderer: FrameUniforms size=\(fu) ObjectUniforms size=\(ou) PostFXUniforms size=\(pu) BufferIndex.postFX=\(BufferIndex.postFXUniforms.rawValue)")

        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0.95, green: 0.48, blue: 0.22, alpha: 1)

        let loadedIBL: IBLTextures
        do {
            loadedIBL = try IBLLoader.load(device: device)
        } catch {
            fail(error.localizedDescription)
            return nil
        }
        self.ibl = loadedIBL
        guard let sm = ShadowMap(device: device, size: 2048) else {
            fail("ShadowMap (depth32Float 2048) Alloc fehlgeschlagen")
            return nil
        }
        self.shadowMap = sm
        self.hdrPipeline = HDRPipeline(device: device)

        let vd = Self.buildMetalVertexDescriptor()
        let hdrFormat: MTLPixelFormat = .rgba16Float
        let ldrFormat = metalKitView.colorPixelFormat

        do {
            solidPipeline = try Self.buildPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: metalKitView.sampleCount,
                vertexDescriptor: vd,
                vertex: "solidVertex",
                fragment: "solidFragment",
                label: "SolidHDR"
            )
            wavePipeline = try Self.buildPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: metalKitView.sampleCount,
                vertexDescriptor: vd,
                vertex: "waveVertex",
                fragment: "waveFragment",
                label: "WaveHDR"
            )
            shadowPipeline = try Self.buildShadowPipeline(device: device, vertexDescriptor: vd)
            skyPipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: metalKitView.sampleCount,
                vertex: "skyVertex",
                fragment: "skyFragment",
                label: "SkyHDR"
            )
            bloomExtractPipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: 1,
                vertex: "postVertex",
                fragment: "bloomExtractFragment",
                label: "BloomExtract"
            )
            bloomBlurPipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: 1,
                vertex: "postVertex",
                fragment: "bloomBlurFragment",
                label: "BloomBlur"
            )
            bloomDownsamplePipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: 1,
                vertex: "postVertex",
                fragment: "bloomDownsampleFragment",
                label: "BloomDownsample"
            )
            bloomUpsamplePipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: 1,
                vertex: "postVertex",
                fragment: "bloomUpsampleFragment",
                label: "BloomUpsample"
            )
            postCopyPipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: 1,
                vertex: "postVertex",
                fragment: "postCopyFragment",
                label: "PostCopy"
            )
            compositePipeline = try Self.buildFullscreenPipeline(
                device: device,
                colorFormat: ldrFormat,
                sampleCount: metalKitView.sampleCount,
                vertex: "postVertex",
                fragment: "compositeFragment",
                label: "Composite"
            )
        } catch {
            fail("Pipeline: \(error.localizedDescription)")
            return nil
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else {
            fail("DepthStencilState (write) fehlgeschlagen")
            return nil
        }
        depthState = ds

        let skyDepthDesc = MTLDepthStencilDescriptor()
        skyDepthDesc.depthCompareFunction = .lessEqual
        skyDepthDesc.isDepthWriteEnabled = false
        guard let sds = device.makeDepthStencilState(descriptor: skyDepthDesc) else {
            fail("DepthStencilState (sky, no write) fehlgeschlagen")
            return nil
        }
        skyDepthState = sds

        let postDepthDesc = MTLDepthStencilDescriptor()
        postDepthDesc.depthCompareFunction = .always
        postDepthDesc.isDepthWriteEnabled = false
        guard let pds = device.makeDepthStencilState(descriptor: postDepthDesc) else {
            fail("DepthStencilState (post) fehlgeschlagen")
            return nil
        }
        postDepthState = pds

        do {
            unitBox = try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(1, 1, 1),
                vertexDescriptor: vd
            )
            waveMesh = try MeshFactory.makePlane(
                device: device,
                width: 30,
                depth: 140,
                segmentsX: 40,
                segmentsZ: 96,
                vertexDescriptor: vd
            )
            surferMesh = try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(0.55, 1.45, 0.4),
                vertexDescriptor: vd
            )
            // Upright thin disk (Y axis) — spun around Y like classic pickup coins.
            coinMesh = try MeshFactory.makeCylinder(
                device: device,
                height: 0.14,
                radius: 0.55,
                radialSegments: 20,
                verticalSegments: 1,
                vertexDescriptor: vd
            )
        } catch {
            fail("MeshFactory: \(error.localizedDescription)")
            return nil
        }

        let residencyDesc = MTLResidencySetDescriptor()
        residencyDesc.initialCapacity = 128
        guard let rs = try? device.makeResidencySet(descriptor: residencyDesc) else {
            fail("makeResidencySet fehlgeschlagen")
            return nil
        }
        rs.addAllocations([frameUniformBuffer, objectUniformBuffer, postFXUniformBuffer])
        rs.addAllocations(shadowMap.allTextures)
        rs.addAllocations(hdrPipeline.allTextures)
        for mesh in [unitBox, waveMesh, surferMesh, coinMesh] {
            rs.addAllocations(mesh.vertexBuffers.map(\.buffer))
            rs.addAllocations(mesh.submeshes.map(\.indexBuffer.buffer))
        }
        let texAllocs: [MTLTexture] = [
            ibl.sky, ibl.irradiance, ibl.specular, ibl.brdfLUT,
            ibl.asphalt.albedo, ibl.asphalt.normal, ibl.asphalt.roughness,
            ibl.concrete.albedo, ibl.concrete.normal, ibl.concrete.roughness,
            ibl.glass.albedo, ibl.glass.normal, ibl.glass.roughness,
            ibl.solidWhite, ibl.flatNormal, ibl.midRoughness
        ]
        rs.addAllocations(texAllocs)
        rs.commit()
        commandQueue.addResidencySet(rs)
        residencySet = rs

        super.init()
        gameState.reset()
        gameState.debugRendererReady = true
        gameState.debugKTXLoaded = true
        gameState.debugIBLPeak = ibl.config.irradiancePeak
        gameState.debugShadowActive = true
        updateTextureMemoryEstimate(gameState: gameState)
        print("Renderer OK: IBL peak=\(ibl.config.irradiancePeak) shadow=\(shadowMap.size) HDR=\(hdrPipeline.width)x\(hdrPipeline.height) bloom=\(ArtDirection.bloomIntensity) FrameUniforms=\(MemoryLayout<FrameUniforms>.size)")
#endif
    }

    private func updateTextureMemoryEstimate(gameState: GameState) {
        let totalBytes = ibl.approximateTextureBytes
            + shadowMap.approximateTextureBytes
            + hdrPipeline.approximateTextureBytes
        let mb = Float(totalBytes) / (1024 * 1024)
        gameState.debugTextureMemoryMB = mb
        let warnMB: Float = 128
        gameState.debugTextureMemoryWarn = mb > warnMB
        if gameState.debugTextureMemoryWarn {
            print("[FloodSurfer Smoke] WARN texture memory ≈ \(String(format: "%.1f", mb)) MB > \(Int(warnMB)) MB budget")
        }
    }

    private func refreshHDRResidency() {
#if !targetEnvironment(simulator)
        // HDR targets recreated on resize — keep residency set in sync.
        residencySet.addAllocations(hdrPipeline.allTextures)
        residencySet.commit()
#endif
    }
    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        vd.attributes[VertexAttribute.position.rawValue].format = .float3
        vd.attributes[VertexAttribute.position.rawValue].offset = 0
        vd.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        vd.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        vd.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        vd.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        vd.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        vd.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        vd.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex

        vd.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        vd.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        vd.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex
        return vd
    }

#if !targetEnvironment(simulator)
    /// Metal 4: `MTL4RenderPipelineDescriptor` has no depth/stencil pixel-format fields
    /// (unlike Metal 1–3). Depth comes from the render-pass attachment at encode time.
    /// Scene color is offscreen `.rgba16Float`; drawable composite uses MTKView format.
    @MainActor
    class func buildPipeline(
        device: MTLDevice,
        colorFormat: MTLPixelFormat,
        sampleCount: Int,
        vertexDescriptor: MTLVertexDescriptor,
        vertex: String,
        fragment: String,
        label: String
    ) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = vertex
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = fragment

        let pipelineDescriptor = MTL4RenderPipelineDescriptor()
        pipelineDescriptor.label = label
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.vertexFunctionDescriptor = vDesc
        pipelineDescriptor.fragmentFunctionDescriptor = fDesc
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        return try compiler.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    @MainActor
    class func buildFullscreenPipeline(
        device: MTLDevice,
        colorFormat: MTLPixelFormat,
        sampleCount: Int,
        vertex: String,
        fragment: String,
        label: String
    ) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = vertex
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = fragment

        let pipelineDescriptor = MTL4RenderPipelineDescriptor()
        pipelineDescriptor.label = label
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.vertexFunctionDescriptor = vDesc
        pipelineDescriptor.fragmentFunctionDescriptor = fDesc
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        return try compiler.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    @MainActor
    class func buildShadowPipeline(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = "shadowVertex"
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = "shadowFragment"

        let pipelineDescriptor = MTL4RenderPipelineDescriptor()
        pipelineDescriptor.label = "Shadow"
        pipelineDescriptor.vertexFunctionDescriptor = vDesc
        pipelineDescriptor.fragmentFunctionDescriptor = fDesc
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        // Depth-only pass: format is the ShadowMap texture (.depth32Float) on the pass descriptor.
        return try compiler.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
#endif

    private func frameUniformsPointer() -> UnsafeMutablePointer<FrameUniforms> {
        let stride = alignedSize(MemoryLayout<FrameUniforms>.size)
        let offset = stride * uniformBufferIndex
        return frameUniformBuffer.contents().advanced(by: offset).bindMemory(to: FrameUniforms.self, capacity: 1)
    }

    private func objectUniformsPointer(slot: Int) -> UnsafeMutablePointer<ObjectUniforms> {
        let stride = alignedSize(MemoryLayout<ObjectUniforms>.size)
        let frameBase = stride * maxObjectsPerFrame * uniformBufferIndex
        let offset = frameBase + stride * slot
        return objectUniformBuffer.contents().advanced(by: offset).bindMemory(to: ObjectUniforms.self, capacity: 1)
    }

    private func objectUniformsGPUAddress(slot: Int) -> UInt64 {
        let stride = alignedSize(MemoryLayout<ObjectUniforms>.size)
        let frameBase = stride * maxObjectsPerFrame * uniformBufferIndex
        let offset = frameBase + stride * slot
        return objectUniformBuffer.gpuAddress + UInt64(offset)
    }

    private func frameUniformsGPUAddress() -> UInt64 {
        let stride = alignedSize(MemoryLayout<FrameUniforms>.size)
        let offset = stride * uniformBufferIndex
        return frameUniformBuffer.gpuAddress + UInt64(offset)
    }

    private func postFXUniformsPointer() -> UnsafeMutablePointer<PostFXUniforms> {
        let stride = alignedSize(MemoryLayout<PostFXUniforms>.size)
        let offset = stride * uniformBufferIndex
        return postFXUniformBuffer.contents().advanced(by: offset).bindMemory(to: PostFXUniforms.self, capacity: 1)
    }

    private func postFXUniformsGPUAddress() -> UInt64 {
        let stride = alignedSize(MemoryLayout<PostFXUniforms>.size)
        let offset = stride * uniformBufferIndex
        return postFXUniformBuffer.gpuAddress + UInt64(offset)
    }

    private func writePostFX(
        time: Float,
        blurDirection: SIMD2<Float>,
        texelSize: SIMD2<Float>
    ) {
        var u = PostFXUniforms()
        HDRPipeline.fillPostFX(&u, time: time, blurDirection: blurDirection, texelSize: texelSize)
        postFXUniformsPointer().pointee = u
        fragmentArgumentTable.setAddress(postFXUniformsGPUAddress(), index: BufferIndex.postFXUniforms.rawValue)
    }

    private func encodeFullscreen(
        _ encoder: MTL4RenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        label: String
    ) {
        encoder.label = label
        encoder.setDepthStencilState(postDepthState)
        encoder.setRenderPipelineState(pipeline)
        encoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func buildDrawList(state: GameState) -> [DrawItem] {
        var items: [DrawItem] = []

        // Road slabs
        let roadZ = 40 - fmod(state.runDistance, 40)
        for i in -1...3 {
            let z = Float(i) * 40 + roadZ - 40
            let model = Math.translation(SIMD3(0, -0.08, z)) * Math.scale(SIMD3(14, 0.12, 40))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: model,
                color: SIMD4(0.12, 0.12, 0.14, 1),
                isWave: false,
                materialId: 1,
                castsShadow: false,
                receivesShadow: true
            ))
        }

        // Sidewalks
        for i in -1...3 {
            let z = Float(i) * 40 + roadZ - 40
            for side: Float in [-1, 1] {
                let model = Math.translation(SIMD3(side * 8.2, 0.05, z)) * Math.scale(SIMD3(2.2, 0.2, 40))
                items.append(DrawItem(
                    mesh: unitBox,
                    modelMatrix: model,
                    color: SIMD4(0.85, 0.85, 0.88, 1),
                    isWave: false,
                    materialId: 2,
                    castsShadow: false,
                    receivesShadow: true
                ))
            }
        }

        // One flood plane: crest near z=0, body behind (-), face ahead (+)
        let waveModel = Math.translation(SIMD3(0, 0, 25))
        items.append(DrawItem(
            mesh: waveMesh,
            modelMatrix: waveModel,
            color: SIMD4(0.1, 0.55, 0.65, 1),
            isWave: true,
            materialId: 0,
            castsShadow: false,
            receivesShadow: false
        ))

        // Surfer + board with lean
        let sp = state.surfer.position
        let sh = state.surfer.currentHeight
        let lean = state.surfer.lean
        let leanRot = Math.rotation(radians: lean * 0.35, axis: SIMD3(0, 0, 1))
        let surferModel = Math.translation(SIMD3(sp.x, sp.y, sp.z))
            * leanRot
            * Math.scale(SIMD3(1, sh / 1.45, 1))
        items.append(DrawItem(
            mesh: surferMesh,
            modelMatrix: surferModel,
            color: SIMD4(0.12, 0.12, 0.12, 1),  // black suit
            isWave: false,
            materialId: 3,
            castsShadow: true,
            receivesShadow: true
        ))
        let accent = Math.translation(SIMD3(sp.x, sp.y + 0.15, sp.z - 0.05))
            * leanRot
            * Math.scale(SIMD3(0.58, 0.35, 0.12))
        items.append(DrawItem(
            mesh: unitBox,
            modelMatrix: accent,
            color: SIMD4(ArtDirection.neonGreen.x, ArtDirection.neonGreen.y, ArtDirection.neonGreen.z, 1),
            isWave: false,
            materialId: 3,
            castsShadow: true,
            receivesShadow: true
        ))
        // Lightning bolt mark on the back (art ref)
        let bolt = Math.translation(SIMD3(sp.x, sp.y + 0.05, sp.z + 0.22))
            * leanRot
            * Math.scale(SIMD3(0.22, 0.55, 0.08))
        items.append(DrawItem(
            mesh: unitBox,
            modelMatrix: bolt,
            color: SIMD4(ArtDirection.neonGreen.x, ArtDirection.neonGreen.y, ArtDirection.neonGreen.z, 1),
            isWave: false,
            materialId: 3,
            castsShadow: false,
            receivesShadow: true
        ))
        let boardY = sp.y - sh * 0.5 + 0.08
        let board = Math.translation(SIMD3(sp.x, boardY, sp.z))
            * leanRot
            * Math.scale(SIMD3(0.85, 0.1, 2.4))
        items.append(DrawItem(
            mesh: unitBox,
            modelMatrix: board,
            color: SIMD4(0.08, 0.08, 0.1, 1),
            isWave: false,
            materialId: 3,
            castsShadow: true,
            receivesShadow: true
        ))
        let boardBolt = Math.translation(SIMD3(sp.x, boardY + 0.08, sp.z))
            * leanRot
            * Math.scale(SIMD3(0.35, 0.06, 1.4))
        items.append(DrawItem(
            mesh: unitBox,
            modelMatrix: boardBolt,
            color: SIMD4(ArtDirection.neonGreen.x, ArtDirection.neonGreen.y, ArtDirection.neonGreen.z, 1),
            isWave: false,
            materialId: 3,
            castsShadow: false,
            receivesShadow: true
        ))

        // Surfer wake spray — chunky stylized foam cubes trailing the board.
        let spWake = state.surfer.position
        for w in 0..<5 {
            let t = Float(w) * 0.18
            let wobble = sin(state.time * 14 + Float(w) * 1.7)
            let wakePos = SIMD3(
                spWake.x + wobble * 0.35,
                spWake.y - state.surfer.currentHeight * 0.45 + 0.05,
                spWake.z - 1.1 - t * 2.4
            )
            let s: Float = 0.35 - Float(w) * 0.04
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: Math.translation(wakePos) * Math.scale(SIMD3(s * 1.4, s * 0.5, s)),
                color: SIMD4(0.95, 0.98, 1.0, 1),
                isWave: false,
                materialId: 3,
                castsShadow: false,
                receivesShadow: false
            ))
        }

        // Collect / style sparks
        for spark in state.fx.sparks {
            let lifeT = max(0, spark.life / spark.maxLife)
            let sc = spark.scale * (0.55 + 0.45 * lifeT)
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: Math.translation(spark.position) * Math.scale(SIMD3(sc, sc, sc)),
                color: spark.color,
                isWave: false,
                materialId: 3,
                castsShadow: false,
                receivesShadow: false
            ))
        }

        // Coins early — never silently truncated by draw budget.
        let spin = state.time * 4.0
        for c in state.coinSystem.coins where c.active {
            let pos = state.coinSystem.worldPosition(
                for: c,
                runDistance: state.runDistance,
                wave: state.wave,
                time: state.time,
                scrollZ: state.scrollZ
            )
            // Cylinder tipped upright; worldPosition already includes hover height.
            let model = Math.translation(pos)
                * Math.rotation(radians: spin + c.localZ * 0.15, axis: SIMD3(0, 1, 0))
                * Math.rotation(radians: .pi * 0.5, axis: SIMD3(1, 0, 0))
            items.append(DrawItem(
                mesh: coinMesh,
                modelMatrix: model,
                color: SIMD4(ArtDirection.coinGold.x, ArtDirection.coinGold.y, ArtDirection.coinGold.z, 1),
                isWave: false,
                materialId: 5,
                castsShadow: false,
                receivesShadow: false
            ))
        }

        // Obstacles — composed vehicles / props
        for o in state.obstacles.obstacles where o.active {
            let pos = state.obstacles.worldPosition(
                for: o,
                runDistance: state.runDistance,
                wave: state.wave,
                time: state.time,
                scrollZ: state.scrollZ
            )
            let rot = Math.rotation(radians: o.roll * 0.28, axis: SIMD3(0, 0, 1))
            let yaw = Math.rotation(radians: .pi * 0.5, axis: SIMD3(0, 1, 0))
            appendObstacle(items: &items, kind: o.kind, at: pos, roll: rot, yaw: yaw)
        }

        // Buildings — irregular Manhattan block fronts (not a 14m picket fence).
        func buildingHash(_ n: Int) -> Float {
            var x = UInt32(bitPattern: Int32(n)) &* 747796405
            x = (x ^ (x >> 16)) &* 2246822519
            return Float(x & 0xFFFF) / 65535.0
        }
        let scroll = state.runDistance
        var zCursor = -fmod(scroll, 120) - 20
        var bi = 0
        while zCursor < 160 && bi < 20 {
            let hL = 16 + buildingHash(bi * 3) * 28
            let hR = 18 + buildingHash(bi * 3 + 1) * 30
            let wL = 6.5 + buildingHash(bi * 5) * 4.5
            let wR = 6.0 + buildingHash(bi * 7 + 2) * 5.0
            // Depth along street: short towers vs long block faces.
            let depthL = 7 + buildingHash(bi * 11) * 14
            let depthR = 7 + buildingHash(bi * 13 + 1) * 14
            // Gap: often abutting (blockfront), sometimes alley / empty lot.
            let gapRoll = buildingHash(bi * 17 + 3)
            let gap: Float
            if gapRoll < 0.35 {
                gap = 0.4 // nearly touching
            } else if gapRoll < 0.7 {
                gap = 2.5 + buildingHash(bi * 19) * 5.0
            } else {
                gap = 10 + buildingHash(bi * 23) * 14 // empty lot breaks periodicity
            }
            let zL = zCursor + depthL * 0.5
            let zR = zCursor + depthR * 0.5 + (buildingHash(bi * 29) - 0.5) * 3.0
            let left = Math.translation(SIMD3(-12.5, hL * 0.5, zL)) * Math.scale(SIMD3(wL, hL, depthL))
            let right = Math.translation(SIMD3(12.5, hR * 0.5, zR)) * Math.scale(SIMD3(wR, hR, depthR))
            let tint3L = ArtDirection.buildingTint(index: bi)
            let tint3R = ArtDirection.buildingTint(index: bi + 3)
            let tintL = SIMD4(tint3L.x, tint3L.y, tint3L.z, 1)
            let tintR = SIMD4(tint3R.x, tint3R.y, tint3R.z, 1)
            items.append(DrawItem(mesh: unitBox, modelMatrix: left, color: tintL, isWave: false, materialId: 6, castsShadow: true, receivesShadow: true))
            items.append(DrawItem(mesh: unitBox, modelMatrix: right, color: tintR, isWave: false, materialId: 6, castsShadow: true, receivesShadow: true))

            // Chunky rooftop palms / water towers — silhouette variety from the art ref.
            if buildingHash(bi * 41) > 0.55 {
                let palmX: Float = -12.5 + (buildingHash(bi * 43) - 0.5) * wL * 0.4
                let palmBase = Math.translation(SIMD3(palmX, hL + 1.2, zL))
                items.append(DrawItem(
                    mesh: unitBox,
                    modelMatrix: palmBase * Math.scale(SIMD3(0.35, 2.4, 0.35)),
                    color: SIMD4(0.35, 0.22, 0.12, 1),
                    isWave: false,
                    materialId: 4,
                    castsShadow: true,
                    receivesShadow: true
                ))
                items.append(DrawItem(
                    mesh: unitBox,
                    modelMatrix: palmBase * Math.translation(SIMD3(0, 1.6, 0)) * Math.scale(SIMD3(2.2, 0.55, 2.2)),
                    color: SIMD4(0.12, 0.55, 0.22, 1),
                    isWave: false,
                    materialId: 4,
                    castsShadow: true,
                    receivesShadow: true
                ))
            }
            if buildingHash(bi * 47) > 0.7 {
                let tower = Math.translation(SIMD3(12.5, hR + 1.5, zR)) * Math.scale(SIMD3(1.6, 2.2, 1.6))
                items.append(DrawItem(
                    mesh: unitBox,
                    modelMatrix: tower,
                    color: SIMD4(0.55, 0.52, 0.48, 1),
                    isWave: false,
                    materialId: 4,
                    castsShadow: true,
                    receivesShadow: true
                ))
            }

            zCursor += max(depthL, depthR) * 0.5 + gap + min(depthL, depthR) * 0.5
            bi += 1
        }

        // Graybox palms along the sidewalks (art-ref silhouettes).
        let palmBase = -fmod(state.runDistance, 28)
        for i in 0..<8 {
            let z = palmBase + Float(i) * 28 - 6
            let side: Float = (i % 2 == 0) ? -1 : 1
            let trunk = Math.translation(SIMD3(side * 9.4, 3.2, z)) * Math.scale(SIMD3(0.45, 6.4, 0.45))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: trunk,
                color: SIMD4(0.35, 0.18, 0.1, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            let fronds = Math.translation(SIMD3(side * 9.4, 6.6, z)) * Math.scale(SIMD3(3.2, 0.9, 3.2))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: fronds,
                color: SIMD4(0.12, 0.55, 0.22, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
        }

        // Stylized city billboards (art-ref vibe — solid color panels).
        let signScroll = -fmod(state.runDistance, 55)
        for i in 0..<4 {
            let z = signScroll + Float(i) * 55 + 18
            let side: Float = (i % 2 == 0) ? -1 : 1
            let pole = Math.translation(SIMD3(side * 10.2, 4.0, z)) * Math.scale(SIMD3(0.25, 8.0, 0.25))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: pole,
                color: SIMD4(0.2, 0.2, 0.22, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            let panelColor: SIMD4<Float> = (i % 2 == 0)
                ? SIMD4(ArtDirection.neonGreen.x, ArtDirection.neonGreen.y, ArtDirection.neonGreen.z, 1)
                : SIMD4(1.0, 0.55, 0.12, 1)
            let panel = Math.translation(SIMD3(side * 10.2, 8.2, z)) * Math.scale(SIMD3(0.2, 3.2, 5.5))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: panel,
                color: panelColor,
                isWave: false,
                materialId: 3,
                castsShadow: true,
                receivesShadow: false
            ))
        }

        return items
    }

    private func appendObstacle(
        items: inout [DrawItem],
        kind: ObstacleKind,
        at pos: SIMD3<Float>,
        roll: matrix_float4x4,
        yaw: matrix_float4x4
    ) {
        let base = Math.translation(pos) * roll
        switch kind {
        case .taxi, .police:
            let bodyColor: SIMD4<Float> = kind == .police
                ? SIMD4(0.12, 0.25, 0.75, 1)
                : SIMD4(0.95, 0.78, 0.1, 1)
            // body
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * yaw * Math.scale(SIMD3(2.0, 1.15, 4.0)),
                color: bodyColor,
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            // cabin
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * yaw * Math.translation(SIMD3(0, 0.85, -0.2)) * Math.scale(SIMD3(1.7, 0.9, 2.2)),
                color: SIMD4(0.15, 0.18, 0.22, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            // light bar / taxi sign
            let roofColor: SIMD4<Float> = kind == .police
                ? SIMD4(0.95, 0.15, 0.15, 1)
                : SIMD4(0.15, 0.15, 0.15, 1)
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * yaw * Math.translation(SIMD3(0, 1.35, 0.1)) * Math.scale(SIMD3(1.1, 0.25, 0.7)),
                color: roofColor,
                isWave: false,
                materialId: kind == .police ? 3 : 4,
                castsShadow: true,
                receivesShadow: true
            ))
            if kind == .police {
                // Blue flasher
                items.append(DrawItem(
                    mesh: unitBox,
                    modelMatrix: base * yaw * Math.translation(SIMD3(0.35, 1.4, 0.1)) * Math.scale(SIMD3(0.35, 0.18, 0.45)),
                    color: SIMD4(0.15, 0.45, 1.0, 1),
                    isWave: false,
                    materialId: 3,
                    castsShadow: false,
                    receivesShadow: false
                ))
            }
        case .barrier:
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.scale(SIMD3(2.6, 1.0, 0.55)),
                color: SIMD4(0.95, 0.45, 0.05, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.translation(SIMD3(0, 0.15, 0)) * Math.scale(SIMD3(2.6, 0.25, 0.58)),
                color: SIMD4(0.1, 0.1, 0.1, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
        case .trafficLight:
            // pole
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.scale(SIMD3(0.28, 3.4, 0.28)),
                color: SIMD4(0.18, 0.18, 0.2, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            // head
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.translation(SIMD3(0, 1.7, 0)) * Math.scale(SIMD3(0.7, 1.4, 0.55)),
                color: SIMD4(0.12, 0.12, 0.12, 1),
                isWave: false,
                materialId: 4,
                castsShadow: true,
                receivesShadow: true
            ))
            // lamps — emissive neon (materialId 3 self-glow path)
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.translation(SIMD3(0, 2.1, 0.28)) * Math.scale(SIMD3(0.35, 0.28, 0.2)),
                color: SIMD4(0.95, 0.15, 0.1, 1),
                isWave: false,
                materialId: 3,
                castsShadow: false,
                receivesShadow: false
            ))
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: base * Math.translation(SIMD3(0, 1.7, 0.28)) * Math.scale(SIMD3(0.35, 0.28, 0.2)),
                color: SIMD4(0.2, 0.95, 0.25, 1),
                isWave: false,
                materialId: 3,
                castsShadow: false,
                receivesShadow: false
            ))
        }
    }

    private func bindMaterialTextures(for item: DrawItem) {
        let mat: PBRMaterialTextures
        switch item.materialId {
        case 0.5..<1.5:
            mat = ibl.asphalt
        case 1.5..<2.5:
            mat = ibl.concrete
        case 5.5..<6.5:
            mat = ibl.glass
        default:
            // Intentional solids for surfer/obstacles/coins/wave — not a missing-asset fallback.
            fragmentArgumentTable.setTexture(ibl.solidWhite.gpuResourceID, index: TextureIndex.albedo.rawValue)
            fragmentArgumentTable.setTexture(ibl.flatNormal.gpuResourceID, index: TextureIndex.normal.rawValue)
            fragmentArgumentTable.setTexture(ibl.midRoughness.gpuResourceID, index: TextureIndex.roughness.rawValue)
            return
        }
        fragmentArgumentTable.setTexture(mat.albedo.gpuResourceID, index: TextureIndex.albedo.rawValue)
        fragmentArgumentTable.setTexture(mat.normal.gpuResourceID, index: TextureIndex.normal.rawValue)
        fragmentArgumentTable.setTexture(mat.roughness.gpuResourceID, index: TextureIndex.roughness.rawValue)
    }

    private func bindSharedLightingTextures() {
        fragmentArgumentTable.setTexture(shadowMap.texture.gpuResourceID, index: TextureIndex.shadow.rawValue)
        fragmentArgumentTable.setTexture(ibl.irradiance.gpuResourceID, index: TextureIndex.irradiance.rawValue)
        fragmentArgumentTable.setTexture(ibl.specular.gpuResourceID, index: TextureIndex.specular.rawValue)
        fragmentArgumentTable.setTexture(ibl.brdfLUT.gpuResourceID, index: TextureIndex.brdfLUT.rawValue)
        fragmentArgumentTable.setTexture(ibl.sky.gpuResourceID, index: TextureIndex.sky.rawValue)
    }

    private func encodeMesh(_ item: DrawItem, encoder: MTL4RenderCommandEncoder) {
        for (index, element) in item.mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout, layout.stride != 0 else { continue }
            let buffer = item.mesh.vertexBuffers[index]
            vertexArgumentTable.setAddress(
                buffer.buffer.gpuAddress + UInt64(buffer.offset),
                index: index
            )
        }
        for submesh in item.mesh.submeshes {
            encoder.drawIndexedPrimitives(
                primitiveType: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer.gpuAddress + UInt64(submesh.indexBuffer.offset),
                indexBufferLength: submesh.indexBuffer.buffer.length
            )
        }
    }

    func draw(in view: MTKView) {
#if !targetEnvironment(simulator)
        guard let state = gameState else { return }
        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentMTL4RenderPassDescriptor else { return }
        configureDrawablePass(renderPassDescriptor, clearColor: view.clearColor)

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 1.0 / 20.0))
        lastTime = now

        state.update(deltaTime: dt)
        fpsAccum += dt
        fpsFrames += 1
        if fpsAccum >= 0.5 {
            state.debugFPS = Int((Float(fpsFrames) / fpsAccum).rounded())
            fpsAccum = 0
            fpsFrames = 0
        }

        waveShapeLogAccum += dt
        if waveShapeLogAccum >= 1.0 {
            waveShapeLogAccum = 0
            let y0 = state.wave.height(x: state.surfer.x, z: 0, time: state.time, scrollZ: state.scrollZ)
            let y30 = state.wave.height(x: state.surfer.x, z: 30, time: state.time, scrollZ: state.scrollZ)
            let camY = camera.smoothEye.y
            print(String(format:
                "[FloodSurfer Wave] y(z=0)=%.2f y(z=+30)=%.2f Δh=%.2f camY=%.2f amp=%.1f face=%.1f crestShift=%.1f",
                y0, y30, y0 - y30, camY,
                state.wave.amplitude, state.wave.faceWidth, state.wave.crestShift
            ))
        }

        // After wipeout → restart, snap camera above water immediately.
        if lastWasGameOver && !state.isGameOver {
            camera.invalidate()
        }
        lastWasGameOver = state.isGameOver

        camera.update(
            follow: state.surfer.position,
            lean: state.surfer.lean,
            shake: state.wipeoutShake,
            deltaTime: dt
        )

        // CPU must not overwrite in-flight uniform / allocator / RT slots.
        waitForInFlightFrameSlot()

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        hdrPipeline.setActiveSlot(uniformBufferIndex)
        shadowMap.setActiveSlot(uniformBufferIndex)

        let commandAllocator = commandAllocators[uniformBufferIndex]
        commandAllocator.reset()
        // Reuse the single MTL4CommandBuffer; allocator provides per-frame backing memory.
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)

        shadowMap.updateLightMatrix(
            sunDirection: ArtDirection.sunDirection,
            focus: state.surfer.position + SIMD3(0, 6, 18)
        )

        let viewM = camera.viewMatrix(follow: state.surfer.position)
        let projM = camera.projectionMatrix(aspect: aspect)
        let viewProj = projM * viewM
        var frame = FrameUniforms()
        state.fillFrameUniforms(
            &frame,
            viewProjection: viewProj,
            invViewProjection: viewProj.inverse,
            lightViewProjection: shadowMap.lightViewProjection,
            cameraPosition: camera.smoothEye,
            lighting: ibl.config
        )
        frameUniformsPointer().pointee = frame

        let draws = buildDrawList(state: state)
        if draws.count > maxObjectsPerFrame {
            print("[FloodSurfer] ASSERT object count \(draws.count) > maxObjectsPerFrame \(maxObjectsPerFrame) — clamping")
            assertionFailure("objectDrawCount exceeded maxObjectsPerFrame")
        }
        objectDrawCount = min(draws.count, maxObjectsPerFrame)
        for i in 0..<objectDrawCount {
            var obj = ObjectUniforms()
            obj.modelMatrix = draws[i].modelMatrix
            obj.color = draws[i].color
            obj.isWave = draws[i].isWave ? 1 : 0
            obj.materialId = draws[i].materialId
            obj.castsShadow = draws[i].castsShadow ? 1 : 0
            obj.receivesShadow = draws[i].receivesShadow ? 1 : 0
            objectUniformsPointer(slot: i).pointee = obj
        }

        vertexArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)
        fragmentArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)

        // --- Shadow pass ---
        let shadowPass = shadowMap.makeRenderPassDescriptor()
        if let shadowEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            shadowEncoder.label = "Shadow"
            shadowEncoder.setCullMode(.front)
            shadowEncoder.setFrontFacing(.counterClockwise)
            shadowEncoder.setDepthStencilState(depthState)
            shadowEncoder.setRenderPipelineState(shadowPipeline)
            shadowEncoder.setArgumentTable(vertexArgumentTable, stages: .vertex)
            shadowEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
            for i in 0..<objectDrawCount where draws[i].castsShadow {
                let objAddr = objectUniformsGPUAddress(slot: i)
                vertexArgumentTable.setAddress(objAddr, index: BufferIndex.objectUniforms.rawValue)
                encodeMesh(draws[i], encoder: shadowEncoder)
            }
            shadowEncoder.endEncoding()
        }

        // --- HDR scene pass (sky + solids + wave) ---
        let scenePass = hdrPipeline.makeScenePassDescriptor()
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            fatalError("Failed to create HDR scene encoder")
        }
        renderEncoder.label = "HDRScene"
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setArgumentTable(vertexArgumentTable, stages: .vertex)
        renderEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
        bindSharedLightingTextures()

        renderEncoder.setDepthStencilState(skyDepthState)
        renderEncoder.setRenderPipelineState(skyPipeline)
        renderEncoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)

        renderEncoder.setDepthStencilState(depthState)
        for i in 0..<objectDrawCount {
            let item = draws[i]
            renderEncoder.setRenderPipelineState(item.isWave ? wavePipeline : solidPipeline)
            let objAddr = objectUniformsGPUAddress(slot: i)
            vertexArgumentTable.setAddress(objAddr, index: BufferIndex.objectUniforms.rawValue)
            fragmentArgumentTable.setAddress(objAddr, index: BufferIndex.objectUniforms.rawValue)
            bindMaterialTextures(for: item)
            encodeMesh(item, encoder: renderEncoder)
        }
        renderEncoder.endEncoding()

        // --- Bloom: extract → blur → 2× downsample/blur → additive upsample ---
        encodeBloomChain(time: state.time)

        // --- Composite into drawable (ACES + grade + grain) ---
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create composite encoder")
        }
        writePostFX(time: state.time, blurDirection: .zero, texelSize: .zero)
        fragmentArgumentTable.setTexture(hdrPipeline.sceneColor.gpuResourceID, index: TextureIndex.albedo.rawValue)
        fragmentArgumentTable.setTexture(hdrPipeline.bloomMips[0].gpuResourceID, index: TextureIndex.normal.rawValue)
        encodeFullscreen(compositeEncoder, pipeline: compositePipeline, label: "Composite")
        compositeEncoder.endEncoding()

        commandBuffer.useResidencySet((view.layer as! CAMetalLayer).residencySet)
        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        drawable.present()
        if !state.debugFirstFrameOK {
            state.debugFirstFrameOK = true
            print("[FloodSurfer Smoke] CHECK OK: first frame presented")
        }
#endif
    }

    /// Never overwrite a uniform/allocator/RT slot still in use by the GPU.
    private func waitForInFlightFrameSlot() {
#if !targetEnvironment(simulator)
        let target = UInt64(frameIndex - maxBuffersInFlight)
        if endFrameEvent.wait(untilSignaledValue: target, timeoutMS: 10) {
            return
        }
        print("[FloodSurfer] WARN: in-flight wait timeout (target=\(target)) — blocking until GPU catches up")
        // Block rather than skip-writing into a live slot (causes magenta/green garbage).
        while !endFrameEvent.wait(untilSignaledValue: target, timeoutMS: 1000) {
            print("[FloodSurfer] WARN: still waiting for GPU frame slot \(target)")
        }
#endif
    }

    /// MTKView drawable pass must always clear — never inherit .load / undefined contents.
    private func configureDrawablePass(_ rp: MTL4RenderPassDescriptor, clearColor: MTLClearColor) {
#if !targetEnvironment(simulator)
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clearColor
        if rp.depthAttachment.texture != nil {
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1.0
            rp.depthAttachment.storeAction = .dontCare
        }
        if rp.stencilAttachment.texture != nil {
            rp.stencilAttachment.loadAction = .clear
            rp.stencilAttachment.clearStencil = 0
            rp.stencilAttachment.storeAction = .dontCare
        }
#endif
    }

    private func encodeBloomChain(time: Float) {
#if !targetEnvironment(simulator)
        let mips = hdrPipeline.bloomMips
        let temps = hdrPipeline.blurTemps
        guard mips.count == 3, temps.count == 3 else { return }

        // Bind slots: albedo=sceneHDR, normal=bloom (same indices as TextureIndexSceneHDR/Bloom).
        let sceneSlot = TextureIndex.albedo.rawValue
        let bloomSlot = TextureIndex.normal.rawValue

        // 1) Threshold extract into mip0 (half res)
        if let enc = commandBuffer.makeRenderCommandEncoder(
            descriptor: hdrPipeline.makeColorPassDescriptor(target: mips[0], loadAction: .clear)
        ) {
            writePostFX(time: time, blurDirection: .zero, texelSize: .zero)
            fragmentArgumentTable.setTexture(hdrPipeline.sceneColor.gpuResourceID, index: sceneSlot)
            encodeFullscreen(enc, pipeline: bloomExtractPipeline, label: "BloomExtract")
            enc.endEncoding()
        }

        // 2) Separable blur each mip; downsample into next
        for i in 0..<mips.count {
            let texel = SIMD2<Float>(1.0 / Float(mips[i].width), 1.0 / Float(mips[i].height))

            if let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: hdrPipeline.makeColorPassDescriptor(target: temps[i], loadAction: .clear)
            ) {
                writePostFX(time: time, blurDirection: SIMD2(1, 0), texelSize: texel)
                fragmentArgumentTable.setTexture(mips[i].gpuResourceID, index: bloomSlot)
                encodeFullscreen(enc, pipeline: bloomBlurPipeline, label: "BloomBlurH\(i)")
                enc.endEncoding()
            }
            if let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: hdrPipeline.makeColorPassDescriptor(target: mips[i], loadAction: .clear)
            ) {
                writePostFX(time: time, blurDirection: SIMD2(0, 1), texelSize: texel)
                fragmentArgumentTable.setTexture(temps[i].gpuResourceID, index: bloomSlot)
                encodeFullscreen(enc, pipeline: bloomBlurPipeline, label: "BloomBlurV\(i)")
                enc.endEncoding()
            }

            if i + 1 < mips.count {
                if let enc = commandBuffer.makeRenderCommandEncoder(
                    descriptor: hdrPipeline.makeColorPassDescriptor(target: mips[i + 1], loadAction: .clear)
                ) {
                    fragmentArgumentTable.setTexture(mips[i].gpuResourceID, index: bloomSlot)
                    encodeFullscreen(enc, pipeline: bloomDownsamplePipeline, label: "BloomDown\(i)")
                    enc.endEncoding()
                }
            }
        }

        // 3) Additive upsample mip2 → mip1 → mip0
        for i in stride(from: mips.count - 1, through: 1, by: -1) {
            if let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: hdrPipeline.makeColorPassDescriptor(target: temps[i - 1], loadAction: .clear)
            ) {
                fragmentArgumentTable.setTexture(mips[i].gpuResourceID, index: bloomSlot)
                fragmentArgumentTable.setTexture(mips[i - 1].gpuResourceID, index: sceneSlot)
                encodeFullscreen(enc, pipeline: bloomUpsamplePipeline, label: "BloomUp\(i)")
                enc.endEncoding()
            }
            if let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: hdrPipeline.makeColorPassDescriptor(target: mips[i - 1], loadAction: .clear)
            ) {
                fragmentArgumentTable.setTexture(temps[i - 1].gpuResourceID, index: bloomSlot)
                encodeFullscreen(enc, pipeline: postCopyPipeline, label: "BloomUpStore\(i)")
                enc.endEncoding()
            }
        }
#endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
#if !targetEnvironment(simulator)
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return }
        if hdrPipeline.recreate(width: w, height: h) {
            refreshHDRResidency()
            if let state = gameState {
                updateTextureMemoryEstimate(gameState: state)
            }
            print("Renderer: HDR targets \(w)x\(h) bloom0=\(hdrPipeline.bloomMips[0].width)x\(hdrPipeline.bloomMips[0].height)")
        }
#endif
    }
}

func alignedSize(_ size: Int) -> Int {
    (size + 0xFF) & ~0xFF
}
