//
//  AssetMeshLibrary.swift
//  city of surf
//
//  Model I/O loader with hard fallback to procedural placeholders.
//  Missing files must never crash or blank the scene.
//

import MetalKit
import ModelIO
import simd
import os

enum AssetMeshKey: String, CaseIterable {
    case surfer = "surfer"
    case board = "board"
    case coin = "coin"
    case obstacleCab = "obstacle_cab"
    case buildingFacade = "building_facade"

    var preferredFilenames: [String] {
        [
            "\(rawValue).usdz",
            "\(rawValue).glb",
            "\(rawValue).obj"
        ]
    }
}

final class AssetMeshLibrary {
    private let device: MTLDevice
    private let vertexDescriptor: MTLVertexDescriptor
    private let textureLoader: MTKTextureLoader
    private var meshCache: [AssetMeshKey: MTKMesh] = [:]
    private var textureCache: [String: MTLTexture] = [:]
    private let logger = Logger(subsystem: "silkrock.city-of-surf", category: "AssetMeshLibrary")

    private(set) var proceduralSurfer: ProceduralSurferMeshes
    private(set) var proceduralBoard: MTKMesh
    private(set) var proceduralCoin: MTKMesh
    private(set) var proceduralBox: MTKMesh

    init(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws {
        self.device = device
        self.vertexDescriptor = vertexDescriptor
        self.textureLoader = MTKTextureLoader(device: device)
        self.proceduralSurfer = try ProceduralSurferMeshes.make(device: device, vertexDescriptor: vertexDescriptor)
        self.proceduralBoard = try MeshFactory.makeBoard(device: device, vertexDescriptor: vertexDescriptor)
        self.proceduralCoin = try MeshFactory.makeCoin(device: device, vertexDescriptor: vertexDescriptor)
        self.proceduralBox = try MeshFactory.makeBox(
            device: device,
            dimensions: SIMD3(1, 1, 1),
            vertexDescriptor: vertexDescriptor
        )
        warmCache()
    }

    private var modelsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Assets/Models", isDirectory: true)
    }

    private func warmCache() {
        for key in AssetMeshKey.allCases {
            _ = mesh(for: key)
        }
    }

    func mesh(for key: AssetMeshKey) -> MTKMesh {
        if let cached = meshCache[key] {
            return cached
        }
        if let loaded = loadMesh(for: key) {
            meshCache[key] = loaded
            return loaded
        }
        let fallback = fallbackMesh(for: key)
        meshCache[key] = fallback
        logger.warning("Missing asset for \(key.rawValue, privacy: .public); using procedural fallback.")
        return fallback
    }

    func texture(named name: String) -> MTLTexture? {
        if let cached = textureCache[name] {
            return cached
        }
        guard let dir = modelsDirectory else { return nil }
        let candidates = ["\(name).png", "\(name).jpg", "\(name).jpeg"]
        for file in candidates {
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let texture = try textureLoader.newTexture(
                    URL: url,
                    options: [
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .SRGB: true
                    ]
                )
                textureCache[name] = texture
                return texture
            } catch {
                logger.error("Texture load failed for \(file, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    var allResidentMeshes: [MTKMesh] {
        var meshes = [proceduralBox, proceduralBoard, proceduralCoin, proceduralSurfer.torso, proceduralSurfer.head, proceduralSurfer.limb]
        meshes.append(contentsOf: meshCache.values)
        // Unique by ObjectIdentifier
        var seen = Set<ObjectIdentifier>()
        return meshes.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func fallbackMesh(for key: AssetMeshKey) -> MTKMesh {
        switch key {
        case .board:
            return proceduralBoard
        case .coin:
            return proceduralCoin
        case .surfer, .obstacleCab, .buildingFacade:
            return proceduralBox
        }
    }

    private func loadMesh(for key: AssetMeshKey) -> MTKMesh? {
        guard let dir = modelsDirectory else { return nil }
        for filename in key.preferredFilenames {
            let url = dir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                return try loadMesh(at: url)
            } catch {
                logger.error("Failed loading \(filename, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    private func loadMesh(at url: URL) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(
            url: url,
            vertexDescriptor: nil,
            bufferAllocator: allocator
        )
        asset.loadTextures()
        guard let mdlMesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else {
            throw MeshFactoryError.badVertexDescriptor
        }
        try MeshFactory.applyVertexDescriptor(vertexDescriptor, to: mdlMesh)
        return try MTKMesh(mesh: mdlMesh, device: device)
    }
}
