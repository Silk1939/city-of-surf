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
let maxObjectsPerFrame = 128

enum RenderTargetFormat {
    static let hdrScene: MTLPixelFormat = .rgba16Float
    static let display: MTLPixelFormat = .bgra8Unorm
    static let linearDepth: MTLPixelFormat = .r32Float
}

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
}

final class Renderer: NSObject, MTKViewDelegate {

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
    var postPipeline: MTLRenderPipelineState
    var bloomExtractPipeline: MTLRenderPipelineState
    var bloomBlurHPipeline: MTLRenderPipelineState
    var bloomBlurVPipeline: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var sceneColorTexture: MTLTexture?
    var sceneDepthTexture: MTLTexture?
    var bloomTexture: MTLTexture?
    var bloomTempTexture: MTLTexture?

    var uniformBufferIndex = 0
    var objectDrawCount = 0

    var camera = ChaseCamera()
    var aspect: Float = 1

    let unitBox: MTKMesh
    let waveMesh: MTKMesh
    let surferMesh: MTKMesh

    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    @MainActor
    init?(metalKitView: MTKView, gameState: GameState) {
#if targetEnvironment(simulator)
        return nil
#else
        guard let device = metalKitView.device else { return nil }
        self.device = device
        self.gameState = gameState

        self.commandQueue = device.makeMTL4CommandQueue()!
        self.commandBuffer = device.makeCommandBuffer()!
        self.commandAllocators = (0...maxBuffersInFlight).map { _ in device.makeCommandAllocator()! }

        let argTableDesc = MTL4ArgumentTableDescriptor()
        argTableDesc.maxBufferBindCount = 4
        self.vertexArgumentTable = try! device.makeArgumentTable(descriptor: argTableDesc)
        argTableDesc.maxTextureBindCount = 3
        self.fragmentArgumentTable = try! device.makeArgumentTable(descriptor: argTableDesc)

        self.endFrameEvent = device.makeSharedEvent()!
        frameIndex = maxBuffersInFlight
        self.endFrameEvent.signaledValue = UInt64(frameIndex - 1)

        let frameSize = alignedSize(MemoryLayout<FrameUniforms>.size) * maxBuffersInFlight
        let objectSize = alignedSize(MemoryLayout<ObjectUniforms>.size) * maxObjectsPerFrame * maxBuffersInFlight
        guard let fb = device.makeBuffer(length: frameSize, options: .storageModeShared),
              let ob = device.makeBuffer(length: objectSize, options: .storageModeShared) else {
            return nil
        }
        frameUniformBuffer = fb
        frameUniformBuffer.label = "FrameUniforms"
        objectUniformBuffer = ob
        objectUniformBuffer.label = "ObjectUniforms"

        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = RenderTargetFormat.display
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(
            red: Double(ArtDirection.fogColor.x),
            green: Double(ArtDirection.fogColor.y),
            blue: Double(ArtDirection.fogColor.z),
            alpha: 1
        )

        let vd = Self.buildMetalVertexDescriptor()

        do {
            solidPipeline = try Self.buildPipeline(
                device: device,
                sampleCount: metalKitView.sampleCount,
                colorPixelFormats: [RenderTargetFormat.hdrScene, RenderTargetFormat.linearDepth],
                vertexDescriptor: vd,
                vertex: "solidVertex",
                fragment: "solidFragment",
                label: "Solid"
            )
            wavePipeline = try Self.buildPipeline(
                device: device,
                sampleCount: metalKitView.sampleCount,
                colorPixelFormats: [RenderTargetFormat.hdrScene],
                vertexDescriptor: vd,
                vertex: "waveVertex",
                fragment: "waveFragment",
                label: "Wave"
            )
            postPipeline = try Self.buildPipeline(
                device: device,
                sampleCount: metalKitView.sampleCount,
                colorPixelFormats: [RenderTargetFormat.display],
                vertexDescriptor: nil,
                vertex: "fullscreenVertex",
                fragment: "tonemapFragment",
                label: "ACES Tonemap"
            )
            bloomExtractPipeline = try Self.buildPipeline(
                device: device,
                sampleCount: 1,
                colorPixelFormats: [RenderTargetFormat.hdrScene],
                vertexDescriptor: nil,
                vertex: "fullscreenVertex",
                fragment: "bloomExtractFragment",
                label: "Bloom Extract"
            )
            bloomBlurPipeline = try Self.buildPipeline(
                device: device,
                sampleCount: 1,
                colorPixelFormats: [RenderTargetFormat.hdrScene],
                vertexDescriptor: nil,
                vertex: "fullscreenVertex",
                fragment: "bloomBlurFragment",
                label: "Bloom Blur"
            )
        } catch {
            print("Pipeline error: \(error)")
            return nil
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else { return nil }
        depthState = ds

        do {
            unitBox = try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(1, 1, 1),
                vertexDescriptor: vd
            )
            // Dense mesh: flood body behind + long face ahead of crest.
            waveMesh = try MeshFactory.makePlane(
                device: device,
                width: 30,
                depth: 140,
                segmentsX: 64,
                segmentsZ: 180,
                vertexDescriptor: vd
            )
            surferMesh = try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(0.55, 1.45, 0.4),
                vertexDescriptor: vd
            )
        } catch {
            print("Mesh error: \(error)")
            return nil
        }

