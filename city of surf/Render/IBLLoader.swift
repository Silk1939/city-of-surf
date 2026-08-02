//
//  IBLLoader.swift
//  city of surf
//

import Foundation
import Metal
import MetalKit
import simd

struct LightingConfig {
    var sunDirection = SIMD3<Float>(0.55, 0.55, 0.45)
    var sunColor = SIMD3<Float>(1.0, 0.72, 0.4)
    var sunIntensity: Float = 2.8
    var iblIntensity: Float = 1.15
    var shadowBias: Float = 0.0025
    var specularMips: Float = 5
    /// Peak luminance from lighting.json / bake (for device smoke HUD).
    var irradiancePeak: Float = 0
}

struct PBRMaterialTextures {
    var albedo: MTLTexture
    var normal: MTLTexture
    var roughness: MTLTexture
}

struct IBLTextures {
    var sky: MTLTexture
    var irradiance: MTLTexture
    var specular: MTLTexture
    var brdfLUT: MTLTexture
    var asphalt: PBRMaterialTextures
    var concrete: PBRMaterialTextures
    var glass: PBRMaterialTextures
    var config: LightingConfig
    /// Intentional solid fills for non-PBR draw items (surfer/obstacles/coins) — never a silent missing-asset fallback.
    var solidWhite: MTLTexture
    var flatNormal: MTLTexture
    var midRoughness: MTLTexture
    /// Approximate resident texture bytes (KTX + PBR + solids + shadow filled by Renderer).
    var approximateTextureBytes: Int
}

enum IBLLoadError: LocalizedError {
    case missingFile(String)
    case decodeFailed(String, String)
    case wrongFormat(String, String)
    case incompleteSpecular(Int)
    case specularPackFailed
    case solidTextureFailed

    var errorDescription: String? {
        switch self {
        case .missingFile(let name):
            return "Asset fehlt: \(name)"
        case .decodeFailed(let name, let why):
            return "KTX/PNG decode fehlgeschlagen (\(name)): \(why)"
        case .wrongFormat(let name, let expected):
            return "Falsches Pixel-Format bei \(name) — erwartet \(expected)"
        case .incompleteSpecular(let n):
            return "Specular-Mips unvollständig: \(n)/5 (specular_m0.ktx … specular_m4.ktx)"
        case .specularPackFailed:
            return "Specular-Array konnte nicht gepackt werden"
        case .solidTextureFailed:
            return "Interne Solid-Texturen fehlgeschlagen"
        }
    }
}

