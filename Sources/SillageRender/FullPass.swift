import Foundation
import SillageCore

/// What a full pass runs on (#278): the solver with its light tracers, the smoothing it reads
/// off the solver's tree, and a drawing for each video preset over the solver's own buffers.
/// Metal (`MetalFullPassEngine`) and CUDA (`CUDAFullPassEngine`) give one each; the flow that
/// steps, draws, checkpoints and reports is `FullPassRun`, the same for both.
public protocol FullPassEngine: AnyObject {
    var solver: any Solver { get }
    /// The massive particles as sampled or read, `[visible | halo]`.
    var massive: ParticleSystem { get }
    var tracerCount: Int { get }
    var diskFrames: [DiskState] { get }
    /// The device it runs on, for the log.
    var device: String { get }
    /// Refreshes the smoothing lengths the drawings read, from the solver's tree.
    func refreshSmoothing() throws
    /// A preset's drawing over the solver's buffers and the smoothing, its exposure
    /// `exposure` and its grain moved on by `drawn` frames.
    func drawing(
        for format: RunVideos.Format, look: LookFile, exposure: Float, drawn: Int, framesPerSecond: Int,
        metadata: VideoMetadata?
    ) throws -> any RunVideoDrawing
    /// Joins a video's segments without encoding them again, and checks it holds `frames`.
    func join(
        _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
    ) throws
    /// Every position the solver holds, tracers first, for the key frames.
    func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) throws
    /// What a take keeps of the drawn particles, `[tracers | massive visible]`.
    func drawnAttributes() throws -> ParticleSystem
    var state: SolverState { get }
    func writeParticles(to handle: FileHandle) throws
    func restore(_ state: SolverState, from handle: FileHandle) throws
    /// The steps' profile since the last call, when the run is profiled.
    func takeProfile() -> StepProfile?
    /// Throws what went wrong on the device since the last call: a pass cannot throw.
    func check() throws
    /// The most the process held, and the device apart when it has memory of its own.
    var peakMemory: (host: Int?, device: Int?) { get }
}

/// Makes the engine of a full pass.
public protocol FullPassEngineMaker {
    /// What runs, which joins the run's identity: `metal`, `cuda-gpu` or `cuda-cpu`.
    var engine: String { get }
    /// Throws where this engine may not run a full pass: a CUDA build whose comparison with the
    /// reference outputs failed or did not run (#281).
    func refuseUnchecked() throws
    func make(_ start: FullPassRun.Start) throws -> any FullPassEngine
}

/// The full pass of a hires (#239), run from the command line `SceneFolder.hiresArguments`
/// gives it, by `sillage-render` on Metal and `sillage-cuda` on CUDA (#278): the massive
/// particles sampled or read and the light tracers drawn with them, the settle, the frames
/// stepped and drawn in every preset into their encoders, the cameras and the look of the
/// massive take (`RunVideos`), the key frames (`KeyFrames.pick`), the checkpoints with their
/// identity (`RunCheckpoint`), and what `hires.json` keeps of it. A change here is a change on
/// both engines.
public final class FullPassRun {
    /// What an engine starts from.
    public struct Start {
        /// The massive count's scene, whose softening and step the run takes.
        public var scene: SceneConfig
        /// The drawn count's, tracers included.
        public var drawn: SceneConfig
        /// The run renderer's settings, which no preset draws with.
        public var settings: RenderSettings
        /// The massive set the massive pass left beside its take (#278), for an engine that does
        /// not sample it the Mac's way; nil when there is none.
        public var massiveSet: URL?
        /// A resumed run's massive set, from its checkpoint, and its tracers' count.
        public var resumed: (massive: ParticleSystem, tracers: Int)?
        public var tracerOpeningAngle: Float?
        public var profiling: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case notBarnesHut
        case noPreset(String)
        case otherRun(String)
        case notCheckpointed(String)
        /// A test stopped the run, as a kill would.
        case stopped(frame: Int)

