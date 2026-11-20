import Foundation
import SillageCore

/// Which moments of a black hole close up's run a video draws (#332): a span of the run, from
/// `from` to `to` in the hole's time units, over `seconds` of video. Each frame lands on a step
/// of the run, so that stepping on from a frame the take kept reaches it exactly.
public struct HolePlan: Sendable, Equatable {
    /// The run's step at each frame, counted from the release.
    public var steps: [Int]
    public var framesPerSecond: Int

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case emptySpan(Double, Double)
        case tooShort

        public var description: String {
            switch self {
            case .emptySpan(let from, let to):
                String(format: "the span from %.1f to %.1f holds no step of the run", from, to)
            case .tooShort: "a video of at least one frame"
            }
        }
    }

    /// The whole run by default; `from` and `to` are clamped to it. A frozen moment, `from` equal
    /// to `to`, is a video of that moment held.
    public init(
        header: HoleTakeFile.Header, from: Double? = nil, to: Double? = nil, seconds: Double,
        framesPerSecond: Int
    ) throws {
        let last = header.steps.last ?? 0
        func step(_ time: Double) -> Int {
            min(max(Int(((time - header.releaseTime) / header.timeStep).rounded()), 0), last)
        }
        let first = from.map(step) ?? 0
        let end = to.map(step) ?? last
        guard end >= first else { throw Failure.emptySpan(from ?? 0, to ?? 0) }
        let count = Int((seconds * Double(framesPerSecond)).rounded())
        guard count >= 1 else { throw Failure.tooShort }
        steps = (0..<count).map { index in
            let share = count == 1 ? 0 : Double(index) / Double(count - 1)
            return first + Int((Double(end - first) * share).rounded())
        }
        self.framesPerSecond = framesPerSecond
    }

    public var frames: Int { steps.count }

    /// How far through the video frame `index` is, from 0 to 1, for a camera that moves.
    public func progress(_ index: Int) -> Double {
        frames <= 1 ? 0 : Double(index) / Double(frames - 1)
    }
}

extension SceneFolder {
    /// Whether the scene here is a black hole close up (#332) rather than galaxies.
    public var isBlackHole: Bool { SceneKind.of(file: scene) == .blackHole }

    public enum HoleError: Error, CustomStringConvertible {
        case notABlackHole(URL)
        case noTake(URL)
        case noSuchLook(String)
        case galaxyStage(String)

        public var description: String {
            switch self {
            case .notABlackHole(let url): "\(url.path): no black hole scene here"
            case .noTake(let url): "\(url.path): no take.sillage yet, run hires first"
            case .noSuchLook(let name):
                "no black hole look \"\(name)\": neither a file, a look kept in the scene nor one of "
                    + HoleLookFile.catalogue.map(\.name).joined(separator: ", ")
            case .galaxyStage(let stage):
                "\(stage) is for galaxies: a black hole close up runs with hires and draws with export"
            }
        }
    }

    public func holeScene() throws -> HoleSceneFile {
        guard isBlackHole else { throw HoleError.notABlackHole(url) }
        return try HoleSceneFile.decoded(from: Data(contentsOf: scene))
    }

    /// Writes a new close up here: its scene, and no look, so that it draws with the default.
    public func create(_ scene: HoleSceneFile) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try scene.encoded().write(to: self.scene, options: .atomic)
    }

    public func holeLookFile(named name: String) -> URL {
        looks.appendingPathComponent("\(name).\(HoleLookFile.fileExtension)")
    }

    /// The look a close up draws with: the scene's `look.json`, else `physics`; or `name`, which
    /// is a file, a look kept in `looks/` or one of the catalogue, in that order.
    public func holeLook(_ name: String?) throws -> HoleLookFile {
        guard let name else {
            return FileManager.default.fileExists(atPath: look.path)
                ? try HoleLookFile.decoded(from: Data(contentsOf: look)) : .physics
        }
        let file = name.hasSuffix(".json") ? URL(fileURLWithPath: name) : nil
        for url in [file, holeLookFile(named: name)].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            return try HoleLookFile.decoded(from: Data(contentsOf: url))
        }
        guard let found = HoleLookFile.catalogue.first(where: { $0.name == name }) else {
            throw HoleError.noSuchLook(name)
        }
        return found
    }
}

/// What `export` is asked for a black hole close up: `--preset`, `--codec`,
/// `--look physics|film|<name>|<file>`, `--from t --to t` in the hole's time units, `--seconds`,
/// `--fps`, `--width`, `--height`, `--out`, `--stills <dir>`. A galaxy's options that mean
/// nothing here are refused rather than ignored.
public struct HoleExportOptions: Sendable {
    public var preset = VideoPreset.named("1080p")!
    public var codec: VideoCodec?
    public var look: String?
    public var from: Double?
    public var to: Double?
    /// The whole run of the default scene, 5000 time units, in 40 s: 4 time units a frame.
    public var seconds: Double = 40
    public var framesPerSecond = 30
    public var width: Int?
    public var height: Int?
    public var out: URL?
    public var stills: URL?

    public init() {}

    public static let galaxyOptions = [
        "speed", "flight", "framing", "format", "palette", "world", "overlay", "take",
    ]

    public init(_ arguments: [String]) throws {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }
        func number(_ name: String) throws -> Double? {
            guard let text = option(name) else { return nil }
            guard let value = Double(text), value.isFinite else {
                throw SceneFolder.ExportError.badValue(name, text)
            }
            return value
        }
        for name in Self.galaxyOptions where arguments.contains("--\(name)") {
            throw SceneFolder.ExportError.badValue(name, "not for a black hole close up")
        }
        if let name = option("preset") {
            guard let preset = VideoPreset.named(name) else {
                throw SceneFolder.ExportError.noSuchPreset(name)
            }
            self.preset = preset
        }
        if let name = option("codec") {
            guard let codec = VideoCodec(rawValue: name.lowercased()) else {
                throw SceneFolder.ExportError.noSuchCodec(name)
            }
            self.codec = codec
        }
        if let pinned = preset.codec, let codec, codec != pinned {
            throw SceneFolder.ExportError.codecNotAllowed(preset: preset.name, codec: pinned)
        }
        look = option("look")
        from = try number("from")
        to = try number("to")
        if let seconds = try number("seconds") {
            guard seconds > 0 else { throw SceneFolder.ExportError.badValue("seconds", String(seconds)) }
            self.seconds = seconds
        }
        if let fps = try number("fps") {
            guard fps >= 1 else { throw SceneFolder.ExportError.badValue("fps", String(fps)) }
            framesPerSecond = Int(fps)
        }
        width = try number("width").map { Int($0) }
        height = try number("height").map { Int($0) }
        if (width ?? 16) < 16 || (height ?? 16) < 16 {
            throw SceneFolder.ExportError.badValue("width or height", "\(width ?? 0)x\(height ?? 0)")
        }
        out = option("out").map { URL(fileURLWithPath: $0) }
        stills = option("stills").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
