import Foundation
import Metal

extension DustScreenTile {
    /// The tile's texture, with its mipmaps, its lut's, and its description.
    static func load(_ path: String, device: MTLDevice) throws -> (
        texture: MTLTexture, lut: MTLTexture?, tile: DustScreenTile
    ) {
        let url = URL(fileURLWithPath: path)
        let tile = try JSONDecoder().decode(DustScreenTile.self, from: Data(contentsOf: url))
        let limit = 16_384
        guard (1...limit).contains(tile.width), (2...limit).contains(tile.height), tile.radii.count == 2,
            tile.radii[0] >= 0, tile.radii[1] > tile.radii[0]
        else {
            throw RenderError.pipelineCreation(
                "dust screen \(path): width and height 1 to \(limit), radii two rising distances")
        }
        let folder = url.deletingLastPathComponent()
        let scores = tile.lut != nil
        let texture = try Self.texture(
            URL(fileURLWithPath: tile.data, relativeTo: folder), tile.width, tile.height,
            floor: scores ? -60_000 : 0, mipmapped: true, device: device)
        guard let lut = tile.lut else { return (texture, nil, tile) }
        guard (2...limit).contains(lut.width), lut.range.count == 2, lut.range[1] > lut.range[0] else {
            throw RenderError.pipelineCreation("dust screen \(path): lut width 2 to \(limit), range rising")
        }
        let table = try Self.texture(
            URL(fileURLWithPath: lut.data, relativeTo: folder), lut.width, tile.height, floor: 0,
            mipmapped: false, device: device)
        return (texture, table, tile)
    }

    /// A half-float texture of `width` by `height` raw little-endian floats.
    private static func texture(
        _ url: URL, _ width: Int, _ height: Int, floor: Float, mipmapped: Bool, device: MTLDevice
    ) throws -> MTLTexture {
        let raw = try Data(contentsOf: url)
        let count = width * height
        guard raw.count == count * 4 else {
            throw RenderError.pipelineCreation(
                "dust screen \(url.lastPathComponent): \(raw.count) bytes, \(count * 4) expected")
        }
        var halves = [Float16](repeating: 0, count: count)
        raw.withUnsafeBytes { bytes in
            for i in 0..<count {
                let bits = UInt32(littleEndian: bytes.load(fromByteOffset: i * 4, as: UInt32.self))
                halves[i] = Float16(max(min(Float(bitPattern: bits), 60_000), floor))
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.textureAllocation
        }
        halves.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 2)
        }
        if mipmapped {
            guard let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer(),
                let blit = buffer.makeBlitCommandEncoder()
            else { throw RenderError.textureAllocation }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}