        public var description: String {
            switch self {
            case .missing(let option): "a full pass needs \(option)"
            case .notBarnesHut: "a full pass needs the Barnes-Hut solver"
            case .noPreset(let name): "--draw: no preset \(name)"
            case .otherRun(let why): "--resume: \(why)"
            case .notCheckpointed(let flag):
                "--checkpoint: only the full pass checkpoints, not a run with \(flag)"
            case .stopped(let frame): "stopped after frame \(frame)"
            }
        }
    }

    /// How far a galaxy's centre may stray from the massive take's before the run warns, in kpc.
    /// Over 2,000 steps of scene-0031 through its first pericentre, the CUDA solver's centres
    /// parted from Metal's by 0.019 kpc and Metal's from themselves after a one-bit change by
    /// 0.021 at most (#274); three times the widest, as its test allows. A longer or wider run
    /// parts further, which the warning says rather than stopping it.
    public static let driftBound: Float = 0.062

    public let arguments: [String]
    public let engineMaker: any FullPassEngineMaker
    public let started: Date
    public let reporter: StageReporter?
    public let hires: (folder: SceneFolder, record: SceneFolder.Hires)?
    /// Called after each frame drawn, with the frame and the checkpoints written so far: true
    /// stops the run there without closing anything, as a kill would. For tests.
    public var stop: ((_ frame: Int, _ checkpoints: Int) -> Bool)?

    /// `hires` is the scene folder and its record when the run is a stage's, which then commits
    /// the videos and writes `full` into `hires.json`.
    public init(
        arguments: [String], engine: any FullPassEngineMaker, started: Date = Date(),
        reporter: StageReporter? = nil, hires: (folder: SceneFolder, record: SceneFolder.Hires)? = nil
    ) {
        self.arguments = arguments
        engineMaker = engine
        self.started = started
        self.reporter = reporter
        self.hires = hires
    }

