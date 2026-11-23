import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// Choosing a scene's look without drawing it (#467): `look <scene folder> --promote <name>` and
/// `--palette auto|<family>|<favourite>|<file>`, the same for either engine. `--style auto` and
/// `--grid` draw the take with Metal and stay the Mac's.
public enum LookChoice {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case message(String)
        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// What `--palette` names: a generated or stored palette, or a bare list of colours.
    public enum PaletteChoice {
        case recipe(Palette, PaletteScore)
        case colours([SIMD3<Float>])
    }

    /// What a scene's palette is drawn from: the seed in its `scene.json`.
    public static func sceneSeed(_ folder: SceneFolder) throws -> (seed: UInt64, galaxies: Int) {
        let file = try SceneFile.decoded(from: Data(contentsOf: folder.scene))
        return (file.seed, file.galaxies.count)
    }

    public static func world(_ name: String?) throws -> Palette.World? {
        try name.map { name in
            guard let world = Palette.World(rawValue: name) else {
                throw Failure.message("--world is telescope or free")
            }
            return world
        }
    }

    /// `auto`, a family, a favourite or a `.palette.json` for `folder`'s scene: `auto` is the best
    /// scored of a fixed number of candidates drawn from the scene's seed, a family the same
    /// inside one family, and a file is taken as it is. Colours come as ramps (#120) unless
    /// `single` asks for one colour per galaxy.
    public static func resolve(
        _ folder: SceneFolder, choice: String, world asked: Palette.World?, single: Bool = false,
        references: [TelescopeReference], favourites: [FavouritePalettes.Favourite]
    ) throws -> PaletteChoice {
        if !FileManager.default.fileExists(atPath: choice),
            let favourite = FavouritePalettes.find(choice, in: favourites)
        {
            let (_, galaxies) = try sceneSeed(folder)
            guard favourite.palette.colours.count >= galaxies else {
                throw Failure.message("favourite \(choice) has fewer colours than the scene has galaxies")
            }
            var palette = favourite.palette.truncated(to: galaxies)
            if single { palette = palette.withMulticolour(false) }
            return .recipe(palette, PaletteScore(palette, references: references))
        }
        if FileManager.default.fileExists(atPath: choice) {
            let data = try Data(contentsOf: URL(fileURLWithPath: choice))
            struct Bare: Decodable { var colours: [SIMD3<Float>] }
            if var recipe = try? JSONDecoder().decode(Palette.self, from: data) {
                if single { recipe = recipe.withMulticolour(false) }
                return .recipe(recipe, PaletteScore(recipe, references: references))
            }
            if let bare = try? JSONDecoder().decode(Bare.self, from: data), !bare.colours.isEmpty {
                return .colours(bare.colours)
            }
            throw Failure.message("\(choice) is not a palette file: {\"colours\": [[r, g, b], ...]}")
        }
        let (seed, galaxies) = try sceneSeed(folder)
        let family = choice == "auto" ? nil : choice
        var chosen = asked ?? .free
        if let family, asked == nil {
            let worlds = Palette.World.allCases.filter { world in
                PaletteGenerator.families(world, telescope: references.map(\.family))
                    .contains { $0.name == family }
            }
            guard let found = worlds.first else {
                throw Failure.message("--palette is auto, a family or a .palette.json file, not \(choice)")
            }
            chosen = found
        }
        let top = try PaletteAuto.ranked(
            galaxies: galaxies, world: chosen, family: family, seed: seed, telescope: references,
            favourites: favourites.map(\.palette), multicolour: !single)[0]
        return .recipe(top.palette, top.score)
    }

    /// Puts the palette in `look`, with the recipe it came from when it has one.
    public static func apply(
        _ choice: PaletteChoice, to look: inout LookFile, references: [TelescopeReference]
    ) {
        switch choice {
        case .recipe(let palette, _):
            look.paletteRecipe = palette
            look.palette = palette.galaxyColours(references: references)
        case .colours(let colours):
            look.paletteRecipe = nil
            look.palette = colours.map { GalaxyColours($0) }
        }
    }

    /// `--palette`: puts a palette in the scene's look, promoted as `--promote` does with the old
    /// look kept. `generated` holds the dust to `StyleAuto.dustCap` as Auto does, for the night.
    public static func promotePalette(
        _ folder: SceneFolder, choice: String, world: Palette.World?, base: String?, single: Bool,
        camera: LookFile.CameraPlan.Mode? = nil, generated: Bool = false, catalogue: [LookFile],
        references: [TelescopeReference], favourites: [FavouritePalettes.Favourite]
    ) throws -> String {
        var look =
            (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) } ?? .standard
        if let base {
            guard
                let found = catalogue.first(where: { $0.name == base })
                    ?? (try? LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: base))))
            else { throw Failure.message("no look \(base)") }
            look = found
        }
        if generated { look = StyleAuto.generated(look) }
        let picked = try resolve(
            folder, choice: choice, world: world, single: single, references: references,
            favourites: favourites)
        apply(picked, to: &look, references: references)
        if let camera { look.camera.mode = camera }
        try folder.promote(look)
        switch picked {
        case .recipe(let palette, let score):
            return String(
                format: "look       palette %@ (%@ world, score %.2f) is now in %@", palette.name,
                palette.world.rawValue, score.total, folder.look.path)
        case .colours(let colours):
            return "look       \(choice): \(colours.count) colours set in \(folder.look.path)"
        }
    }

    /// `look` on an engine that draws nothing for it: `--promote` and `--palette`.
    public static func lines(_ arguments: [String], command: String) throws -> [String] {
        guard let path = arguments.first, !path.hasPrefix("--") else {
            throw Failure.message(
                "usage: \(command) look <scene folder> --promote <name> | --palette <auto|family|file>")
        }
        let options = Array(arguments.dropFirst())
        func option(_ name: String) -> String? {
            options.firstIndex(of: "--\(name)").flatMap { $0 + 1 < options.count ? options[$0 + 1] : nil }
        }
        let folder = SceneFolder(path: path)
        for drawn in ["style", "grid"] where options.contains("--\(drawn)") {
            throw Failure.message(
                "--\(drawn) draws the take with Metal: run it with sillage-render look on the Mac")
        }
        var camera: LookFile.CameraPlan.Mode?
        if let name = option("camera") {
            guard let mode = LookFile.CameraPlan.Mode(rawValue: name) else {
                throw Failure.message("--camera is auto, fixed, director or immersed")
            }
            camera = mode
        }
        if let choice = option("palette") {
            return [
                try promotePalette(
                    folder, choice: choice, world: try world(option("world")), base: option("base"),
                    single: options.contains("--single"), camera: camera,
                    generated: options.contains("--generated"), catalogue: try LookCatalogue.fromRepository(),
                    references: try TelescopeReference.fromRepository(), favourites: FavouritePalettes.load())
            ]
        }
        if let name = option("promote") {
            let file = try folder.promote(look: name)
            return ["look       \(file.name) is now \(folder.look.path)"]
        }
        return [
            "look       choose a look with",
            "           \(command) look \(folder.url.path) --palette auto",
            "           \(command) look \(folder.url.path) --promote <name>",
        ]
    }
}
