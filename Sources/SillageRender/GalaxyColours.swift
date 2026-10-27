import Foundation
import simd

/// One galaxy's entry in a look file's palette: one colour, as every file before #119 holds,
/// or a ramp from core to outskirts with a young and a knot colour, blended into the population
/// colour (#118 chose them, `docs/notes/galaxy-colours.md`).
///
/// A single colour is written as `[r, g, b]`, so an old file reads, renders and writes back
/// exactly as before.
public struct GalaxyColours: Codable, Sendable, Equatable {
    public enum Mapping: String, Codable, Sendable {
        /// Every star on the ramp by its birth radius. The free world.
        case radius
        /// Bulge on the core colour, outskirts on the outer one, gas and young stars on the
        /// young one, disk stars on the ramp. The telescope world.
        case mix
    }

    public struct Ramp: Sendable, Equatable {
        public var mapping: Mapping
        public var core: SIMD3<Float>
        public var disk: SIMD3<Float>
        public var outskirts: SIMD3<Float>
        public var young: SIMD3<Float>
        /// What an ionised knot glows in, in place of the physical HII colour.
        public var knot: SIMD3<Float>
        /// 0 keeps the population colour, 1 draws the ramp alone.
        public var blend: Float

        public init(
            mapping: Mapping, core: SIMD3<Float>, disk: SIMD3<Float>, outskirts: SIMD3<Float>,
            young: SIMD3<Float>, knot: SIMD3<Float>, blend: Float = GalaxyColours.blend
        ) {
            self.mapping = mapping
            self.core = core
            self.disk = disk
            self.outskirts = outskirts
            self.young = young
            self.knot = knot
            self.blend = blend
        }
    }

    /// Region colours of a telescope reference set, in OKLab.
    public struct Regions: Sendable, Equatable {
        public var core, disk, outskirts, young, knot: SIMD3<Float>

        /// Hubble visible, for when no set is on disk.
        public static let hubble = Regions(
            core: SIMD3(0.75, 0.045, 0.086), disk: SIMD3(0.49, 0.006, 0.002),
            outskirts: SIMD3(0.27, -0.017, -0.015), young: SIMD3(0.68, -0.022, -0.073),
            knot: SIMD3(0.66, 0.085, 0.035))
    }

    /// The galaxy's own colour: the swatch, the plain look, and the tint when there is no ramp.
    public var colour: SIMD3<Float>
    public var ramp: Ramp?

    public init(_ colour: SIMD3<Float>, ramp: Ramp? = nil) {
        self.colour = colour
        self.ramp = ramp
    }

    /// Where the ramp's colours sit, in disk scale lengths of birth radius: core at the
    /// centre, disk from one to 2.4, outskirts from 4.5 out.
    public static let stops = SIMD4<Float>(0, 1.0, 2.4, 4.5)
    /// Below it the ramp washes the population's saturation out; above it the stars lose the
    /// variety their ages give them.
    public static let blend: Float = 0.75
    /// The free colours' chroma is raised this much: blended into the population colour at
    /// the palette's own chroma, colourfulness fell from 95 to 47 on night scene 23.
    public static let freeChroma: Float = 1.8
    /// How far a telescope galaxy's own colour tints its ramp, to keep galaxies apart.
    public static let telescopeIdentity: Float = 0.3

    /// The ramp #118 chose for `colour` in its world. `family` names the free family whose
    /// other arc colours the outskirts; `regions` the telescope set the colours come from.
    public static func ramped(
        _ colour: SIMD3<Float>, world: Palette.World, family: String? = nil,
        regions: Regions? = nil
    ) -> GalaxyColours {
        switch world {
        case .telescope:
            let set = regions ?? .hubble
            let own = normalised(colour)
            func tinted(_ lab: SIMD3<Float>) -> SIMD3<Float> {
                let base = normalised(OKLab.rgb(lab: lab))
                return normalised(base * (1 + (own - 1) * telescopeIdentity))
            }
            return GalaxyColours(
                colour,
                ramp: Ramp(
                    mapping: .mix, core: tinted(set.core), disk: tinted(set.disk),
                    outskirts: tinted(set.outskirts), young: tinted(set.young),
                    knot: tinted(set.knot)))
        case .free:
            let lch = OKLab.lch(colour)
            let (lightness, chroma, hue) = (lch.x, lch.y * freeChroma, lch.z)
            let core = OKLab.rgb(
                lch: SIMD3(min(lightness + 0.08, 0.95), chroma * 0.45, toward(hue, 75, by: 40)))
            let named = PaletteFamily.free.first { $0.name == family }
            let outerHue: Float
            if let named, named.hues.count > 1 {
                let other = named.hues.first { $0.distance(to: hue) > 1 } ?? named.hues[1]
                outerHue = other.nearest(to: hue + 180)
            } else if let named {
                outerHue = named.nearest(to: hue + 50)
            } else {
                outerHue = hue + 50
            }
            let outer = normalised(OKLab.rgb(lch: SIMD3(lightness, chroma, outerHue)))
            let knot = normalised(
                simd_mix(SIMD3<Float>(1.00, 0.34, 0.30), normalised(colour), SIMD3(repeating: 0.4)))
            return GalaxyColours(
                colour,
                ramp: Ramp(
                    mapping: .radius, core: normalised(core),
                    disk: normalised(OKLab.rgb(lch: SIMD3(lightness, chroma, hue))),
                    outskirts: outer, young: outer, knot: knot))
        }
    }

