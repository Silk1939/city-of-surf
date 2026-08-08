//
//  SurferVisual.swift
//  city of surf
//
//  Procedural articulated surfer — visual only. Collision stays in SurferController.
//

import MetalKit
import simd

enum SurferVisualPose: Int, CaseIterable {
    case neutral
    case carveLeft
    case carveRight
    case jumpAnticipate
    case airborne
    case landing
    case duck
    case wipeout
}

/// Shared procedural meshes for the articulated figure.
struct SurferMeshes {
    let capsule: MTKMesh
    let sphere: MTKMesh
    let foot: MTKMesh
    let hand: MTKMesh

    static func make(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> SurferMeshes {
        let capsule = try MeshFactory.makeCapsule(
            device: device,
            height: 1.0,
            radius: 0.5,
            radialSegments: 12,
            verticalSegments: 1,
            vertexDescriptor: vertexDescriptor
        )
        let sphere = try MeshFactory.makeSphere(
            device: device,
            radii: SIMD3(0.5, 0.5, 0.5),
            radialSegments: 14,
            verticalSegments: 10,
            vertexDescriptor: vertexDescriptor
        )
        let foot = try MeshFactory.makeRoundedBox(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            segments: 8,
            vertexDescriptor: vertexDescriptor
        )
        let hand = try MeshFactory.makeRoundedBox(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            segments: 8,
            vertexDescriptor: vertexDescriptor
        )
        return SurferMeshes(capsule: capsule, sphere: sphere, foot: foot, hand: hand)
    }

    var allMeshes: [MTKMesh] { [capsule, sphere, foot, hand] }
}

/// Soft pose blender driven by gameplay state (no collision changes).
struct SurferVisual {
    private var weights = [Float](repeating: 0, count: SurferVisualPose.allCases.count)
    private var initialized = false

    mutating func invalidate() {
        initialized = false
    }

    mutating func update(surfer: SurferController, isWipeout: Bool, deltaTime: Float) {
        var target = [Float](repeating: 0, count: SurferVisualPose.allCases.count)

        if isWipeout {
            target[SurferVisualPose.wipeout.rawValue] = 1
        } else {
            switch surfer.pose {
            case .ducking:
                target[SurferVisualPose.duck.rawValue] = 1
            case .jumping:
                let t = 1 - (surfer.poseTimer / SurferController.jumpDuration)
                if t < 0.12 {
                    target[SurferVisualPose.jumpAnticipate.rawValue] = 1
                } else if t > 0.82 {
                    target[SurferVisualPose.landing.rawValue] = 1
                } else {
                    target[SurferVisualPose.airborne.rawValue] = 1
                }
            case .standing:
                let lean = surfer.lean
                let carve = min(1, abs(lean) * 1.35)
                target[SurferVisualPose.neutral.rawValue] = 1 - carve
                if lean < 0 {
                    target[SurferVisualPose.carveLeft.rawValue] = carve
                } else {
                    target[SurferVisualPose.carveRight.rawValue] = carve
                }
            }
        }

        if !initialized {
            weights = target
            initialized = true
            return
        }

        let blend = min(1, deltaTime * 11)
        for i in weights.indices {
            weights[i] += (target[i] - weights[i]) * blend
        }
        // Renormalize soft weights so blended joints stay stable.
        let sum = max(weights.reduce(0, +), 0.0001)
        for i in weights.indices {
            weights[i] /= sum
        }
    }

