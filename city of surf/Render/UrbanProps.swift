//
//  UrbanProps.swift
//  city of surf
//
//  Readable gameplay silhouettes for palms, vehicles, barriers, lights, signs.
//  Collision sizes stay in ObstacleSystem — visuals only here.
//

import MetalKit
import simd

struct UrbanPropMeshes {
    let capsule: MTKMesh
    let sphere: MTKMesh
    let cylinder: MTKMesh
    let plate: MTKMesh
    let wedge: MTKMesh
    let unitBox: MTKMesh

    static func make(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor, unitBox: MTKMesh) throws -> UrbanPropMeshes {
        let capsule = try MeshFactory.makeCapsule(
            device: device, height: 1, radius: 0.5, radialSegments: 10, verticalSegments: 1, vertexDescriptor: vertexDescriptor
        )
        let sphere = try MeshFactory.makeSphere(
            device: device, radii: SIMD3(0.5, 0.5, 0.5), radialSegments: 12, verticalSegments: 8, vertexDescriptor: vertexDescriptor
        )
        let cylinder = try MeshFactory.makeCylinder(
            device: device, height: 1, radius: 0.5, radialSegments: 12, verticalSegments: 1, vertexDescriptor: vertexDescriptor
        )
        let plate = try MeshFactory.makeFrame(
            device: device, size: SIMD2(1, 1), thickness: 1, vertexDescriptor: vertexDescriptor
        )
        let wedge = try MeshFactory.makeWedge(
            device: device, dimensions: SIMD3(1, 1, 1), vertexDescriptor: vertexDescriptor
        )
        return UrbanPropMeshes(
            capsule: capsule, sphere: sphere, cylinder: cylinder, plate: plate, wedge: wedge, unitBox: unitBox
        )
    }

    var allMeshes: [MTKMesh] { [capsule, sphere, cylinder, plate, wedge] }
}

enum UrbanProps {
    static func appendPalm(
        items: inout [DrawItem],
        meshes: UrbanPropMeshes,
        at position: SIMD3<Float>,
        scale: Float = 1
    ) {
        let trunkColor = SIMD4<Float>(0.42, 0.26, 0.14, 1)
        let frondColor = SIMD4<Float>(0.12, 0.55, 0.22, 1)
        let s = scale

        func add(_ mesh: MTKMesh, _ m: matrix_float4x4, _ c: SIMD4<Float>) {
            items.append(DrawItem(
                mesh: mesh, modelMatrix: m, color: c, isWave: false,
                materialId: 4, castsShadow: true, receivesShadow: true
            ))
        }

        // Slightly bent trunk (capsule stack).
        add(
            meshes.capsule,
            Math.translation(position + SIMD3(0, 2.8 * s, 0)) * Math.scale(SIMD3(0.28 * s, 5.6 * s, 0.28 * s)),
            trunkColor
        )
        add(
            meshes.sphere,
            Math.translation(position + SIMD3(0, 5.7 * s, 0)) * Math.scale(SIMD3(0.35 * s, 0.35 * s, 0.35 * s)),
            trunkColor
        )
        // Frond fan — clear leaf silhouettes, not a green cube.
        let frondCount = 6
        for i in 0..<frondCount {
            let a = Float(i) / Float(frondCount) * (.pi * 2)
            let tilt = Math.rotation(radians: 0.85, axis: SIMD3(1, 0, 0))
            let yaw = Math.rotation(radians: a, axis: SIMD3(0, 1, 0))
            add(
                meshes.plate,
                Math.translation(position + SIMD3(0, 5.9 * s, 0))
                    * yaw * tilt
                    * Math.translation(SIMD3(0, 0, 1.1 * s))
                    * Math.scale(SIMD3(0.55 * s, 0.08 * s, 2.2 * s)),
                frondColor
            )
        }
    }

    static func appendBillboard(
        items: inout [DrawItem],
        meshes: UrbanPropMeshes,
        at position: SIMD3<Float>,
        panelColor: SIMD4<Float>
    ) {
        items.append(DrawItem(
            mesh: meshes.cylinder,
            modelMatrix: Math.translation(position + SIMD3(0, 4.0, 0)) * Math.scale(SIMD3(0.22, 8.0, 0.22)),
            color: SIMD4(0.18, 0.18, 0.2, 1),
            isWave: false, materialId: 4, castsShadow: true, receivesShadow: true
        ))
        items.append(DrawItem(
            mesh: meshes.plate,
            modelMatrix: Math.translation(position + SIMD3(0, 8.2, 0)) * Math.scale(SIMD3(0.18, 3.0, 5.2)),
            color: panelColor,
            isWave: false, materialId: 3, castsShadow: true, receivesShadow: false
        ))
    }

    static func appendWaterTank(
        items: inout [DrawItem],
        meshes: UrbanPropMeshes,
        at position: SIMD3<Float>
    ) {
        items.append(DrawItem(
            mesh: meshes.cylinder,
            modelMatrix: Math.translation(position) * Math.scale(SIMD3(1.5, 2.0, 1.5)),
            color: SIMD4(0.55, 0.52, 0.48, 1),
            isWave: false, materialId: 4, castsShadow: true, receivesShadow: true
        ))
        items.append(DrawItem(
            mesh: meshes.cylinder,
            modelMatrix: Math.translation(position + SIMD3(0, 1.15, 0)) * Math.scale(SIMD3(1.55, 0.25, 1.55)),
            color: SIMD4(0.35, 0.34, 0.32, 1),
            isWave: false, materialId: 4, castsShadow: true, receivesShadow: true
        ))
    }

