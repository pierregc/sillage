import Foundation

/// What a night's style step does for one pick: which world, which rendering if one is named,
/// and which palette.
public struct NightStyle: Equatable, Sendable {
    public var world: Palette.World
    /// A rendering of the catalogue, or nil for Auto to choose one.
    public var rendering: String?
    /// `auto`, a family or a `.palette.json` file.
    public var palette: String

    /// The world Auto gives the pick at `index`, best first: the two worlds in turn, so each
    /// morning shows both.
    public static func alternate(_ index: Int) -> Palette.World {
        index.isMultiple(of: 2) ? .telescope : .free
    }

    /// The world a family or a stored palette belongs to; nil for `auto` or bare colours.
    public static func world(
        ofPalette choice: String, references: [TelescopeReference]
    ) -> Palette.World? {
        if FileManager.default.fileExists(atPath: choice) {
            return
                (try? JSONDecoder().decode(Palette.self, from: Data(contentsOf: URL(fileURLWithPath: choice))))?
                .world
        }
        return Palette.World.allCases.first { world in
            PaletteGenerator.families(world, telescope: references.map(\.family))
                .contains { $0.name == choice }
        }
    }

    /// The style of the pick at `index`: a world asked for wins, then the named rendering's
    /// and the palette's, then the turn of the picks. A recipe whose parts disagree is refused.
    public static func resolve(
        _ style: NightRecipe.Style, pick index: Int, catalogue: [LookFile],
        references: [TelescopeReference]
    ) throws -> NightStyle {
        let asked = style.world.value.flatMap(Palette.World.init(rawValue:))
        let choice = style.palette.value ?? "auto"
        var rendering: LookFile?
        if let name = style.style.value {
            guard let found = catalogue.first(where: { $0.name == name }) else {
                throw NightCommand.Failure.noStyle(name)
            }
            rendering = found
        }
        var palette: Palette.World?
        if choice != "auto" {
            palette = world(ofPalette: choice, references: references)
            if palette == nil {
                guard FileManager.default.fileExists(atPath: choice) else {
                    throw NightRecipe.Failure.badValue(
                        "style.palette", "\(choice) is not auto, a family or a .palette.json file")
                }
                guard rendering != nil else {
                    throw NightRecipe.Failure.badValue(
                        "style.palette",
                        "\(choice) holds bare colours: name a style.style for them")
                }
            }
        }
        for (what, other) in [("style.style", rendering?.world), ("style.palette", palette)] {
            if let other, let asked, other != asked {
                throw NightRecipe.Failure.badValue(
                    what, "belongs to the \(other.rawValue) world, not the \(asked.rawValue) one")
            }
        }
        if let a = rendering?.world, let b = palette, a != b {
            throw NightRecipe.Failure.badValue(
                "style.palette", "belongs to the \(b.rawValue) world, style.style to the \(a.rawValue) one")
        }
        return NightStyle(
            world: asked ?? rendering?.world ?? palette ?? alternate(index),
            rendering: rendering?.name, palette: choice)
    }

    /// The `look` command that carries it out.
    public func arguments(scene: String) -> [String] {
        if let rendering {
            return ["look", scene, "--palette", palette, "--world", world.rawValue, "--base", rendering]
        }
        return ["look", scene, "--style", "auto", "--world", world.rawValue]
            + (palette == "auto" ? [] : ["--palette", palette])
    }
}
