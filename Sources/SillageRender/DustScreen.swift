import Foundation
import Metal

/// A dust screen (#506): a galaxy's dust drawn from a map laid in its disk's plane rather than
/// from where its grains stand. The map is a polar tile (azimuth across, radius down) of the
/// dust's column across the plane, read where the pixel's ray meets the disk's mid-plane at
/// every angle, edge on included, and carried round by the disk's rotation from the moment it
/// rests at; the grains, drawn into the web's carrier at the frame's resolution, only say how
/// the dust is shared among the slabs, and where there is none. A flight's `inside.dustScreen`
/// names it; absent, the web is drawn as always. Metal only.
public struct DustScreenRef: Codable, Sendable, Equatable {
    /// The tile's description (`DustScreenTile`), a JSON file.
    public var tile: String
    /// The galaxy whose dust it draws.
    public var galaxy: Int = 0
    /// The moment, in megayears of the take, at which the tile lies in the plane as written:
    /// before and after it, each radius is turned by the disk's rotation there.
    public var rest: Float = 0
    /// The dust a unit of the tile's column lays in the frame, as `dustStrength` does a grain's.
    public var depth: Float = 1
    /// The colour law the dust is seen through (#499's `law=hubble`); absent, the look's
    /// reddening as for any dust.
    public var law: DustScreenLaw?
    /// How often, in megayears, the pattern is born again (#506): two realizations half a period
    /// apart, each unsheared at its own rest and cross-faded, so that what shows is never wound
    /// by more than half a period; the one resting at `rest` is the tile as written. 0, the
    /// default, keeps one realization wound from `rest` for ever.
    public var renew: Float = 0
    /// Keeps the screen only where the line of sight runs along the radius (#506): from none
    /// at the first radial share of the line of sight in the plane to all of it at the second,
    /// the grains' own dust in its place elsewhere (the ring's tips), and the colour law's rim
    /// with it. Absent, the screen everywhere.
    public var front: [Float]?

    public init(tile: String, galaxy: Int = 0, rest: Float = 0, depth: Float = 1) {
        self.tile = tile
        self.galaxy = galaxy
        self.rest = rest
        self.depth = depth
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tile = try c.decode(String.self, forKey: .tile)
        galaxy = try c.value(.galaxy, or: galaxy)
        rest = try c.value(.rest, or: rest)
        depth = try c.value(.depth, or: depth)
        law = try c.decodeIfPresent(DustScreenLaw.self, forKey: .law)
        renew = try c.value(.renew, or: renew)
        front = try c.decodeIfPresent([Float].self, forKey: .front)
    }

    var fault: String? {
        if tile.isEmpty { return "dustScreen: a tile" }
        if !FileManager.default.fileExists(atPath: tile) { return "dustScreen tile \(tile): no such file" }
        if !(0...255).contains(galaxy) { return "dustScreen galaxy \(galaxy): 0 to 255" }
        if !rest.isFinite { return "dustScreen rest \(rest): a moment in megayears" }
        if !(depth >= 0 && depth <= 1000) { return "dustScreen depth \(depth): 0 to 1000" }
        if let fault = law?.fault { return fault }
        if let front, !(front.count == 2 && front[0] >= 0 && front[1] > front[0] && front[1] <= 1) {
            return "dustScreen front \(front): two rising shares, 0 to 1"
        }
        if !(renew == 0 || (renew >= 1 && renew <= 1000)) {
            return "dustScreen renew \(renew): 0, or 1 to 1000 megayears"
        }
        return nil
    }
}

/// A screen's colour law: each channel's optical depth a share of the green's, `a` in thin dust
/// tending to one as the green's passes `t` (share = 1 + (a - 1) / (1 + tau / t)), as red, blue
/// and t; the rim, the dust within `rimRadii` of the galaxy's centre (all of it inside the first,
/// none past the second), takes `rim`, the rest `diffuse`. The bench's fit to Hubble (#499):
/// diffuse [0.19, 1.95, 3.5], rim [0.20, 1.68, 0.37].
public struct DustScreenLaw: Codable, Sendable, Equatable {
    public var diffuse: [Float]
    public var rim: [Float]
    public var rimRadii: [Float]

    var fault: String? {
        let shares = [diffuse, rim].allSatisfy { $0.count == 3 && $0.allSatisfy { $0 > 0 && $0.isFinite } }
        if !shares { return "dustScreen law: diffuse and rim are three numbers above 0, red, blue and t" }
        if !(rimRadii.count == 2 && rimRadii[0] >= 0 && rimRadii[1] > rimRadii[0]) {
            return "dustScreen law rimRadii \(rimRadii): two rising distances in kpc"
        }
        return nil
    }
}

/// A screen's tile on disk: `width` azimuths from -pi to pi (cell centres, -pi/2 on the disk's
/// -v axis) by `height` radii from `radii[0]` to `radii[1]` kiloparsecs, in `data`, raw
/// little-endian 32-bit floats row by row (a path beside the description's), each the dust's
/// column across the plane there, in units the screen's `depth` turns into the frame's dust.
/// With a `lut` the tile holds standard normal scores instead, and the column at a radius is
/// the lut's row for that radius read at the score (`range` the scores its `width` columns
/// span): two realizations blended with their variance kept still give the column's own
/// statistics, radius by radius.
struct DustScreenTile: Codable {
    var width: Int
    var height: Int
    var radii: [Float]
    var data: String
    var lut: Lut?

    struct Lut: Codable {
        var data: String
        var width: Int
        var range: [Float]
    }

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

/// What the web's resolve reads of a screen; mirrors `ScreenUniforms` in `Shaders`.
struct ScreenUniforms {
    /// The galaxy plus one (0: no screen), the tile's inner and outer radii in kpc, and the
    /// moment it rests at in time units.
    var shape: SIMD4<Float> = .zero
    /// The dust a unit of the tile lays.
    var depth: SIMD4<Float> = .zero
    /// The renewal period in time units (0: none), whether the tile holds scores read through
    /// its lut, and the scores the lut spans.
    var renew: SIMD4<Float> = .zero
    /// Whether the screen is kept by the radial share of the line of sight, and between which.
    var front: SIMD4<Float> = .zero

    static func front(_ ref: DustScreenRef?) -> SIMD4<Float> {
        guard let front = ref?.front else { return .zero }
        return SIMD4(1, front[0], front[1], 0)
    }
}

/// What the light fragments read of a screen's colour law; mirrors `ScreenLaw` in `Shaders`.
struct ScreenLaw {
    var diffuse: SIMD4<Float> = .zero
    var rim: SIMD4<Float> = .zero
    var radii: SIMD4<Float> = .zero
    var front: SIMD4<Float> = .zero
    var eye: SIMD4<Float> = .zero
    var right: SIMD4<Float> = .zero
    var up: SIMD4<Float> = .zero
    var forward: SIMD4<Float> = .zero
    var target = SIMD4<Float>(1, 1, 1, 0)

    init(_ screen: DustScreenRef?, web: WebUniforms?) {
        guard let screen, let law = screen.law, let web else { return }
        diffuse = SIMD4(law.diffuse[0], law.diffuse[1], law.diffuse[2], 0)
        rim = SIMD4(law.rim[0], law.rim[1], law.rim[2], 0)
        radii = SIMD4(law.rimRadii[0], law.rimRadii[1], Float(screen.galaxy), 1)
        front = ScreenUniforms.front(screen)
        eye = web.eye
        right = web.right
        up = web.up
        forward = web.forward
        target = web.target
    }
}
