//
//  HeroWaveMesh.swift
//  city of surf
//
//  Statisches (u,v)-Parametergitter für die überschlagende Hero-Wave.
//
//  Das Gitter wird EINMAL erzeugt und nie wieder hochgeladen. Die Profilauswertung
//  liegt in `WaveProfile.h` und wird in Schritt 2 in den Vertex-Shader gezogen; hier
//  wird sie CPU-seitig ausgewertet, damit das Mesh in den bestehenden Draw-Pfad
//  (Positions- + Texcoord-Buffer laut `Renderer.buildMetalVertexDescriptor`) passt.
//
//  Normalen gibt es in diesem Layout nicht — der Shader leitet sie ab (Schritt 3).
//

import MetalKit
import ModelIO
import simd

/// Reine Mathematik der Hero-Wave, ohne Metal. Bewusst mit Swift-Typen in der
/// Signatur, damit das Test-Target (ohne Bridging-Header) sie aufrufen kann.
/// Gerechnet wird ausschließlich in den `static inline` C-Funktionen aus
/// `WaveProfile.h`, die auch der Metal-Compiler übersetzt.
enum HeroWave {

    /// Tuning-Defaults mit gefülltem `heightScale`.
    static func defaultParams() -> HeroWaveParams {
        heroWaveResolve(heroWaveDefaultParams())
    }

    /// Defaults mit überschriebenem Wurfwinkel — für Parameterstudien im Test.
    static func params(thetaMaxDegrees: Float) -> HeroWaveParams {
        var p = heroWaveDefaultParams()
        p.thetaMaxDegrees = thetaMaxDegrees
        return heroWaveResolve(p)
    }

    static var defaultThetaMaxDegrees: Float { heroWaveDefaultParams().thetaMaxDegrees }
    static var defaultWaveHeight: Float { heroWaveDefaultParams().waveHeight }
    static var defaultBarrelRadius: Float { heroWaveDefaultParams().barrelRadius }
    static var defaultFootLength: Float { heroWaveDefaultParams().footLength }
    static var defaultBreakPhase: Float { heroWaveDefaultParams().breakPhase }
    static var defaultHeightScale: Float { defaultParams().heightScale }

    /// Weltposition eines Gitterpunkts (u entlang des Profils, v entlang Welt-x).
    static func worldPosition(u: Float, v: Float) -> SIMD3<Float> {
        heroWaveWorldPosition(defaultParams(), u, v)
    }

    /// Feine Abtastung der Profilkurve in Weltkoordinaten. Die Parameter werden
    /// einmal aufgelöst, nicht pro Punkt — sonst kostet die Höhennormierung O(n²).
    static func sampledWorldProfile(
        samples: Int,
        v: Float = 0.5,
        thetaMaxDegrees: Float? = nil
    ) -> [SIMD3<Float>] {
        let p = thetaMaxDegrees.map { params(thetaMaxDegrees: $0) } ?? defaultParams()
        return (0...max(samples, 1)).map { i in
            heroWaveWorldPosition(p, Float(i) / Float(max(samples, 1)), v)
        }
    }
}

enum HeroWaveMesh {

    /// Auflösung des Parametergitters. u braucht Dichte, weil die Lippe eng krümmt;
    /// v ist grob, solange es keine Sweep-Variation gibt (Schritt 6).
    static let uSegments = 96
    static let vSegments = 32

    static func make(
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor,
        params: HeroWaveParams = HeroWave.defaultParams()
    ) throws -> MTKMesh {
        let uCount = uSegments + 1
        let vCount = vSegments + 1
        let vertexCount = uCount * vCount

        // Layout 0: packed float3 (stride 12) — SIMD3<Float> hätte stride 16.
        var positions = [Float]()
        positions.reserveCapacity(vertexCount * 3)
        var texcoords = [Float]()
        texcoords.reserveCapacity(vertexCount * 2)

        for vi in 0..<vCount {
            let v = Float(vi) / Float(vSegments)
            for ui in 0..<uCount {
                let u = Float(ui) / Float(uSegments)
                let p = heroWaveWorldPosition(params, u, v)
                positions.append(p.x)
                positions.append(p.y)
                positions.append(p.z)
                texcoords.append(u)
                texcoords.append(v)
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity(uSegments * vSegments * 6)
        for vi in 0..<vSegments {
            for ui in 0..<uSegments {
                let i00 = UInt32(vi * uCount + ui)
                let i10 = i00 + 1
                let i01 = i00 + UInt32(uCount)
                let i11 = i01 + 1
                indices.append(contentsOf: [i00, i10, i11, i00, i11, i01])
            }
        }

        let allocator = MTKMeshBufferAllocator(device: device)
        let positionBuffer = allocator.newBuffer(
            with: positions.withUnsafeBufferPointer { Data(buffer: $0) },
            type: .vertex
        )
        let texcoordBuffer = allocator.newBuffer(
            with: texcoords.withUnsafeBufferPointer { Data(buffer: $0) },
            type: .vertex
        )
        let indexBuffer = allocator.newBuffer(
            with: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            type: .index
        )

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let mdl = MDLMesh(
            vertexBuffers: [positionBuffer, texcoordBuffer],
            vertexCount: vertexCount,
            descriptor: try MeshFactory.modelIOVertexDescriptor(from: vertexDescriptor),
            submeshes: [submesh]
        )
        return try MTKMesh(mesh: mdl, device: device)
    }
}