enum IBLLoader {
    static func load(device: MTLDevice) throws -> IBLTextures {
        let pngLoader = MTKTextureLoader(device: device)
        let linearPNG: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .SRGB: false,
            .generateMipmaps: false
        ]
        let srgbPNG: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .SRGB: true,
            .generateMipmaps: true
        ]

        func findURL(_ name: String, ext: String) -> URL? {
            let candidates: [URL?] = [
                Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Lighting"),
                Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/Lighting"),
                Bundle.main.url(forResource: name, withExtension: ext)
            ]
            if let hit = candidates.compactMap({ $0 }).first { return hit }
            if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                return urls.first(where: { $0.lastPathComponent == "\(name).\(ext)" })
            }
            return nil
        }

        func pngTex(_ name: String, srgbColor: Bool) throws -> MTLTexture {
            let file = "\(name).png"
            guard let url = findURL(name, ext: "png") else {
                throw IBLLoadError.missingFile(file)
            }
            do {
                return try pngLoader.newTexture(URL: url, options: srgbColor ? srgbPNG : linearPNG)
            } catch {
                throw IBLLoadError.decodeFailed(file, error.localizedDescription)
            }
        }

        func hdrTex(_ name: String, expected: MTLPixelFormat) throws -> MTLTexture {
            let file = "\(name).ktx"
            guard let url = findURL(name, ext: "ktx") else {
                throw IBLLoadError.missingFile(file)
            }
            // No silent MTKTextureLoader fallback — float KTX must go through our parser.
            let tex: MTLTexture
            do {
                tex = try loadKTXhalfFloat(url: url, device: device)
            } catch let e as IBLLoadError {
                throw e
            } catch {
                throw IBLLoadError.decodeFailed(file, error.localizedDescription)
            }
            guard tex.pixelFormat == expected else {
                throw IBLLoadError.wrongFormat(
                    file,
                    "\(expected) (ist \(tex.pixelFormat.rawValue))"
                )
            }
            return tex
        }

        func material(_ prefix: String) throws -> PBRMaterialTextures {
            let a = try pngTex("\(prefix)_albedo", srgbColor: true)
            let n = try pngTex("\(prefix)_normal", srgbColor: false)
            let r = try pngTex("\(prefix)_roughness", srgbColor: false)
            return PBRMaterialTextures(albedo: a, normal: n, roughness: r)
        }

        let sky = try hdrTex("sky_equirect", expected: .rgba16Float)
        let irr = try hdrTex("irradiance_equirect", expected: .rgba16Float)
        let brdf = try hdrTex("brdf_lut", expected: .rg16Float)
        let asphalt = try material("asphalt")
        let concrete = try material("concrete")
        let glass = try material("glass")

        var mipImages: [MTLTexture] = []
        for i in 0..<5 {
            let t = try hdrTex("specular_m\(i)", expected: .rgba16Float)
            mipImages.append(t)
        }
        guard mipImages.count == 5 else {
            throw IBLLoadError.incompleteSpecular(mipImages.count)
        }
        guard let specular = makeSpecularArray(device: device, mips: mipImages) else {
            throw IBLLoadError.specularPackFailed
        }

        var config = LightingConfig()
        if let url = findURL("lighting", ext: "json") {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let d = json["sunDirection"] as? [Double], d.count == 3 {
                    config.sunDirection = simd_normalize(SIMD3(Float(d[0]), Float(d[1]), Float(d[2])))
                }
                if let c = json["sunColor"] as? [Double], c.count == 3 {
                    config.sunColor = SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
                }
                if let v = json["sunIntensity"] as? Double { config.sunIntensity = Float(v) }
                if let v = json["iblIntensity"] as? Double { config.iblIntensity = Float(v) }
                if let v = json["shadowBias"] as? Double { config.shadowBias = Float(v) }
                if let v = json["specularMips"] as? Int { config.specularMips = Float(v) }
                if let v = json["irradiancePeak"] as? Double { config.irradiancePeak = Float(v) }
            }
        } else {
            print("IBLLoader WARN: lighting.json fehlt — Default-Sonne")
        }

        guard let white = makeSolidTexture(device: device, color: SIMD4(1, 1, 1, 1)),
              let flatN = makeSolidTexture(device: device, color: SIMD4(0.5, 0.5, 1, 1)),
              let grayR = makeSolidTexture(device: device, color: SIMD4(0.55, 0.55, 0.55, 1)) else {
            throw IBLLoadError.solidTextureFailed
        }

        print("IBLLoader OK: sky=\(sky.width)x\(sky.height) \(sky.pixelFormat.rawValue) irrPeak=\(config.irradiancePeak) specularLayers=\(specular.arrayLength)")

        let bytes = estimateBytes(textures: [
            sky, irr, specular, brdf,
            asphalt.albedo, asphalt.normal, asphalt.roughness,
            concrete.albedo, concrete.normal, concrete.roughness,
            glass.albedo, glass.normal, glass.roughness,
            white, flatN, grayR
        ])
        print(String(format: "IBLLoader texture memory ≈ %.1f MB", Double(bytes) / (1024 * 1024)))

        return IBLTextures(
            sky: sky,
            irradiance: irr,
            specular: specular,
            brdfLUT: brdf,
            asphalt: asphalt,
            concrete: concrete,
            glass: glass,
            config: config,
            solidWhite: white,
            flatNormal: flatN,
            midRoughness: grayR,
            approximateTextureBytes: bytes
        )
    }

    private static func estimateBytes(textures: [MTLTexture]) -> Int {
        var total = 0
        for t in textures {
            let bpp: Int
            switch t.pixelFormat {
            case .rgba16Float: bpp = 8
            case .rg16Float: bpp = 4
            case .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb, .bgra8Unorm_srgb: bpp = 4
            case .depth32Float: bpp = 4
            default: bpp = 4
            }
            var levelBytes = t.width * t.height * bpp * max(t.arrayLength, 1)
            // Account for mip chain if present (~1.33× for full chain).
            if t.mipmapLevelCount > 1 {
                levelBytes = Int(Double(levelBytes) * 1.333)
            }
            total += levelBytes
        }
        return total
    }

    /// Parse KTX 1.1 uncompressed half-float (RGBA16F or RG16F).
    private static func loadKTXhalfFloat(url: URL, device: MTLDevice) throws -> MTLTexture {
        let file = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IBLLoadError.decodeFailed(file, "Datei lesen: \(error.localizedDescription)")
        }
        guard data.count > 64 else {
            throw IBLLoadError.decodeFailed(file, "Datei zu klein (\(data.count) B)")
        }
        let ident = Data([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.prefix(12) == ident else {
            throw IBLLoadError.decodeFailed(file, "Kein KTX 1.1 Identifier")
        }

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
        }

        let endian = u32(12)
        guard endian == 0x04030201 else {
            throw IBLLoadError.decodeFailed(file, "Endianness \(endian) — erwartet little-endian 0x04030201")
        }
        let glType = u32(16)
        let glTypeSize = u32(20)
        let glInternal = u32(28)
        let width = Int(u32(36))
        let height = Int(u32(40))
        let depth = Int(u32(44))
        let arrayElems = Int(u32(48))
        let faces = Int(u32(52))
        let mips = Int(u32(56))
        let kvBytes = Int(u32(60))

        guard glType == 0x140B, glTypeSize == 2 else {
            throw IBLLoadError.decodeFailed(file, "glType muss GL_HALF_FLOAT (0x140B) sein")
        }
        guard depth == 0, arrayElems == 0, faces == 1, mips == 1 else {
            throw IBLLoadError.decodeFailed(
                file,
                "Unerwartete Dims depth=\(depth) arr=\(arrayElems) faces=\(faces) mips=\(mips) (erwartet 0/0/1/1)"
            )
        }
        guard width > 0, height > 0 else {
            throw IBLLoadError.decodeFailed(file, "Ungültige Größe \(width)x\(height)")
        }

        let pixelFormat: MTLPixelFormat
        let channelCount: Int
        switch glInternal {
        case 0x881A: // GL_RGBA16F — linear HDR, no sRGB
            pixelFormat = .rgba16Float
            channelCount = 4
        case 0x822F: // GL_RG16F — linear BRDF scale/bias
            pixelFormat = .rg16Float
            channelCount = 2
        default:
            throw IBLLoadError.wrongFormat(file, "RGBA16F (0x881A) oder RG16F (0x822F), got \(glInternal)")
        }

        let imageSizeOffset = 64 + kvBytes
        guard imageSizeOffset + 4 <= data.count else {
            throw IBLLoadError.decodeFailed(file, "imageSize Offset außerhalb Datei")
        }
        let imageSize = Int(u32(imageSizeOffset))
        let payloadOffset = imageSizeOffset + 4
        guard payloadOffset + imageSize <= data.count else {
            throw IBLLoadError.decodeFailed(file, "Payload überschreitet Datei")
        }

        let expected = width * height * channelCount * MemoryLayout<UInt16>.size
        guard imageSize >= expected else {
            throw IBLLoadError.decodeFailed(file, "imageSize \(imageSize) < expected \(expected)")
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw IBLLoadError.decodeFailed(file, "MTLTexture alloc fehlgeschlagen")
        }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base.advanced(by: payloadOffset),
                bytesPerRow: width * channelCount * MemoryLayout<UInt16>.size
            )
        }
        texture.label = file
        return texture
    }

    /// Pack specular mips into a 2D array. Metal requires identical layer sizes — upsample smaller mips.
    private static func makeSpecularArray(device: MTLDevice, mips: [MTLTexture]) -> MTLTexture? {
        guard let first = mips.first else { return nil }
        let maxW = mips.map(\.width).max() ?? first.width
        let maxH = mips.map(\.height).max() ?? first.height
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba16Float
        desc.width = maxW
        desc.height = maxH
        desc.arrayLength = mips.count
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let array = device.makeTexture(descriptor: desc) else { return nil }

        for (i, src) in mips.enumerated() {
            if src.width == maxW, src.height == maxH {
                var bytes = [UInt16](repeating: 0, count: maxW * maxH * 4)
                bytes.withUnsafeMutableBytes { buf in
                    src.getBytes(
                        buf.baseAddress!,
                        bytesPerRow: maxW * 8,
                        from: MTLRegionMake2D(0, 0, maxW, maxH),
                        mipmapLevel: 0
                    )
                }
                bytes.withUnsafeBytes { buf in
                    array.replace(
                        region: MTLRegionMake2D(0, 0, maxW, maxH),
                        mipmapLevel: 0,
                        slice: i,
                        withBytes: buf.baseAddress!,
                        bytesPerRow: maxW * 8,
                        bytesPerImage: maxW * maxH * 8
                    )
                }
            } else {
                // Nearest upsample rgba16f into full layer
                var srcBytes = [UInt16](repeating: 0, count: src.width * src.height * 4)
                srcBytes.withUnsafeMutableBytes { buf in
                    src.getBytes(
                        buf.baseAddress!,
                        bytesPerRow: src.width * 8,
                        from: MTLRegionMake2D(0, 0, src.width, src.height),
                        mipmapLevel: 0
                    )
                }
                var dst = [UInt16](repeating: 0, count: maxW * maxH * 4)
                for y in 0..<maxH {
                    let sy = min(src.height - 1, y * src.height / maxH)
                    for x in 0..<maxW {
                        let sx = min(src.width - 1, x * src.width / maxW)
                        let si = (sy * src.width + sx) * 4
                        let di = (y * maxW + x) * 4
                        dst[di] = srcBytes[si]
                        dst[di + 1] = srcBytes[si + 1]
                        dst[di + 2] = srcBytes[si + 2]
                        dst[di + 3] = srcBytes[si + 3]
                    }
                }
                dst.withUnsafeBytes { buf in
                    array.replace(
                        region: MTLRegionMake2D(0, 0, maxW, maxH),
                        mipmapLevel: 0,
                        slice: i,
                        withBytes: buf.baseAddress!,
                        bytesPerRow: maxW * 8,
                        bytesPerImage: maxW * maxH * 8
                    )
                }
            }
        }
        array.label = "specular_ibl_array"
        return array
    }

    private static func makeSolidTexture(device: MTLDevice, color: SIMD4<Float>) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        var bytes: [UInt8] = [
            UInt8(max(0, min(255, Int(color.x * 255)))),
            UInt8(max(0, min(255, Int(color.y * 255)))),
            UInt8(max(0, min(255, Int(color.z * 255)))),
            UInt8(max(0, min(255, Int(color.w * 255))))
        ]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        return t
    }
}
