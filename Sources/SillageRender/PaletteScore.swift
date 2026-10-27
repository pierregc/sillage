import Foundation
import SillageCore
import simd

/// How good a palette is, from 0 to 1, without drawing anything: the colours decide. Every part
/// is 0 to 1 too, and the total is their weighted mean.
public struct PaletteScore: Sendable, Equatable {
    /// How far apart the two nearest galaxies' colours are.
    public var separation: Float
    /// How well the hues sit on the harmony's anchors.
    public var harmony: Float
    /// How comfortably chroma and lightness sit inside the generator's ranges.
    public var range: Float
    /// How evenly warm and cool colours share the palette.
    public var balance: Float
    /// How close the colours are to the pictures of #125; only in the telescope world, and only
    /// once the reference files are given.
    public var reference: Float?
    public var total: Float

    /// Distance at which two colours count as fully apart. The generator's own floor is
    /// `PaletteGenerator.minimumDistance`.
    static let apart: Float = 0.08
    /// Distance from the references that scores one half.
    static let referenceScale: Float = 0.035
    /// Hue the warm side of the wheel is centred on, in degrees: orange.
    static let warmHue: Float = 50
    static let weights: (separation: Float, harmony: Float, range: Float, balance: Float, reference: Float) =
        (0.30, 0.20, 0.15, 0.10, 0.25)

    /// `references` are the sets of #125; a palette is compared with the set of its family when
    /// there is one, else with all of them.
    public init(_ palette: Palette, references: [TelescopeReference] = []) {
        let colours = palette.colours
        separation = Self.separation(colours)
        harmony = Self.harmony(colours, palette.harmony)
        range = Self.range(colours, monochrome: palette.harmony == .monochrome)
        balance = Self.balance(colours)
        if palette.world == .telescope, !references.isEmpty {
            let own = references.filter { $0.name == palette.family }
            reference = Self.reference(colours, own.isEmpty ? references : own)
        }
        let w = Self.weights
        var sum =
            w.separation * separation + w.harmony * harmony + w.range * range
            + w.balance * balance
        var weight = w.separation + w.harmony + w.range + w.balance
        if let reference {
            sum += w.reference * reference
            weight += w.reference
        }
        total = sum / weight
    }

    static func separation(_ colours: [SIMD3<Float>]) -> Float {
        guard colours.count > 1 else { return 1 }
        var nearest = Float.infinity
        for i in colours.indices {
            for j in colours.indices where j > i {
                nearest = min(nearest, PaletteGenerator.distance(colours[i], colours[j]))
            }
        }
        return smooth(nearest / apart)
    }

    /// The hues are fitted to the harmony's anchors over every turn of the wheel that puts one
    /// colour on its anchor and every spread the generator draws; the mean miss in degrees
    /// scores 1 at none and 0 at thirty. Colours too grey to have a hue are left out.
    static func harmony(_ colours: [SIMD3<Float>], _ harmony: Palette.Harmony) -> Float {
        let hued = colours.enumerated().compactMap { index, colour -> (Int, Float)? in
            let lch = OKLab.lch(colour)
            guard lch.y * PaletteGenerator.commonLightness / lch.x >= PaletteGenerator.greyChroma
            else { return nil }
            return (index, lch.z)
        }
        guard hued.count > 1 else { return 1 }
        var best = Float.infinity
        for spread in stride(from: Float(22), through: 40, by: 2) {
            let anchors = harmony.anchors(spread: spread)
            func anchor(_ index: Int) -> Float { anchors[index % anchors.count] }
            for (index, hue) in hued {
                let base = hue - anchor(index)
                let miss =
                    hued.reduce(Float(0)) { sum, other in
                        sum + circular(other.1, base + anchor(other.0))
                    } / Float(hued.count)
                best = min(best, miss)
            }
        }
        return 1 - min(best / 30, 1)
    }