    func appendDrawItems(
        to items: inout [DrawItem],
        meshes: SurferMeshes,
        surfer: SurferController,
        rootLean: Float
    ) {
        let sp = surfer.position
        let sh = surfer.currentHeight
        // Lean from carve + soft water-surface roll/pitch so the silhouette rides the face.
        let leanRot = Math.rotation(radians: rootLean * 0.28 + surfer.surfaceRoll * 0.55, axis: SIMD3(0, 0, 1))
        let pitchRot = Math.rotation(radians: surfer.surfacePitch * 0.65, axis: SIMD3(1, 0, 0))
        // Match previous visual center: position is collision center; figure stands on board below.
        let root = Math.translation(SIMD3(sp.x, sp.y - sh * 0.42, sp.z)) * leanRot * pitchRot

        let suit = SIMD4<Float>(0.10, 0.10, 0.11, 1)
        let skin = SIMD4<Float>(0.72, 0.48, 0.36, 1)
        let accent = SIMD4<Float>(ArtDirection.neonCyan.x, ArtDirection.neonCyan.y, ArtDirection.neonCyan.z, 1)

        func part(
            _ mesh: MTKMesh,
            local: matrix_float4x4,
            color: SIMD4<Float>,
            castShadow: Bool = true
        ) {
            items.append(DrawItem(
                mesh: mesh,
                modelMatrix: root * local,
                color: color,
                isWave: false,
                materialId: 3,
                castsShadow: castShadow,
                receivesShadow: true
            ))
        }

        func euler(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
            Math.rotation(radians: x, axis: SIMD3(1, 0, 0))
                * Math.rotation(radians: y, axis: SIMD3(0, 1, 0))
                * Math.rotation(radians: z, axis: SIMD3(0, 0, 1))
        }

        func blendAngles(_ keyPath: (SurferVisualPose) -> SIMD3<Float>) -> SIMD3<Float> {
            var r = SIMD3<Float>.zero
            for pose in SurferVisualPose.allCases {
                r += keyPath(pose) * weights[pose.rawValue]
            }
            return r
        }

        // Joint angle tables (radians) — readable silhouette over anatomical accuracy.
        func pelvisTilt(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.18, 0, 0)
            case .carveLeft: return SIMD3(0.22, 0.08, 0.28)
            case .carveRight: return SIMD3(0.22, -0.08, -0.28)
            case .jumpAnticipate: return SIMD3(0.42, 0, 0)
            case .airborne: return SIMD3(0.05, 0, 0)
            case .landing: return SIMD3(0.48, 0, 0)
            case .duck: return SIMD3(0.55, 0, 0)
            case .wipeout: return SIMD3(-0.35, 0.4, 0.6)
            }
        }
        func torsoTwist(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.12, 0, 0)
            case .carveLeft: return SIMD3(0.15, 0.25, 0.12)
            case .carveRight: return SIMD3(0.15, -0.25, -0.12)
            case .jumpAnticipate: return SIMD3(0.35, 0, 0)
            case .airborne: return SIMD3(-0.08, 0, 0)
            case .landing: return SIMD3(0.4, 0, 0)
            case .duck: return SIMD3(0.5, 0, 0)
            case .wipeout: return SIMD3(0.2, -0.5, -0.4)
            }
        }
        func headNod(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(-0.1, 0, 0)
            case .carveLeft: return SIMD3(-0.05, 0.2, 0.05)
            case .carveRight: return SIMD3(-0.05, -0.2, -0.05)
            case .jumpAnticipate: return SIMD3(0.15, 0, 0)
            case .airborne: return SIMD3(-0.2, 0, 0)
            case .landing: return SIMD3(0.25, 0, 0)
            case .duck: return SIMD3(0.35, 0, 0)
            case .wipeout: return SIMD3(0.5, 0.3, 0.2)
            }
        }
        func thighL(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.85, 0.12, 0.08)
            case .carveLeft: return SIMD3(0.95, 0.2, 0.35)
            case .carveRight: return SIMD3(0.7, 0.05, -0.15)
            case .jumpAnticipate: return SIMD3(1.15, 0.1, 0.1)
            case .airborne: return SIMD3(0.55, 0.15, 0.1)
            case .landing: return SIMD3(1.25, 0.12, 0.1)
            case .duck: return SIMD3(1.45, 0.15, 0.12)
            case .wipeout: return SIMD3(0.3, 0.4, 0.5)
            }
        }
        func thighR(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.85, -0.12, -0.08)
            case .carveLeft: return SIMD3(0.7, -0.05, 0.15)
            case .carveRight: return SIMD3(0.95, -0.2, -0.35)
            case .jumpAnticipate: return SIMD3(1.15, -0.1, -0.1)
            case .airborne: return SIMD3(0.55, -0.15, -0.1)
            case .landing: return SIMD3(1.25, -0.12, -0.1)
            case .duck: return SIMD3(1.45, -0.15, -0.12)
            case .wipeout: return SIMD3(0.2, -0.5, -0.35)
            }
        }
        func shinL(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(-1.05, 0, 0)
            case .carveLeft: return SIMD3(-1.15, 0.05, 0.1)
            case .carveRight: return SIMD3(-0.95, 0, -0.05)
            case .jumpAnticipate: return SIMD3(-1.35, 0, 0)
            case .airborne: return SIMD3(-0.7, 0, 0)
            case .landing: return SIMD3(-1.45, 0, 0)
            case .duck: return SIMD3(-1.55, 0, 0)
            case .wipeout: return SIMD3(-0.4, 0.2, 0.3)
            }
        }
        func shinR(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(-1.05, 0, 0)
            case .carveLeft: return SIMD3(-0.95, 0, 0.05)
            case .carveRight: return SIMD3(-1.15, -0.05, -0.1)
            case .jumpAnticipate: return SIMD3(-1.35, 0, 0)
            case .airborne: return SIMD3(-0.7, 0, 0)
            case .landing: return SIMD3(-1.45, 0, 0)
            case .duck: return SIMD3(-1.55, 0, 0)
            case .wipeout: return SIMD3(-0.35, -0.25, -0.25)
            }
        }
        func upperArmL(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.35, 0, 1.05)
            case .carveLeft: return SIMD3(0.25, 0.15, 1.35)
            case .carveRight: return SIMD3(0.55, -0.1, 0.75)
            case .jumpAnticipate: return SIMD3(0.6, 0, 0.85)
            case .airborne: return SIMD3(-0.15, 0.1, 1.45)
            case .landing: return SIMD3(0.5, 0, 0.9)
            case .duck: return SIMD3(0.7, 0.1, 0.7)
            case .wipeout: return SIMD3(-0.8, 0.6, 1.2)
            }
        }
        func upperArmR(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.35, 0, -1.05)
            case .carveLeft: return SIMD3(0.55, 0.1, -0.75)
            case .carveRight: return SIMD3(0.25, -0.15, -1.35)
            case .jumpAnticipate: return SIMD3(0.6, 0, -0.85)
            case .airborne: return SIMD3(-0.15, -0.1, -1.45)
            case .landing: return SIMD3(0.5, 0, -0.9)
            case .duck: return SIMD3(0.7, -0.1, -0.7)
            case .wipeout: return SIMD3(0.9, -0.5, -0.8)
            }
        }
        func lowerArmL(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.55, 0, 0.15)
            case .carveLeft: return SIMD3(0.35, 0.1, 0.25)
            case .carveRight: return SIMD3(0.7, 0, 0.05)
            case .jumpAnticipate: return SIMD3(0.85, 0, 0.1)
            case .airborne: return SIMD3(0.25, 0, 0.2)
            case .landing: return SIMD3(0.75, 0, 0.1)
            case .duck: return SIMD3(0.95, 0, 0.05)
            case .wipeout: return SIMD3(0.4, 0.3, 0.4)
            }
        }
        func lowerArmR(_ p: SurferVisualPose) -> SIMD3<Float> {
            switch p {
            case .neutral: return SIMD3(0.55, 0, -0.15)
            case .carveLeft: return SIMD3(0.7, 0, -0.05)
            case .carveRight: return SIMD3(0.35, -0.1, -0.25)
            case .jumpAnticipate: return SIMD3(0.85, 0, -0.1)
            case .airborne: return SIMD3(0.25, 0, -0.2)
            case .landing: return SIMD3(0.75, 0, -0.1)
            case .duck: return SIMD3(0.95, 0, -0.05)
            case .wipeout: return SIMD3(0.5, -0.35, -0.3)
            }
        }

        let pA = blendAngles(pelvisTilt)
        let tA = blendAngles(torsoTwist)
        let hA = blendAngles(headNod)
        let thL = blendAngles(thighL)
        let thR = blendAngles(thighR)
        let shL = blendAngles(shinL)
        let shR = blendAngles(shinR)
        let uaL = blendAngles(upperArmL)
        let uaR = blendAngles(upperArmR)
        let laL = blendAngles(lowerArmL)
        let laR = blendAngles(lowerArmR)

        // Hierarchy: pelvis → torso/head + legs; torso → arms.
        let pelvisM = Math.translation(SIMD3(0, 0.55, 0)) * euler(pA.x, pA.y, pA.z)
        part(
            meshes.capsule,
            local: pelvisM * Math.scale(SIMD3(0.42, 0.28, 0.32)),
            color: suit
        )

        let torsoM = pelvisM * Math.translation(SIMD3(0, 0.38, 0)) * euler(tA.x, tA.y, tA.z)
        part(
            meshes.capsule,
            local: torsoM * Math.scale(SIMD3(0.48, 0.42, 0.28)),
            color: suit
        )
        // Neon chest accent — silhouette readable against foam.
        part(
            meshes.capsule,
            local: torsoM * Math.translation(SIMD3(0, 0.05, 0.12)) * Math.scale(SIMD3(0.22, 0.28, 0.08)),
            color: accent,
            castShadow: false
        )

        let headM = torsoM * Math.translation(SIMD3(0, 0.48, 0.02)) * euler(hA.x, hA.y, hA.z)
        part(
            meshes.sphere,
            local: headM * Math.scale(SIMD3(0.28, 0.30, 0.28)),
            color: skin
        )

        // Left leg
        let hipL = pelvisM * Math.translation(SIMD3(-0.14, -0.05, 0.02))
        let thighLM = hipL * euler(thL.x, thL.y, thL.z) * Math.translation(SIMD3(0, -0.28, 0))
        part(meshes.capsule, local: thighLM * Math.scale(SIMD3(0.22, 0.32, 0.24)), color: suit)
        let shinLM = thighLM * Math.translation(SIMD3(0, -0.32, 0)) * euler(shL.x, shL.y, shL.z) * Math.translation(SIMD3(0, -0.26, 0))
        part(meshes.capsule, local: shinLM * Math.scale(SIMD3(0.18, 0.28, 0.20)), color: suit)
        let footLM = shinLM * Math.translation(SIMD3(0, -0.28, 0.06))
        part(meshes.foot, local: footLM * Math.scale(SIMD3(0.18, 0.10, 0.36)), color: suit)

        // Right leg
        let hipR = pelvisM * Math.translation(SIMD3(0.14, -0.05, 0.02))
        let thighRM = hipR * euler(thR.x, thR.y, thR.z) * Math.translation(SIMD3(0, -0.28, 0))
        part(meshes.capsule, local: thighRM * Math.scale(SIMD3(0.22, 0.32, 0.24)), color: suit)
        let shinRM = thighRM * Math.translation(SIMD3(0, -0.32, 0)) * euler(shR.x, shR.y, shR.z) * Math.translation(SIMD3(0, -0.26, 0))
        part(meshes.capsule, local: shinRM * Math.scale(SIMD3(0.18, 0.28, 0.20)), color: suit)
        let footRM = shinRM * Math.translation(SIMD3(0, -0.28, 0.06))
        part(meshes.foot, local: footRM * Math.scale(SIMD3(0.18, 0.10, 0.36)), color: suit)

        // Left arm
        let shLBase = torsoM * Math.translation(SIMD3(-0.28, 0.28, 0))
        let upperLM = shLBase * euler(uaL.x, uaL.y, uaL.z) * Math.translation(SIMD3(0, -0.22, 0))
        part(meshes.capsule, local: upperLM * Math.scale(SIMD3(0.16, 0.26, 0.16)), color: suit)
        let lowerLM = upperLM * Math.translation(SIMD3(0, -0.26, 0)) * euler(laL.x, laL.y, laL.z) * Math.translation(SIMD3(0, -0.2, 0))
        part(meshes.capsule, local: lowerLM * Math.scale(SIMD3(0.14, 0.22, 0.14)), color: skin)
        part(meshes.hand, local: lowerLM * Math.translation(SIMD3(0, -0.22, 0)) * Math.scale(SIMD3(0.12, 0.10, 0.16)), color: skin)

        // Right arm
        let shRBase = torsoM * Math.translation(SIMD3(0.28, 0.28, 0))
        let upperRM = shRBase * euler(uaR.x, uaR.y, uaR.z) * Math.translation(SIMD3(0, -0.22, 0))
        part(meshes.capsule, local: upperRM * Math.scale(SIMD3(0.16, 0.26, 0.16)), color: suit)
        let lowerRM = upperRM * Math.translation(SIMD3(0, -0.26, 0)) * euler(laR.x, laR.y, laR.z) * Math.translation(SIMD3(0, -0.2, 0))
        part(meshes.capsule, local: lowerRM * Math.scale(SIMD3(0.14, 0.22, 0.14)), color: skin)
        part(meshes.hand, local: lowerRM * Math.translation(SIMD3(0, -0.22, 0)) * Math.scale(SIMD3(0.12, 0.10, 0.16)), color: skin)
    }
}
