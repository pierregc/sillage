import Foundation

/// One scene's folder, `library/<batch>/<scene>/`, which every stage reads and writes. Each
/// path is derived from the folder, so a stage needs the folder and its own options and
/// nothing else.
public struct SceneFolder: Sendable, Equatable {
    public enum Stage: String, CaseIterable, Sendable {
        case explore, hires, look, export

        /// The issue a stage still waiting for its implementation arrives with.
        public var pendingIssue: Int? {
            switch self {
            case .explore: nil
            case .hires: 19
            case .look: 22
            case .export: 24
            }
        }
    }

    /// What neither the scene file nor the look file holds: how long the clip runs and how
    /// large it is drawn. Kept beside them, so a rerun plays the same stretch of time.
    public struct Clip: Codable, Sendable, Equatable {
        public var particles = 700_000
        public var width = 1600
        public var height = 900
        public var frames = 900
        public var fps = 30
        public var steps = 900
        public var settle = 400

        public init() {}

        public static let options = [
            "particles", "width", "height", "frames", "fps", "steps", "settle",
        ]

        public subscript(option: String) -> Int? {
            get {
                switch option {
                case "particles": particles
                case "width": width
                case "height": height
                case "frames": frames
                case "fps": fps
                case "steps": steps
                case "settle": settle
                default: nil
                }
            }
            set {
                guard let newValue else { return }
                switch option {
                case "particles": particles = newValue
                case "width": width = newValue
                case "height": height = newValue
                case "frames": frames = newValue
                case "fps": fps = newValue
                case "steps": steps = newValue
                case "settle": settle = newValue
                default: break
                }
            }
        }

        /// Takes the clip's own options out of a command line, leaving every other one as it
        /// was given.
        public func updated(with options: [String]) -> (clip: Clip, rest: [String]) {
            var clip = self
            var rest: [String] = []
            var index = 0
            while index < options.count {
                let name = options[index].hasPrefix("--") ? String(options[index].dropFirst(2)) : ""
                if Self.options.contains(name), index + 1 < options.count,
                    let value = Double(options[index + 1])
                {
                    clip[name] = Int(value)
                    index += 2
                } else {
                    rest.append(options[index])
                    index += 1
                }
            }
            return (clip, rest)
        }

        public var arguments: [String] {
            Self.options.flatMap { ["--\($0)", String(self[$0] ?? 0)] }
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    public let url: URL

    public init(_ url: URL) { self.url = url.standardizedFileURL }

    public init(path: String) { self.init(URL(fileURLWithPath: path, isDirectory: true)) }

    /// Where the batch's own files sit: `index.csv` and the ratings.
    public var batch: URL { url.deletingLastPathComponent() }
    public var scene: URL { file("scene.json") }
    public var look: URL { file("look.json") }
    public var clip: URL { file("clip.json") }
    public var preview: URL { file("preview.mov") }
    public var thumbnail: URL { file("thumbnail.png") }
    public var curves: URL { file("curves.csv") }
    public var take: URL { file("take.sillage") }
    public var exports: URL { url.appendingPathComponent("exports", isDirectory: true) }

    private func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The clip last explored here, or the default one.
    public func storedClip() throws -> Clip {
        exists(clip) ? try JSONDecoder().decode(Clip.self, from: Data(contentsOf: clip)) : Clip()
    }

    /// The `sillage-render` command line `explore` runs. The first occurrence of a flag wins,
    /// so the outputs come first and the folder cannot be written around, then the options
    /// given, then the files already here. A folder with no scene file yet starts a free draw,
    /// self-gravitating, at whatever `--batch-seed` and `--index` the options give.
    public func exploreArguments(_ options: [String], clip: Clip) -> [String] {
        var arguments = [
            "--video", preview.path, "--curves", curves.path, "--thumbnail", thumbnail.path,
            "--scene-out", scene.path, "--look-out", look.path,
        ]
        arguments += options + clip.arguments
        arguments +=
            exists(scene)
            ? ["--scene", scene.path] : ["--preset", "free", "--solver", "barnes-hut"]
        if exists(look) { arguments += ["--look", look.path] }
        return arguments
    }
}
