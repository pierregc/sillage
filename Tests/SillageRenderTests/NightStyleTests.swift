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

    private func resolve(_ style: NightRecipe.Style, pick: Int = 0, seed: UInt64 = 20_261_102) throws
        -> NightStyle
    {
        try NightStyle.resolve(
            style, pick: pick, seed: seed, catalogue: catalogue, references: references, favourites: [])
    }

    private func style(share: Double) -> NightRecipe.Style {
        var style = style()
        style.freeShare = .value(share)
        return style
    }

    /// The seeds of `count` nights from 2026-11-01, as Auto gives them.
    private func nights(_ count: Int) throws -> [UInt64] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        return try (0..<count).map { day in
            NightRecipe.daySeed(
                try #require(calendar.date(byAdding: .day, value: day, to: first)), calendar: calendar)
        }
    }

    @Test func autoGivesTheFreeWorldToAFifthOfThePicks() throws {
        // Four picks a night over 250 nights.
        var free = 0
        for seed in try nights(250) {
            for pick in 0..<4 where try resolve(style(), pick: pick, seed: seed).world == .free {
                free += 1
            }
        }
        #expect((180...220).contains(free), "\(free) free picks in 1000")
        #expect(try resolve(style()).rendering == nil && resolve(style()).palette == "auto")
        let seeds = try nights(50)
        for share in [0.0, 1.0] {
            let worlds = try seeds.flatMap { seed in
                try (0..<4).map { try resolve(style(share: share), pick: $0, seed: seed).world }
            }
            #expect(Set(worlds) == [share == 0 ? .telescope : .free], "share \(share)")
        }
    }

    @Test func aPickIsDrawnTheSameWorldEveryTime() throws {
        let seeds = try nights(20)
        func worlds() throws -> [[Palette.World]] {
            try seeds.map { seed in try (0..<4).map { try resolve(style(), pick: $0, seed: seed).world } }
        }
        let first = try worlds()
        #expect(try worlds() == first)
        // The draw the planner predicts the night with.
        let drawn = seeds.map { seed in
            (0..<4).map { NightStyle.drawnWorld(pick: $0, seed: seed, share: NightRecipe.defaultFreeShare) }
        }
        #expect(first == drawn)
        // Each night draws its own.
        #expect(Set(first).count > 1 && Set(first.flatMap { $0 }) == [.telescope, .free])
    }

    @Test func aWorldAskedForHoldsForEveryPick() throws {
        #expect(try (0..<3).map { try resolve(style("free"), pick: $0).world } == [.free, .free, .free])
        for (world, share) in [("telescope", 1.0), ("free", 0.0)] {
            var asked = style(share: share)
            asked.world = .value(world)
            for seed in try nights(10) {
                #expect(
                    try (0..<4).allSatisfy {
                        try resolve(asked, pick: $0, seed: seed).world.rawValue == world
                    })
            }
        }
    }

    @Test func aFamilyOrARenderingFixesTheWorld() throws {
        let telescope = try #require(references.first).family.name
        #expect(try resolve(style(nil, nil, telescope), pick: 1).world == .telescope)
        #expect(try resolve(style(nil, nil, "ember"), pick: 0).world == .free)
        #expect(try resolve(style(nil, "aurora"), pick: 0).world == .free)
        // Whatever the share would draw.
        var named = style(nil, nil, telescope)
        named.freeShare = .value(1)
        #expect(try (0..<4).allSatisfy { try resolve(named, pick: $0).world == .telescope })
        named = style(nil, "aurora")
        named.freeShare = .value(0)
        #expect(try (0..<4).allSatisfy { try resolve(named, pick: $0).world == .free })
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
