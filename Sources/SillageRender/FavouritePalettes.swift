import Foundation

/// The palettes kept in the repository's `palettes/`, one `<name>.palette.json` each, the
/// file `look --palette` already takes.
public enum FavouritePalettes {
    public struct Favourite: Equatable, Sendable {
        public var name: String
        public var palette: Palette
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noName
        case taken(String)

        public var description: String {
            switch self {
            case .noName: "a favourite needs a name made of letters or digits"
            case .taken(let name): "a favourite called \(name) already exists"
            }
        }
    }

    public static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("palettes", isDirectory: true)

    public static let suffix = ".palette.json"

    /// Every readable favourite of `directory`, by name. A file that does not decode is left out.
    public static func load(from directory: URL = directory) -> [Favourite] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.sorted().compactMap { file in
            (try? Data(contentsOf: directory.appendingPathComponent(file)))
                .flatMap { try? JSONDecoder().decode(Palette.self, from: $0) }
                .map { Favourite(name: String(file.dropLast(suffix.count)), palette: $0) }
        }
    }

    /// `name` as a file stem: lower case words joined by dashes. Empty when nothing is left.
    public static func slug(_ name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
    }

    /// The favourites of `world` that `galaxies` galaxies can use: one with more colours than
    /// galaxies keeps its first ones, one with fewer is left out. `family` keeps one family.
    public static func fitting(
        _ favourites: [Favourite], world: Palette.World, galaxies: Int, family: String? = nil
    ) -> [Favourite] {
        favourites.filter {
            $0.palette.world == world && $0.palette.colours.count >= galaxies
                && (family == nil || $0.palette.family == family)
        }.map { Favourite(name: $0.name, palette: $0.palette.truncated(to: galaxies)) }
    }

    public static func find(_ name: String, in favourites: [Favourite]) -> Favourite? {
        favourites.first { $0.name == name }
    }

    /// The favourite that `palette`, possibly cut to fewer galaxies, comes from.
    public static func favourite(
        matching palette: Palette, in favourites: [Favourite]
    ) -> Favourite? {
        favourites.first { $0.palette.truncated(to: palette.colours.count) == palette }
    }

    /// Writes `palette` as `<slug of name>.palette.json`, never over another favourite.
    @discardableResult
    public static func save(
        _ palette: Palette, named name: String, in directory: URL = directory
    ) throws -> Favourite {
        let stem = slug(name)
        guard !stem.isEmpty else { throw Failure.noName }
        let url = directory.appendingPathComponent(stem + suffix)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.taken(stem) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(palette) + Data("\n".utf8)).write(to: url, options: .atomic)
        return Favourite(name: stem, palette: palette)
    }

    public static func remove(_ favourite: Favourite, in directory: URL = directory) throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(favourite.name + suffix))
    }
}

extension Palette {
    /// The first `count` colours.
    public func truncated(to count: Int) -> Palette {
        var palette = self
        palette.colours = Array(colours.prefix(count))
        return palette
    }
}
