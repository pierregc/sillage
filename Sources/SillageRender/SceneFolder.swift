import Foundation
import SillageCore

/// One scene's folder, `library/<batch>/<scene>/`, which every stage reads and writes. Each
/// path is derived from the folder, so a stage needs the folder and its own options and
/// nothing else.
public struct SceneFolder: Sendable, Equatable {
    public enum Stage: String, CaseIterable, Sendable {
        case explore, hires, look, export, palettes
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
        /// Steps run before the first frame: 150 Myr at the explore count's step, where the
        /// first radial excursion of a sampled disk has peaked (docs/notes/disk-settling.md).
        public var settle = 750
        /// Where the story runs in the captured frames, once `explore` has followed it to its end.
        public var story: Story.Span?

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
    /// The look `explore` wrote, kept aside once another look is promoted over it.
    public var rawLook: URL { file("look-raw.json") }
    /// Candidate looks for the scene, one `<name>.look.json` each.
    public var looks: URL { url.appendingPathComponent("looks", isDirectory: true) }
    public var clip: URL { file("clip.json") }
    public var preview: URL { file("preview.mov") }
    public var thumbnail: URL { file("thumbnail.png") }
    public var curves: URL { file("curves.csv") }
    public var interest: URL { file("interest.json") }
    public var take: URL { file("take.sillage") }
    public var hiresVideo: URL { file("hires.mov") }
    public var hiresCurves: URL { file("curves-hires.csv") }
    public var hires: URL { file("hires.json") }
    /// Every particle of a full pass at a few key frames (#239), and which frames they are.
    public var keyFrames: URL { file("keyframes.sillage") }
    public var keyFrameList: URL { file("keyframes.json") }
    public var exports: URL { url.appendingPathComponent("exports", isDirectory: true) }
    public var lookGrid: URL { looks.appendingPathComponent("grid.png") }
    /// What `palettes` draws: `sheet.png`, `swatches.png` and one look file per palette.
    public var palettes: URL { url.appendingPathComponent("palettes", isDirectory: true) }

    private func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Makes `look` the one the scene renders with. The first look it replaces is kept as
    /// `look-raw.json`, so the plain look `explore` judged the dynamics with is never lost.
    public func promote(_ look: LookFile) throws {
        let manager = FileManager.default
        if exists(self.look), !exists(rawLook) {
            try manager.moveItem(at: self.look, to: rawLook)
        }
        try look.encoded().write(to: self.look, options: .atomic)
    }

    /// The clip last explored here, or the default one.
    public func storedClip() throws -> Clip {
        exists(clip) ? try JSONDecoder().decode(Clip.self, from: Data(contentsOf: clip)) : Clip()
    }

    /// The `sillage-render` command line `explore` runs. The first occurrence of a flag wins,
    /// so the outputs come first and the folder cannot be written around, then the options
    /// given, then the files already here. The story is followed past the planned clip to its
    /// end, up to `Story.capMyr`. A folder with no scene file yet starts a free draw,
    /// self-gravitating, at whatever `--batch-seed` and `--index` the options give.
    public func exploreArguments(_ options: [String], clip: Clip) -> [String] {
        var arguments = [
            "--video", preview.path, "--curves", curves.path, "--thumbnail", thumbnail.path,
            "--scene-out", scene.path, "--look-out", look.path,
        ]
        arguments += options + clip.arguments
        if !options.contains("--story-cap") { arguments += ["--story-cap", String(Story.capMyr)] }
        arguments +=
            exists(scene)
            ? ["--scene", scene.path] : ["--preset", "free", "--solver", "barnes-hut"]
        if exists(look) { arguments += ["--look", look.path] }
        return arguments
    }
}

extension SceneFolder.Clip {
    /// The preview's story, or its whole clip before one was recorded, at a step no longer than
    /// `maximumStep`. A whole number of steps per frame keeps every frame at the time the preview
    /// showed it; only the settle is rounded, to the nearest step. `frames` takes that many from
    /// the start of the story.
    public func spanning(previewStep: Double, maximumStep: Double, frames: Int? = nil)
        -> (settle: Int, steps: Int, timeStep: Double)
    {
        let interval = Double(max(steps / max(self.frames, 1), 1)) * previewStep
        let perFrame = max(Int((interval / maximumStep * (1 - 1e-9)).rounded(.up)), 1)
        let timeStep = interval / Double(perFrame)
        let settle =
            Int((Double(self.settle) * previewStep / timeStep).rounded())
            + (story?.startFrame ?? 0) * perFrame
        return (settle, perFrame * (frames ?? storyFrames), timeStep)
    }

