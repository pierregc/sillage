import Foundation
import Testing

@testable import SillageCore

struct SpiralPatternTests {
    private static let shape = SpiralPattern.Shape(
        arms: 4, windRate: 2.6, irregularity: 0.55, index: 0)
    private static let regular = SpiralPattern.Shape(
        arms: 4, windRate: 2.6, irregularity: 0, index: 0)

    private func samples(_ shape: SpiralPattern.Shape) -> [Float] {
        var values: [Float] = []
        for i in 0..<200 {
            for j in 0..<200 {
                values.append(
                    SpiralPattern.ridge(
                        extent: 0.5 + 3.5 * Float(i) / 200,
                        phi: 2 * .pi * Float(j) / 200, shape: shape))
            }
        }
        return values.sorted()
    }

    /// Irregular has to mean unequal, not weaker.
    ///
    /// It meant weaker: each modulator was a noise term with a mean well under one, so every
    /// arm lost a share of its strength and the picture went soft. Measured, the irregular
    /// pattern averaged 0.375 against the regular one's 0.500 and its ninetieth percentile
    /// 0.744 against 0.976. Normalised to unit mean, the modulators redistribute an arm's
    /// strength instead of taking it away, and what is left of the gap is the clip at one.
    @Test func irregularArmsAreUnequalRatherThanWeak() {
        let irregular = samples(Self.shape)
        let regular = samples(Self.regular)
        let mean = { (v: [Float]) in v.reduce(0, +) / Float(v.count) }
        #expect(mean(irregular) > 0.42)
        #expect(mean(irregular) > 0.82 * mean(regular))
        // And genuinely unequal: the spread across the disk has to be wider than a clean
        // pattern's, not narrower.
        func spread(_ v: [Float]) -> Float { v[9 * v.count / 10] - v[v.count / 10] }
        #expect(spread(irregular) > 0.55)
    }

    /// No rotation maps the pattern onto itself.
    ///
    /// A clean m-fold spiral is the same picture turned by a quarter of a circle, and that is
    /// exactly what makes a rendered galaxy read as a machined part.
    @Test func noRotationRepeatsThePattern() {
        let turn = 2 * Float.pi / Self.shape.arms
        var worst: Float = 0
        var regularWorst: Float = 0
        for i in 0..<64 {
            let extent = 1.0 + 2.5 * Float(i) / 64
            for j in 0..<64 {
                let phi = 2 * .pi * Float(j) / 64
                let here = SpiralPattern.ridge(extent: extent, phi: phi, shape: Self.shape)
                let there = SpiralPattern.ridge(
                    extent: extent, phi: phi + turn, shape: Self.shape)
                worst = max(worst, abs(here - there))
                regularWorst = max(
                    regularWorst,
                    abs(
                        SpiralPattern.ridge(extent: extent, phi: phi, shape: Self.regular)
                            - SpiralPattern.ridge(
                                extent: extent, phi: phi + turn, shape: Self.regular)))
            }
        }
        // A clean pattern is invariant under exactly this turn, to rounding.
        #expect(regularWorst < 0.01)
        #expect(worst > 0.35)
    }

    /// The hash is integer mixing so that the sampler and the shader agree exactly.
    ///
    /// `fract(sin(x) * 43758.5453)` cannot: the last bits of `sin` differ between a CPU and a
    /// GPU and the multiply turns that into unrelated numbers, so the matter would sit where
    /// the paint says there is nothing. This checks the property that makes agreement possible
    /// — the hash depends only on the integer part, and only through integer arithmetic.
    @Test func theHashIsExactAndDependsOnlyOnTheIntegerPart() {
        for index in stride(from: Float(-40), through: 40, by: 1) {
            #expect(SpiralPattern.hash(index) == SpiralPattern.hash(index + 0.4))
            let value = SpiralPattern.hash(index)
            #expect(value >= 0 && value < 1)
        }
        // Neighbouring cells are unrelated, or the noise has structure it should not have.
        var same = 0
        for index in 0..<200
        where
            abs(SpiralPattern.hash(Float(index)) - SpiralPattern.hash(Float(index + 1))) < 0.02
        {
            same += 1
        }
        #expect(same < 20)
    }
}
