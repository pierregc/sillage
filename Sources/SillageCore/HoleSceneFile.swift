import Foundation

/// What a scene file holds: galaxies, as every file written before #332, or a black hole close up.
public enum SceneKind: String, Codable, Sendable, CaseIterable {
    case galaxies
    case blackHole

    private struct Peek: Decodable { var kind: SceneKind? }

    /// The kind a scene file says it is, galaxies when it says nothing; nil when it is not JSON
    /// or names a kind this build does not know.
    public static func of(_ data: Data) -> SceneKind? {
        (try? JSONDecoder().decode(Peek.self, from: data)).map { $0.kind ?? .galaxies }
    }

    public static func of(file url: URL) -> SceneKind? {
        (try? Data(contentsOf: url)).flatMap(of)
    }
}

/// A black hole close up as a scene folder keeps it in `scene.json` (#332): a `TidalDisruption`
/// under a kind of its own, so that a reader of galaxies refuses it by name rather than by a
/// missing field. The tracer count is the scene's, unlike a galaxy scene's: the gas's grid and
/// the take are counted in tracers, and a run repeats only at the count it ran at.
public struct HoleSceneFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var kind = SceneKind.blackHole
    public var name: String
    public var blackHole: TidalDisruption

    public init(name: String, blackHole: TidalDisruption) {
        self.name = name
        self.blackHole = blackHole
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case unsupportedVersion(Int)
        case notABlackHole(SceneKind?)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "black hole scene version \(version), this build reads \(HoleSceneFile.currentVersion)"
            case .notABlackHole(let kind):
                "not a black hole scene: \(kind.map(\.rawValue) ?? "unreadable")"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> HoleSceneFile {
        let kind = SceneKind.of(data)
        guard kind == .blackHole else { throw ReadError.notABlackHole(kind) }
        let file = try JSONDecoder().decode(HoleSceneFile.self, from: data)
        guard file.version == currentVersion else { throw ReadError.unsupportedVersion(file.version) }
        return file
    }
}
