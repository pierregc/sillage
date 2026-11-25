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
/// pixel sees each object's light fall as the pixel's solid angle, as a camera of one focal
/// ratio does, so a 1080p frame is the 4K one reduced, and a view wider than the reference by
/// `depth` past that: the faint ones go, and from inside a disk the sky is all but gone. Behind
/// every slab of dust. Metal only.
public struct SkyField: Codable, Sendable, Equatable {
    /// The light of a mid-level object: 0.07 lands the counts of Hubble's frame of the Sombrero
    /// in a 4K still at `fieldOfView`. Zero draws no sky.
    public var brightness: Float
    /// Objects per frame against the default.
    public var density: Float
    /// The view the sky is drawn at its full depth in: a vertical field of view, in radians,
    /// over a frame of `height` pixels. Hubble's Sombrero framed as the film does.
    public var fieldOfView: Float
    public var height: Float
    /// How fast the faint objects fade in a view wider than `fieldOfView`: 2 is a camera of one
    /// focal ratio, which keeps the count per frame but fills a wide view with faint stars;
    /// above 2, fewer. A smaller frame always sees them as a camera of one focal ratio would.
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
    /// Share of the camera's turns the sky shows: 1 holds it fixed in space; below, it turns
    /// that share of the camera's turn from `anchor`, so a telephoto orbiting a galaxy sees it
    /// drift gently rather than race past, rolls and banks included.
    public var turn: Float
    /// The view the sky is where it is at any `turn`, and its up.
    public var anchor: SIMD3<Float>
    public var anchorUp: SIMD3<Float>

    public init(
        brightness: Float = 1, density: Float = 1, fieldOfView: Float = 0.018632,
        height: Float = 2160, depth: Float = 2, spikes: Float = 1, spikeAngle: Float = 0,
        galaxies: Float = 1, starWidth: Float = 0.65, seed: Int = 1, turn: Float = 1,
        anchor: SIMD3<Float> = SIMD3(0, 1, 0), anchorUp: SIMD3<Float> = SIMD3(0, 0, 1)
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
        self.turn = turn
        self.anchor = anchor
        self.anchorUp = anchorUp
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
            seed: try c.value(.seed, or: d.seed),
            turn: try c.value(.turn, or: d.turn),
            anchor: try c.value(.anchor, or: d.anchor),
            anchorUp: try c.value(.anchorUp, or: d.anchorUp))
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
    static let coarsest: Float = 96

    /// The angle between two cameras' views, and between their rolls about it.
    static func turn(from a: Camera, to b: Camera) -> SIMD2<Float> {
        let fa = simd_normalize(a.target - a.eye)
        let fb = simd_normalize(b.target - b.eye)
        let view = acos(min(max(simd_dot(fa, fb), -1), 1))
        let ra = simd_normalize(simd_cross(fa, a.up))
        let rb = simd_normalize(simd_cross(fb, b.up))
        let roll = acos(min(max(simd_dot(ra, rb), -1), 1))
        return SIMD2(view, max(roll - view, 0))
    }

    /// The camera's axes as the sky sees them: turned from the anchor's by `share` of the
    /// rotation that takes the anchor's axes to the camera's.
    static func axes(
        right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, sky: SkyField
    ) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let af = simd_normalize(sky.anchor)
        let ar = simd_normalize(simd_cross(af, sky.anchorUp))
        let au = simd_cross(ar, af)
        // The rotation from the anchor's axes to the camera's, as an axis and an angle.
        let twice = simd_cross(ar, right) + simd_cross(au, up) + simd_cross(af, forward)
        let cosine = (simd_dot(ar, right) + simd_dot(au, up) + simd_dot(af, forward) - 1) / 2
        let angle = atan2(simd_length(twice) / 2, cosine)
        guard simd_length(twice) > 1e-7 else { return angle > 1 ? (right, up, forward) : (ar, au, af) }
        let axis = simd_normalize(twice)
        let turned = angle * max(sky.turn, 0)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            v * cos(turned) + simd_cross(axis, v) * sin(turned)
                + axis * simd_dot(axis, v) * (1 - cos(turned))
        }
        return (rotate(ar), rotate(au), rotate(af))
    }

    init(
        _ sky: SkyField, camera: Camera, width: Int, height: Int, supersample: Int,
        turn: SIMD2<Float> = .zero
    ) {
        var forward = simd_normalize(camera.target - camera.eye)
        var right = simd_normalize(simd_cross(forward, camera.up))
        var up = simd_cross(right, forward)
        if sky.turn != 1 {
            (right, up, forward) = Self.axes(right: right, up: up, forward: forward, sky: sky)
        }
        let share = min(max(sky.turn, 0), 1)
        let tangent = tan(camera.fieldOfView / 2)
        let aspect = Float(width) / Float(max(height, 1))
        // One output pixel, in radians, against the reference's.
        let pixel = 2 * tangent / Float(max(height, 1))
        let reference = 2 * tan(sky.fieldOfView / 2) / max(sky.height, 1)
        // Over the pixel's solid angle, as a camera of one focal ratio; a view wider than the
        // reference past that, by `depth`.
        let wider = min(tan(sky.fieldOfView / 2) / max(tangent, 1e-12), 1)
        // A star the turning view drags into a streak of `streak` pixels: its light spread
        // along it, so it fades as a camera's does, and a fast turn does not strobe.
        // Past a few pixels, a safety: a sky that drifts never streaks that far.
        let streak = share * (turn.x / max(pixel, 1e-12) + turn.y * Float(height) / 2)
        let kept =
            pow(reference / max(pixel, 1e-12), 2) * pow(wider, sky.depth - 2)
            / (1 + max(streak - 6, 0) / 6)
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