    static func appendObstacle(
        items: inout [DrawItem],
        meshes: UrbanPropMeshes,
        kind: ObstacleKind,
        at pos: SIMD3<Float>,
        roll: matrix_float4x4,
        yaw: matrix_float4x4
    ) {
        let base = Math.translation(pos) * roll

        func add(_ mesh: MTKMesh, _ local: matrix_float4x4, _ color: SIMD4<Float>, material: Float, cast: Bool = true, receive: Bool = true) {
            items.append(DrawItem(
                mesh: mesh,
                modelMatrix: base * local,
                color: color,
                isWave: false,
                materialId: material,
                castsShadow: cast,
                receivesShadow: receive
            ))
        }

        switch kind {
        case .taxi, .police:
            let bodyColor: SIMD4<Float> = kind == .police
                ? SIMD4(0.12, 0.25, 0.75, 1)
                : SIMD4(0.95, 0.78, 0.1, 1)
            // Body
            add(meshes.unitBox, yaw * Math.scale(SIMD3(2.0, 1.05, 4.0)), bodyColor, material: 4)
            // Cabin
            add(meshes.unitBox, yaw * Math.translation(SIMD3(0, 0.85, -0.15)) * Math.scale(SIMD3(1.7, 0.85, 2.0)), SIMD4(0.12, 0.14, 0.18, 1), material: 4)
            // Hood taper hint
            add(meshes.wedge, yaw * Math.translation(SIMD3(0, 0.35, 1.35)) * Math.scale(SIMD3(1.8, 0.55, 1.1)), bodyColor, material: 4)
            // Wheels — readable direction
            let wheel = SIMD4<Float>(0.08, 0.08, 0.09, 1)
            for wx: Float in [-0.85, 0.85] {
                for wz: Float in [-1.2, 1.15] {
                    add(
                        meshes.cylinder,
                        yaw * Math.translation(SIMD3(wx, -0.35, wz))
                            * Math.rotation(radians: .pi * 0.5, axis: SIMD3(0, 0, 1))
                            * Math.scale(SIMD3(0.55, 0.28, 0.55)),
                        wheel,
                        material: 4
                    )
                }
            }
            if kind == .police {
                add(meshes.unitBox, yaw * Math.translation(SIMD3(0, 1.35, 0.05)) * Math.scale(SIMD3(1.1, 0.22, 0.7)), SIMD4(0.95, 0.15, 0.15, 1), material: 3)
                add(meshes.unitBox, yaw * Math.translation(SIMD3(0.35, 1.4, 0.05)) * Math.scale(SIMD3(0.35, 0.16, 0.4)), SIMD4(0.15, 0.45, 1.0, 1), material: 3, cast: false, receive: false)
            } else {
                add(meshes.unitBox, yaw * Math.translation(SIMD3(0, 1.3, 0.1)) * Math.scale(SIMD3(0.9, 0.22, 0.55)), SIMD4(0.12, 0.12, 0.12, 1), material: 4)
            }

        case .barrier:
            // Jump cue — bright orange + black stripe, low wide silhouette.
            add(meshes.unitBox, Math.scale(SIMD3(2.6, 0.95, 0.5)), SIMD4(0.95, 0.45, 0.05, 1), material: 4)
            add(meshes.unitBox, Math.translation(SIMD3(0, 0.2, 0)) * Math.scale(SIMD3(2.6, 0.22, 0.55)), SIMD4(0.08, 0.08, 0.08, 1), material: 4)
            add(meshes.unitBox, Math.translation(SIMD3(0, 0.55, 0)) * Math.scale(SIMD3(2.6, 0.18, 0.55)), SIMD4(0.08, 0.08, 0.08, 1), material: 4)
            // Feet
            add(meshes.unitBox, Math.translation(SIMD3(-1.0, -0.35, 0)) * Math.scale(SIMD3(0.35, 0.35, 0.55)), SIMD4(0.2, 0.2, 0.22, 1), material: 4)
            add(meshes.unitBox, Math.translation(SIMD3(1.0, -0.35, 0)) * Math.scale(SIMD3(0.35, 0.35, 0.55)), SIMD4(0.2, 0.2, 0.22, 1), material: 4)

        case .trafficLight:
            // Duck cue — tall pole + glowing head clearly above duck height.
            add(meshes.cylinder, Math.scale(SIMD3(0.26, 3.4, 0.26)), SIMD4(0.16, 0.16, 0.18, 1), material: 4)
            add(meshes.unitBox, Math.translation(SIMD3(0, 1.7, 0)) * Math.scale(SIMD3(0.75, 1.45, 0.55)), SIMD4(0.1, 0.1, 0.1, 1), material: 4)
            // Lamps — red dominant (duck), yellow, green
            add(meshes.sphere, Math.translation(SIMD3(0, 2.15, 0.28)) * Math.scale(SIMD3(0.28, 0.28, 0.18)), SIMD4(0.95, 0.12, 0.1, 1), material: 3, cast: false, receive: false)
            add(meshes.sphere, Math.translation(SIMD3(0, 1.75, 0.28)) * Math.scale(SIMD3(0.26, 0.26, 0.16)), SIMD4(0.95, 0.75, 0.12, 1), material: 3, cast: false, receive: false)
            add(meshes.sphere, Math.translation(SIMD3(0, 1.35, 0.28)) * Math.scale(SIMD3(0.26, 0.26, 0.16)), SIMD4(0.15, 0.9, 0.25, 1), material: 3, cast: false, receive: false)
            // Arm hint toward street
            add(meshes.unitBox, Math.translation(SIMD3(0.55, 1.9, 0)) * Math.scale(SIMD3(1.1, 0.12, 0.12)), SIMD4(0.16, 0.16, 0.18, 1), material: 4)
        }
    }
}
