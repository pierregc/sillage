import Foundation
import SillageCore

/// A dust screen as the CUDA engine holds it (#513): the tile with the levels Metal's
/// `generateMipmaps` makes, its lut, every value a half float as Metal's r16Float textures keep
/// it, and what the web's resolve reads of it, as `Renderer.encodeSplat` sets it. Metal's own
/// textures are made by `DustScreenMetal.swift`.
public struct DustScreenTexels: Sendable {
    /// Level 0 first, each level half the one before on each side, never under 1, each texel
    /// the mean of the two by two above it.
    public let tile: [Float]
    public let width: Int
    public let height: Int
    public let levels: Int
    /// `lutWidth` values by `height`; empty for a tile of columns.
    public let lut: [Float]
    public let lutWidth: Int
    public let uniforms: ScreenUniforms

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Refuses what Metal draws without, by name: a tile it cannot read, and dabs on a tile
    /// without a lut.
    public init(_ ref: DustScreenRef) throws {
        let path = ref.tile
        let url = URL(fileURLWithPath: path)
        let tile: DustScreenTile
        do {
            tile = try JSONDecoder().decode(DustScreenTile.self, from: Data(contentsOf: url))
        } catch {
            throw Failure(description: "dust screen \(path): \(error)")
        }
        let limit = 16_384
        guard (1...limit).contains(tile.width), (2...limit).contains(tile.height), tile.radii.count == 2,
            tile.radii[0] >= 0, tile.radii[1] > tile.radii[0]
        else {
            throw Failure(
                description: "dust screen \(path): width and height 1 to \(limit), radii two rising distances"
            )
        }
        if let lut = tile.lut,
            !((2...limit).contains(lut.width) && lut.range.count == 2 && lut.range[1] > lut.range[0])
        {
            throw Failure(description: "dust screen \(path): lut width 2 to \(limit), range rising")
        }
        if ref.dabs != nil, tile.lut == nil {
            throw Failure(description: "dust screen \(path): dabs need a tile with a lut")
        }
        let folder = url.deletingLastPathComponent()
        var level = try Self.halves(
            URL(fileURLWithPath: tile.data, relativeTo: folder), tile.width, tile.height,
            floor: tile.lut != nil ? -60_000 : 0)
        var texels = level
        var size = (tile.width, tile.height)
        var count = 1
        while size.0 > 1 || size.1 > 1 {
            let next = (max(size.0 / 2, 1), max(size.1 / 2, 1))
            level = Self.halved(level, size, next)
            texels += level
            size = next
            count += 1
        }
        self.tile = texels
        width = tile.width
        height = tile.height
        levels = count
        if let lut = tile.lut {
            self.lut = try Self.halves(
                URL(fileURLWithPath: lut.data, relativeTo: folder), lut.width, tile.height, floor: 0)
            lutWidth = lut.width
        } else {
            self.lut = []
            lutWidth = 0
        }
        uniforms = ScreenUniforms(ref, tile: tile)
    }

    /// `width` by `height` raw little-endian floats, each held within `floor` and 60,000 and
    /// rounded to a half float.
    private static func halves(_ url: URL, _ width: Int, _ height: Int, floor: Float) throws -> [Float] {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw Failure(description: "dust screen \(url.lastPathComponent): \(error)")
        }
        let count = width * height
        guard raw.count == count * 4 else {
            throw Failure(
                description: "dust screen \(url.lastPathComponent): \(raw.count) bytes, \(count * 4) expected"
            )
        }
        return raw.withUnsafeBytes { bytes in
            (0..<count).map { i in
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                return Float(Float16(max(min(Float(bitPattern: bits), 60_000), floor)))
            }
        }
    }

    /// The next level: each texel the mean of the two by two above it, the last row or column
    /// of an odd side read twice.
    private static func halved(_ above: [Float], _ from: (Int, Int), _ to: (Int, Int)) -> [Float] {
        var level = [Float](repeating: 0, count: to.0 * to.1)
        for y in 0..<to.1 {
            let y0 = min(2 * y, from.1 - 1)
            let y1 = min(2 * y + 1, from.1 - 1)
            for x in 0..<to.0 {
                let x0 = min(2 * x, from.0 - 1)
                let x1 = min(2 * x + 1, from.0 - 1)
                let sum =
                    above[y0 * from.0 + x0] + above[y0 * from.0 + x1] + above[y1 * from.0 + x0]
                    + above[y1 * from.0 + x1]
                level[y * to.0 + x] = Float(Float16(0.25 * sum))
            }
        }
        return level
    }
}

extension ScreenUniforms {
    /// What `Renderer.encodeSplat` sets for `ref` over its tile.
    init(_ ref: DustScreenRef, tile: DustScreenTile) {
        self.init()
        front = Self.front(ref)
        if let lut = tile.lut {
            renew = SIMD4(ref.renew / Float(Physics.megayearsPerTimeUnit), 1, lut.range[0], lut.range[1])
        } else {
            renew = SIMD4(ref.renew / Float(Physics.megayearsPerTimeUnit), 0, 0, 1)
        }
        shape = SIMD4(
            Float(ref.galaxy + 1), tile.radii[0], tile.radii[1],
            ref.rest / Float(Physics.megayearsPerTimeUnit))
        depth = SIMD4(ref.depth, 0, 0, 0)
        dabs(ref.dabs)
    }
}