    /// How many captured frames the story holds.
    public var storyFrames: Int { story?.frames ?? frames }
}

extension SceneFolder {
    /// What a `hires` run used, and what it cost, kept beside the preview.
    public struct Hires: Codable, Sendable, Equatable {
        /// Drawn, light tracers included.
        public var particles: Int
        /// The particles that carry the mass when the others are light tracers (#211); absent
        /// when all of them do, as in every record written before.
        public var massive: Int?
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
        /// `massive` when the run held the massive particles alone, the first of two passes
        /// (#239): the take, the curves and the video here are theirs, and the particles drawn
        /// come with the full pass. Absent for a run of every particle.
        public var pass: Pass?
        /// The full pass, once it has drawn the videos.
        public var full: FullPass?

        public enum Pass: String, Codable, Sendable { case massive }

        /// The second of two passes: every particle again, the videos drawn as it ran.
        public struct FullPass: Codable, Sendable, Equatable {
            public var presets: [String]
            public var frames: Int
            public var seconds: Double
            /// Drawing and handing over each preset's frames, the solver's time apart.
            public var drawSeconds: [String: Double]
            public var peakMemoryBytes: Int?
            /// The frames `keyframes.sillage` holds.
            public var keyFrames: [Int]
            /// How far a galaxy's centre strayed from the massive pass's, in kpc, over
            /// `checkedFrames` of its stored frames: 0 when the mass repeated it to the bit.
            public var drift: Float
            public var checkedFrames: Int

            public init(
                presets: [String], frames: Int, seconds: Double, drawSeconds: [String: Double],
                peakMemoryBytes: Int? = nil, keyFrames: [Int] = [], drift: Float = 0,
                checkedFrames: Int = 0
            ) {
                self.presets = presets
                self.frames = frames
                self.seconds = seconds
                self.drawSeconds = drawSeconds
                self.peakMemoryBytes = peakMemoryBytes
                self.keyFrames = keyFrames
                self.drift = drift
                self.checkedFrames = checkedFrames
            }

            /// What drawing cost in all.
            public var drawingSeconds: Double { drawSeconds.values.reduce(0, +) }
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }

        /// Every particle drawn, unless the others were light tracers.
        public var massiveParticles: Int { massive ?? particles }
        public var tracers: Int { particles - massiveParticles }
        /// The particles the run itself moved: the massive ones alone in a massive pass.
        public var simulatedTracers: Int { pass == .massive ? 0 : tracers }

        /// Whether this run stands for one asked at `particles` drawn, `massive` of them carrying
        /// the mass (all when nil), and `frames` when given: drawn alike, with at least as many
        /// massive, so a real 8 M stands for 8 M drawn from 2 M. A massive pass stands only for
        /// the first of two `passes`.
        public func covers(particles: Int, massive: Int?, frames: Int?, passes: Int = 1) -> Bool {
            (pass == nil || passes == 2) && self.particles == particles
                && massiveParticles >= min(massive ?? particles, particles)
                && frames.map { self.frames == $0 } ?? true
        }

        /// Whether a full pass asked as `asked` can follow this run: the same draw at the same
        /// steps, of which this is the massive pass.
        public func leadsTo(_ asked: Hires) -> Bool {
            pass == .massive && particles == asked.particles && massive == asked.massive
                && frames == asked.frames && settle == asked.settle && steps == asked.steps
                && timeStep == asked.timeStep
        }
    }

    public enum HiresError: Error, CustomStringConvertible {
        case notExplored(URL)
        case derived(String)
        case aboveMaximum(Int, Int)
        case badMassive(String)
        case tracerAngle
        case badPass(String)
        case passWithoutTracers
        case noMassivePass(URL)
        case notAVideo(String)