    /// Every colour turned by `transform`, the ramp's with the galaxy's own.
    public func map(_ transform: (SIMD3<Float>) -> SIMD3<Float>) -> GalaxyColours {
        var out = GalaxyColours(transform(colour), ramp: ramp)
        if var ramp {
            ramp.core = transform(ramp.core)
            ramp.disk = transform(ramp.disk)
            ramp.outskirts = transform(ramp.outskirts)
            ramp.young = transform(ramp.young)
            ramp.knot = transform(ramp.knot)
            out.ramp = ramp
        }
        return out
    }

    /// The colour at `radius` scale lengths along the ramp, as the shader reads it.
    public func colour(atScaleLengths radius: Float) -> SIMD3<Float> {
        guard let ramp else { return colour }
        let s = Self.stops
        let inner = simd_mix(
            ramp.core, ramp.disk, SIMD3(repeating: min(max((radius - s.x) / (s.y - s.x), 0), 1)))
        let outer = min(max((radius - s.z) / (s.w - s.z), 0), 1)
        return simd_mix(inner, ramp.outskirts, SIMD3(repeating: outer))
    }

    /// Unit luminance, as every emitter in the shader.
    static func normalised(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_max(rgb, SIMD3(repeating: 0))
        return c / max(simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)), 1e-4)
    }

    /// `hue` moved `limit` degrees at most toward `target`, the short way round.
    static func toward(_ hue: Float, _ target: Float, by limit: Float) -> Float {
        var d = (target - hue).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return hue + max(min(d, limit), -limit)
    }

    private enum CodingKeys: String, CodingKey {
        case colour, mapping, core, disk, outskirts, young, knot, blend
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(SIMD3<Float>.self) {
            self.init(single)
            return
        }
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try c.decode(SIMD3<Float>.self, forKey: .colour),
            ramp: Ramp(
                mapping: try c.decode(Mapping.self, forKey: .mapping),
                core: try c.decode(SIMD3<Float>.self, forKey: .core),
                disk: try c.decode(SIMD3<Float>.self, forKey: .disk),
                outskirts: try c.decode(SIMD3<Float>.self, forKey: .outskirts),
                young: try c.decode(SIMD3<Float>.self, forKey: .young),
                knot: try c.decode(SIMD3<Float>.self, forKey: .knot),
                blend: try c.value(.blend, or: Self.blend)))
    }

    public func encode(to encoder: any Encoder) throws {
        guard let ramp else {
            var single = encoder.singleValueContainer()
            try single.encode(colour)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(colour, forKey: .colour)
        try c.encode(ramp.mapping, forKey: .mapping)
        try c.encode(ramp.core, forKey: .core)
        try c.encode(ramp.disk, forKey: .disk)
        try c.encode(ramp.outskirts, forKey: .outskirts)
        try c.encode(ramp.young, forKey: .young)
        try c.encode(ramp.knot, forKey: .knot)
        try c.encode(ramp.blend, forKey: .blend)
    }
}

extension Palette {
    /// The palette as a look file holds it: each colour with the ramp of its world.
    public func galaxyColours(
        references: [TelescopeReference] = TelescopeReference.repository
    ) -> [GalaxyColours] {
        let regions =
            world == .telescope
            ? (references.first { $0.name == family }
                ?? references.first {
                    $0.name == "hubble-visible"
                })?.ramp : nil
        return colours.map {
            GalaxyColours.ramped($0, world: world, family: family, regions: regions)
        }
    }
}

/// One galaxy's ramp as the splat shader reads it; mirrors `GalaxyRamp` in `Shaders`.
struct GalaxyRamp {
    var core: SIMD4<Float>
    var disk: SIMD4<Float>
    var outskirts: SIMD4<Float>
    var young: SIMD4<Float>
    var knot: SIMD4<Float>
    var stops: SIMD4<Float>
    /// Blend, mix mapping (0 or 1), whether the galaxy has a ramp at all (0 or 1).
    var params: SIMD4<Float>

    static let none = GalaxyRamp(
        core: .zero, disk: .zero, outskirts: .zero, young: .zero, knot: .zero, stops: .zero,
        params: .zero)

    init(
        core: SIMD4<Float>, disk: SIMD4<Float>, outskirts: SIMD4<Float>, young: SIMD4<Float>,
        knot: SIMD4<Float>, stops: SIMD4<Float>, params: SIMD4<Float>
    ) {
        self.core = core
        self.disk = disk
        self.outskirts = outskirts
        self.young = young
        self.knot = knot
        self.stops = stops
        self.params = params
    }

    init(_ entry: GalaxyColours) {
        guard let ramp = entry.ramp else {
            self = .none
            return
        }
        func f4(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(c, 0) }
        self.init(
            core: f4(ramp.core), disk: f4(ramp.disk), outskirts: f4(ramp.outskirts),
            young: f4(ramp.young), knot: f4(ramp.knot), stops: GalaxyColours.stops,
            params: SIMD4(ramp.blend, ramp.mapping == .mix ? 1 : 0, 1, 0))
    }
}
