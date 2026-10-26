import Foundation
import SillageCore
import simd

/// OKLab and its polar form OKLCH (Björn Ottosson, 2020), from and to the linear sRGB the
/// renderer takes. OKLCH is `(L, C, h)` with the hue in degrees.
public enum OKLab {
    public static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let r = Double(rgb.x)
        let g = Double(rgb.y)
        let b = Double(rgb.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            Float(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
            Float(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
            Float(0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s))
    }

    public static func rgb(lab: SIMD3<Float>) -> SIMD3<Float> {
        let light = Double(lab.x)
        let a = Double(lab.y)
        let b = Double(lab.z)
        let l = pow3(light + 0.3963377774 * a + 0.2158037573 * b)
        let m = pow3(light - 0.1055613458 * a - 0.0638541728 * b)
        let s = pow3(light - 0.0894841775 * a - 1.2914855480 * b)
        return SIMD3(
            Float(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            Float(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            Float(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    public static func lch(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let lab = lab(rgb)
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        return SIMD3(lab.x, hypot(lab.y, lab.z), hue)
    }

    public static func rgb(lch: SIMD3<Float>) -> SIMD3<Float> {
        let angle = lch.z * .pi / 180
        return rgb(lab: SIMD3(lch.x, lch.y * cos(angle), lch.y * sin(angle)))
    }

    private static func pow3(_ x: Double) -> Double { x * x * x }
}

/// One colour per galaxy and where it came from, so a palette can be drawn again from its seed
/// or named in the editor. The colours alone decide what is drawn.
public struct Palette: Codable, Sendable, Equatable {
    public enum World: String, Codable, Sendable, CaseIterable {
        /// Close to the pictures Hubble and Webb publish.
        case telescope
        /// Chosen for beauty alone.
        case free
    }

    public enum Harmony: String, Codable, Sendable, CaseIterable {
        case analogous, complementary
        case splitComplementary = "split-complementary"
        case triadic, tetradic, monochrome

        /// Where each galaxy sits around the wheel from the first one, in degrees. Past the
        /// end the anchors repeat, shifted by `spread`.
        func anchors(spread: Float) -> [Float] {
            switch self {
            case .analogous: [0, spread, -spread, 2 * spread, -2 * spread]
            case .complementary: [0, 180, spread, 180 + spread, -spread]
            case .splitComplementary: [0, 150, 210, spread, -spread]
            case .triadic: [0, 120, 240, spread, 120 + spread]
            case .tetradic: [0, 90, 180, 270, spread]
            case .monochrome: [0]
            }
        }
    }

    public var world: World
    public var family: String
    public var harmony: Harmony
    public var seed: UInt64
    public var colours: [SIMD3<Float>]

    public init(
        world: World, family: String, harmony: Harmony, seed: UInt64, colours: [SIMD3<Float>]
    ) {
        self.world = world
        self.family = family
        self.harmony = harmony
        self.seed = seed
        self.colours = colours
    }

    public var name: String { "\(family)-\(harmony.rawValue)-\(seed)" }
}

/// A range of hues, in degrees. `through` may pass 360 to wrap around red.
public struct HueArc: Sendable, Equatable {
    public var from: Float
    public var through: Float

    public init(_ from: Float, _ through: Float) {
        self.from = from
        self.through = through
    }

    var length: Float { through - from }

    /// `hue` if it is inside, else the nearer end, going round the wheel.
    func nearest(to hue: Float) -> Float {
        let h = wrapped(hue)
        for turn: Float in [-360, 0, 360] where h + turn >= from && h + turn <= through {
            return h
        }
        let toStart = circular(h, from)
        let toEnd = circular(h, through)
        return wrapped(toStart <= toEnd ? from : through)
    }

    func distance(to hue: Float) -> Float { circular(nearest(to: hue), hue) }
}

func wrapped(_ hue: Float) -> Float {
    let h = hue.truncatingRemainder(dividingBy: 360)
    return h < 0 ? h + 360 : h
}

func circular(_ a: Float, _ b: Float) -> Float {
    let d = abs(wrapped(a) - wrapped(b))
    return min(d, 360 - d)
}

/// A family of colours: where on the wheel, how vivid and how light. Chroma and lightness are
/// OKLCH's.
public struct PaletteFamily: Sendable, Equatable {
    public var name: String
    public var world: Palette.World
    public var hues: [HueArc]
    public var chroma: ClosedRange<Float>
    public var lightness: ClosedRange<Float>
    /// Said aloud wherever the family is used, for one that stands in for something missing.
    public var note: String?

    public init(
        name: String, world: Palette.World, hues: [HueArc], chroma: ClosedRange<Float>,
        lightness: ClosedRange<Float>, note: String? = nil
    ) {
        self.name = name
        self.world = world
        self.hues = hues
        self.chroma = chroma
        self.lightness = lightness
        self.note = note
    }

    func nearest(to hue: Float) -> Float {
        hues.min { $0.distance(to: hue) < $1.distance(to: hue) }!.nearest(to: hue)
    }

    public static let free: [PaletteFamily] = [
        PaletteFamily(
            name: "nebula", world: .free, hues: [HueArc(285, 375), HueArc(185, 230)],
            chroma: 0.08...0.17, lightness: 0.74...0.9),
        PaletteFamily(
            name: "ember", world: .free, hues: [HueArc(20, 90)], chroma: 0.08...0.17,
            lightness: 0.76...0.92),
        PaletteFamily(
            name: "ice-and-fire", world: .free, hues: [HueArc(195, 255), HueArc(20, 65)],
            chroma: 0.07...0.16, lightness: 0.76...0.92),
        PaletteFamily(
            name: "aurora", world: .free, hues: [HueArc(135, 195), HueArc(290, 335)],
            chroma: 0.08...0.16, lightness: 0.78...0.93),
        PaletteFamily(
            name: "pastel", world: .free, hues: [HueArc(0, 360)], chroma: 0.055...0.09,
            lightness: 0.86...0.95),
        PaletteFamily(
            name: "gold-and-ink", world: .free, hues: [HueArc(70, 100), HueArc(245, 285)],
            chroma: 0.07...0.15, lightness: 0.76...0.92),
        PaletteFamily(
            name: "spectrum", world: .free, hues: [HueArc(0, 360)], chroma: 0.08...0.16,
            lightness: 0.76...0.92),
    ]

    /// Stands in for the families measured on Hubble and Webb images (#125) until their files
    /// exist: warm cores, blue arms and pink knots, judged by eye on published pictures.
    public static let telescopePlaceholder = PaletteFamily(
        name: "telescope-placeholder", world: .telescope,
        hues: [HueArc(60, 95), HueArc(225, 265), HueArc(355, 385)], chroma: 0.05...0.12,
        lightness: 0.8...0.95,
        note: "telescope colours are a placeholder until references/telescope/*.json exist (#125)")
}

/// Palettes for 1 to 5 galaxies, drawn from a seed: the same input gives the same colours.
public enum PaletteGenerator {
    /// Below this a colour reads dim on black wherever it is drawn as it is: swatches and
    /// the plain look. The full look keeps only its hue and saturation.
    public static let minimumLightness: Float = 0.72
    public static let maximumLightness: Float = 0.96
    /// Past it a tint pushes one channel far over the others and bloom clips it to a flat
    /// primary. The catalogue's own palettes, judged on renders, stay at or under 0.2.
    public static let maximumChroma: Float = 0.19
    /// Largest channel over luminance: what the shader's chromaticity multiplies a channel by
    /// at a tint of one. A saturated blue reaches 14; the catalogue stays under 2.8.
    public static let maximumPeak: Float = 2.6
    /// The shader divides every tint by its luminance, so two colours that differ only in
    /// lightness draw the same. They are compared at this common lightness, on hue and
    /// saturation alone.
    public static let commonLightness: Float = 0.8
    /// Distance in OKLab at the common lightness. About five times the smallest difference
    /// the eye picks out, so two galaxies stay apart once their stars mix.
    public static let minimumDistance: Float = 0.05
    /// Chroma at the common lightness under which a colour reads as white.
    public static let greyChroma: Float = 0.04
    /// Monochrome keeps every galaxy within this many degrees of the first.
    public static let monochromeSpread: Float = 15

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noGalaxies
        case tooManyGalaxies(Int)
        case noFamily(Palette.World, String?)
        case noRoom(family: String?, harmony: Palette.Harmony?, galaxies: Int)

        public var description: String {
            switch self {
            case .noGalaxies: "a palette needs at least one galaxy"
            case .tooManyGalaxies(let count): "a palette holds at most 5 galaxies, not \(count)"
            case .noFamily(let world, let name):
                "no family \(name ?? "at all") in the \(world.rawValue) world"
            case .noRoom(let family, let harmony, let galaxies):
                "\(family ?? "no family") has no room for \(galaxies) galaxies kept apart in "
                    + (harmony?.rawValue ?? "any harmony")
            }
        }
    }

    public static let attempts = 4000

    /// The families of a world: telescope ones read from #125's files when given, else the
    /// placeholder.
    public static func families(
        _ world: Palette.World, telescope: [PaletteFamily] = []
    ) -> [PaletteFamily] {
        switch world {
        case .free: PaletteFamily.free
        case .telescope: telescope.isEmpty ? [PaletteFamily.telescopePlaceholder] : telescope
        }
    }

    /// `family` and `harmony` left out are drawn from the seed, afresh on every attempt.
    public static func palette(
        galaxies: Int, world: Palette.World, family: String? = nil,
        harmony: Palette.Harmony? = nil, seed: UInt64, telescope: [PaletteFamily] = []
    ) throws -> Palette {
        guard galaxies > 0 else { throw Failure.noGalaxies }
        guard galaxies <= 5 else { throw Failure.tooManyGalaxies(galaxies) }
        let pool = families(world, telescope: telescope).filter {
            family == nil || $0.name == family
        }
        guard !pool.isEmpty else { throw Failure.noFamily(world, family) }

        var random = SeededGenerator(seed: seed)
        for _ in 0..<attempts {
            let chosen = pool[Int(random.next() % UInt64(pool.count))]
            let tune =
                harmony
                ?? Palette.Harmony.allCases[
                    Int(random.next() % UInt64(Palette.Harmony.allCases.count))]
            if let colours = draw(galaxies, chosen, tune, &random),
                violations(colours, monochrome: tune == .monochrome).isEmpty
            {
                return Palette(
                    world: world, family: chosen.name, harmony: tune, seed: seed,
                    colours: colours)
            }
        }
        throw Failure.noRoom(family: family, harmony: harmony, galaxies: galaxies)
    }

    /// Every constraint `colours` breaks, in words; empty when it holds them all.
    public static func violations(_ colours: [SIMD3<Float>], monochrome: Bool) -> [String] {
        var broken: [String] = []
        let lch = colours.map(OKLab.lch)
        for (index, colour) in colours.enumerated() {
            let (L, C) = (lch[index].x, lch[index].y)
            if colour.min() < -1e-4 || colour.max() > 1 + 1e-4 {
                broken.append("colour \(index) is outside sRGB")
            }
            if L < minimumLightness - 1e-4 || L > maximumLightness + 1e-4 {
                broken.append("colour \(index) has lightness \(L)")
            }
            if C > maximumChroma + 1e-4 { broken.append("colour \(index) has chroma \(C)") }
            if peak(colour) > maximumPeak + 1e-3 {
                broken.append("colour \(index) peaks at \(peak(colour))")
            }
            if !monochrome && C * commonLightness / L < greyChroma - 1e-4 {
                broken.append("colour \(index) is near grey")
            }
        }
        for i in colours.indices {
            for j in colours.indices where j > i {
                let d = distance(colours[i], colours[j])
                if d < minimumDistance - 1e-4 {
                    broken.append("colours \(i) and \(j) are \(d) apart")
                }
            }
        }
        return broken
    }

    /// OKLab distance once both colours are brought to the common lightness.
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let la = OKLab.lab(a)
        let lb = OKLab.lab(b)
        let pa = SIMD2(la.y, la.z) * (commonLightness / max(la.x, 1e-4))
        let pb = SIMD2(lb.y, lb.z) * (commonLightness / max(lb.x, 1e-4))
        return simd_distance(pa, pb)
    }

    /// Largest channel over luminance.
    public static func peak(_ colour: SIMD3<Float>) -> Float {
        let c = simd_max(colour, SIMD3(repeating: 0))
        return c.max() / max(simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)), 1e-4)
    }

    private static func draw(
        _ count: Int, _ family: PaletteFamily, _ harmony: Palette.Harmony,
        _ random: inout SeededGenerator
    ) -> [SIMD3<Float>]? {
        let lightness =
            max(
                family.lightness.lowerBound, minimumLightness)...min(
                family.lightness.upperBound, maximumLightness)
        let base = hue(in: family, &random)
        let anchors = harmony.anchors(spread: random.uniform(in: 22...40))
        var colours: [SIMD3<Float>] = []
        for index in 0..<count {
            let hue: Float
            let chroma: Float
            if harmony == .monochrome {
                hue = family.nearest(
                    to: base + random.uniform(in: -monochromeSpread...monochromeSpread))
                chroma = random.uniform(in: 0...family.chroma.upperBound)
            } else {
                hue = family.nearest(
                    to: base + anchors[index % anchors.count] + random.uniform(in: -6...6))
                chroma = random.uniform(in: family.chroma)
            }
            guard
                let colour = fitted(
                    lch: SIMD3(random.uniform(in: lightness), chroma, hue),
                    minimumChroma: harmony == .monochrome ? 0 : family.chroma.lowerBound * 0.6)
            else { return nil }
            colours.append(colour)
        }
        return colours
    }

    private static func hue(in family: PaletteFamily, _ random: inout SeededGenerator) -> Float {
        var at = random.uniform() * family.hues.reduce(0) { $0 + $1.length }
        for arc in family.hues {
            if at <= arc.length { return wrapped(arc.from + at) }
            at -= arc.length
        }
        return wrapped(family.hues[0].from)
    }

    /// The colour with its chroma lowered until it is inside sRGB, under the chroma cap and
    /// under the peak; nil when that leaves it greyer than `minimumChroma`.
    private static func fitted(lch: SIMD3<Float>, minimumChroma: Float) -> SIMD3<Float>? {
        func fits(_ chroma: Float) -> SIMD3<Float>? {
            let rgb = OKLab.rgb(lch: SIMD3(lch.x, chroma, lch.z))
            guard rgb.min() >= 0, rgb.max() <= 1, peak(rgb) <= maximumPeak else { return nil }
            return rgb
        }
        let wanted = min(lch.y, maximumChroma)
        if let rgb = fits(wanted) { return rgb }
        var low: Float = 0
        var high = wanted
        guard fits(low) != nil else { return nil }
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if fits(middle) != nil { low = middle } else { high = middle }
        }
        return low >= minimumChroma ? fits(low) : nil
    }
}