        let residencyDesc = MTLResidencySetDescriptor()
        residencyDesc.initialCapacity = 64
        let rs = try! device.makeResidencySet(descriptor: residencyDesc)
        rs.addAllocations([frameUniformBuffer, objectUniformBuffer])
        for mesh in [unitBox, waveMesh, surferMesh] {
            rs.addAllocations(mesh.vertexBuffers.map(\.buffer))
            rs.addAllocations(mesh.submeshes.map(\.indexBuffer.buffer))
        }
        rs.commit()
        commandQueue.addResidencySet(rs)
        residencySet = rs

        super.init()
        gameState.reset()
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
    @MainActor
    class func buildPipeline(
        device: MTLDevice,
        sampleCount: Int,
        colorPixelFormats: [MTLPixelFormat],
        vertexDescriptor: MTLVertexDescriptor?,
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
        for (index, format) in colorPixelFormats.enumerated() {
            pipelineDescriptor.colorAttachments[index].pixelFormat = format
        }

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
                materialId: 1
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
                    color: SIMD4(0.22, 0.22, 0.24, 1),
                    isWave: false,
                    materialId: 0
                ))
            }
        }

        // Buildings — denser canyon
        let buildingSpacing: Float = 14
        let base = -fmod(state.runDistance, buildingSpacing)
        for i in 0..<16 {
            let z = base + Float(i) * buildingSpacing - 8
            let hL = 12 + Float((i * 3) % 9) * 2.8
            let hR = 14 + Float((i * 5) % 8) * 3.1
            let wL = 7.5 + Float(i % 3) * 0.8
            let wR = 7.0 + Float((i + 1) % 3) * 0.9
            let left = Math.translation(SIMD3(-12.5, hL * 0.5, z)) * Math.scale(SIMD3(wL, hL, 11))
            let right = Math.translation(SIMD3(12.5, hR * 0.5, z)) * Math.scale(SIMD3(wR, hR, 11))
            let tintL = SIMD4(0.28 + Float(i % 4) * 0.04, 0.30, 0.34, 1)
            let tintR = SIMD4(0.26, 0.29 + Float(i % 3) * 0.03, 0.36, 1)
            items.append(DrawItem(mesh: unitBox, modelMatrix: left, color: tintL, isWave: false, materialId: 2))
            items.append(DrawItem(mesh: unitBox, modelMatrix: right, color: tintR, isWave: false, materialId: 2))
        }

        // One flood plane: crest near z=0, body behind (-), face ahead (+)
        let waveModel = Math.translation(SIMD3(0, 0, 25))
        items.append(DrawItem(
            mesh: waveMesh,
            modelMatrix: waveModel,
            color: SIMD4(0.1, 0.55, 0.65, 1),
            isWave: true,
            materialId: 0
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
            color: SIMD4(0.95, 0.42, 0.18, 1),
            isWave: false,
            materialId: 3
        ))
        let boardY = sp.y - sh * 0.5 + 0.08
        let board = Math.translation(SIMD3(sp.x, boardY, sp.z))
            * leanRot
            * Math.scale(SIMD3(0.85, 0.1, 2.4))
        items.append(DrawItem(
            mesh: unitBox,
            modelMatrix: board,
            color: SIMD4(0.15, 0.12, 0.08, 1),
            isWave: false,
            materialId: 3
        ))

        // Obstacles (cabs / debris)
        for o in state.obstacles.obstacles where o.active {
            let pos = state.obstacles.worldPosition(
                for: o,
                runDistance: state.runDistance,
                wave: state.wave,
                time: state.time,
                scrollZ: state.scrollZ
            )
            let rot = Math.rotation(radians: o.roll * 0.35, axis: SIMD3(0, 0, 1))
            let model = Math.translation(pos) * rot * Math.scale(o.size)
            items.append(DrawItem(
                mesh: unitBox,
                modelMatrix: model,
                color: SIMD4(0.95, 0.78, 0.12, 1),
                isWave: false,
                materialId: 4
            ))
        }

        return items
    }

    func draw(in view: MTKView) {
#if !targetEnvironment(simulator)
        guard let state = gameState else { return }
        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentMTL4RenderPassDescriptor else { return }
        if sceneColorTexture?.width != Int(view.drawableSize.width)
            || sceneColorTexture?.height != Int(view.drawableSize.height) {
            rebuildSceneTargets(size: view.drawableSize)
        }
        guard let sceneColorTexture,
              let sceneDepthTexture,
              let bloomTexture,
              let bloomTempTexture else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 1.0 / 20.0))
        lastTime = now

        state.update(deltaTime: dt)
        let boardPosition = state.surfer.position
            - SIMD3<Float>(0, state.surfer.currentHeight * 0.5, 0)
        camera.update(
            follow: boardPosition,
            steering: state.surfer.lean,
            speed: state.speed,
            deltaTime: dt
        )

        let previousValueToWaitFor = frameIndex - maxBuffersInFlight
        endFrameEvent.wait(untilSignaledValue: UInt64(previousValueToWaitFor), timeoutMS: 10)

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        let commandAllocator = commandAllocators[uniformBufferIndex]
        commandAllocator.reset()
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)

        let viewM = camera.viewMatrix()
        let projM = camera.projectionMatrix(aspect: aspect)
        var frame = FrameUniforms()
        state.fillFrameUniforms(
            &frame,
            viewProjection: projM * viewM,
            cameraPosition: camera.smoothEye,
            cameraNear: ChaseCameraTuning.nearZ,
            cameraFar: ChaseCameraTuning.farZ
        )
        frameUniformsPointer().pointee = frame

        let draws = buildDrawList(state: state)
        objectDrawCount = min(draws.count, maxObjectsPerFrame)
        for i in 0..<objectDrawCount {
            var obj = ObjectUniforms()
            obj.modelMatrix = draws[i].modelMatrix
            obj.color = draws[i].color
            obj.isWave = draws[i].isWave ? 1 : 0
            obj.materialId = draws[i].materialId
            objectUniformsPointer(slot: i).pointee = obj
        }

        guard let opaquePassDescriptor = renderPassDescriptor.copy() as? MTL4RenderPassDescriptor else {
            fatalError("Failed to copy render pass descriptor")
        }
        opaquePassDescriptor.colorAttachments[0].texture = sceneColorTexture
        opaquePassDescriptor.colorAttachments[0].loadAction = .clear
        opaquePassDescriptor.colorAttachments[0].storeAction = .store
        opaquePassDescriptor.colorAttachments[0].clearColor = view.clearColor
        opaquePassDescriptor.colorAttachments[1].texture = sceneDepthTexture
        opaquePassDescriptor.colorAttachments[1].loadAction = .clear
        opaquePassDescriptor.colorAttachments[1].storeAction = .store
        opaquePassDescriptor.colorAttachments[1].clearColor = MTLClearColor(red: Double(ChaseCameraTuning.farZ), green: 0, blue: 0, alpha: 1)

        guard let opaqueEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: opaquePassDescriptor) else {
            fatalError("Failed to create opaque encoder")
        }

        opaqueEncoder.label = "FloodSurfer Opaque"
        opaqueEncoder.setCullMode(.back)
        opaqueEncoder.setFrontFacing(.counterClockwise)
        opaqueEncoder.setDepthStencilState(depthState)
        opaqueEncoder.setArgumentTable(vertexArgumentTable, stages: .vertex)
        opaqueEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
        opaqueEncoder.setRenderPipelineState(solidPipeline)

        vertexArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)
        fragmentArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)

        func drawItem(_ item: DrawItem, slot: Int, encoder: MTL4RenderCommandEncoder) {
            let objAddr = objectUniformsGPUAddress(slot: slot)
            vertexArgumentTable.setAddress(objAddr, index: BufferIndex.objectUniforms.rawValue)
            fragmentArgumentTable.setAddress(objAddr, index: BufferIndex.objectUniforms.rawValue)

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

        for i in 0..<objectDrawCount where !draws[i].isWave {
            drawItem(draws[i], slot: i, encoder: opaqueEncoder)
        }
        opaqueEncoder.endEncoding()

        guard let wavePassDescriptor = renderPassDescriptor.copy() as? MTL4RenderPassDescriptor else {
            fatalError("Failed to copy wave pass descriptor")
        }
        wavePassDescriptor.colorAttachments[0].texture = sceneColorTexture
        wavePassDescriptor.colorAttachments[0].loadAction = .load
        wavePassDescriptor.colorAttachments[0].storeAction = .store
        wavePassDescriptor.colorAttachments[1].texture = nil
        wavePassDescriptor.depthAttachment.loadAction = .load
        wavePassDescriptor.depthAttachment.storeAction = .dontCare
        wavePassDescriptor.stencilAttachment.loadAction = .dontCare
        wavePassDescriptor.stencilAttachment.storeAction = .dontCare

        guard let waveEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: wavePassDescriptor) else {
            fatalError("Failed to create wave encoder")
        }
        waveEncoder.label = "FloodSurfer Wave"
        waveEncoder.setCullMode(.none)
        waveEncoder.setFrontFacing(.counterClockwise)
        waveEncoder.setDepthStencilState(depthState)
        waveEncoder.setArgumentTable(vertexArgumentTable, stages: .vertex)
        waveEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
        waveEncoder.setRenderPipelineState(wavePipeline)
        vertexArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)
        fragmentArgumentTable.setAddress(frameUniformsGPUAddress(), index: BufferIndex.frameUniforms.rawValue)
        fragmentArgumentTable.setTexture(sceneDepthTexture.gpuResourceID, index: TextureIndex.depth.rawValue)

        for i in 0..<objectDrawCount where draws[i].isWave {
            drawItem(draws[i], slot: i, encoder: waveEncoder)
        }
        waveEncoder.endEncoding()

        func encodeFullscreen(
            label: String,
            pipeline: MTLRenderPipelineState,
            destination: MTLTexture,
            source: MTLTexture,
            blurDirection: SIMD2<Float>
        ) {
            let pass = MTL4RenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                fatalError("Failed to create \(label) encoder")
            }
            encoder.label = label
            encoder.setCullMode(.none)
            encoder.setRenderPipelineState(pipeline)
            encoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)

            var postFrame = frameUniformsPointer().pointee
            postFrame.bloomBlurDirection = blurDirection
            frameUniformsPointer().pointee = postFrame

            fragmentArgumentTable.setAddress(
                frameUniformsGPUAddress(),
                index: BufferIndex.frameUniforms.rawValue
            )
            fragmentArgumentTable.setTexture(source.gpuResourceID, index: TextureIndex.color.rawValue)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        encodeFullscreen(
            label: "Bloom Extract",
            pipeline: bloomExtractPipeline,
            destination: bloomTempTexture,
            source: sceneColorTexture,
            blurDirection: .zero
        )
        encodeFullscreen(
            label: "Bloom Blur H",
            pipeline: bloomBlurPipeline,
            destination: bloomTexture,
            source: bloomTempTexture,
            blurDirection: SIMD2(1, 0)
        )
        encodeFullscreen(
            label: "Bloom Blur V",
            pipeline: bloomBlurPipeline,
            destination: bloomTempTexture,
            source: bloomTexture,
            blurDirection: SIMD2(0, 1)
        )

        guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create post-process encoder")
        }
        postEncoder.label = "FloodSurfer ACES Tonemap"
        postEncoder.setCullMode(.none)
        postEncoder.setRenderPipelineState(postPipeline)
        postEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)
        fragmentArgumentTable.setAddress(
            frameUniformsGPUAddress(),
            index: BufferIndex.frameUniforms.rawValue
        )
        fragmentArgumentTable.setTexture(
            sceneColorTexture.gpuResourceID,
            index: TextureIndex.color.rawValue
        )
        fragmentArgumentTable.setTexture(
            bloomTempTexture.gpuResourceID,
            index: TextureIndex.bloom.rawValue
        )
        postEncoder.drawPrimitives(
            primitiveType: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        postEncoder.endEncoding()

        commandBuffer.useResidencySet((view.layer as! CAMetalLayer).residencySet)
        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        drawable.present()
#endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
#if !targetEnvironment(simulator)
        rebuildSceneTargets(size: size)
#endif
    }

