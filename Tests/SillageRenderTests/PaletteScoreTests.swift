import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

/// A set shaped like #125's files: `vivid` medians per region.
let referenceJSON = #"""
    {"regions": {
      "core": {"median": [0.84, 0.02, 0.04],
        "vivid": {"warm": {"share": 1.0, "median": [0.75, 0.045, 0.086]}}},
      "knots": {"median": [0.7, 0.015, -0.006],
        "vivid": {"warm": {"share": 0.76, "median": [0.66, 0.085, 0.04]},
                  "cool": {"share": 0.24, "median": [0.68, -0.03, -0.083]},
                  "faint": {"share": 0.02, "median": [0.68, 0.0, 0.1]}}},
      "tails": {"median": [0.26, 0, 0],
        "vivid": {"cool": {"share": 1.0, "median": [0.27, -0.02, -0.02]}}},
      "sky": {"median": [0.14, 0, 0],
        "vivid": {"cool": {"share": 1.0, "median": [0.13, -0.01, -0.01]}}}
    }}
    """#

@Suite("Telescope reference")
struct TelescopeReferenceTests {
    @Test func aReferenceFileKeepsItsVividTonesWithoutSkyTailsOrNoise() throws {
        let set = try TelescopeReference(data: Data(referenceJSON.utf8), name: "hubble-visible")
        #expect(set.tones.map { "\($0.region)-\($0.side)" } == ["core-warm", "knots-cool", "knots-warm"])
        let family = set.family
        #expect(family.world == .telescope && family.hues.count == 3)
        let palette = try PaletteGenerator.palette(
            galaxies: 2, world: .telescope, seed: 1, telescope: [family])
        #expect(palette.family == "hubble-visible")
        #expect(PaletteGeneratorTests.check(palette).isEmpty)
    }

    @Test func theCommittedFilesAreReadAndMarksIsNot() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("references/telescope")
        let sets = TelescopeReference.load(from: directory)
        #expect(sets.map(\.name) == ["hubble-visible", "webb-miri", "webb-nircam-miri", "webb-nircam"])
        for set in sets {
            let palette = try PaletteGenerator.palette(
                galaxies: 4, world: .telescope, seed: 3, telescope: [set.family])
            #expect(PaletteGeneratorTests.check(palette).isEmpty, "\(set.name)")
        }
    }

    @Test func aColourOnATonePlaysItsOwnDistanceAsZero() throws {
        let set = try TelescopeReference(data: Data(referenceJSON.utf8), name: "x")
        let tone = set.tones[0]
        #expect(set.distance(to: OKLab.rgb(lab: tone.lab)) < 1e-4)
        #expect(set.distance(to: OKLab.rgb(lch: SIMD3(0.8, 0.1, 200))) > 0.05)
    }
}

@Suite("Palette score")
struct PaletteScoreTests {
    static func palette(_ colours: [SIMD3<Float>], harmony: Palette.Harmony = .complementary)
        -> Palette
    {
        Palette(world: .free, family: "by-hand", harmony: harmony, seed: 0, colours: colours)
    }

    static func lch(_ hue: Float, chroma: Float = 0.09, lightness: Float = 0.82) -> SIMD3<Float> {
        OKLab.rgb(lch: SIMD3(lightness, chroma, hue))
    }

    @Test func twoNearlyIdenticalColoursScoreBelowAGoodPalette() {
        let good = Self.palette([Self.lch(40), Self.lch(220)])
        let bad = Self.palette([Self.lch(40), Self.lch(43, chroma: 0.091)])
        let scoreGood = PaletteScore(good)
        let scoreBad = PaletteScore(bad)
        #expect(scoreBad.separation < 0.05)
        #expect(scoreGood.separation > 0.95)
        #expect(scoreBad.total < scoreGood.total)
        #expect(scoreGood.total > 0.8)
    }

    @Test func everyPartAndTheTotalStayBetweenZeroAndOne() throws {
        for world in Palette.World.allCases {
            for galaxies in 1...5 {
                for seed in UInt64(0)..<60 {
                    let score = PaletteScore(
                        try PaletteGenerator.palette(
                            galaxies: galaxies, world: world, seed: seed))
                    for part in [
                        score.separation, score.harmony, score.range, score.balance, score.total,
                    ] { #expect(part >= 0 && part <= 1) }
                }
            }
        }
    }

    @Test func aPaletteOffItsHarmonyScoresBelowOneOnIt() {
        let on = Self.palette(
            [Self.lch(20), Self.lch(140), Self.lch(260)], harmony: .triadic)
        let off = Self.palette(
            [Self.lch(20), Self.lch(70), Self.lch(95)], harmony: .triadic)
        #expect(PaletteScore(on).harmony > 0.95)
        #expect(PaletteScore(off).harmony < 0.6)
    }

    @Test func colourOutsideTheRangesScoresZeroOnRange() {
        let fine = Self.palette([Self.lch(40), Self.lch(220)])
        let dim = Self.palette([Self.lch(40, lightness: 0.6), Self.lch(220, lightness: 0.5)])
        let grey = Self.palette([Self.lch(40, chroma: 0.0), Self.lch(220, chroma: 0.01)])
        #expect(PaletteScore(fine).range > 0.95)
        #expect(PaletteScore(dim).range == 0)
        #expect(PaletteScore(grey).range == 0)
    }

    @Test func warmAndCoolBalanceBeatsAllWarm() {
        let mixed = Self.palette([Self.lch(50), Self.lch(230)])
        let warm = Self.palette([Self.lch(30), Self.lch(70)])
        #expect(PaletteScore(mixed).balance > 0.95)
        #expect(PaletteScore(warm).balance < 0.2)
        #expect(PaletteScore(Self.palette([Self.lch(30)])).balance == 1)
    }

    @Test func theTelescopeWorldAlsoScoresTheDistanceToTheReferences() throws {
        let set = try TelescopeReference(data: Data(referenceJSON.utf8), name: "hubble-visible")
        func telescope(_ colours: [SIMD3<Float>]) -> Palette {
            Palette(
                world: .telescope, family: "hubble-visible", harmony: .complementary, seed: 0,
                colours: colours)
        }
        let near = telescope(set.tones.prefix(2).map { OKLab.rgb(lab: SIMD3($0.lab.x, $0.lab.y, $0.lab.z)) })
        let far = telescope([Self.lch(150, chroma: 0.15), Self.lch(320, chroma: 0.15)])
        #expect(PaletteScore(near, references: [set]).reference! > 0.9)
        #expect(PaletteScore(far, references: [set]).reference! < 0.3)
        #expect(PaletteScore(far).reference == nil)
        let free = Self.palette([Self.lch(150), Self.lch(320)])
        #expect(PaletteScore(free, references: [set]).reference == nil)
    }
}

@Suite("Auto palette")
struct PaletteAutoTests {
    static let sets: [TelescopeReference] = {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("references/telescope")
        return TelescopeReference.load(from: directory)
    }()

    @Test func theSameSceneAlwaysGetsTheSamePalette() throws {
        for world in Palette.World.allCases {
            for galaxies in 1...5 {
                let a = try PaletteAuto.palette(
                    galaxies: galaxies, world: world, seed: 77, telescope: Self.sets)
                let b = try PaletteAuto.palette(
                    galaxies: galaxies, world: world, seed: 77, telescope: Self.sets)
                #expect(a == b)
                #expect(a.colours.count == galaxies && a.world == world)
            }
        }
        let one = try PaletteAuto.palette(galaxies: 3, world: .free, seed: 1)
        let two = try PaletteAuto.palette(galaxies: 3, world: .free, seed: 2)
        #expect(one != two)
    }

    @Test func theChoiceIsTheTopOfTheRankingAndAPaletteCanBeDrawnAgainFromItsSeed() throws {
        let ranked = try PaletteAuto.ranked(
            galaxies: 3, world: .telescope, seed: 5, telescope: Self.sets)
        #expect(ranked.count == PaletteAuto.candidates)
        #expect(ranked.map(\.score.total) == ranked.map(\.score.total).sorted(by: >))
        let best = ranked[0].palette
        let again = try PaletteGenerator.palette(
            galaxies: 3, world: .telescope, seed: best.seed,
            telescope: Self.sets.map(\.family))
        #expect(again == best)
    }

    @Test func autoBeatsTheAverageCandidateAndKeepsEveryConstraint() throws {
        for galaxies in 1...5 {
            for world in Palette.World.allCases {
                let ranked = try PaletteAuto.ranked(
                    galaxies: galaxies, world: world, seed: UInt64(galaxies), telescope: Self.sets)
                let mean = ranked.map(\.score.total).reduce(0, +) / Float(ranked.count)
                #expect(ranked[0].score.total >= mean)
                #expect(PaletteGeneratorTests.check(ranked[0].palette).isEmpty)
            }
        }
    }

    @Test func aFamilyKeepsTheCandidatesInIt() throws {
        let ranked = try PaletteAuto.ranked(
            galaxies: 2, world: .free, family: "ember", seed: 9)
        #expect(ranked.allSatisfy { $0.palette.family == "ember" })
    }
}
