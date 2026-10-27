import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Palette ramps")
struct PaletteRampTests {
    static let sets = PaletteAutoTests.sets

    @Test func aMulticolourPaletteIsTheDefaultAndIsWrittenOnlyWhenItIsOff() throws {
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 3)
        #expect(palette.multicolour)
        let text = String(decoding: try JSONEncoder().encode(palette), as: UTF8.self)
        #expect(!text.contains("multicolour"))
        let single = palette.withMulticolour(false)
        let written = try JSONEncoder().encode(single)
        #expect(String(decoding: written, as: UTF8.self).contains("\"multicolour\":false"))
        #expect(try JSONDecoder().decode(Palette.self, from: written) == single)
        #expect(try JSONDecoder().decode(Palette.self, from: JSONEncoder().encode(palette)) == palette)
    }

    @Test func aSingleColourPaletteDrawsTheColoursAlone() throws {
        let palette = try PaletteGenerator.palette(galaxies: 3, world: .telescope, seed: 4)
        #expect(palette.galaxyColours(references: Self.sets).allSatisfy { $0.ramp != nil })
        let single = palette.withMulticolour(false).galaxyColours(references: Self.sets)
        #expect(single == palette.colours.map { GalaxyColours($0) })
    }

    @Test func theFreeWorldKeepsItsRampsTogetherAndApart() throws {
        for galaxies in 1...5 {
            for seed in UInt64(0)..<200 {
                let palette = try PaletteGenerator.palette(
                    galaxies: galaxies, world: .free, seed: seed, references: Self.sets)
                let measures = RampMeasures(palette.galaxyColours(references: Self.sets))
                #expect(measures.violations.isEmpty, "\(palette.name): \(measures.violations)")
                #expect(PaletteGeneratorTests.check(palette).isEmpty)
            }
        }
    }

    @Test func aSingleColourPaletteIsNotHeldToTheRamps() throws {
        // Seeds that a multicolour draw refuses still give a palette without ramps.
        var drawnDifferently = 0
        for seed in UInt64(0)..<200 {
            let single = try PaletteGenerator.palette(
                galaxies: 5, world: .free, seed: seed, multicolour: false)
            let multi = try PaletteGenerator.palette(galaxies: 5, world: .free, seed: seed)
            if single.colours != multi.colours { drawnDifferently += 1 }
        }
        #expect(drawnDifferently > 0)
    }

    @Test func theMeasuresFindWhatTheyStandFor() {
        func entry(_ colour: SIMD3<Float>, _ world: Palette.World = .free) -> GalaxyColours {
            .ramped(colour, world: world, family: "spectrum", references: [])
        }
        let orange = entry(SIMD3(1, 0.62, 0.4))
        #expect(RampMeasures([orange]).apart == nil && RampMeasures([orange]).between == 1)
        let twin = RampMeasures([orange, orange])
        #expect(twin.apart == 0 && twin.between == 0)
        #expect(!twin.violations.isEmpty)
        let blue = entry(SIMD3(0.45, 0.7, 1))
        let apart = RampMeasures([orange, blue])
        #expect(apart.apart! > RampMeasures.minimumApart && apart.violations.isEmpty)
        #expect(apart.between > 0.9)
        // No ramp, nothing to hold together or apart.
        let plain = RampMeasures([GalaxyColours(SIMD3(1, 0.6, 0.3)), GalaxyColours(SIMD3(1, 0.6, 0.3))])
        #expect(plain.apart == nil && plain.misses == [0, 0])
    }

    @Test func aTurnBetweenTheIntervalsIsMissedAndOnOneIsNot() {
        for turn: Float in [0, 30, 60, 120, 150, 180] { #expect(RampMeasures.miss(turn) == 0) }
        #expect(RampMeasures.miss(90) == 30)
        #expect(RampMeasures.miss(70) == 10)
        #expect(RampMeasures.miss(135) == 15)
    }

    @Test func theRampPartsOnlyScoreWhatTheyCan() throws {
        let free = try PaletteGenerator.palette(galaxies: 3, world: .free, seed: 8)
        let multi = PaletteScore(free)
        #expect(multi.inside != nil && multi.between != nil)
        let single = PaletteScore(free.withMulticolour(false))
        #expect(single.inside == nil && single.between == nil)
        #expect(single.separation == multi.separation && single.harmony == multi.harmony)
        let telescope = try PaletteGenerator.palette(
            galaxies: 3, world: .telescope, seed: 8, telescope: Self.sets.map(\.family))
        let scored = PaletteScore(telescope, references: Self.sets)
        #expect(scored.inside == nil && scored.between != nil)
        for score in [multi, single, scored] {
            for part in [score.total, score.inside, score.between].compactMap({ $0 }) {
                #expect((0...1).contains(part))
            }
        }
    }

    @Test func aPaletteWhoseRampsRunTogetherScoresLowerOnBetween() {
        let near = Palette(
            world: .free, family: "spectrum", harmony: .analogous, seed: 1,
            colours: [SIMD3(1, 0.62, 0.4), SIMD3(1, 0.63, 0.41)])
        let far = Palette(
            world: .free, family: "spectrum", harmony: .complementary, seed: 1,
            colours: [SIMD3(1, 0.62, 0.4), SIMD3(0.45, 0.7, 1)])
        #expect(PaletteScore(near).between! < 0.1)
        #expect(PaletteScore(far).between! > 0.9)
        #expect(PaletteScore(near).total < PaletteScore(far).total)
    }

    @Test func autoFollowsTheSwitch() throws {
        let multi = try PaletteAuto.ranked(galaxies: 3, world: .free, seed: 5, telescope: Self.sets)
        let single = try PaletteAuto.ranked(
            galaxies: 3, world: .free, seed: 5, telescope: Self.sets, multicolour: false)
        #expect(multi.allSatisfy { $0.palette.multicolour && $0.score.between != nil })
        #expect(single.allSatisfy { !$0.palette.multicolour && $0.score.between == nil })
        let favourite = try PaletteGenerator.palette(galaxies: 3, world: .free, seed: 99)
        let withFavourite = try PaletteAuto.ranked(
            galaxies: 3, world: .free, seed: 5, telescope: Self.sets, favourites: [favourite],
            multicolour: false)
        #expect(withFavourite.contains { $0.palette == favourite.withMulticolour(false) })
    }

    @Test func aSwatchShowsTheRampInsideSRGBAtOneLightness() throws {
        for world in Palette.World.allCases {
            let palette = try PaletteGenerator.palette(galaxies: 3, world: world, seed: 6)
            for entry in palette.galaxyColours(references: Self.sets) {
                let swatches = entry.swatches
                #expect(swatches.count == 5)
                for colour in swatches {
                    #expect(colour.min() >= -1e-3 && colour.max() <= 1 + 1e-3)
                    #expect(abs(OKLab.lch(colour).x - PaletteGenerator.commonLightness) < 0.02)
                }
            }
        }
        #expect(GalaxyColours(SIMD3(0.9, 0.6, 0.3)).swatches == [SIMD3(0.9, 0.6, 0.3)])
    }
}