        public var description: String {
            switch self {
            case .notExplored(let url): "\(url.path): no scene.json and clip.json, explore it first"
            case .derived(let option):
                "--\(option) is worked out from the preview's, so the clip covers the same time"
            case .aboveMaximum(let asked, let maximum):
                "\(asked) particles is above this Mac's maximum of \(maximum);"
                    + " raise it with \(SceneFolder.maximumParticlesVariable)"
            case .badMassive(let value): "--massive \(value) is not a count of particles"
            case .tracerAngle:
                "--theta-tracers: light tracers walk at the scene's opening angle, a looser one"
                    + " drifts them off the mass (docs/notes/light-tracers.md)"
            case .badPass(let value): "--pass \(value): massive or full"
            case .passWithoutTracers:
                "--pass: two passes need light tracers, --massive below --particles"
            case .noMassivePass(let url):
                "\(url.path): no massive pass of the same draw and steps here, run --pass massive first"
            case .notAVideo(let name):
                "--export \(name): a full pass draws video presets, "
                    + VideoPreset.all.map(\.name).joined(separator: ", ")
            }
        }
    }

    public static let maximumParticlesVariable = "SILLAGE_MAX_PARTICLES"
    /// Measured on the M4 Max with 36 GB, see "High resolution" in docs/reference.md: ten million
    /// peaks at 16 GB, and a full clip takes a night.
    public static let defaultMaximumParticles = 10_000_000
    /// Wall clock per visible particle per step on the same machine, flat from one to ten
    /// million: 150 at #19, 62 since the opening angle of 0.9 (#166), within 3 % of the two
    /// 8 M hires of 2026-10-30.
    public static let nanosecondsPerParticleStep = 62.0
    /// What a light tracer adds to a step on the same machine (#187), linear in their count.
    public static let nanosecondsPerTracerStep = 20.0
    /// The take keeps one frame in this many, and drawing it again interpolates the rest. At
    /// the cadence `hires` captures, under a megayear a frame, four cannot be told apart from
    /// one on screen, and ten million particles over nine hundred frames come to 13.5 GB
    /// instead of 54. `--take-interval` overrides it.
    public static let hiresTakeInterval = 4

    /// The most particles `hires` runs: a setting of the machine rather than of the scene.
    public static func maximumParticles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        environment[maximumParticlesVariable].flatMap { Double($0) }.map { Int($0) }
            ?? defaultMaximumParticles
    }

    /// The count `--massive` gives in a hires command line, if any.
    public static func massive(in options: [String]) -> Int? {
        guard let index = options.firstIndex(of: "--massive"), index + 1 < options.count,
            let count = Double(options[index + 1]), count >= 1, count < 1e15
        else { return nil }
        return Int(count)
    }

    /// What a hires asked with `options` draws, and how many of those carry the mass (nil for
    /// all). `--particles N` alone is a real N. Without it, what a night draws (#243): its
    /// count, at most `maximumParticles`, from its massive count unless `--massive` is given.
    public static func hiresDraw(_ options: [String], maximumParticles: Int) -> (
        particles: Int, massive: Int?
    ) {
        hiresDraw(
            particles: options.contains("--particles") ? Clip().updated(with: options).clip.particles : nil,
            massive: massive(in: options), maximumParticles: maximumParticles)
    }

    static func hiresDraw(particles: Int?, massive: Int?, maximumParticles: Int) -> (
        particles: Int, massive: Int?
    ) {
        let night = NightRecipe()
        let drawn = particles ?? night.hiresParticles(maximum: maximumParticles)
        let carrying = massive ?? (particles == nil ? night.hiresMassive(maximum: maximumParticles) : drawn)
        // As many as are drawn, or more: every particle carries mass, as without `--massive`.
        return (drawn, carrying < drawn ? carrying : nil)
    }

    /// Whether the hires run here stands for one asked with `options`, which a batch then skips.
    /// A full pass is done once its videos are drawn.
    public func hiresDone(_ options: [String], maximumParticles: Int) -> Bool {
        let draw = Self.hiresDraw(options, maximumParticles: maximumParticles)
        let frames = options.contains("--frames") ? Clip().updated(with: options).clip.frames : nil
        let pass = Self.pass(in: options)
        guard
            let record = storedHires(),
            record.covers(
                particles: draw.particles, massive: draw.massive, frames: frames,
                passes: pass == nil ? 1 : 2)
        else { return false }
        return pass != "full" || record.full != nil
    }

    /// `massive` or `full`, what `--pass` asks, nil without it.
    public static func pass(in options: [String]) -> String? {
        options.firstIndex(of: "--pass").flatMap { $0 + 1 < options.count ? options[$0 + 1] : "" }
    }