#if !targetEnvironment(simulator)
    private func rebuildSceneTargets(size: CGSize) {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let bloomWidth = max(width / 2, 1)
        let bloomHeight = max(height / 2, 1)
        if sceneColorTexture?.width == width,
           sceneColorTexture?.height == height,
           sceneDepthTexture?.width == width,
           sceneDepthTexture?.height == height,
           bloomTexture?.width == bloomWidth,
           bloomTexture?.height == bloomHeight {
            return
        }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTargetFormat.hdrScene,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.storageMode = .private
        colorDesc.usage = [.renderTarget, .shaderRead]

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTargetFormat.linearDepth,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.storageMode = .private
        depthDesc.usage = [.renderTarget, .shaderRead]

        let bloomDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTargetFormat.hdrScene,
            width: bloomWidth,
            height: bloomHeight,
            mipmapped: false
        )
        bloomDesc.storageMode = .private
        bloomDesc.usage = [.renderTarget, .shaderRead]

        guard let newColor = device.makeTexture(descriptor: colorDesc),
              let newDepth = device.makeTexture(descriptor: depthDesc),
              let newBloom = device.makeTexture(descriptor: bloomDesc),
              let newBloomTemp = device.makeTexture(descriptor: bloomDesc) else {
            sceneColorTexture = nil
            sceneDepthTexture = nil
            bloomTexture = nil
            bloomTempTexture = nil
            return
        }
        newColor.label = "HDR Scene Color"
        newDepth.label = "Opaque Linear Depth"
        newBloom.label = "Bloom A"
        newBloomTemp.label = "Bloom B"

        for old in [sceneColorTexture, sceneDepthTexture, bloomTexture, bloomTempTexture].compactMap({ $0 }) {
            residencySet.removeAllocation(old)
        }
        residencySet.addAllocations([newColor, newDepth, newBloom, newBloomTemp])
        residencySet.commit()
        sceneColorTexture = newColor
        sceneDepthTexture = newDepth
        bloomTexture = newBloom
        bloomTempTexture = newBloomTemp
    }
#endif
}

func alignedSize(_ size: Int) -> Int {
    (size + 0xFF) & ~0xFF
}