    /// Per colour the lesser of two terms, each 1 well inside its range and 0 at its edge or
    /// outside: lightness against the generator's limits, and chroma, at the common lightness,
    /// from the grey floor up to a clear tint and down again towards the cap. A monochrome
    /// palette may be grey.
    static func range(_ colours: [SIMD3<Float>], monochrome: Bool) -> Float {
        guard !colours.isEmpty else { return 0 }
        let sum = colours.reduce(Float(0)) { sum, colour in
            let lch = OKLab.lch(colour)
            guard colour.min() >= -1e-4, colour.max() <= 1 + 1e-4,
                PaletteGenerator.peak(colour) <= PaletteGenerator.maximumPeak + 1e-3
            else { return sum }
            let edge = min(
                lch.x - PaletteGenerator.minimumLightness,
                PaletteGenerator.maximumLightness - lch.x)
            let lightness = smooth(edge / 0.05)
            let chroma = lch.y * PaletteGenerator.commonLightness / lch.x
            let tint = monochrome ? 1 : smooth((chroma - PaletteGenerator.greyChroma) / 0.03)
            let cap = smooth((PaletteGenerator.maximumChroma - lch.y) / 0.04)
            return sum + min(lightness, tint, cap)
        }
        return sum / Float(colours.count)
    }

    /// One minus the absolute mean warmth, warmth being the cosine of the hue's distance from
    /// orange. A lone galaxy has nothing to balance.
    static func balance(_ colours: [SIMD3<Float>]) -> Float {
        guard colours.count > 1 else { return 1 }
        let warmth = colours.map { cos((OKLab.lch($0).z - warmHue) * .pi / 180) }
        return 1 - abs(warmth.reduce(0, +) / Float(colours.count))
    }

    /// A half at `referenceScale` from the nearest tone, on average.
    static func reference(_ colours: [SIMD3<Float>], _ sets: [TelescopeReference]) -> Float {
        let miss =
            colours.map { colour in sets.map { $0.distance(to: colour) }.min() ?? .infinity }
            .reduce(0, +) / Float(max(colours.count, 1))
        let ratio = miss / referenceScale
        return 1 / (1 + ratio * ratio)
    }

    /// Smoothstep of `x` clamped to 0 to 1.
    static func smooth(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The palette Auto chooses: the best scored of a fixed number of candidates drawn from the
/// scene's seed, so a scene always gets the same one.
public enum PaletteAuto {
    public static let candidates = 48

    public struct Ranked: Sendable, Equatable {
        public var palette: Palette
        public var score: PaletteScore

        public init(palette: Palette, score: PaletteScore) {
            self.palette = palette
            self.score = score
        }
    }

    /// Every candidate that could be drawn, best first, ties by order of drawing. `family`
    /// keeps the candidates to one family; candidates that find no room are dropped.
    public static func ranked(
        galaxies: Int, world: Palette.World, family: String? = nil, seed: UInt64,
        telescope: [TelescopeReference] = [], favourites: [Palette] = []
    ) throws -> [Ranked] {
        let families = telescope.map(\.family)
        var random = SeededGenerator(seed: seed ^ 0x5A17_7A6E_0000_0112)
        // Favourites that fit are drawn first, so they win a tie.
        var found: [Ranked] = favourites.filter {
            $0.world == world && $0.colours.count >= galaxies && (family == nil || $0.family == family)
        }.map {
            let palette = $0.truncated(to: galaxies)
            return Ranked(palette: palette, score: PaletteScore(palette, references: telescope))
        }
        var failure: Error?
        for _ in 0..<candidates {
            do {
                let palette = try PaletteGenerator.palette(
                    galaxies: galaxies, world: world, family: family, seed: random.next(),
                    telescope: families)
                found.append(
                    Ranked(palette: palette, score: PaletteScore(palette, references: telescope)))
            } catch let error as PaletteGenerator.Failure {
                if case .noRoom = error { failure = error } else { throw error }
            }
        }
        if found.isEmpty, let failure { throw failure }
        return found.enumerated().sorted {
            $0.element.score.total != $1.element.score.total
                ? $0.element.score.total > $1.element.score.total : $0.offset < $1.offset
        }.map(\.element)
    }

    public static func palette(
        galaxies: Int, world: Palette.World, family: String? = nil, seed: UInt64,
        telescope: [TelescopeReference] = []
    ) throws -> Palette {
        try ranked(
            galaxies: galaxies, world: world, family: family, seed: seed, telescope: telescope
        )[0].palette
    }
}
