//
//  MeshFactory.swift
//  city of surf
//

import MetalKit
import ModelIO
import simd

enum MeshFactoryError: Error {
    case badVertexDescriptor
}

enum MeshFactory {
    static func applyVertexDescriptor(_ mtlVertexDescriptor: MTLVertexDescriptor, to mdlMesh: MDLMesh) throws {
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)
        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw MeshFactoryError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        mdlMesh.vertexDescriptor = mdlVertexDescriptor
    }

    static func makeBox(
        device: MTLDevice,
        dimensions: SIMD3<Float>,
        segments: SIMD3<UInt32> = SIMD3(1, 1, 1),
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newBox(
            withDimensions: dimensions,
            segments: segments,
            geometryType: .triangles,
            inwardNormals: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    /// XZ plane, Y up — suitable for Gerstner displacement.
    static func makePlane(
        device: MTLDevice,
        width: Float,
        depth: Float,
        segmentsX: UInt32,
        segmentsZ: UInt32,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newPlane(
            withDimensions: SIMD2(width, depth),
            segments: SIMD2(segmentsX, segmentsZ),
            geometryType: .triangles,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    static func makeCylinder(
        device: MTLDevice,
        height: Float,
        radii: SIMD2<Float>,
        radialSegments: UInt32 = 20,
        verticalSegments: UInt32 = 1,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newCylinder(
            withHeight: height,
            radii: radii,
            radialSegments: radialSegments,
            verticalSegments: verticalSegments,
            geometryType: .triangles,
            inwardNormals: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    static func makeSphere(
        device: MTLDevice,
        radii: SIMD3<Float>,
        radialSegments: UInt32 = 12,
        verticalSegments: UInt32 = 12,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newEllipsoid(
            withRadii: radii,
            radialSegments: radialSegments,
            verticalSegments: verticalSegments,
            geometryType: .triangles,
            inwardNormals: false,
            hemisphere: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    /// Coin: short cylinder with a slightly larger rim radius for a bevelled read.
    static func makeCoin(
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        try makeCylinder(
            device: device,
            height: 0.12,
            radii: SIMD2(0.55, 0.48),
            radialSegments: 24,
            verticalSegments: 2,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Flat oval board approximated by a flattened ellipsoid.
    static func makeBoard(
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        try makeSphere(
            device: device,
            radii: SIMD3(0.42, 0.06, 1.15),
            radialSegments: 16,
            verticalSegments: 10,
            vertexDescriptor: vertexDescriptor
        )
    }
}

/// Readable graybox surfer assembled from a few primitives.
struct ProceduralSurferMeshes {
    let torso: MTKMesh
    let head: MTKMesh
    let limb: MTKMesh

    static func make(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> ProceduralSurferMeshes {
        ProceduralSurferMeshes(
            torso: try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(0.42, 0.7, 0.28),
                vertexDescriptor: vertexDescriptor
            ),
            head: try MeshFactory.makeSphere(
                device: device,
                radii: SIMD3(0.18, 0.2, 0.18),
                radialSegments: 10,
                verticalSegments: 8,
                vertexDescriptor: vertexDescriptor
            ),
            limb: try MeshFactory.makeBox(
                device: device,
                dimensions: SIMD3(0.14, 0.55, 0.14),
                vertexDescriptor: vertexDescriptor
            )
        )
    }

    func appendDrawItems(
        to items: inout [DrawItem],
        position: SIMD3<Float>,
        height: Float,
        lean: Float,
        color: SIMD4<Float>
    ) {
        let leanRot = Math.rotation(radians: lean * 0.35, axis: SIMD3(0, 0, 1))
        let scaleY = height / 1.55
        let base = Math.translation(position) * leanRot * Math.scale(SIMD3(1, scaleY, 1))

        items.append(DrawItem(
            mesh: torso,
            modelMatrix: base * Math.translation(SIMD3(0, 0.15, 0)),
            color: color,
            isWave: false,
            materialId: 3
        ))
        items.append(DrawItem(
            mesh: head,
            modelMatrix: base * Math.translation(SIMD3(0, 0.72, 0)),
            color: SIMD4(0.95, 0.78, 0.62, 1),
            isWave: false,
            materialId: 3
        ))
        items.append(DrawItem(
            mesh: limb,
            modelMatrix: base * Math.translation(SIMD3(-0.32, 0.05, 0)) * Math.rotation(radians: 0.2, axis: SIMD3(0, 0, 1)),
            color: color,
            isWave: false,
            materialId: 3
        ))
        items.append(DrawItem(
            mesh: limb,
            modelMatrix: base * Math.translation(SIMD3(0.32, 0.05, 0)) * Math.rotation(radians: -0.2, axis: SIMD3(0, 0, 1)),
            color: color,
            isWave: false,
            materialId: 3
        ))
        items.append(DrawItem(
            mesh: limb,
            modelMatrix: base * Math.translation(SIMD3(-0.12, -0.55, 0)),
            color: SIMD4(0.12, 0.14, 0.22, 1),
            isWave: false,
            materialId: 3
        ))
        items.append(DrawItem(
            mesh: limb,
            modelMatrix: base * Math.translation(SIMD3(0.12, -0.55, 0)),
            color: SIMD4(0.12, 0.14, 0.22, 1),
            isWave: false,
            materialId: 3
        ))
    }
}
