import Foundation
import simd

/// How a palette's ramps hold together inside a galaxy and keep apart between galaxies (#120).
/// The generator holds the free world to the first two limits; the score reads both.
public struct RampMeasures: Sendable, Equatable {
    /// Per galaxy, how far its worst turn of hue, from the disk colour to the core or the
    /// outskirts, sits from a harmonious interval, in degrees. A galaxy without a ramp misses
    /// nothing. The knots are left out: they glow warm in every galaxy, whatever its colour.
    public var misses: [Float]
    /// Smallest distance, at the common lightness, between a colour of one galaxy's ramp and
    /// the colour of another's at the same place or next to it: disk against disk, outskirts
    /// against outskirts, and each one's outskirts against the other's disk. The cores are
    /// left out: they all lean toward gold, which is what they are for. Nil with fewer than two
    /// ramps.
    public var apart: Float?

    /// Turns of hue that read as one scheme: close neighbours up to 60 degrees (analogous),
    /// then a third of the wheel (triadic), split complementary and complementary. Between 60
    /// and 120 degrees a colour is neither near the other nor opposite it.
    static let intervals: [ClosedRange<Float>] = [0...60, 120...120, 150...150, 180...180]
    /// Past it a turn is too far from a harmonious interval for the generator to keep.
    public static let maximumMiss: Float = 20
    /// The miss that scores nothing.
    static let worstMiss: Float = 30
    /// Below it two galaxies' ramps run into each other. The disk colours already keep the
    /// generator's 0.05; the ramps' chroma is raised 1.8 times, so this is a little more.
    public static let minimumApart: Float = 0.07

    public init(_ entries: [GalaxyColours]) {
        misses = entries.map { entry in
            guard let ramp = entry.ramp, let disk = Self.hue(ramp.disk) else { return 0 }
            return [ramp.core, ramp.outskirts].compactMap(Self.hue).map {
                Self.miss(circular($0, disk))
            }.max() ?? 0
        }
        var nearest: Float?
        let ramps = entries.compactMap(\.ramp)
        for i in ramps.indices {
            for j in ramps.indices where j > i {
                let (a, b) = (ramps[i], ramps[j])
                for pair in [
                    (a.disk, b.disk), (a.outskirts, b.outskirts), (a.outskirts, b.disk),
                    (a.disk, b.outskirts),
                ] {
                    let d = PaletteGenerator.distance(pair.0, pair.1)
                    nearest = min(nearest ?? d, d)
                }
            }
        }
        apart = nearest
    }

    /// Degrees from `turn` to the nearest harmonious interval.
    static func miss(_ turn: Float) -> Float {
        intervals.map { turn < $0.lowerBound ? $0.lowerBound - turn : max(turn - $0.upperBound, 0) }
            .min() ?? 0
    }

    /// The hue of a ramp colour, nil when it is too grey to have one.
    static func hue(_ colour: SIMD3<Float>) -> Float? {
        let lch = OKLab.lch(simd_max(colour, SIMD3(repeating: 0)))
        guard lch.y * PaletteGenerator.commonLightness / max(lch.x, 1e-4) >= PaletteGenerator.greyChroma
        else { return nil }
        return lch.z
    }

    /// Why a free-world palette's ramps are refused, in words; empty when they hold.
    public var violations: [String] {
        var broken: [String] = []
        for (index, miss) in misses.enumerated() where miss > Self.maximumMiss + 1e-3 {
            broken.append("galaxy \(index) turns \(miss) degrees off a harmonious interval")
        }
        if let apart, apart < Self.minimumApart - 1e-4 {
            broken.append("two galaxies' ramps are \(apart) apart")
        }
        return broken
    }

    /// How well each galaxy's colours hold together, 0 to 1: 1 on a harmonious interval, 0 from
    /// 30 degrees off. Mean over the galaxies.
    public var inside: Float {
        guard !misses.isEmpty else { return 1 }
        return misses.reduce(Float(0)) { $0 + 1 - PaletteScore.smooth($1 / Self.worstMiss) }
            / Float(misses.count)
    }

    /// How far apart the galaxies' ramps stay, 0 to 1: 1 from twice the floor. A lone galaxy
    /// has nothing to keep apart.
    public var between: Float {
        guard let apart else { return 1 }
        return PaletteScore.smooth(apart / (2 * Self.minimumApart))
    }
}

extension GalaxyColours {
    /// The colours a swatch shows for this entry: the galaxy's own alone, or its ramp's core,
    /// disk, outskirts, young and knot colours. The ramp's own colours are unit luminance, and
    /// raised in chroma to survive the blend; a swatch needs them at one lightness inside sRGB.
    public var swatches: [SIMD3<Float>] {
        guard let ramp else { return [colour] }
        return [ramp.core, ramp.disk, ramp.outskirts, ramp.young, ramp.knot].map(Self.displayed)
    }

    /// `colour` at the common lightness, its chroma lowered until it is inside sRGB.
    static func displayed(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        let lch = OKLab.lch(simd_max(colour, SIMD3(repeating: 0)))
        func rgb(_ chroma: Float) -> SIMD3<Float> {
            OKLab.rgb(lch: SIMD3(PaletteGenerator.commonLightness, chroma, lch.z))
        }
        func inside(_ c: SIMD3<Float>) -> Bool { c.min() >= 0 && c.max() <= 1 }
        var wanted = min(lch.y, PaletteGenerator.maximumChroma)
        guard !inside(rgb(wanted)) else { return rgb(wanted) }
        var low: Float = 0
        for _ in 0..<12 {
            let middle = (low + wanted) / 2
            if inside(rgb(middle)) { low = middle } else { wanted = middle }
        }
        return rgb(low)
    }
}