    /// The scene's video presets a full pass draws (#239).
    public static let fullPassPresets = NightRecipe.defaultExports

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

    /// The rate the take here was captured at, which an export plays it and replays its camera
    /// at: the hires run's, else the explored clip's.
    public func capturedRate() throws -> Int { try storedHires()?.fps ?? storedClip().fps }

    /// The `sillage-render` command line `hires` runs, and what it will record. The scene and
    /// the look are the preview's, the particles are drawn as `hiresDraw` says, and the steps are
    /// worked out again so the run spans the same megayears as the preview's story. `--frames`
    /// takes the first frames of it at the same cadence, for a shorter run. `--massive M` gives
    /// the mass to about M of the particles and makes the others light tracers (#187): the
    /// softening, the step and the settle are then M's. Nothing the preview wrote is touched.
    /// The take, the video and the curves go to their partial paths, for `commitHires`.
    ///
    /// `--pass massive` runs the massive particles of that draw alone, the tracers left out, and
    /// `--pass full` the whole draw again once the style is chosen on the massive take, drawing
    /// the videos of `--export` (4k and vertical by default) as it runs (#239).
    public func hiresArguments(_ options: [String], maximumParticles: Int) throws -> (
        arguments: [String], record: Hires
    ) {
        guard isExplored else { throw HiresError.notExplored(url) }
        for option in ["steps", "settle", "dt"] where options.contains("--\(option)") {
            throw HiresError.derived(option)
        }
        if options.contains("--theta-tracers") { throw HiresError.tracerAngle }
        let preview = try storedClip()
        var (asked, rest) = preview.updated(with: options)
        if !options.contains("--frames") { asked.frames = preview.storyFrames }
        var massiveAsked: Int?
        if let index = rest.firstIndex(of: "--massive") {
            guard let count = Self.massive(in: rest) else {
                throw HiresError.badMassive(index + 1 < rest.count ? rest[index + 1] : "")
            }
            rest.removeSubrange(index...index + 1)
            massiveAsked = count
        }
        func cut(_ option: String) -> String? {
            guard let index = rest.firstIndex(of: "--\(option)") else { return nil }
            let value = index + 1 < rest.count ? rest[index + 1] : ""
            rest.removeSubrange(index...min(index + 1, rest.count - 1))
            return value
        }
        let pass = cut("pass")
        if let pass, pass != "massive", pass != "full" { throw HiresError.badPass(pass) }
        let presets = try cut("export").map { list in
            try list.split(separator: ",").map(String.init).map { name in
                guard VideoPreset.named(name) != nil else { throw HiresError.notAVideo(name) }
                return name
            }
        }
        let draw = Self.hiresDraw(
            particles: options.contains("--particles") ? asked.particles : nil, massive: massiveAsked,
            maximumParticles: maximumParticles)
        asked.particles = draw.particles
        let massive = draw.massive
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
        let target = hiresFile.scene(particleCount: massive ?? asked.particles)
        let span = preview.spanning(
            previewStep: previewStep, maximumStep: Double(target.timeStep), frames: asked.frames)
        let myr = Physics.megayearsPerTimeUnit
        var record = Hires(
            particles: asked.particles, massive: massive, previewParticles: preview.particles,
            width: asked.width, height: asked.height, frames: asked.frames, fps: asked.fps,
            settle: span.settle, steps: span.steps, timeStepScale: hiresFile.timeStepScale,
            timeStep: span.timeStep, timeStepMyr: span.timeStep * myr,
            previewTimeStepMyr: previewStep * myr, softening: target.softening,
            clipStartMyr: Double(span.settle) * span.timeStep * myr,
            clipEndMyr: Double(span.settle + span.steps) * span.timeStep * myr)
        if pass != nil, massive == nil { throw HiresError.passWithoutTracers }

        var arguments = [
            "--video", Self.partial(hiresVideo).path, "--curves", Self.partial(hiresCurves).path,
            "--take", Self.partial(take).path, "--no-sidecars",
        ]
        if pass == "massive" {
            record.pass = .massive
            arguments.append("--massive-only")
        }
        // The full pass writes no take, no curves and no video of its own: the massive pass's
        // frame its videos, drawn into `exports/` as the run goes, and a few key frames of
        // every particle.
        if pass == "full" {
            guard let stored = storedHires(), stored.leadsTo(record), exists(take) else {
                throw HiresError.noMassivePass(url)
            }
            record = stored
            arguments = [
                "--draw", (presets ?? Self.fullPassPresets).joined(separator: ","),
                "--draw-take", take.path, "--draw-out", exports.path,
                "--key-frames", Self.partial(keyFrames).path, "--key-frame-list", keyFrameList.path,
                "--key-frame-curves", hiresCurves.path, "--no-sidecars",
            ]
        }
        arguments += ["--particles", String(asked.particles)]
        if let massive { arguments += ["--massive", String(massive)] }
        arguments += [
            "--width", String(asked.width), "--height",
            String(asked.height), "--frames", String(asked.frames), "--fps", String(asked.fps),
            "--steps", String(span.steps), "--settle", String(span.settle),
            "--dt", String(format: "%.9g", span.timeStep),
        ]
        arguments += rest + ["--scene", scene.path]
        if !rest.contains("--take-interval") {
            arguments += ["--take-interval", String(Self.hiresTakeInterval)]
        }
        if exists(look) { arguments += ["--look", look.path] }
        return (arguments, record)
    }
}