@Suite("Multicolour in the look file")
struct MulticolourLookTests {
    private let scene = SceneConfig.merger(particleCount: 20_000)

    private func file(multicolour: Bool = true) throws -> LookFile {
        let recipe = try PaletteGenerator.palette(
            galaxies: 2, world: .free, seed: 11, multicolour: multicolour)
        var file = LookFile.standard
        file.world = .free
        return file.withPalette(recipe, in: scene, references: PaletteRampTests.sets)
    }

    @Test func theSwitchTurnsTheRampsOffAndOnAndKeepsTheColours() throws {
        let ramped = try file()
        #expect(ramped.hasRamps)
        let off = ramped.withRamps(false, references: PaletteRampTests.sets)
        #expect(!off.hasRamps && off.palette.map(\.colour) == ramped.palette.map(\.colour))
        #expect(off.paletteRecipe?.multicolour == false)
        let on = off.withRamps(true, references: PaletteRampTests.sets)
        #expect(on == ramped)
    }

    @Test func aLockedGalaxyKeepsItsEntry() throws {
        let ramped = try file()
        let off = ramped.withRamps(false, keeping: [0], references: PaletteRampTests.sets)
        #expect(off.palette[0] == ramped.palette[0] && off.palette[1].ramp == nil)
    }

    @Test func aHandPickedColourKeepsItsOwnRamp() throws {
        var file = try self.file(multicolour: false)
        file.setColour(SIMD3(0.8, 0.5, 0.9), ofGalaxy: 0, in: scene)
        let on = file.withRamps(true, references: PaletteRampTests.sets)
        #expect(on.palette[0].colour == SIMD3(0.8, 0.5, 0.9) && on.palette[0].ramp != nil)
    }

    @Test func aPaletteWithoutRampsAppliesWithoutThem() throws {
        let recipe = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 2)
            .withMulticolour(false)
        let applied = LookFile.standard.withPalette(
            recipe, in: scene, references: PaletteRampTests.sets)
        #expect(!applied.hasRamps && applied.paletteRecipe == recipe)
    }
}

@Suite("Multicolour in a night")
struct MulticolourNightTests {
    @Test func theRecipeReadsTheSwitchAndAutoIsOn() throws {
        let off = try NightRecipe.decoded(from: Data(#"{"style": {"multicolour": false}}"#.utf8))
        #expect(off.style.multicolour == .value(false))
        let auto = try NightRecipe.decoded(from: Data(#"{"style": {"multicolour": "auto"}}"#.utf8))
        #expect(auto.style.multicolour == .auto)
        #expect(throws: NightRecipe.Failure.self) {
            try NightRecipe.decoded(from: Data(#"{"style": {"colours": 1}}"#.utf8))
        }
    }

    @Test func theStyleStepAsksForSingleColoursOnlyWhenTold() throws {
        let catalogue = LookCatalogue.repository
        let references = PaletteRampTests.sets
        var style = NightRecipe.Style()
        let auto = try NightStyle.resolve(style, pick: 1, catalogue: catalogue, references: references)
        #expect(auto.multicolour && !auto.arguments(scene: "s").contains("--single"))
        style.multicolour = .value(false)
        let single = try NightStyle.resolve(style, pick: 1, catalogue: catalogue, references: references)
        #expect(!single.multicolour && single.arguments(scene: "s").contains("--single"))
        style.style = .value("aurora")
        let named = try NightStyle.resolve(style, pick: 0, catalogue: catalogue, references: references)
        #expect(named.arguments(scene: "s").contains("--single"))
    }
}
