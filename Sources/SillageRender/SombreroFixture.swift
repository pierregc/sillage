import Foundation

/// The Sombrero fixture (#513): a few frames of the film's look and inside options over the
/// engines' small take, which Metal draws on the Mac as references and the CUDA engine draws on
/// Linux against them. `Tests/Fixtures/sombrero/recipe.json` lists the frames.
public struct SombreroFixture: Decodable, Sendable {
    public struct Frame: Decodable, Sendable {
        public var flight: String
        public var seconds: Double
        /// Metal's frame, 8-bit RGBA rows from the top, beside the recipe.
        public var file: String
        public var what: String
    }

    public var take: String
    public var look: String
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var frames: [Frame]
    /// The folder the recipe's paths are relative to.
    public var folder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case take, look, width, height, framesPerSecond, frames
    }

    /// The command that writes Metal's references, run on the Mac from the repository.
    public static let command = "SILLAGE_WRITE_SOMBRERO=1 ./scripts/dev.sh test --filter SombreroFixtureTests"

    public static func load(from folder: URL) throws -> SombreroFixture {
        let data = try Data(contentsOf: folder.appendingPathComponent("recipe.json"))
        var fixture = try JSONDecoder().decode(SombreroFixture.self, from: data)
        fixture.folder = folder
        return fixture
    }

    public func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
    }

    /// The video frame whose grain a frame is drawn with.
    public func index(_ frame: Frame) -> Int { Int((frame.seconds * Double(framesPerSecond)).rounded()) }

    /// The flight `name` in a file of its own under `directory`, its dust screen's tile named by
    /// its whole path, as a flight read from anywhere needs it.
    public func flight(_ name: String, into directory: URL) throws -> URL {
        let data = try Data(contentsOf: url(name))
        guard var flight = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if var inside = flight["inside"] as? [String: Any],
            var screen = inside["dustScreen"] as? [String: Any],
            let tile = screen["tile"] as? String
        {
            screen["tile"] = url(tile).path
            inside["dustScreen"] = screen
            flight["inside"] = inside
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: flight, options: [.sortedKeys]).write(to: out)
        return out
    }
}
