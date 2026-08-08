//
//  SurfboardVisual.swift
//  city of surf
//
//  Procedural surfboard — visual only. SurferController collision proxy unchanged.
//

import MetalKit
import simd

struct SurfboardMeshes {
    let hull: MTKMesh
    let nose: MTKMesh
    let fin: MTKMesh
    let rail: MTKMesh

    static func make(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> SurfboardMeshes {
        // Hull along Y, then rotated to +Z in the draw path.
        let hull = try MeshFactory.makeCapsule(
            device: device,
            height: 1.0,
            radius: 0.5,
            radialSegments: 16,
            verticalSegments: 2,
            vertexDescriptor: vertexDescriptor
        )
        let nose = try MeshFactory.makeSphere(
            device: device,
            radii: SIMD3(0.5, 0.5, 0.55),
            radialSegments: 14,
            verticalSegments: 10,
            vertexDescriptor: vertexDescriptor
        )
        let fin = try MeshFactory.makeCapsule(
            device: device,
            height: 1.0,
            radius: 0.5,
            radialSegments: 8,
            verticalSegments: 1,
            vertexDescriptor: vertexDescriptor
        )
        let rail = try MeshFactory.makeCapsule(
            device: device,
            height: 1.0,
            radius: 0.5,
            radialSegments: 10,
            verticalSegments: 1,
            vertexDescriptor: vertexDescriptor
        )
        return SurfboardMeshes(hull: hull, nose: nose, fin: fin, rail: rail)
    }

    var allMeshes: [MTKMesh] { [hull, nose, fin, rail] }
}

enum SurfboardVisual {
    /// Build board draws under the surfer. Pitch/roll follow water + carve / jump.
    static func appendDrawItems(
        to items: inout [DrawItem],
        meshes: SurfboardMeshes,
        surfer: SurferController,
        poseWeights: (lean: Float, jumpT: Float, isDuck: Bool, isWipeout: Bool)
    ) {
        let sp = surfer.position
        let sh = surfer.currentHeight
        let boardY = sp.y - sh * 0.5 + 0.06

        let lean = poseWeights.lean
        let jumpT = poseWeights.jumpT
        // Water-aligned base + pose accents.
        var roll = surfer.surfaceRoll
        var pitch = surfer.surfacePitch + 0.03
        if surfer.pose == .jumping {
            if jumpT < 0.12 {
                pitch += 0.16 // anticipate: nose up slightly
                roll *= 0.6
            } else if jumpT > 0.82 {
                pitch += -0.18 // landing: slap flat
            } else {
                pitch += -0.06 + sin(jumpT * .pi) * 0.10
                roll *= 0.45
            }
        } else if poseWeights.isDuck {
            pitch += 0.10
            roll *= 0.75
        } else if poseWeights.isWipeout {
            pitch = 0.55
            roll = lean * 0.2 + 0.8
        }

        let root = Math.translation(SIMD3(sp.x, boardY, sp.z))
            * Math.rotation(radians: roll, axis: SIMD3(0, 0, 1))
            * Math.rotation(radians: pitch, axis: SIMD3(1, 0, 0))

        // Lay capsule (Y) along board length (+Z): rotate X by 90°.
        let alongZ = Math.rotation(radians: .pi * 0.5, axis: SIMD3(1, 0, 0))

        let deckDark = SIMD4<Float>(0.07, 0.08, 0.10, 1)
        let deckWet = SIMD4<Float>(0.12, 0.14, 0.18, 1)
        let neon = SIMD4<Float>(ArtDirection.neonCyan.x, ArtDirection.neonCyan.y, ArtDirection.neonCyan.z, 1)
        let finColor = SIMD4<Float>(0.95, 0.55, 0.12, 1)

        func add(_ mesh: MTKMesh, _ local: matrix_float4x4, _ color: SIMD4<Float>, material: Float, cast: Bool = true) {
            items.append(DrawItem(
                mesh: mesh,
                modelMatrix: root * local,
                color: color,
                isWave: false,
                materialId: material,
                castsShadow: cast,
                receivesShadow: true
            ))
        }

        // Main hull — wider mid, visible thickness (material 7 = wet gloss).
        add(
            meshes.hull,
            alongZ * Math.scale(SIMD3(0.72, 2.05, 0.11)),
            deckWet,
            material: 7
        )
        // Narrower tail block (behind).
        add(
            meshes.hull,
            Math.translation(SIMD3(0, 0, -0.85)) * alongZ * Math.scale(SIMD3(0.48, 0.55, 0.09)),
            deckDark,
            material: 7
        )
        // Rounded nose.
        add(
            meshes.nose,
            Math.translation(SIMD3(0, 0.01, 1.05)) * Math.scale(SIMD3(0.55, 0.09, 0.42)),
            deckWet,
            material: 7
        )
        // Soft rails along sides.
        add(
            meshes.rail,
            Math.translation(SIMD3(-0.28, 0.02, 0.05)) * alongZ * Math.scale(SIMD3(0.12, 1.7, 0.08)),
            deckDark,
            material: 7,
            cast: false
        )
        add(
            meshes.rail,
            Math.translation(SIMD3(0.28, 0.02, 0.05)) * alongZ * Math.scale(SIMD3(0.12, 1.7, 0.08)),
            deckDark,
            material: 7,
            cast: false
        )

        // Neon deck pattern — center stripe + chevron tips (emissive via material 3).
        add(
            meshes.rail,
            Math.translation(SIMD3(0, 0.08, 0.05)) * alongZ * Math.scale(SIMD3(0.14, 1.55, 0.04)),
            neon,
            material: 3,
            cast: false
        )
        add(
            meshes.rail,
            Math.translation(SIMD3(0, 0.085, 0.55)) * Math.rotation(radians: 0.55, axis: SIMD3(0, 1, 0)) * alongZ * Math.scale(SIMD3(0.1, 0.45, 0.035)),
            neon,
            material: 3,
            cast: false
        )
        add(
            meshes.rail,
            Math.translation(SIMD3(0, 0.085, 0.55)) * Math.rotation(radians: -0.55, axis: SIMD3(0, 1, 0)) * alongZ * Math.scale(SIMD3(0.1, 0.45, 0.035)),
            neon,
            material: 3,
            cast: false
        )

        // Three fins under the tail.
        let finBaseZ: Float = -0.95
        let finTilt = Math.rotation(radians: 0.35, axis: SIMD3(1, 0, 0))
        add(
            meshes.fin,
            Math.translation(SIMD3(0, -0.12, finBaseZ)) * finTilt * Math.scale(SIMD3(0.045, 0.28, 0.12)),
            finColor,
            material: 4
        )
        add(
            meshes.fin,
            Math.translation(SIMD3(-0.18, -0.1, finBaseZ + 0.05)) * Math.rotation(radians: 0.25, axis: SIMD3(0, 0, 1)) * finTilt * Math.scale(SIMD3(0.04, 0.22, 0.1)),
            finColor,
            material: 4
        )
        add(
            meshes.fin,
            Math.translation(SIMD3(0.18, -0.1, finBaseZ + 0.05)) * Math.rotation(radians: -0.25, axis: SIMD3(0, 0, 1)) * finTilt * Math.scale(SIMD3(0.04, 0.22, 0.1)),
            finColor,
            material: 4
        )
    }

    static func jumpPhase(_ surfer: SurferController) -> Float {
        guard surfer.pose == .jumping else { return 0 }
        return 1 - (surfer.poseTimer / SurferController.jumpDuration)
    }
}

