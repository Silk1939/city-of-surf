//
//  InstanceStreamer.swift
//  city of surf
//
//  Ring-buffered instance ObjectUniforms — no per-frame allocations in the hot path.
//

import Metal
import MetalKit
import simd

let maxInstancesPerFrame = 512

struct InstancedDraw {
    var mesh: MTKMesh
    var firstInstance: Int
    var instanceCount: Int
    var materialId: Float
    var castsShadow: Bool
    var receivesShadow: Bool
}

private func makeEmptyObjectUniforms() -> ObjectUniforms {
    var obj = ObjectUniforms()
    obj.modelMatrix = matrix_identity_float4x4
    obj.color = SIMD4(1, 1, 1, 1)
    obj.isWave = 0
    obj.materialId = 0
    obj.castsShadow = 0
    obj.receivesShadow = 1
    return obj
}

/// CPU staging for one frame's instance stream (reused arrays).
final class InstanceStreamer {
    private var staging: [ObjectUniforms]
    private(set) var count: Int = 0
    private(set) var batches: [InstancedDraw] = []

    init() {
        staging = [ObjectUniforms](repeating: makeEmptyObjectUniforms(), count: maxInstancesPerFrame)
        batches.reserveCapacity(32)
    }

    func beginFrame() {
        count = 0
        batches.removeAll(keepingCapacity: true)
    }

    var nextIndex: Int { count }

    @discardableResult
    func append(
        modelMatrix: matrix_float4x4,
        color: SIMD4<Float>,
        materialId: Float,
        castsShadow: Bool,
        receivesShadow: Bool
    ) -> Bool {
        guard count < maxInstancesPerFrame else {
            print("[FloodSurfer] ASSERT instance count > maxInstancesPerFrame \(maxInstancesPerFrame) — dropping")
            return false
        }
        var obj = makeEmptyObjectUniforms()
        obj.modelMatrix = modelMatrix
        obj.color = color
        obj.materialId = materialId
        obj.castsShadow = castsShadow ? 1 : 0
        obj.receivesShadow = receivesShadow ? 1 : 0
        staging[count] = obj
        count += 1
        return true
    }

    func closeBatch(
        mesh: MTKMesh,
        start: Int,
        materialId: Float,
        castsShadow: Bool,
        receivesShadow: Bool
    ) {
        let n = count - start
        guard n > 0 else { return }
        batches.append(InstancedDraw(
            mesh: mesh,
            firstInstance: start,
            instanceCount: n,
            materialId: materialId,
            castsShadow: castsShadow,
            receivesShadow: receivesShadow
        ))
    }

    /// Tightly packed ObjectUniforms for [[instance_id]] fetches (not 256-byte aligned).
    func write(to buffer: MTLBuffer, frameSlot: Int) {
        let stride = MemoryLayout<ObjectUniforms>.stride
        let frameBase = stride * maxInstancesPerFrame * frameSlot
        guard count > 0 else { return }
        staging.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            let dest = buffer.contents().advanced(by: frameBase)
            dest.copyMemory(from: base, byteCount: stride * count)
        }
    }

    func gpuAddress(buffer: MTLBuffer, frameSlot: Int, firstInstance: Int) -> UInt64 {
        let stride = MemoryLayout<ObjectUniforms>.stride
        let frameBase = stride * maxInstancesPerFrame * frameSlot
        return buffer.gpuAddress + UInt64(frameBase + stride * firstInstance)
    }

    var drawCallCount: Int { batches.count }
    var instanceTotal: Int { count }
}