    func argument(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    func number(_ name: String, _ fallback: Double) -> Double {
        argument(name).flatMap(Double.init) ?? fallback
    }

    func url(_ name: String, directory: Bool = false) -> URL? {
        argument(name).map { URL(fileURLWithPath: $0, isDirectory: directory) }
    }

    /// The scenes of the run, built from the scene file as `sillage-render` builds a run's.
    public struct Scenes {
        public var file: SceneFile
        /// The massive count's when the others are light tracers, the drawn count's otherwise.
        public var scene: SceneConfig
        public var drawn: SceneConfig
        public var massive: Int?
        /// The look the scene's colours were taken from, with them.
        public var look: LookFile
    }

    public func scenes() throws -> Scenes {
        guard let path = argument("scene") else { throw Failure.missing("--scene") }
        var file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
        var look =
            try url("look").map { try LookFile.decoded(from: Data(contentsOf: $0)) } ?? .standard
        let particles = Int(number("particles", 1_000_000))
        if arguments.contains("--calm") {
            for index in file.galaxies.indices { file.galaxies[index].adoptCalmDisk() }
        }
        if let seed = argument("seed").flatMap(UInt64.init) { file.seed = seed }
        let placedFor = (file.solver, file.galaxies.map(\.haloParticleRatio))
        guard
            (argument("solver") ?? (file.solver == .restricted ? "restricted" : "barnes-hut")) == "barnes-hut"
        else { throw Failure.notBarnesHut }
        file.solver = .barnesHut
        if let ratio = argument("halo").flatMap(Float.init) {
            for index in file.galaxies.indices where file.galaxies[index].kind != .blackHole {
                file.galaxies[index].haloParticleRatio = ratio
            }
        }
        if let scale = argument("dt-scale").flatMap(Float.init) { file.timeStepScale = scale }
        if let dissipation = argument("dissipation").flatMap(Float.init) {
            for index in file.galaxies.indices { file.galaxies[index].dissipationTime = dissipation }
        }
        if let dt = argument("dt").flatMap(Float.init) { file.timeStep = dt }
        if let theta = argument("theta").flatMap(Float.init) { file.openingAngle = theta }
        if let value = argument("softening").flatMap(Float.init) { file.softening = value }
        let palette = look.palette.map(\.colour)
        var scene = file.scene(particleCount: particles, palette: palette)
        if !scene.encounters.isEmpty,
            placedFor.0 != file.solver || placedFor.1 != file.galaxies.map(\.haloParticleRatio)
        {
            scene.placeEncountersGivingWay()
            let kept = file
            file = SceneFile(scene)
            file.softening = kept.softening
            file.timeStep = kept.timeStep
        }
        look.palette = scene.galaxies.enumerated().map { index, galaxy in
            index < look.palette.count ? look.palette[index] : GalaxyColours(galaxy.color)
        }
        let massive = SceneFolder.massive(in: arguments).map { min($0, particles) }
        var drawn = scene
        if let massive {
            scene = file.scene(particleCount: massive, palette: palette)
            drawn.solveToomreQ(softening: scene.softening)
        }
        return Scenes(file: file, scene: scene, drawn: drawn, massive: massive, look: look)
    }

    /// The run, to its end: videos, key frames, `hires.json`.
    public func run() throws {
        try engineMaker.refuseUnchecked()
        guard let list = argument("draw") else { throw Failure.missing("--draw") }
        guard let framingPath = argument("draw-take") else { throw Failure.missing("--draw-take") }
        guard let out = url("draw-out", directory: true) else { throw Failure.missing("--draw-out") }
        let framingURL = URL(fileURLWithPath: framingPath)
        let particles = Int(number("particles", 1_000_000))
        let frames = Int(number("frames", 1))
        let steps = Int(number("steps", 3_000))
        let settle = Int(number("settle", 0))
        let framesPerSecond = Int(number("fps", 30))
        let stepsPerFrame = max(steps / max(frames, 1), 1)

        let built = try scenes()
        let scene = built.scene
        print(
            "scene      \(scene.name), \(built.drawn.totalParticleCount) visible"
                + (scene.hasLiveHalos
                    ? ", \(scene.simulatedParticleCount - scene.totalParticleCount) halo" : ""))

        // `--checkpoint <dir>` (#240): saved there every `--checkpoint-frames` frames and
        // `--checkpoint-steps` steps of the settle, the videos closed in segments; `--resume`
        // picks the last checkpoint up and refuses one of another run, the engine included.
        let checkpoint = url("checkpoint", directory: true).map { RunCheckpoint(directory: $0) }
        let identity = checkpoint.map { _ in
            RunCheckpoint.Identity(
                arguments: arguments,
                scene: argument("scene").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "",
                look: argument("look").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "",
                framing: RunCheckpoint.stamp(framingURL), particles: particles, massive: built.massive,
                timeStep: scene.timeStep, presets: list.split(separator: ",").map(String.init),
                code: RunCheckpoint.codeVersion(), engine: engineMaker.engine)
        }
        var resuming: (run: RunCheckpoint.Run, particles: FileHandle)?
        if let checkpoint, let identity {
            for flag in [
                "take", "take-massive", "video", "curves", "density", "out", "thumbnail", "massive-only",
            ]
            where arguments.contains("--\(flag)") {
                throw Failure.notCheckpointed("--\(flag)")
            }
            if arguments.contains("--resume"), let stored = try checkpoint.load() {
                let differences = stored.run.identity.differences(from: identity)
                guard differences.isEmpty else {
                    throw Failure.otherRun(
                        "the checkpoint in \(checkpoint.directory.path) is of another run, its "
                            + differences.joined(separator: ", ") + " differ")
                }
                if stored.run.identity.code != identity.code {
                    print("warning    the code changed since the checkpoint: the run goes on, not to the bit")
                }
                resuming = stored
            } else {
                if arguments.contains("--resume") {
                    print("resume     no checkpoint in \(checkpoint.directory.path): from the start")
                }
                checkpoint.clear()
            }
        }

        // `--tracer-sort N` and `--tracer-sort-chunk N`: how often the tracers' walk order is
        // sorted, and how many are sorted together.
        if let interval = argument("tracer-sort").flatMap(Int.init) {
            BarnesHutHost.tracerSortInterval = interval
        }
        if let chunk = argument("tracer-sort-chunk").flatMap(Int.init) {
            BarnesHutHost.tracerSortChunk = chunk
        }

        let reading = Date()
        let resumedSet = try resuming.map { stored -> (massive: ParticleSystem, tracers: Int) in
            (try checkpoint!.massiveSet(), stored.run.solver.tracers)
        }
        let engine = try engineMaker.make(
            Start(
                scene: scene, drawn: built.drawn,
                settings: built.look.renderSettings(
                    width: Int(number("width", 1920)), height: Int(number("height", 1080))),
                massiveSet: SceneFolder(framingURL.deletingLastPathComponent()).massiveSet,
                resumed: resumedSet, tracerOpeningAngle: argument("theta-tracers").flatMap(Float.init),
                profiling: arguments.contains("--profile")))
        let massive = engine.massive
        let tracerCount = engine.tracerCount
        print(
            String(
                format:
                    "tracers    %d light, %d massive visible, %d halo, softening %.4f, step %.5f, %@ in %.1f s",
                tracerCount, massive.visibleCount, massive.count - massive.visibleCount, scene.softening,
                scene.timeStep, resumedSet == nil ? "drawn" : "from the checkpoint",
                Date().timeIntervalSince(reading)))
        print("engine     \(engineMaker.engine) on \(engine.device)")
        let drawnCount = tracerCount + (massive.visibleCount > 0 ? massive.visibleCount : massive.count)

        var resumed: RunCheckpoint.Run?
        if let checkpoint {
            if let (run, handle) = resuming {
                let restoring = Date()
                try engine.restore(run.solver, from: handle)
                try handle.close()
                resumed = run
                print(
                    String(
                        format:
                            "resume     checkpoint %d: frame %d, settle %d, t=%.1f Myr, restored in %.2f s",
                        run.index, run.frame, run.settled,
                        Double(run.solver.time) * Physics.megayearsPerTimeUnit,
                        Date().timeIntervalSince(restoring)))
            } else {
                let saved = try checkpoint.saveMassive(massive)
                print(
                    String(
                        format: "checkpoint the massive set, once: %.2f GB in %.2f s",
                        Double(saved.bytes) / 1e9, saved.seconds))
            }
            fflush(nil)
        }
        let everyFrames = resumed?.everyFrames ?? max(Int(number("checkpoint-frames", 0)), 0)
        let everySteps = resumed?.everySteps ?? max(Int(number("checkpoint-steps", 0)), 0)
        let resumes = resumed.map { $0.resumes + 1 } ?? 0

        // The videos, framed, painted and exposed as an export of the massive take is (#239).
        let framing = try RecordingFile.read(from: framingURL)
        var drawnLook =
            try url("look").map { try LookFile.decoded(from: Data(contentsOf: $0)) } ?? .standard
        if drawnLook.palette.isEmpty {
            drawnLook.palette = framing.scene.galaxies.map { GalaxyColours($0.color) }
        }
        let formats = try list.split(separator: ",").map { name in
            guard let preset = VideoPreset.named(String(name)) else { throw Failure.noPreset(String(name)) }
            return try RunVideos.Format(
                preset: preset, frames: frames, framesPerSecond: framesPerSecond,
                url: out.appendingPathComponent("\(preset.name).\(preset.defaultCodec.fileExtension)"),
                divisor: Int(number("draw-divisor", 1)))
        }
        let metadata = VideoMetadata(sceneID: SceneFolder(framingURL.deletingLastPathComponent()).sceneID)
        let look = drawnLook
        let videos = try RunVideos(
            formats: formats, look: look, framing: framing, capturedRate: framesPerSecond,
            metadata: metadata, segments: checkpoint?.segments, resume: resumed?.videos,
            drawing: { format, exposure, drawn in
                try engine.drawing(
                    for: format, look: look, exposure: exposure, drawn: drawn,
                    framesPerSecond: framesPerSecond, metadata: metadata)
            },
            join: { parts, url, count, rate, metadata in
                try engine.join(parts, into: url, frames: count, framesPerSecond: rate, metadata: metadata)
            })
        print(
            "draw       "
                + formats.map { "\($0.preset.name) \($0.width)x\($0.height)" }.joined(separator: ", ")
                + " with \(look.name), framed on \(framingPath)")
        for line in videos.shots { print("shot       \(line)") }

        // `--draw-stills 12,300 --draw-stills-dir <dir>`: those frames of every preset as PNGs,
        // as the encoder took them.
        let stills = Set(argument("draw-stills")?.split(separator: ",").compactMap { Int($0) } ?? [])
        let stillsDirectory = url("draw-stills-dir", directory: true)
        // `--key-frames <path> --key-frame-curves <csv>`: every drawn particle at the key frames
        // of the massive pass's curves, in a take of their own.
        let keyFrameTake: KeyFrameTake? = try argument("key-frames").map { _ in
            let samples =
                argument("key-frame-curves").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .map(KeyFrames.samples) ?? []
            var keys = KeyFrames.pick(samples.filter { $0.frame < frames })
            if keys.isEmpty { keys = [KeyFrame(frame: frames / 2, role: .middle, timeMyr: 0)] }
            return try KeyFrameTake(
                keys: keys, particleCount: drawnCount, galaxyCount: scene.galaxies.count,
                blocks: checkpoint?.keyFrames, taken: resumed?.keyFrames ?? [])
        }

        var checkpointIndex = resumed?.index ?? 0
        /// Closes the videos' segments and saves the run, the next frame to draw `frame`.
        func save(frame: Int, settled: Int) throws {
            guard let checkpoint, let identity else { return }
            try videos.cut()
            checkpointIndex += 1
            let run = RunCheckpoint.Run(
                identity: identity, index: checkpointIndex, frame: frame, settled: settled,
                elapsed: (resumed?.elapsed ?? 0) + Date().timeIntervalSince(started), resumes: resumes,
                everyFrames: everyFrames, everySteps: everySteps, solver: engine.state,
                videos: videos.state, keyFrames: keyFrameTake?.entries ?? [])
            let saved = try checkpoint.save(run) { try engine.writeParticles(to: $0) }
            print(
                String(
                    format: "checkpoint %d before frame %d, settle %d: %.2f GB in %.2f s", checkpointIndex,
                    frame, settled, Double(saved.bytes) / 1e9, saved.seconds))
            // A log cut by a restart still says where the run was saved.
            fflush(nil)
        }

        let solver = engine.solver
        // The cost of a step is flat (#19): the pace so far says what is left.
        let totalSteps = settle + stepsPerFrame * frames
        if settle > 0 && (resumed?.frame ?? 0) == 0 {
            let settleStart = Date()
            // In chunks, so a settle of minutes still reports, cut at the checkpoints' steps.
            let chunk = max(settle / 50, 1)
            var settled = resumed?.settled ?? 0
            while settled < settle {
                var count = min(chunk, settle - settled)
                if everySteps > 0 { count = min(count, everySteps - settled % everySteps) }
                solver.step(count: count)
                try engine.check()
                settled += count
                if everySteps > 0, settled % everySteps == 0, settled < settle {
                    try save(frame: 0, settled: settled)
                }
                let elapsed = Date().timeIntervalSince(settleStart)
                let progress = Double(settled) / Double(max(totalSteps, 1))
                reporter?.update(
                    progress: progress, detail: "settle \(settled)/\(settle)",
                    eta: RunStatus.eta(elapsed: elapsed, progress: progress, now: Date()))
                print(
                    String(
                        format: "settle     %d/%d steps, t=%.1f Myr, %.1f s", settled, settle,
                        Double(solver.time) * Physics.megayearsPerTimeUnit, elapsed))
            }
        }

        let framesStart = Date()
        let firstFrame = resumed?.frame ?? 0
        var warned = false
        for frame in firstFrame..<max(frames, firstFrame) {
            let simulationStart = Date()
            solver.step(count: stepsPerFrame)
            try engine.check()
            let simulationMs = Date().timeIntervalSince(simulationStart) * 1000
            let smoothingStart = Date()
            try engine.refreshSmoothing()
            let smoothingMs = Date().timeIntervalSince(smoothingStart) * 1000
            try videos.drawFrame(
                frame, centres: solver.centers,
                keeping: stills.contains(frame) && stillsDirectory != nil
                    ? { format, still in
                        let url = stillsDirectory!.appendingPathComponent(
                            String(format: "%@-%04d.png", format.preset.name, frame))
                        try FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try still.writePNG(to: url)
                    } : nil)
            if let gap = videos.gaps.last, gap.frame == frame, gap.kpc > Self.driftBound, !warned {
                warned = true
                print(
                    String(
                        format:
                            "warning    frame %d: a centre is %.4f kpc from the massive pass's, past %.3f",
                        frame, gap.kpc, Self.driftBound))
            }
            if let keyFrameTake, keyFrameTake.wants(frame: frame) {
                try engine.withPositions { positions in
                    try keyFrameTake.offer(
                        frame: frame, positions: positions, time: solver.time, centers: solver.centers,
                        disks: engine.diskFrames)
                }
            }
            let done = Double(frame + 1 - firstFrame) / Double(max(frames - firstFrame, 1))
            reporter?.update(
                progress: Double(settle + (frame + 1) * stepsPerFrame) / Double(max(totalSteps, 1)),
                detail: "frame \(frame + 1)/\(frames)",
                eta: RunStatus.eta(
                    elapsed: Date().timeIntervalSince(framesStart), progress: done, now: Date()))
            if let profile = engine.takeProfile() {
                let phases = StepProfile.phases.compactMap { phase -> String? in
                    let value = profile.perStep(phase)
                    return value > 0 ? String(format: "%@ %.2f", phase, value) : nil
                }
                print("profile    " + phases.joined(separator: ", "))
            }
            let drawing = zip(videos.formats, videos.lastSeconds).map {
                String(format: "%@ %.1f ms", $0.preset.name, $1 * 1000)
            }
            let eta = Date().timeIntervalSince(framesStart) / max(done, 1e-9) * (1 - done)
            print(
                String(
                    format: "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms  draw %@"
                        + "  %.0f %%, %.0f s left",
                    frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
                    simulationMs / Double(stepsPerFrame), smoothingMs, drawing.joined(separator: ", "),
                    done * 100, eta))
            fflush(nil)
            if everyFrames > 0, (frame + 1) % everyFrames == 0, frame + 1 < frames {
                try save(frame: frame + 1, settled: settle)
            }
            if let stop, stop(frame, checkpointIndex) { throw Failure.stopped(frame: frame) }
        }

        reporter?.update(progress: 1, detail: "finishing", eta: Date())
        let reports = try videos.finish()
        for report in reports {
            print(
                String(
                    format: "draw       %@ %d frames, %.1f s drawing, %.1f ms a frame",
                    report.format.preset.name, report.frames, report.seconds,
                    report.seconds * 1000 / Double(max(report.frames, 1))))
        }
        print(
            videos.firstDrift.map {
                String(
                    format: "massive    drifts from the massive pass from frame %d,"
                        + " %.4f kpc at most over %d frames%@",
                    $0, videos.drift, videos.checkedFrames,
                    videos.drift > Self.driftBound ? String(format: ", past %.3f", Self.driftBound) : "")
            } ?? "massive    repeats the massive pass to the bit over \(videos.checkedFrames) stored frames")
        if let keyFrameTake, let path = argument("key-frames") {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let list =
                self.url("key-frame-list") ?? url.deletingPathExtension().appendingPathExtension("json")
            try keyFrameTake.write(
                scene: built.drawn, particles: engine.drawnAttributes(), to: url, list: list)
            print(
                "key frames " + keyFrameTake.entries.map { "\($0.role) \($0.frame)" }.joined(separator: ", "))
        }
        // `--state-out <path>`: what a checkpoint keeps of the particles at the end, and the
        // solver's state beside it as `<path>.json`, to compare two runs to the bit.
        if let url = url("state-out") {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try engine.writeParticles(to: handle)
            try handle.close()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(engine.state).write(to: url.appendingPathExtension("json"))
            print("state      \(url.path)")
        }
        if let (folder, done) = hires {
            try finish(
                folder: folder, record: done, reports: reports, videos: videos,
                keyFrames: keyFrameTake?.entries.map(\.frame) ?? [], resumed: resumed, resumes: resumes,
                memory: engine.peakMemory)
        }
        // The run is whole: its checkpoint has nothing left to give.
        checkpoint?.clear()
    }

    private func finish(
        folder: SceneFolder, record done: SceneFolder.Hires, reports: [RunVideos.Report], videos: RunVideos,
        keyFrames: [Int], resumed: RunCheckpoint.Run?, resumes: Int, memory: (host: Int?, device: Int?)
    ) throws {
        try folder.commitFullPass(reports.map(\.format.url))
        var record = done
        // The run's time kept across its resumes, the intervals a restart lost left out.
        let seconds = (resumed?.elapsed ?? 0) + Date().timeIntervalSince(started)
        var draws: [String: Double] = [:]
        for report in reports { draws[report.format.preset.name] = report.seconds }
        var full = SceneFolder.Hires.FullPass(
            presets: reports.map(\.format.preset.name), frames: videos.frames, seconds: seconds,
            drawSeconds: draws, peakMemoryBytes: memory.host, keyFrames: keyFrames, drift: videos.drift,
            checkedFrames: videos.checkedFrames, resumes: resumes > 0 ? resumes : nil)
        full.engine = engineMaker.engine
        full.peakDeviceBytes = memory.device
        full.gaps = videos.gaps
        full.driftBound = Self.driftBound
        record.full = full
        try record.encoded().write(to: folder.hires)
        print(
            String(
                format: "hires      full pass %.0f s, %.0f s of it drawing, peak %.2f GB%@", seconds,
                full.drawingSeconds, Double(memory.host ?? 0) / 1e9,
                memory.device.map { String(format: ", %.2f GB on the device", Double($0) / 1e9) } ?? ""))
        for report in reports {
            let bytes =
                (try? FileManager.default.attributesOfItem(atPath: report.format.url.path)[.size] as? Int)
                ?? 0
            var event = RunEvent(RunEvent.Kind.exportDone)
            event.preset = report.format.preset.name
            event.style = videos.look.name
            event.setPalette(videos.look.paletteRecipe)
            event.codec = report.format.codec.rawValue
            event.frames = report.frames
            event.megabytes = Double(bytes) / 1e6
            event.seconds = report.seconds
            event.path = report.format.url.path
            event.pass = "full"
            reporter?.record(event)
            print("video      \(report.format.url.path)")
            if report.format.preset.caption {
                try VideoMetadata(sceneID: folder.sceneID).caption.write(
                    to: report.format.url.deletingPathExtension().appendingPathExtension("txt"),
                    atomically: true, encoding: .utf8)
            }
        }
        var finished = RunEvent(RunEvent.Kind.hiresDone)
        finished.particles = record.particles
        finished.massive = record.massive
        finished.steps = record.steps
        finished.minutes = seconds / 60
        finished.pass = "full"
        reporter?.record(finished)
    }
}

/// The process's memory at its peak.
public enum ProcessMemory {
    /// The most physical memory the process has held: its footprint's peak on the Mac, its
    /// resident set's high-water mark (`VmHWM`) on Linux.
    public static func peakFootprint() -> Int? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : nil
        #else
            guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
                let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmHWM:") }),
                let kilobytes = Int(line.split(separator: " ").dropFirst().first ?? "")
            else { return nil }
            return kilobytes * 1024
        #endif
    }
}
