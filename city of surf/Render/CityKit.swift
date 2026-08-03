//
//  CityKit.swift
//  city of surf
//
//  Modular procedural avenue buildings — deterministic seeds, large readable silhouettes.
//

import MetalKit
import simd

enum FacadeFamily: Int, CaseIterable {
    case brickWalkup      // stepped cornice, punched windows
    case glassTower       // vertical fins, selective glow band
    case terracottaBlock  // deep base, arched window band
    case neonHotel        // setback crown + sparse neon ledge
    case warehouseLoft    // wide low, loading canopy
    case cornerClock      // clock crown / spire accent
}

struct CityKitMeshes {
    let beveled: MTKMesh
    let rounded: MTKMesh
    let wedge: MTKMesh
    let cylinder: MTKMesh
    let plate: MTKMesh
    let unitBox: MTKMesh

    static func make(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor, unitBox: MTKMesh) throws -> CityKitMeshes {
        let beveled = try MeshFactory.makeBeveledBox(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            segments: SIMD3(2, 2, 2),
            vertexDescriptor: vertexDescriptor
        )
        let rounded = try MeshFactory.makeRoundedBox(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            segments: 8,
            vertexDescriptor: vertexDescriptor
        )
        let wedge = try MeshFactory.makeWedge(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            vertexDescriptor: vertexDescriptor
        )
        let cylinder = try MeshFactory.makeCylinder(
            device: device,
            height: 1,
            radius: 0.5,
            radialSegments: 12,
            verticalSegments: 1,
            vertexDescriptor: vertexDescriptor
        )
        let plate = try MeshFactory.makeFrame(
            device: device,
            size: SIMD2(1, 1),
            thickness: 1,
            vertexDescriptor: vertexDescriptor
        )
        return CityKitMeshes(
            beveled: beveled,
            rounded: rounded,
            wedge: wedge,
            cylinder: cylinder,
            plate: plate,
            unitBox: unitBox
        )
    }

    var allMeshes: [MTKMesh] { [beveled, rounded, wedge, cylinder, plate] }
}

enum CityKit {
    /// Deterministic 0…1 hash (same as prior buildingHash).
    static func hash(_ n: Int) -> Float {
        var x = UInt32(bitPattern: Int32(n)) &* 747796405
        x = (x ^ (x >> 16)) &* 2246822519
        return Float(x & 0xFFFF) / 65535.0
    }

    static func family(forIndex bi: Int) -> FacadeFamily {
        let families = FacadeFamily.allCases
        let idx = Int(hash(bi * 91 + 7) * Float(families.count)) % families.count
        return families[idx]
    }

    static func appendAvenue(
        items: inout [DrawItem],
        meshes: CityKitMeshes,
        runDistance: Float
    ) {
        // Interactive avenue (near) + mid canyon + far skyline.
        appendLayer(items: &items, meshes: meshes, runDistance: runDistance, layer: .avenue)
        appendLayer(items: &items, meshes: meshes, runDistance: runDistance, layer: .mid)
        appendLayer(items: &items, meshes: meshes, runDistance: runDistance, layer: .far)
    }

    private enum DepthLayer {
        case avenue, mid, far
    }

    private static func appendLayer(
        items: inout [DrawItem],
        meshes: CityKitMeshes,
        runDistance: Float,
        layer: DepthLayer
    ) {
        let (xSide, zStart, zEnd, maxCount, scaleY, detail): (Float, Float, Float, Int, Float, Bool)
        switch layer {
        case .avenue:
            (xSide, zStart, zEnd, maxCount, scaleY, detail) = (12.5, -20, 160, 14, 1.0, true)
        case .mid:
            (xSide, zStart, zEnd, maxCount, scaleY, detail) = (22.0, -10, 180, 10, 1.35, true)
        case .far:
            (xSide, zStart, zEnd, maxCount, scaleY, detail) = (36.0, 40, 220, 8, 1.8, false)
        }

        let seedBase: Int
        switch layer {
        case .avenue: seedBase = 0
        case .mid: seedBase = 1000
        case .far: seedBase = 2000
        }

        var zCursor = -fmod(runDistance * (layer == .far ? 0.55 : 1.0), 120) + zStart
        var bi = 0
        while zCursor < zEnd && bi < maxCount {
            let seed = seedBase + bi
            let fam = family(forIndex: seed)
            // Avoid identical families abutting on the same side.
            let famL = fam
            let famR = FacadeFamily.allCases[(fam.rawValue + 1 + Int(hash(seed * 3) * 4)) % FacadeFamily.allCases.count]

            let hL = (14 + hash(seed * 3) * 26) * scaleY
            let hR = (16 + hash(seed * 3 + 1) * 28) * scaleY
            let wL = 6.0 + hash(seed * 5) * 4.0
            let wR = 5.5 + hash(seed * 7 + 2) * 4.5
            let depthL = 7 + hash(seed * 11) * 12
            let depthR = 7 + hash(seed * 13 + 1) * 12
            let gapRoll = hash(seed * 17 + 3)
            let gap: Float
            if gapRoll < 0.35 {
                gap = 0.5
            } else if gapRoll < 0.7 {
                gap = 2.5 + hash(seed * 19) * 5.0
            } else {
                gap = 10 + hash(seed * 23) * 12
            }

            let zL = zCursor + depthL * 0.5
            let zR = zCursor + depthR * 0.5 + (hash(seed * 29) - 0.5) * 3.0

            appendBuilding(
                items: &items,
                meshes: meshes,
                family: famL,
                center: SIMD3(-xSide, hL * 0.5, zL),
                size: SIMD3(wL, hL, depthL),
                seed: seed * 2,
                detail: detail,
                side: -1
            )
            appendBuilding(
                items: &items,
                meshes: meshes,
                family: famR,
                center: SIMD3(xSide, hR * 0.5, zR),
                size: SIMD3(wR, hR, depthR),
                seed: seed * 2 + 1,
                detail: detail,
                side: 1
            )

            zCursor += max(depthL, depthR) * 0.5 + gap + min(depthL, depthR) * 0.5
            bi += 1
        }
    }

