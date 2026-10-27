import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Palette generator")
struct PaletteGeneratorTests {
    @Test func oklchRoundTripsThroughLinearSRGB() {
        var random = SeededGenerator(seed: 3)
        for _ in 0..<2000 {
            let rgb = SIMD3<Float>(random.uniform(), random.uniform(), random.uniform())
            #expect(simd_distance(OKLab.rgb(lch: OKLab.lch(rgb)), rgb) < 1e-4)
        }
        let white = OKLab.lab(SIMD3(1, 1, 1))
        #expect(abs(white.x - 1) < 1e-4 && abs(white.y) < 1e-4 && abs(white.z) < 1e-4)
    }

    @Test func theSameInputGivesTheSameColours() throws {
        for world in Palette.World.allCases {
            for galaxies in 1...5 {
                let a = try PaletteGenerator.palette(galaxies: galaxies, world: world, seed: 42)
                let b = try PaletteGenerator.palette(galaxies: galaxies, world: world, seed: 42)
                #expect(a == b)
            }
        }
        let one = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 1)
        let two = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 2)
        #expect(one.colours != two.colours)
    }

    @Test func everyConstraintHoldsOverAThousandSeeds() throws {
        for world in Palette.World.allCases {
            for galaxies in 1...5 {
                for seed in UInt64(0)..<1000 {
                    let palette = try PaletteGenerator.palette(
                        galaxies: galaxies, world: world, seed: seed)
                    #expect(palette.colours.count == galaxies)
                    #expect(palette.world == world)
                    let broken = Self.check(palette)
                    #expect(broken.isEmpty, "\(palette.name): \(broken)")
                }
            }
        }
    }

    @Test func aNamedFamilyAndHarmonyAreKeptOrRefused() throws {
        for family in PaletteFamily.free {
            for harmony in Palette.Harmony.allCases {
                for galaxies in 1...5 {
                    for seed in UInt64(0)..<40 {
                        do {
                            let palette = try PaletteGenerator.palette(
                                galaxies: galaxies, world: .free, family: family.name,
                                harmony: harmony, seed: seed)
                            #expect(palette.family == family.name && palette.harmony == harmony)
                            #expect(Self.check(palette).isEmpty)
                            for colour in palette.colours {
                                let hue = OKLab.lch(colour).z
                                let grey = OKLab.lch(colour).y < 0.01
                                #expect(grey || family.hues.contains { $0.distance(to: hue) < 0.5 })
                            }
                        } catch PaletteGenerator.Failure.noRoom {
                            // Pastel's chroma is so narrow that two analogous galaxies rarely
                            // keep their ramps apart.
                            #expect(
                                galaxies >= 3 || family.name == "pastel",
                                "\(family.name) \(harmony) \(galaxies)")
                        }
                    }
                }
            }
        }
    }

    @Test func monochromeKeepsOneHue() throws {
        for seed in UInt64(0)..<200 {
            let palette = try PaletteGenerator.palette(
                galaxies: 3, world: .free, family: "spectrum", harmony: .monochrome, seed: seed)
            let tinted = palette.colours.map(OKLab.lch).filter { $0.y > 0.02 }
            for a in tinted {
                for b in tinted {
                    #expect(circular(a.z, b.z) <= 2 * PaletteGenerator.monochromeSpread + 0.5)
                }
            }
        }
    }

    @Test func theTelescopeWorldSaysItIsAPlaceholder() throws {
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 5)
        #expect(palette.family == PaletteFamily.telescopePlaceholder.name)
        #expect(PaletteFamily.telescopePlaceholder.note != nil)
    }

    @Test func theChecksCatchWhatTheyStand() {
        let grey = SIMD3<Float>(0.7, 0.7, 0.7)
        #expect(!PaletteGenerator.violations([grey], monochrome: false).isEmpty)
        #expect(PaletteGenerator.violations([grey], monochrome: true).isEmpty)
        #expect(!PaletteGenerator.violations([SIMD3(0.1, 0.2, 1)], monochrome: false).isEmpty)
        #expect(!PaletteGenerator.violations([SIMD3(0.05, 0.04, 0.03)], monochrome: true).isEmpty)
        let warm = SIMD3<Float>(1, 0.75, 0.5)
        #expect(PaletteGenerator.violations([warm], monochrome: false).isEmpty)
        #expect(!PaletteGenerator.violations([warm, warm * 0.8], monochrome: false).isEmpty)
    }

    @Test func aLookFileKeepsItsRecipeAndReadsWithoutOne() throws {
        let recipe = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 9)
        var file = LookFile.standard
        file.palette = recipe.galaxyColours()
        file.paletteRecipe = recipe
        let written = try file.encoded()
        #expect(try LookFile.decoded(from: written) == file)
        #expect(try LookFile.decoded(from: Data(#"{"version": 1}"#.utf8)).paletteRecipe == nil)
        #expect(try LookFile.standard.encoded() == LookFile.standard.encoded())
        #expect(!String(decoding: try LookFile.standard.encoded(), as: UTF8.self).contains("Recipe"))
    }

    /// The constraints worked out again from the colours, not through the generator's own check.
    static func check(_ palette: Palette) -> [String] {
        var broken: [String] = []
        let colours = palette.colours
        for colour in colours {
            let lch = OKLab.lch(colour)
            if colour.min() < -1e-4 || colour.max() > 1 + 1e-4 { broken.append("gamut") }
            if lch.x < 0.72 - 1e-4 { broken.append("dim \(lch.x)") }
            if lch.y > 0.19 + 1e-4 { broken.append("vivid \(lch.y)") }
            let luminance = simd_dot(colour, SIMD3(0.2126, 0.7152, 0.0722))
            if colour.max() / luminance > 2.6 + 1e-3 { broken.append("peak") }
            if palette.harmony != .monochrome && lch.y * 0.8 / lch.x < 0.04 - 1e-4 {
                broken.append("grey")
            }
        }
        for i in colours.indices {
            for j in colours.indices where j > i {
                let a = OKLab.lab(colours[i])
                let b = OKLab.lab(colours[j])
                let d = simd_distance(
                    SIMD2(a.y, a.z) * (0.8 / a.x), SIMD2(b.y, b.z) * (0.8 / b.x))
                if d < 0.05 - 1e-4 { broken.append("close \(i) \(j) \(d)") }
            }
        }
        return broken
    }
}
