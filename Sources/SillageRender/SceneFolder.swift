import Foundation
import SillageCore

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
            case .hires: nil
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
    public var interest: URL { file("interest.json") }
    public var take: URL { file("take.sillage") }
    public var hiresVideo: URL { file("hires.mov") }
    public var hiresCurves: URL { file("curves-hires.csv") }
    public var hires: URL { file("hires.json") }
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

extension SceneFolder.Clip {
    /// The preview's stretch of simulated time at a step no longer than `maximumStep`. A whole
    /// number of steps per frame keeps every frame at the time the preview showed it; only the
    /// settle is rounded, to the nearest step.
    public func spanning(previewStep: Double, maximumStep: Double, frames: Int? = nil)
        -> (settle: Int, steps: Int, timeStep: Double)
    {
        let interval = Double(max(steps / max(self.frames, 1), 1)) * previewStep
        let perFrame = max(Int((interval / maximumStep * (1 - 1e-9)).rounded(.up)), 1)
        let timeStep = interval / Double(perFrame)
        let settle = Int((Double(self.settle) * previewStep / timeStep).rounded())
        return (settle, perFrame * (frames ?? self.frames), timeStep)
    }
}

extension SceneFolder {
    /// What a `hires` run used, and what it cost, kept beside the preview.
    public struct Hires: Codable, Sendable, Equatable {
        public var particles: Int
        public var previewParticles: Int
        public var width: Int
        public var height: Int
        public var frames: Int
        public var fps: Int
        public var settle: Int
        public var steps: Int
        public var timeStepScale: Float
        /// In simulation units, pinned for the run; the Myr figures are for reading.
        public var timeStep: Double
        public var timeStepMyr: Double
        public var previewTimeStepMyr: Double
        public var softening: Float
        public var clipStartMyr: Double
        public var clipEndMyr: Double
        public var seconds: Double?
        public var peakMemoryBytes: Int?
        public var takeBytes: Int?

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    public enum HiresError: Error, CustomStringConvertible {
        case notExplored(URL)
        case derived(String)
        case aboveMaximum(Int, Int)

        public var description: String {
            switch self {
            case .notExplored(let url): "\(url.path): no scene.json and clip.json, explore it first"
            case .derived(let option):
                "--\(option) is worked out from the preview's, so the clip covers the same time"
            case .aboveMaximum(let asked, let maximum):
                "\(asked) particles is above this Mac's maximum of \(maximum);"
                    + " raise it with \(SceneFolder.maximumParticlesVariable)"
            }
        }
    }

    public static let maximumParticlesVariable = "SILLAGE_MAX_PARTICLES"
    /// Measured on the M4 Max with 36 GB, see "High resolution" in the README.
    public static let defaultMaximumParticles = 2_000_000

    /// The most particles `hires` runs, and what it runs when not told: a setting of the
    /// machine rather than of the scene.
    public static func maximumParticles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        environment[maximumParticlesVariable].flatMap { Double($0) }.map { Int($0) }
            ?? defaultMaximumParticles
    }

    /// The scenes of a batch folder marked yes in its ratings.
    public static func chosen(inBatch batch: URL) -> [SceneFolder] {
        SceneRatings.read(batch: batch).chosen.map {
            SceneFolder(batch.appendingPathComponent($0, isDirectory: true))
        }
    }

    public var isExplored: Bool { exists(scene) && exists(clip) }

    /// The record of the last `hires` run here, if it finished.
    public func storedHires() -> Hires? {
        (try? Data(contentsOf: hires)).flatMap { try? JSONDecoder().decode(Hires.self, from: $0) }
    }

    /// The `sillage-render` command line `hires` runs, and what it will record. The scene and
    /// the look are the preview's, the particle count is the one asked for, and the steps are
    /// worked out again so the clip spans the same megayears. `--frames` takes the first frames
    /// of the clip at the same cadence, for a shorter run. Nothing the preview wrote is touched.
    public func hiresArguments(_ options: [String], maximumParticles: Int) throws -> (
        arguments: [String], record: Hires
    ) {
        guard isExplored else { throw HiresError.notExplored(url) }
        for option in ["steps", "settle", "dt"] where options.contains("--\(option)") {
            throw HiresError.derived(option)
        }
        let preview = try storedClip()
        var (asked, rest) = preview.updated(with: options)
        if !options.contains("--particles") { asked.particles = maximumParticles }
        guard asked.particles <= maximumParticles else {
            throw HiresError.aboveMaximum(asked.particles, maximumParticles)
        }

        let file = try SceneFile.decoded(from: Data(contentsOf: scene))
        var hiresFile = file
        if let index = rest.firstIndex(of: "--dt-scale"), index + 1 < rest.count,
            let scale = Float(rest[index + 1])
        {
            hiresFile.timeStepScale = scale
        }
        let previewStep = Double(file.scene(particleCount: preview.particles).timeStep)
        let target = hiresFile.scene(particleCount: asked.particles)
        let span = preview.spanning(
            previewStep: previewStep, maximumStep: Double(target.timeStep), frames: asked.frames)
        let myr = Physics.megayearsPerTimeUnit
        let record = Hires(
            particles: asked.particles, previewParticles: preview.particles, width: asked.width,
            height: asked.height, frames: asked.frames, fps: asked.fps, settle: span.settle,
            steps: span.steps, timeStepScale: hiresFile.timeStepScale, timeStep: span.timeStep,
            timeStepMyr: span.timeStep * myr, previewTimeStepMyr: previewStep * myr,
            softening: target.softening, clipStartMyr: Double(span.settle) * span.timeStep * myr,
            clipEndMyr: Double(span.settle + span.steps) * span.timeStep * myr)

        var arguments = [
            "--video", hiresVideo.path, "--curves", hiresCurves.path, "--take", take.path,
            "--no-sidecars",
        ]
        arguments += [
            "--particles", String(asked.particles), "--width", String(asked.width), "--height",
            String(asked.height), "--frames", String(asked.frames), "--fps", String(asked.fps),
            "--steps", String(span.steps), "--settle", String(span.settle),
            "--dt", String(format: "%.9g", span.timeStep),
        ]
        arguments += rest + ["--scene", scene.path]
        if exists(look) { arguments += ["--look", look.path] }
        return (arguments, record)
    }
}