extension SceneFolder {
    public enum LookError: Error, CustomStringConvertible {
        case noTake(URL)
        case noSuchLook(String, URL)
        case noRawLook(URL)

        public var description: String {
            switch self {
            case .noTake(let url): "\(url.path): no take.sillage yet, run hires first"
            case .noRawLook(let url): "\(url.path): no look-raw.json, the look was never replaced"
            case .noSuchLook(let name, let looks):
                "no look \"\(name)\" in \(looks.path), run look first or pick a row of its grid"
            }
        }
    }

    /// The scene renders with its raw look again, the one `explore` wrote.
    public var hasRawLook: Bool {
        guard let raw = try? Data(contentsOf: rawLook) else { return false }
        return (try? Data(contentsOf: look)) == raw
    }

    /// Puts the look `explore` wrote back in `look.json`. The look it replaces is kept in
    /// `looks/` first, unless a file there holds it already, so going back loses nothing.
    /// Returns where it was kept.
    @discardableResult
    public func restoreRawLook() throws -> URL? {
        guard let raw = try? Data(contentsOf: rawLook) else { throw LookError.noRawLook(url) }
        var kept: URL?
        if let current = try? Data(contentsOf: look), current != raw {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: looks.path)) ?? []
            let files = names.filter { $0.hasSuffix(".look.json") }.map { looks.appendingPathComponent($0) }
            kept = files.first { (try? Data(contentsOf: $0)) == current }
            if kept == nil {
                let name = (try? LookFile.decoded(from: current).name) ?? "style"
                let base = name.isEmpty || name.contains("/") ? "style" : name
                var candidate = lookFile(named: base)
                var suffix = 2
                while exists(candidate) {
                    candidate = lookFile(named: "\(base)-\(suffix)")
                    suffix += 1
                }
                try FileManager.default.createDirectory(at: looks, withIntermediateDirectories: true)
                try current.write(to: candidate, options: .atomic)
                kept = candidate
            }
        }
        try raw.write(to: look, options: .atomic)
        return kept
    }

    public func lookFile(named name: String) -> URL {
        looks.appendingPathComponent("\(name).look.json")
    }

    /// Makes one row of the grid the scene's look, for the full render.
    @discardableResult
    public func promote(look name: String) throws -> LookFile {
        let source = lookFile(named: name)
        guard exists(source) else { throw LookError.noSuchLook(name, looks) }
        let file = try LookFile.decoded(from: Data(contentsOf: source))
        try promote(file)
        return file
    }
}

extension SceneFolder {
    public enum ExportError: Error, CustomStringConvertible {
        case noSuchPreset(String)
        case noSuchLook(String)
        case badValue(String, String)
        case noSuchCodec(String)
        case codecNotAllowed(preset: String, codec: VideoCodec)
        case noRateControl(VideoCodec)
        case tooLong(preset: String, seconds: Double)

