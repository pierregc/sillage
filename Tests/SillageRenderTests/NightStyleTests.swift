import Foundation
import Testing

@testable import SillageRender

@Suite("Night style")
struct NightStyleTests {
    let references = TelescopeReference.repository
    let catalogue: [LookFile] = {
        var hubble = LookFile.standard
        hubble.name = "hubble"
        hubble.world = .telescope
        var aurora = LookFile.standard
        aurora.name = "aurora"
        aurora.world = .free
        return [hubble, aurora]
    }()

    private func style(_ world: String? = nil, _ rendering: String? = nil, _ palette: String? = nil)
        -> NightRecipe.Style
    {
        var style = NightRecipe.Style()
        if let world { style.world = .value(world) }
        if let rendering { style.style = .value(rendering) }
        if let palette { style.palette = .value(palette) }
        return style
    }

    private func resolve(_ style: NightRecipe.Style, pick: Int = 0) throws -> NightStyle {
        try NightStyle.resolve(style, pick: pick, catalogue: catalogue, references: references)
    }

    @Test func autoWorldAlternatesAcrossThePicks() throws {
        let worlds = try (0..<4).map { try resolve(style(), pick: $0).world }
        #expect(worlds == [.telescope, .free, .telescope, .free])
        #expect(try resolve(style()).rendering == nil && resolve(style()).palette == "auto")
    }

    @Test func aWorldAskedForHoldsForEveryPick() throws {
        #expect(try (0..<3).map { try resolve(style("free"), pick: $0).world } == [.free, .free, .free])
    }

    @Test func aFamilyOrARenderingFixesTheWorld() throws {
        let telescope = try #require(references.first).family.name
        #expect(try resolve(style(nil, nil, telescope), pick: 1).world == .telescope)
        #expect(try resolve(style(nil, nil, "ember"), pick: 0).world == .free)
        #expect(try resolve(style(nil, "aurora"), pick: 0).world == .free)
    }

    @Test func partsThatDisagreeAreRefused() throws {
        #expect(throws: NightRecipe.Failure.self) { try resolve(style("telescope", nil, "ember")) }
        #expect(throws: NightRecipe.Failure.self) { try resolve(style("telescope", "aurora")) }
        #expect(throws: NightRecipe.Failure.self) { try resolve(style(nil, "hubble", "ember")) }
        #expect(throws: NightRecipe.Failure.self) { try resolve(style(nil, nil, "no-such-family")) }
        #expect(throws: NightCommand.Failure.self) { try resolve(style(nil, "no-such-look")) }
    }

    @Test func theCommandIsAutoOrTheNamedRendering() throws {
        #expect(
            try resolve(style(nil, nil, "ember")).arguments(scene: "s")
                == ["look", "s", "--style", "auto", "--world", "free", "--palette", "ember"])
        #expect(
            try resolve(style(nil, "aurora")).arguments(scene: "s")
                == ["look", "s", "--palette", "auto", "--world", "free", "--base", "aurora"])
    }

    @Test func aPaletteFileGivesItsWorld() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).palette.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let palette = Palette(
            world: .free, family: "ember", harmony: .analogous, seed: 3, colours: [SIMD3(1, 0.5, 0.2)])
        try JSONEncoder().encode(palette).write(to: file)
        #expect(try resolve(style(nil, nil, file.path), pick: 0).world == .free)
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).palette.json")
        defer { try? FileManager.default.removeItem(at: bare) }
        try Data(#"{"colours": [[1, 0.5, 0.2]]}"#.utf8).write(to: bare)
        #expect(throws: NightRecipe.Failure.self) { try resolve(style(nil, nil, bare.path)) }
        #expect(try resolve(style(nil, "aurora", bare.path)).rendering == "aurora")
    }

    @Test func theEventKeepsThePalettesRecipe() throws {
        var event = RunEvent(RunEvent.Kind.style, scene: "scene-0001")
        event.setPalette(
            Palette(world: .free, family: "ember", harmony: .triadic, seed: 5, colours: []))
        let back = try RunStatus.decoder().decode(RunEvent.self, from: RunStatus.encoder().encode(event))
        #expect(back.world == "free" && back.family == "ember" && back.harmony == "triadic" && back.seed == 5)
        let parsed = try RunEvent("style", options: ["--world", "free", "--seed", "5"])
        #expect(parsed.world == "free" && parsed.seed == 5)
    }
}
