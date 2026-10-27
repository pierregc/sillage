import Foundation
import Testing

@testable import SillageRender

@Suite("Favourite palettes")
struct FavouritePalettesTests {
    private func palette(
        _ world: Palette.World = .free, colours: Int = 3, family: String = "ember"
    ) -> Palette {
        Palette(
            world: world, family: family, harmony: .analogous, seed: 7,
            colours: (0..<colours).map { SIMD3(0.9, 0.5 + Float($0) / 10, 0.4) })
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "favourites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func everyFileOfTheRepositoryDecodes() throws {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: FavouritePalettes.directory.path))
            ?? []
        let files = names.filter { $0.hasSuffix(FavouritePalettes.suffix) }
        for file in files {
            let data = try Data(contentsOf: FavouritePalettes.directory.appendingPathComponent(file))
            let palette = try JSONDecoder().decode(Palette.self, from: data)
            #expect(!palette.colours.isEmpty && palette.colours.count <= 5, "\(file)")
        }
        #expect(FavouritePalettes.load().count == files.count)
    }

    @Test func aSavedPaletteComesBackUnderItsSlug() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try FavouritePalettes.save(palette(), named: "  Soir d'Été ", in: directory)
        #expect(kept.name == "soir-d-été")
        #expect(FavouritePalettes.load(from: directory) == [kept])
        #expect(try FavouritePalettes.favourite(matching: palette(), in: [kept]) == kept)
    }

    @Test func aNameIsNeverReusedAndNeverEmpty() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FavouritePalettes.save(palette(), named: "one", in: directory)
        #expect(throws: FavouritePalettes.Failure.taken("one")) {
            try FavouritePalettes.save(palette(), named: "One", in: directory)
        }
        #expect(throws: FavouritePalettes.Failure.noName) {
            try FavouritePalettes.save(palette(), named: " !? ", in: directory)
        }
    }

    @Test func aRemovedFavouriteIsGone() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try FavouritePalettes.save(palette(), named: "one", in: directory)
        try FavouritePalettes.remove(kept, in: directory)
        #expect(FavouritePalettes.load(from: directory).isEmpty)
    }

    @Test func aFileThatIsNotAPaletteIsLeftOut() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FavouritePalettes.save(palette(), named: "good", in: directory)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("bad.palette.json"))
        #expect(FavouritePalettes.load(from: directory).map(\.name) == ["good"])
    }

    @Test func fittingKeepsTheWorldAndCutsExtraColours() {
        let all = [
            FavouritePalettes.Favourite(name: "free-five", palette: palette(.free, colours: 5)),
            FavouritePalettes.Favourite(name: "free-two", palette: palette(.free, colours: 2)),
            FavouritePalettes.Favourite(
                name: "scope", palette: palette(.telescope, colours: 3, family: "hubble-visible")),
        ]
        let three = FavouritePalettes.fitting(all, world: .free, galaxies: 3)
        #expect(three.map(\.name) == ["free-five"] && three[0].palette.colours.count == 3)
        #expect(three[0].palette.colours == all[0].palette.colours.prefix(3).map { $0 })
        #expect(FavouritePalettes.fitting(all, world: .telescope, galaxies: 3).map(\.name) == ["scope"])
        #expect(FavouritePalettes.fitting(all, world: .telescope, galaxies: 4).isEmpty)
        #expect(
            FavouritePalettes.fitting(all, world: .free, galaxies: 2).map(\.name) == [
                "free-five", "free-two",
            ])
        // A cut favourite is still recognised as itself.
        #expect(FavouritePalettes.favourite(matching: three[0].palette, in: all)?.name == "free-five")
    }

    @Test func autoTriesFavouritesFirstAndOnlyThoseThatFit() throws {
        let mine = palette(.free, colours: 4)
        let ranked = try PaletteAuto.ranked(
            galaxies: 3, world: .free, seed: 11, favourites: [mine, palette(.telescope, colours: 3)])
        #expect(ranked.contains { $0.palette == mine.truncated(to: 3) })
        #expect(ranked.allSatisfy { $0.palette.world == .free })
        let none = try PaletteAuto.ranked(
            galaxies: 3, world: .free, seed: 11, favourites: [palette(.free, colours: 2)])
        #expect(!none.contains { $0.palette.seed == 7 })
    }

    @Test func aNightCanNameAFavourite() throws {
        let kept = FavouritePalettes.Favourite(name: "soir", palette: palette(.free))
        var style = NightRecipe.Style()
        style.palette = .value("soir")
        let resolved = try NightStyle.resolve(
            style, pick: 0, catalogue: [], references: [], favourites: [kept])
        #expect(resolved.world == .free && resolved.palette == "soir")
        style.world = .value("telescope")
        #expect(throws: NightRecipe.Failure.self) {
            try NightStyle.resolve(style, pick: 0, catalogue: [], references: [], favourites: [kept])
        }
    }
}
