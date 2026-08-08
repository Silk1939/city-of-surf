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
/// Soft warn only — never abort a device frame; clamp draws instead.
/// Keep false until device is stable without green/white block glitches.
let enableBloomChain = false

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
    /// One argument-table pair per in-flight frame — never mutate a table the GPU still reads.
    let vertexArgumentTables: [MTL4ArgumentTable]
    let fragmentArgumentTables: [MTL4ArgumentTable]
#endif


    let endFrameEvent: MTLSharedEvent
    var frameIndex = 0

    var frameUniformBuffer: MTLBuffer
    var objectUniformBuffer: MTLBuffer
    var solidPipeline: MTLRenderPipelineState
    var solidInstancedPipeline: MTLRenderPipelineState
    var wavePipeline: MTLRenderPipelineState
    var shadowPipeline: MTLRenderPipelineState
    var shadowInstancedPipeline: MTLRenderPipelineState
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
    var instanceUniformBuffer: MTLBuffer
    var instanceStreamer = InstanceStreamer()
    var quality = QualitySettings.high
    private var lastLoggedDrawStats = 0
    var hdrPipeline: HDRPipeline!
    /// 1×1 black HDR tex for composite bloom bind when bloom chain is off.
    var blackBloomTexture: MTLTexture!

    var camera = ChaseCamera()
    var aspect: Float = 1
    var ibl: IBLTextures!
    var shadowMap: ShadowMap!

    let unitBox: MTKMesh
    let waveMesh: MTKMesh
    let coinMesh: MTKMesh
    /// Soft ellipsoid for wake / spray / mist (material 8).
    let sprayMesh: MTKMesh
    let surferMeshes: SurferMeshes
    let surfboardMeshes: SurfboardMeshes
    let cityKitMeshes: CityKitMeshes
    let urbanPropMeshes: UrbanPropMeshes
    private var surferVisual = SurferVisual()

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var fpsAccum: Float = 0
    private var fpsFrames: Int = 0
    private var waveShapeLogAccum: Float = 0
    private var lastWasGameOver = false
    private var lastSurferPose: SurferPose = .standing
    private var lastStylePulse: Float = 0
    /// HDR textures currently registered in `residencySet` (removed on recreate).
    private var residentHDRTextures: [MTLTexture] = []

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
        argTableDesc.maxBufferBindCount = 6
        argTableDesc.maxTextureBindCount = 8
        var vTables: [MTL4ArgumentTable] = []
        var fTables: [MTL4ArgumentTable] = []
        for i in 0..<maxBuffersInFlight {
            guard let vat = try? device.makeArgumentTable(descriptor: argTableDesc) else {
                fail("vertexArgumentTable[\(i)] fehlgeschlagen")
                return nil
            }
            guard let fat = try? device.makeArgumentTable(descriptor: argTableDesc) else {
                fail("fragmentArgumentTable[\(i)] fehlgeschlagen")
                return nil
            }
            vTables.append(vat)
            fTables.append(fat)
        }
        self.vertexArgumentTables = vTables
        self.fragmentArgumentTables = fTables

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
        let instanceSize = MemoryLayout<ObjectUniforms>.stride * maxInstancesPerFrame * maxBuffersInFlight
        guard let fb = device.makeBuffer(length: frameSize, options: .storageModeShared),
              let ob = device.makeBuffer(length: objectSize, options: .storageModeShared),
              let pb = device.makeBuffer(length: postFXSize, options: .storageModeShared),
              let ib = device.makeBuffer(length: instanceSize, options: .storageModeShared) else {
            fail("Uniform-Buffer Alloc fehlgeschlagen (frame=\(frameSize) object=\(objectSize) postFX=\(postFXSize) instance=\(instanceSize))")
            return nil
        }
        frameUniformBuffer = fb
        frameUniformBuffer.label = "FrameUniforms"
        objectUniformBuffer = ob
        objectUniformBuffer.label = "ObjectUniforms"
        postFXUniformBuffer = pb
        postFXUniformBuffer.label = "PostFXUniforms"
        instanceUniformBuffer = ib
        instanceUniformBuffer.label = "InstanceUniforms"

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
        // Single HDR/shadow slot: 3× full-res rgba16Float blew residency/memory → green blocks.
        guard let sm = ShadowMap(device: device, size: 2048, slotCount: 1) else {
            fail("ShadowMap (depth32Float 2048) Alloc fehlgeschlagen")
            return nil
        }
        self.shadowMap = sm
        self.hdrPipeline = HDRPipeline(device: device, slotCount: 1)

        let blackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        blackDesc.usage = [.shaderRead]
        blackDesc.storageMode = .shared
        guard let blackTex = device.makeTexture(descriptor: blackDesc) else {
            fail("blackBloomTexture Alloc fehlgeschlagen")
            return nil
        }
        blackTex.label = "BlackBloom"
        // rgba16Float texels are IEEE half — write zeros (0.0h), not Float32.
        var blackHalf = [UInt16](repeating: 0, count: 4)
        blackTex.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes: &blackHalf,
            bytesPerRow: MemoryLayout<UInt16>.stride * 4
        )
        self.blackBloomTexture = blackTex

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
            solidInstancedPipeline = try Self.buildPipeline(
                device: device,
                colorFormat: hdrFormat,
                sampleCount: metalKitView.sampleCount,
                vertexDescriptor: vd,
                vertex: "solidInstancedVertex",
                fragment: "solidFragment",
                label: "SolidInstancedHDR"
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
            shadowPipeline = try Self.buildShadowPipeline(
                device: device,
                vertexDescriptor: vd,
                vertex: "shadowVertex",
                label: "Shadow"
            )
            shadowInstancedPipeline = try Self.buildShadowPipeline(
                device: device,
                vertexDescriptor: vd,
                vertex: "shadowInstancedVertex",
                label: "ShadowInstanced"
            )
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
            // Pinch compresses Z — denser segments along the street; X can be coarser.
            let waterQ = quality.water
            waveMesh = try MeshFactory.makePlane(
                device: device,
                width: 30,
                depth: 140,
                segmentsX: waterQ.waveSegmentsX,
                segmentsZ: waterQ.waveSegmentsZ,
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
            sprayMesh = try MeshFactory.makeSphere(
                device: device,
                radii: SIMD3(0.5, 0.5, 0.5),
                radialSegments: 10,
                verticalSegments: 8,
                vertexDescriptor: vd
            )
            surferMeshes = try SurferMeshes.make(device: device, vertexDescriptor: vd)
            surfboardMeshes = try SurfboardMeshes.make(device: device, vertexDescriptor: vd)
            cityKitMeshes = try CityKitMeshes.make(device: device, vertexDescriptor: vd, unitBox: unitBox)
            urbanPropMeshes = try UrbanPropMeshes.make(device: device, vertexDescriptor: vd, unitBox: unitBox)
        } catch {
            fail("MeshFactory: \(error.localizedDescription)")
            return nil
        }

        let residencyDesc = MTLResidencySetDescriptor()
        residencyDesc.initialCapacity = 256
        guard let rs = try? device.makeResidencySet(descriptor: residencyDesc) else {
            fail("makeResidencySet fehlgeschlagen")
            return nil
        }
        rs.addAllocations([frameUniformBuffer, objectUniformBuffer, postFXUniformBuffer, instanceUniformBuffer, blackBloomTexture])
        rs.addAllocations(shadowMap.allTextures)
        residentHDRTextures = hdrPipeline.allTextures
        rs.addAllocations(residentHDRTextures)
        for mesh in [unitBox, waveMesh, coinMesh, sprayMesh]
            + surferMeshes.allMeshes
            + surfboardMeshes.allMeshes
            + cityKitMeshes.allMeshes
            + urbanPropMeshes.allMeshes
        {
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
        gameState.waterQuality = quality.water
        gameState.reset()
        gameState.debugRendererReady = true
        gameState.debugKTXLoaded = true
        gameState.debugIBLPeak = ibl.config.irradiancePeak
        gameState.debugShadowActive = true
        updateTextureMemoryEstimate(gameState: gameState)
        print("Renderer OK: IBL peak=\(ibl.config.irradiancePeak) shadow=\(shadowMap.size) HDR=\(hdrPipeline.width)x\(hdrPipeline.height) bloomChain=\(enableBloomChain) waterSeg=\(quality.water.waveSegmentsX)x\(quality.water.waveSegmentsZ) FrameUniforms=\(MemoryLayout<FrameUniforms>.size)")
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
        // Drop freed placeholder/previous HDR targets — dangling residency = green garbage.
        if !residentHDRTextures.isEmpty {
            residencySet.removeAllocations(residentHDRTextures)
        }
        residentHDRTextures = hdrPipeline.allTextures
        residencySet.addAllocations(residentHDRTextures)
        residencySet.commit()
#endif
    }

#if !targetEnvironment(simulator)
    private var vertexArgumentTable: MTL4ArgumentTable {
        vertexArgumentTables[uniformBufferIndex]
    }

    private var fragmentArgumentTable: MTL4ArgumentTable {
        fragmentArgumentTables[uniformBufferIndex]
    }
#endif
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
    class func buildShadowPipeline(
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor,
        vertex: String = "shadowVertex",
        label: String = "Shadow"
    ) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vDesc = MTL4LibraryFunctionDescriptor()
        vDesc.library = library
        vDesc.name = vertex
        let fDesc = MTL4LibraryFunctionDescriptor()
        fDesc.library = library
        fDesc.name = "shadowFragment"

        let pipelineDescriptor = MTL4RenderPipelineDescriptor()
        pipelineDescriptor.label = label
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
        instanceStreamer.beginFrame()

        // Road slabs — one instanced batch
        let roadStart = instanceStreamer.nextIndex
        let roadZ = 40 - fmod(state.runDistance, 40)
        for i in -1...3 {
            let z = Float(i) * 40 + roadZ - 40
            let model = Math.translation(SIMD3(0, -0.08, z)) * Math.scale(SIMD3(14, 0.12, 40))
            _ = instanceStreamer.append(
                modelMatrix: model,
                color: SIMD4(0.12, 0.12, 0.14, 1),
                materialId: 1,
                castsShadow: false,
                receivesShadow: true
            )
        }
        instanceStreamer.closeBatch(
            mesh: unitBox, start: roadStart, materialId: 1, castsShadow: false, receivesShadow: true
        )

        // Sidewalks — one instanced batch
        let walkStart = instanceStreamer.nextIndex
        for i in -1...3 {
            let z = Float(i) * 40 + roadZ - 40
            for side: Float in [-1, 1] {
                let model = Math.translation(SIMD3(side * 8.2, 0.05, z)) * Math.scale(SIMD3(2.2, 0.2, 40))
                _ = instanceStreamer.append(
                    modelMatrix: model,
                    color: SIMD4(0.85, 0.85, 0.88, 1),
                    materialId: 2,
                    castsShadow: false,
                    receivesShadow: true
                )
            }
        }
        instanceStreamer.closeBatch(
            mesh: unitBox, start: walkStart, materialId: 2, castsShadow: false, receivesShadow: true
        )

        // One flood plane
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

        let lean = state.surfer.lean
        surferVisual.appendDrawItems(
            to: &items,
            meshes: surferMeshes,
            surfer: state.surfer,
            rootLean: lean
        )
        SurfboardVisual.appendDrawItems(
            to: &items,
            meshes: surfboardMeshes,
            surfer: state.surfer,
            poseWeights: (
                lean: lean,
                jumpT: SurfboardVisual.jumpPhase(state.surfer),
                isDuck: state.surfer.pose == .ducking,
                isWipeout: state.isGameOver
            )
        )

        // Wake / spray / mist — soft ellipsoids (material 8); coin sparks stay neon (material 3).
        let waterFXStart = instanceStreamer.nextIndex
        let qScale = quality.water.particleScale * quality.particleScale
        for spark in state.fx.sparks where spark.kind != .spark {
            let lifeT = max(0, spark.life / max(spark.maxLife, 0.001))
            let fade = lifeT * lifeT * (3 - 2 * lifeT)
            let sc = spark.scale * (0.45 + 0.55 * fade) * qScale
            let teal = SIMD4<Float>(0.18, 0.72, 0.70, 1)
            let t = fade * 0.85 + 0.15
            var col = teal * (1 - t) + spark.color * t
            if spark.kind == .mist {
                col = SIMD4(col.x * 0.88, col.y * 0.94, col.z * 0.96, 1)
            }
            let stretch = spark.stretch * sc
            _ = instanceStreamer.append(
                modelMatrix: Math.translation(spark.position) * Math.scale(stretch),
                color: col,
                materialId: 8,
                castsShadow: false,
                receivesShadow: false
            )
        }
        if instanceStreamer.nextIndex > waterFXStart {
            instanceStreamer.closeBatch(
                mesh: sprayMesh, start: waterFXStart, materialId: 8, castsShadow: false, receivesShadow: false
            )
        }

        let sparkStart = instanceStreamer.nextIndex
        for spark in state.fx.sparks where spark.kind == .spark {
            let lifeT = max(0, spark.life / max(spark.maxLife, 0.001))
            let fade = lifeT * lifeT * (3 - 2 * lifeT)
            let sc = spark.scale * (0.45 + 0.55 * fade) * qScale
            _ = instanceStreamer.append(
                modelMatrix: Math.translation(spark.position) * Math.scale(SIMD3(sc, sc, sc)),
                color: spark.color,
                materialId: 3,
                castsShadow: false,
                receivesShadow: false
            )
        }
        if instanceStreamer.nextIndex > sparkStart {
            instanceStreamer.closeBatch(
                mesh: sprayMesh, start: sparkStart, materialId: 3, castsShadow: false, receivesShadow: false
            )
        }

        // Coins — instanced
        let coinStart = instanceStreamer.nextIndex
        let spin = state.time * 4.0
        for c in state.coinSystem.coins where c.active {
            let pos = state.coinSystem.worldPosition(
                for: c,
                runDistance: state.runDistance,
                wave: state.wave,
                time: state.time,
                scrollZ: state.scrollZ
            )
            let model = Math.translation(pos)
                * Math.rotation(radians: spin + c.localZ * 0.15, axis: SIMD3(0, 1, 0))
                * Math.rotation(radians: .pi * 0.5, axis: SIMD3(1, 0, 0))
            _ = instanceStreamer.append(
                modelMatrix: model,
                color: SIMD4(ArtDirection.coinGold.x, ArtDirection.coinGold.y, ArtDirection.coinGold.z, 1),
                materialId: 5,
                castsShadow: false,
                receivesShadow: false
            )
        }
        instanceStreamer.closeBatch(
            mesh: coinMesh, start: coinStart, materialId: 5, castsShadow: false, receivesShadow: false
        )

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
            UrbanProps.appendObstacle(
                items: &items,
                meshes: urbanPropMeshes,
                kind: o.kind,
                at: pos,
                roll: rot,
                yaw: yaw
            )
        }

        CityKit.appendAvenue(items: &items, meshes: cityKitMeshes, runDistance: state.runDistance)

        let palmBase = -fmod(state.runDistance, 28)
        for i in 0..<6 {
            let z = palmBase + Float(i) * 28 - 6
            let side: Float = (i % 2 == 0) ? -1 : 1
            UrbanProps.appendPalm(
                items: &items,
                meshes: urbanPropMeshes,
                at: SIMD3(side * 9.4, 0, z),
                scale: 1
            )
        }
        let tankBase = -fmod(state.runDistance, 70)
        for i in 0..<2 {
            let z = tankBase + Float(i) * 70 + 25
            let side: Float = (i % 2 == 0) ? -1 : 1
            UrbanProps.appendWaterTank(
                items: &items,
                meshes: urbanPropMeshes,
                at: SIMD3(side * 11.5, 14 + CityKit.hash(i * 17) * 10, z)
            )
        }

        let signScroll = -fmod(state.runDistance, 55)
        for i in 0..<3 {
            let z = signScroll + Float(i) * 55 + 18
            let side: Float = (i % 2 == 0) ? -1 : 1
            let panelColor: SIMD4<Float> = (i % 2 == 0)
                ? SIMD4(ArtDirection.neonCyan.x, ArtDirection.neonCyan.y, ArtDirection.neonCyan.z, 1)
                : SIMD4(1.0, 0.55, 0.12, 1)
            UrbanProps.appendBillboard(
                items: &items,
                meshes: urbanPropMeshes,
                at: SIMD3(side * 10.2, 0, z),
                panelColor: panelColor
            )
        }

        return items
    }

    private func bindMaterialTextures(materialId: Float) {
        let mat: PBRMaterialTextures
        switch materialId {
        case 0.5..<1.5:
            mat = ibl.asphalt
        case 1.5..<2.5:
            mat = ibl.concrete
        case 5.5..<6.5:
            mat = ibl.glass
        default:
            fragmentArgumentTable.setTexture(ibl.solidWhite.gpuResourceID, index: TextureIndex.albedo.rawValue)
            fragmentArgumentTable.setTexture(ibl.flatNormal.gpuResourceID, index: TextureIndex.normal.rawValue)
            fragmentArgumentTable.setTexture(ibl.midRoughness.gpuResourceID, index: TextureIndex.roughness.rawValue)
            return
        }
        fragmentArgumentTable.setTexture(mat.albedo.gpuResourceID, index: TextureIndex.albedo.rawValue)
        fragmentArgumentTable.setTexture(mat.normal.gpuResourceID, index: TextureIndex.normal.rawValue)
        fragmentArgumentTable.setTexture(mat.roughness.gpuResourceID, index: TextureIndex.roughness.rawValue)
    }

    private func bindMaterialTextures(for item: DrawItem) {
        bindMaterialTextures(materialId: item.materialId)
    }

    private func bindSharedLightingTextures() {
        fragmentArgumentTable.setTexture(shadowMap.texture.gpuResourceID, index: TextureIndex.shadow.rawValue)
        fragmentArgumentTable.setTexture(ibl.irradiance.gpuResourceID, index: TextureIndex.irradiance.rawValue)
        fragmentArgumentTable.setTexture(ibl.specular.gpuResourceID, index: TextureIndex.specular.rawValue)
        fragmentArgumentTable.setTexture(ibl.brdfLUT.gpuResourceID, index: TextureIndex.brdfLUT.rawValue)
        fragmentArgumentTable.setTexture(ibl.sky.gpuResourceID, index: TextureIndex.sky.rawValue)
    }

    private func encodeMesh(_ mesh: MTKMesh, encoder: MTL4RenderCommandEncoder, instanceCount: Int = 1) {
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout, layout.stride != 0 else { continue }
            let buffer = mesh.vertexBuffers[index]
            vertexArgumentTable.setAddress(
                buffer.buffer.gpuAddress + UInt64(buffer.offset),
                index: index
            )
        }
        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(
                primitiveType: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer.gpuAddress + UInt64(submesh.indexBuffer.offset),
                indexBufferLength: submesh.indexBuffer.buffer.length,
                instanceCount: instanceCount
            )
        }
    }

    private func encodeMesh(_ item: DrawItem, encoder: MTL4RenderCommandEncoder) {
        encodeMesh(item.mesh, encoder: encoder, instanceCount: 1)
    }

    private func encodeInstancedBatches(encoder: MTL4RenderCommandEncoder, shadowPass: Bool) {
        for batch in instanceStreamer.batches {
            if shadowPass && !batch.castsShadow { continue }
            let addr = instanceStreamer.gpuAddress(
                buffer: instanceUniformBuffer,
                frameSlot: uniformBufferIndex,
                firstInstance: batch.firstInstance
            )
            vertexArgumentTable.setAddress(addr, index: BufferIndex.instanceUniforms.rawValue)
            if shadowPass {
                encoder.setRenderPipelineState(shadowInstancedPipeline)
            } else {
                encoder.setRenderPipelineState(solidInstancedPipeline)
                fragmentArgumentTable.setAddress(addr, index: BufferIndex.instanceUniforms.rawValue)
                // solidFragment still declares ObjectUniforms — bind first instance as safe placeholder.
                fragmentArgumentTable.setAddress(addr, index: BufferIndex.objectUniforms.rawValue)
                bindMaterialTextures(materialId: batch.materialId)
            }
            encodeMesh(batch.mesh, encoder: encoder, instanceCount: batch.instanceCount)
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

        // Short camera impulses — landing / style / wipeout (no permanent shake).
        if lastSurferPose == .jumping && state.surfer.pose == .standing && !state.isGameOver {
            camera.addImpulse(SIMD3(0, -0.42, 0.12))
        }
        if state.stylePulse > 0.85 && lastStylePulse <= 0.85 {
            camera.addImpulse(SIMD3(0, 0.18, -0.15))
        }
        if state.isGameOver && !lastWasGameOver {
            camera.addImpulse(SIMD3(0, 0.55, 0.28))
        }
        lastSurferPose = state.surfer.pose
        lastStylePulse = state.stylePulse

        // After wipeout → restart, snap camera above water immediately.
        if lastWasGameOver && !state.isGameOver {
            camera.invalidate()
            surferVisual.invalidate()
        }
        lastWasGameOver = state.isGameOver

        surferVisual.update(
            surfer: state.surfer,
            isWipeout: state.isGameOver,
            deltaTime: dt
        )

        let waveY = state.wave.height(
            x: state.surfer.x,
            z: state.surfer.position.z,
            time: state.time,
            scrollZ: state.scrollZ
        )
        camera.update(
            follow: state.surfer.position,
            waveHeight: waveY,
            lean: state.surfer.lean,
            shake: state.wipeoutShake,
            speed: state.speed,
            deltaTime: dt
        )

        // Serialize GPU work onto one HDR/shadow target (no in-flight RT races).
        // frameIndex starts at maxBuffersInFlight (≥1) in init — never wait on UInt64(-1).
        let previousValueToWaitFor = max(frameIndex - 1, 0)
        if !endFrameEvent.wait(untilSignaledValue: UInt64(previousValueToWaitFor), timeoutMS: 10) {
            print("[FloodSurfer] WARN: frame wait timeout (target=\(previousValueToWaitFor)) — blocking")
            while !endFrameEvent.wait(untilSignaledValue: UInt64(previousValueToWaitFor), timeoutMS: 1000) {
                print("[FloodSurfer] WARN: still waiting for GPU frame \(previousValueToWaitFor)")
            }
        }

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        hdrPipeline.setActiveSlot(0)
        shadowMap.setActiveSlot(0)

        let commandAllocator = commandAllocators[uniformBufferIndex]
        commandAllocator.reset()
        // Reuse the single MTL4CommandBuffer; allocator provides per-frame backing memory.
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)
        // beginCommandBuffer clears prior residency — re-attach every frame.
        commandBuffer.useResidencySet(residencySet)
        commandBuffer.useResidencySet((view.layer as! CAMetalLayer).residencySet)

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
        instanceStreamer.write(to: instanceUniformBuffer, frameSlot: uniformBufferIndex)
        if draws.count > maxObjectsPerFrame {
            print("[FloodSurfer] WARN object count \(draws.count) > maxObjectsPerFrame \(maxObjectsPerFrame) — clamping (missing unique draws)")
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

        let totalDrawCalls = objectDrawCount + instanceStreamer.drawCallCount
        if lastLoggedDrawStats != totalDrawCalls {
            lastLoggedDrawStats = totalDrawCalls
            print("[FloodSurfer Draw] unique=\(objectDrawCount) instancedBatches=\(instanceStreamer.drawCallCount) instances=\(instanceStreamer.instanceTotal) totalDrawCalls=\(totalDrawCalls) (pre-instance coin+road+wake ~+\(instanceStreamer.instanceTotal - instanceStreamer.drawCallCount) saved)")
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
            encodeInstancedBatches(encoder: shadowEncoder, shadowPass: true)
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
        encodeInstancedBatches(encoder: renderEncoder, shadowPass: false)
        renderEncoder.endEncoding()

        // Bloom optional — off until green-block glitches are gone on device.
        if enableBloomChain {
            encodeBloomChain(time: state.time)
        }

        // --- Composite into drawable (ACES + grade + grain) ---
        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create composite encoder")
        }
        var post = PostFXUniforms()
        HDRPipeline.fillPostFX(&post, time: state.time, blurDirection: .zero, texelSize: .zero)
        if !enableBloomChain {
            post.bloomIntensity = 0
        }
        postFXUniformsPointer().pointee = post
        fragmentArgumentTable.setAddress(postFXUniformsGPUAddress(), index: BufferIndex.postFXUniforms.rawValue)
        fragmentArgumentTable.setTexture(hdrPipeline.sceneColor.gpuResourceID, index: TextureIndex.albedo.rawValue)
        let bloomTex = enableBloomChain ? hdrPipeline.bloomMips[0] : blackBloomTexture!
        fragmentArgumentTable.setTexture(bloomTex.gpuResourceID, index: TextureIndex.normal.rawValue)
        encodeFullscreen(compositeEncoder, pipeline: compositePipeline, label: "Composite")
        compositeEncoder.endEncoding()

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