        public var description: String {
            switch self {
            case .noSuchPreset(let name):
                "no preset \"\(name)\", pick one of "
                    + VideoPreset.all.map(\.name).joined(separator: ", ")
            case .noSuchLook(let name):
                "no look \"\(name)\": neither a file, a look kept in the scene nor a catalogue look"
            case .badValue(let option, let value): "--\(option) \(value) is not usable"
            case .noSuchCodec(let name):
                "no codec \"\(name)\", pick one of "
                    + VideoCodec.allCases.map(\.rawValue).joined(separator: ", ")
            case .codecNotAllowed(let preset, let codec):
                "the \(preset) preset is \(codec.rawValue) only"
            case .noRateControl(let codec):
                "\(codec.rawValue) has a fixed rate: neither --bitrate nor --quality applies"
            case .tooLong(let preset, let seconds):
                String(
                    format: "%.0f s is too long for the %@ preset's size limit: cut it with --duration",
                    seconds, preset)
            }
        }
    }

    /// The preset's own codec keeps its name (`codec` left out); another adds its own, so one
    /// preset can be exported in all three side by side.
    public func export(preset name: String, codec: VideoCodec? = nil) -> URL {
        let suffix = codec.map { "-\($0.rawValue)" } ?? ""
        return exports.appendingPathComponent(
            "\(name)\(suffix).\((codec ?? .hevc).fileExtension)")
    }

    public func preview(_ name: String, extension: String) -> URL {
        exports.appendingPathComponent("\(name).\(`extension`)")
    }

    /// The scene folder a take belongs to, when it is that folder's own `take.sillage`.
    public static func holding(take url: URL) -> SceneFolder? {
        let folder = SceneFolder(url.deletingLastPathComponent())
        let manager = FileManager.default
        guard folder.take.path == url.standardizedFileURL.path,
            manager.fileExists(atPath: folder.scene.path) || manager.fileExists(atPath: folder.clip.path)
        else { return nil }
        return folder
    }

    /// `<batch>/<scene>`, which names the scene wherever its video ends up.
    public var sceneID: String {
        "\(batch.lastPathComponent)/\(url.lastPathComponent)"
    }

    /// The look an export draws with: the scene's own by default, or `name`, which is a look
    /// file, a row of the look grid or a look of the catalogue, in that order.
    public func exportLook(_ name: String?, catalogue: [LookFile]) throws -> LookFile {
        guard let name else {
            return exists(look) ? try LookFile.decoded(from: Data(contentsOf: look)) : .standard
        }
        let file = name.hasSuffix(".json") ? URL(fileURLWithPath: name) : nil
        for url in [file, lookFile(named: name)].compactMap({ $0 }) where exists(url) {
            return try LookFile.decoded(from: Data(contentsOf: url))
        }
        guard let found = catalogue.first(where: { $0.name == name }) else {
            throw ExportError.noSuchLook(name)
        }
        return found
    }
}

extension SceneFolder {
    /// Where an output is written until it is whole: hidden beside it, so the library never
    /// shows half a take or half a video, and what an interrupted stage leaves is easy to find.
    public static func partial(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent)
    }

    /// Renames a finished output into place, over the one it replaces.
    public static func commit(_ url: URL) throws {
        guard rename(partial(url).path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Puts a finished `hires` run's take, video and curves in place of the last run's.
    public func commitHires() throws {
        for url in [take, hiresVideo, hiresCurves] { try Self.commit(url) }
    }

    /// Puts a finished full pass's videos and key frames in place (#239).
    public func commitFullPass(_ videos: [URL]) throws {
        for url in videos { try Self.commit(url) }
        if FileManager.default.fileExists(atPath: Self.partial(keyFrames).path) {
            try Self.commit(keyFrames)
        }
    }

    /// Removes what an interrupted `hires` or `export` left half written here.
    @discardableResult
    public func removePartialOutputs() -> [URL] {
        let hidden =
            ((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != ".DS_Store" }
            .map { exports.appendingPathComponent($0) }
        return Self.remove([take, hiresVideo, hiresCurves, keyFrames].map(Self.partial) + hidden)
    }

    /// The same for a whole batch, with the scenes still being explored in their hidden folders.
    @discardableResult
    public static func removePartialOutputs(inBatch batch: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: batch.path)) ?? []
        let exploring = names.filter { $0.hasPrefix(".scene-") }.map {
            batch.appendingPathComponent($0)
        }
        let scenes = names.filter { $0.hasPrefix("scene-") }.flatMap {
            SceneFolder(batch.appendingPathComponent($0, isDirectory: true)).removePartialOutputs()
        }
        return remove(exploring) + scenes
    }

    private static func remove(_ urls: [URL]) -> [URL] {
        urls.filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }
}