    private static func appendBuilding(
        items: inout [DrawItem],
        meshes: CityKitMeshes,
        family: FacadeFamily,
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        seed: Int,
        detail: Bool,
        side: Float
    ) {
        let tint3 = ArtDirection.buildingTint(index: seed)
        let body = SIMD4(tint3.x, tint3.y, tint3.z, 1)
        let shadow = SIMD4(ArtDirection.buildingShadow.x, ArtDirection.buildingShadow.y, ArtDirection.buildingShadow.z, 1)
        let warm = SIMD4(ArtDirection.windowGlow.x, ArtDirection.windowGlow.y, ArtDirection.windowGlow.z, 1)

        func add(_ mesh: MTKMesh, _ model: matrix_float4x4, _ color: SIMD4<Float>, material: Float, cast: Bool = true, receive: Bool = true) {
            items.append(DrawItem(
                mesh: mesh,
                modelMatrix: model,
                color: color,
                isWave: false,
                materialId: material,
                castsShadow: cast,
                receivesShadow: receive
            ))
        }

        let baseH = size.y * 0.12
        let bodyH = size.y - baseH
        let baseCenter = SIMD3(center.x, baseH * 0.5, center.z)
        let bodyCenter = SIMD3(center.x, baseH + bodyH * 0.5, center.z)

        // Sockel
        add(
            meshes.beveled,
            Math.translation(baseCenter) * Math.scale(SIMD3(size.x * 1.05, baseH, size.z * 1.05)),
            shadow,
            material: 2
        )

        // Primary mass — family silhouette
        switch family {
        case .brickWalkup:
            add(meshes.beveled, Math.translation(bodyCenter) * Math.scale(SIMD3(size.x, bodyH, size.z)), body, material: 6)
            // Cornice
            add(
                meshes.plate,
                Math.translation(SIMD3(center.x, size.y + 0.25, center.z + side * size.z * 0.02))
                    * Math.scale(SIMD3(size.x * 1.08, 0.45, size.z * 0.2)),
                shadow,
                material: 4
            )
            if detail {
                // Punched window band (selective glow — not every floor)
                let glow = hash(seed + 11) > 0.55
                add(
                    meshes.plate,
                    Math.translation(SIMD3(center.x + side * size.x * 0.48, size.y * 0.55, center.z))
                        * Math.scale(SIMD3(0.12, size.y * 0.35, size.z * 0.7)),
                    glow ? warm : shadow,
                    material: glow ? 3 : 4,
                    cast: false,
                    receive: false
                )
            }

        case .glassTower:
            let slim = SIMD3(size.x * 0.72, bodyH * 1.15, size.z * 0.72)
            add(
                meshes.beveled,
                Math.translation(SIMD3(center.x, baseH + slim.y * 0.5, center.z)) * Math.scale(slim),
                SIMD4(ArtDirection.buildingShadow.x * 1.1, ArtDirection.buildingShadow.y * 1.15, ArtDirection.buildingShadow.z * 1.2, 1),
                material: 6
            )
            if detail && hash(seed + 5) > 0.4 {
                add(
                    meshes.plate,
                    Math.translation(SIMD3(center.x + side * slim.x * 0.5, baseH + slim.y * 0.7, center.z))
                        * Math.scale(SIMD3(0.08, slim.y * 0.25, slim.z * 0.55)),
                    warm,
                    material: 3,
                    cast: false,
                    receive: false
                )
            }
            // Antenna
            add(
                meshes.cylinder,
                Math.translation(SIMD3(center.x, baseH + slim.y + 1.2, center.z)) * Math.scale(SIMD3(0.2, 2.4, 0.2)),
                shadow,
                material: 4
            )

        case .terracottaBlock:
            let t = SIMD4(ArtDirection.terracotta.x, ArtDirection.terracotta.y, ArtDirection.terracotta.z, 1)
            add(meshes.rounded, Math.translation(bodyCenter) * Math.scale(SIMD3(size.x, bodyH, size.z)), t, material: 6)
            // Deep arched band
            if detail {
                add(
                    meshes.rounded,
                    Math.translation(SIMD3(center.x + side * size.x * 0.42, size.y * 0.4, center.z))
                        * Math.scale(SIMD3(0.35, size.y * 0.22, size.z * 0.55)),
                    shadow,
                    material: 4
                )
            }
            add(
                meshes.wedge,
                Math.translation(SIMD3(center.x, size.y + 0.6, center.z)) * Math.scale(SIMD3(size.x * 0.95, 1.2, size.z * 0.95)),
                t,
                material: 4
            )

        case .neonHotel:
            add(meshes.beveled, Math.translation(bodyCenter) * Math.scale(SIMD3(size.x, bodyH, size.z)), body, material: 6)
            // Setback crown
            add(
                meshes.beveled,
                Math.translation(SIMD3(center.x, size.y + 1.0, center.z)) * Math.scale(SIMD3(size.x * 0.7, 2.0, size.z * 0.7)),
                shadow,
                material: 6
            )
            if detail && hash(seed + 19) > 0.35 {
                let neon = hash(seed + 21) > 0.5
                    ? SIMD4(ArtDirection.neonMagenta.x, ArtDirection.neonMagenta.y, ArtDirection.neonMagenta.z, 1)
                    : SIMD4(ArtDirection.neonCyan.x, ArtDirection.neonCyan.y, ArtDirection.neonCyan.z, 1)
                add(
                    meshes.plate,
                    Math.translation(SIMD3(center.x + side * size.x * 0.52, size.y * 0.72, center.z))
                        * Math.scale(SIMD3(0.1, 0.35, size.z * 0.65)),
                    neon,
                    material: 3,
                    cast: false,
                    receive: false
                )
            }

        case .warehouseLoft:
            let lowH = bodyH * 0.72
            add(
                meshes.beveled,
                Math.translation(SIMD3(center.x, baseH + lowH * 0.5, center.z)) * Math.scale(SIMD3(size.x * 1.15, lowH, size.z * 1.1)),
                body,
                material: 6
            )
            // Loading canopy / awning
            if detail {
                add(
                    meshes.plate,
                    Math.translation(SIMD3(center.x + side * size.x * 0.7, baseH + 3.2, center.z))
                        * Math.scale(SIMD3(2.2, 0.2, size.z * 0.6)),
                    shadow,
                    material: 4
                )
            }
            // Sawtooth roof hint
            add(
                meshes.wedge,
                Math.translation(SIMD3(center.x, baseH + lowH + 0.8, center.z)) * Math.scale(SIMD3(size.x * 1.1, 1.4, size.z * 0.4)),
                shadow,
                material: 4
            )

        case .cornerClock:
            add(meshes.beveled, Math.translation(bodyCenter) * Math.scale(SIMD3(size.x, bodyH, size.z)), body, material: 6)
            // Clock drum
            add(
                meshes.cylinder,
                Math.translation(SIMD3(center.x, size.y + 1.4, center.z + side * size.z * 0.1))
                    * Math.scale(SIMD3(size.x * 0.45, 2.2, size.x * 0.45)),
                shadow,
                material: 4
            )
            add(
                meshes.wedge,
                Math.translation(SIMD3(center.x, size.y + 3.2, center.z + side * size.z * 0.1))
                    * Math.scale(SIMD3(1.2, 1.6, 1.2)),
                SIMD4(ArtDirection.sunSideWarm.x, ArtDirection.sunSideWarm.y, ArtDirection.sunSideWarm.z, 1),
                material: 4
            )
            if detail && hash(seed + 33) > 0.6 {
                add(
                    meshes.plate,
                    Math.translation(SIMD3(center.x + side * size.x * 0.5, size.y * 0.5, center.z))
                        * Math.scale(SIMD3(0.1, size.y * 0.2, size.z * 0.4)),
                    warm,
                    material: 3,
                    cast: false,
                    receive: false
                )
            }
        }
    }
}
