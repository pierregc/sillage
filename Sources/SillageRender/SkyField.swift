#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// A deep sky behind the scene (#512): field stars, the brightest with a telescope's four
/// diffraction spikes, and small distant galaxies, drawn per pixel from a seeded hash of the
/// direction, so the sky is fixed in space, has no parallax and costs no memory. Ten levels of
/// cells on an equi-angular cube, each four times as many objects as the one before and
/// fainter. The sky is drawn at its full depth at `fieldOfView` over `height` pixels; a coarser
/// pixel, from a wider view or a smaller frame, sees each object's light fall as the pixel's
/// solid angle to the power `depth` over two, as a camera of one focal ratio does at `depth` 2:
/// the faint ones go, the sky's count per frame stays about the same, and from inside a disk
/// it is all but gone. Behind every slab of dust. Metal only.
public struct SkyField: Codable, Sendable, Equatable {
    /// The light of a mid-level object, a little under a hundred and fifty in the 8-bit frame of
    /// a 4K still at `fieldOfView`. Zero draws no sky.
    public var brightness: Float
    /// Objects per frame against the default.
    public var density: Float
    /// The view the sky is drawn at its full depth in: a vertical field of view, in radians,
    /// over a frame of `height` pixels. Hubble's Sombrero framed as the film does.
    public var fieldOfView: Float
    public var height: Float
    /// How fast the faint objects fade in a coarser pixel: 2 is a camera of one focal ratio.
    public var depth: Float
    /// Share of each object's light thrown into the four spikes; zero draws none.
    public var spikes: Float
    /// The spikes' angle on the frame, in radians.
    public var spikeAngle: Float
    /// How many of the objects are galaxies, against the default.
    public var galaxies: Float
    /// Width of a star, in output pixels.
    public var starWidth: Float
    public var seed: Int

    public init(
        brightness: Float = 1, density: Float = 1, fieldOfView: Float = 0.018632,
        height: Float = 2160, depth: Float = 2, spikes: Float = 1, spikeAngle: Float = 0,
        galaxies: Float = 1, starWidth: Float = 0.65, seed: Int = 1
    ) {
        self.brightness = brightness
        self.density = density
        self.fieldOfView = fieldOfView
        self.height = height
        self.depth = depth
        self.spikes = spikes
        self.spikeAngle = spikeAngle
        self.galaxies = galaxies
        self.starWidth = starWidth
        self.seed = seed
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkyField()
        self.init(
            brightness: try c.value(.brightness, or: d.brightness),
            density: try c.value(.density, or: d.density),
            fieldOfView: try c.value(.fieldOfView, or: d.fieldOfView),
            height: try c.value(.height, or: d.height),
            depth: try c.value(.depth, or: d.depth),
            spikes: try c.value(.spikes, or: d.spikes),
            spikeAngle: try c.value(.spikeAngle, or: d.spikeAngle),
            galaxies: try c.value(.galaxies, or: d.galaxies),
            starWidth: try c.value(.starWidth, or: d.starWidth),
            seed: try c.value(.seed, or: d.seed))
    }
}

/// What the sky's pass reads; mirrors `SkyParams` in `Shaders`.
struct SkyParams {
    /// The camera's axes; `right.w` and `up.w` the tangents of the half fields.
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    /// The target's width and height, the supersampling, and the light kept for a pixel this
    /// size against the reference.
    var size: SIMD4<Float>
    /// Brightness, the share of a cell holding an object, the spikes' share, the galaxies'.
    var field: SIMD4<Float>
    /// The spikes' cosine and sine, the seed, a star's width in output pixels.
    var more: SIMD4<Float>
    /// Pixels a cell of the coarsest level spans, and the reference pixel's size in radians.
    var scale: SIMD4<Float>

    /// Cells along a face's edge at the coarsest level.
    static let coarsest: Float = 20

    init(_ sky: SkyField, camera: Camera, width: Int, height: Int, supersample: Int) {
        let forward = simd_normalize(camera.target - camera.eye)
        let right = simd_normalize(simd_cross(forward, camera.up))
        let up = simd_cross(right, forward)
        let tangent = tan(camera.fieldOfView / 2)
        let aspect = Float(width) / Float(max(height, 1))
        // One output pixel, in radians, against the reference's.
        let pixel = 2 * tangent / Float(max(height, 1))
        let reference = 2 * tan(sky.fieldOfView / 2) / max(sky.height, 1)
        let kept = pow(reference / max(pixel, 1e-12), sky.depth)
        self.right = SIMD4(right, tangent * aspect)
        self.up = SIMD4(up, tangent)
        self.forward = SIMD4(forward, 0)
        self.size = SIMD4(
            Float(width * supersample), Float(height * supersample), Float(supersample), kept)
        self.field = SIMD4(
            sky.brightness, 0.5 * max(sky.density, 0), max(sky.spikes, 0), max(sky.galaxies, 0))
        self.more = SIMD4(
            cos(sky.spikeAngle), sin(sky.spikeAngle), Float(UInt32(truncatingIfNeeded: sky.seed) % 65_521),
            max(sky.starWidth, 0.3))
        // A coarsest cell is half pi over `coarsest` radians wide.
        self.scale = SIMD4(Float.pi / 2 / Self.coarsest / pixel, reference, 0, 0)
    }
}
