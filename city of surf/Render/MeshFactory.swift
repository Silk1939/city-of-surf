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

    /// Thin cylinder (axis = Y) — upright coin disk spun around Y.
    static func makeCylinder(
        device: MTLDevice,
        height: Float,
        radius: Float,
        radialSegments: UInt32 = 24,
        verticalSegments: UInt32 = 1,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newCylinder(
            withHeight: height,
            radii: SIMD2(radius, radius),
            radialSegments: Int(radialSegments),
            verticalSegments: Int(verticalSegments),
            geometryType: .triangles,
            inwardNormals: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }
}
