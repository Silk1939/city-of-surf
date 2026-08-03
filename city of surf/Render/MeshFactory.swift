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

    /// Capsule along Y — limbs / torso segments (no naked boxes).
    static func makeCapsule(
        device: MTLDevice,
        height: Float,
        radius: Float,
        radialSegments: UInt32 = 12,
        verticalSegments: UInt32 = 1,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newCapsule(
            withHeight: height,
            radii: SIMD2(radius, radius),
            radialSegments: Int(radialSegments),
            verticalSegments: Int(verticalSegments),
            hemisphereSegments: 6,
            geometryType: .triangles,
            inwardNormals: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    /// Sphere — head, hands, joint accents.
    static func makeSphere(
        device: MTLDevice,
        radii: SIMD3<Float>,
        radialSegments: UInt32 = 14,
        verticalSegments: UInt32 = 10,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdl = MDLMesh.newEllipsoid(
            withRadii: radii,
            radialSegments: Int(radialSegments),
            verticalSegments: Int(verticalSegments),
            geometryType: .triangles,
            inwardNormals: false,
            hemisphere: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: mdl)
        return try MTKMesh(mesh: mdl, device: device)
    }

    /// Slightly softened box via ellipsoid — feet / pelvis blocks without hard cubes.
    static func makeRoundedBox(
        device: MTLDevice,
        dimensions: SIMD3<Float>,
        segments: UInt32 = 8,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        // Ellipsoid approximates a chunky rounded block at game scale.
        return try makeSphere(
            device: device,
            radii: dimensions * 0.5,
            radialSegments: max(8, segments),
            verticalSegments: max(6, segments - 2),
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Beveled massing block — higher segment box reads softer than a unit cube.
    static func makeBeveledBox(
        device: MTLDevice,
        dimensions: SIMD3<Float>,
        segments: SIMD3<UInt32> = SIMD3(2, 2, 2),
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        try makeBox(
            device: device,
            dimensions: dimensions,
            segments: segments,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Wedge / roof cap — low-poly ellipsoid diamond reads as a chunky pitched mass.
    static func makeWedge(
        device: MTLDevice,
        dimensions: SIMD3<Float>,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let cone = MDLMesh.newEllipsoid(
            withRadii: SIMD3(dimensions.x * 0.5, dimensions.y * 0.5, dimensions.z * 0.5),
            radialSegments: 4,
            verticalSegments: 2,
            geometryType: .triangles,
            inwardNormals: false,
            hemisphere: false,
            allocator: allocator
        )
        try applyVertexDescriptor(vertexDescriptor, to: cone)
        return try MTKMesh(mesh: cone, device: device)
    }

    /// Thin plate for awnings / window bands / signs.
    static func makeFrame(
        device: MTLDevice,
        size: SIMD2<Float>,
        thickness: Float,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        try makeBox(
            device: device,
            dimensions: SIMD3(size.x, size.y, thickness),
            segments: SIMD3(1, 1, 1),
            vertexDescriptor: vertexDescriptor
        )
    }
}
