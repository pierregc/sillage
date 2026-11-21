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
    /// Draws the frames that follow from a copy of the drawn particles `fraction` of the step in
    /// force past the last step, on the straight line the next step's drift moves them along,
    /// which is what the integrator gives a frame between two steps (#310); nil draws from the
    /// solver's own again. Nothing of the run moves.
    func drawDrifted(by fraction: Float?) throws
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
    /// The exposure a look that measures its own (#340) draws `frames` of `framing` with at
    /// `width` by `height`; nil draws the look's own.
    func exposure(
        of look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int, track: TimeTrack?,
        frames: [TimeTrack.Frame], width: Int, height: Int
    ) throws -> ClipExposure?
}

extension FullPassEngineMaker {
    /// An engine that cannot draw the massive take apart draws the look's own exposure.
    public func exposure(
        of look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int, track: TimeTrack?,
        frames: [TimeTrack.Frame], width: Int, height: Int
    ) throws -> ClipExposure? { nil }
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

    /// Where a frame of the videos falls in the run (#310): `step` steps into the steps that lead
    /// to captured frame `frame`, from the solver's positions, then `fraction` of a step on from
    /// a copy drifted that far. Captured frame k stands (k + 1) times the steps of a frame past
    /// the settle, where the massive pass took it, so a frame on it is `step` a whole frame.
    public struct Place: Equatable, Sendable {
        public var frame: Int
        public var step: Int
        public var fraction: Double

        public init(frame: Int, step: Int, fraction: Double) {
            self.frame = frame
            self.step = step
            self.fraction = fraction
        }

        /// The same moment in a frame whose steps are `scale` of the run's own (#312): between
        /// two of them unless it falls on one, the fraction being of the step in force.
        public func taking(_ scale: Int) -> Place {
            guard scale > 1 else { return self }
            let steps = (Double(step) + fraction) / Double(scale)
            var whole = steps.rounded(.down)
            var part = steps - whole
            if part > 1 - 1e-6 {
                whole += 1
                part = 0
            } else if part < 1e-6 {
                part = 0
            }
            return Place(frame: frame, step: Int(whole), fraction: part)
        }
    }

    /// Where captured position `captured` falls, at `stepsPerFrame` of the run's own steps a
    /// captured frame; `taking` turns it into the steps of a frame a schedule coarsened (#312).
    public static func place(captured: Double, stepsPerFrame: Int) -> Place {
        let each = max(stepsPerFrame, 1)
        let steps = (max(captured, 0) + 1) * Double(each)
        var whole = steps.rounded(.down)
        var fraction = steps - whole
        // A track's arithmetic a rounding away from a step is that step.
        if fraction > 1 - 1e-6 {
            whole += 1
            fraction = 0
        } else if fraction < 1e-6 {
            fraction = 0
        }
        let count = Int(whole)
        let frame = fraction == 0 ? (count - 1) / each : count / each
        return Place(frame: frame, step: count - frame * each, fraction: fraction)
    }

    /// Every frame of the videos, at its played and captured positions, as far as the run goes:
    /// along `track`, or a frame a captured frame without one.
    public static func videoFrames(track: TimeTrack?, frames: Int, framesPerSecond: Int) -> [TimeTrack.Frame]
    {
        guard let track else {
            return (0..<max(frames, 0)).map { TimeTrack.Frame(played: Double($0), captured: Double($0)) }
        }
        let last = Double(max(frames - 1, 0)) + 1e-9
        return track.frames(framesPerSecond: framesPerSecond).filter { $0.captured <= last }
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
        guard argument("scene") != nil else { throw Failure.missing("--scene") }
        // Built as the take pass builds its scenes (#376).
        let built = try RunScenes(arguments, look: try RunScenes.look(arguments))
        guard built.backend == "barnes-hut" else { throw Failure.notBarnesHut }
        return Scenes(
            file: built.file, scene: built.scene, drawn: built.drawn, massive: built.massive,
            look: built.painted)
    }

    /// What `--speed` gives the full pass: a track file or a speed as an export reads them, or a
    /// pace (`auto`), computed from the massive pass's curves. A pace that reads the pictures
    /// needs an export to draw them: `pace` writes its file.
    static func speedFile(_ text: String, folder: SceneFolder, framing: RecordingFile.Loaded) throws
        -> TimeTrackFile
    {
        guard let spec = PaceSpec(text) else { return try TimeTrackFile.given(text) }
        let read = try PaceTrack.fromCurves(
            spec, folder: folder, scene: framing.scene, megayears: TimeTrack.megayears(of: framing.recording))
        print(
            String(
                format: "pace       %@ from %@: first pass %@ Myr, engaged until %@ Myr", text,
                read.curves.lastPathComponent,
                read.made.firstPassMyr.map { String(format: "%.0f", $0) } ?? "none",
                read.made.engagedUntilMyr.map { String(format: "%.0f", $0) } ?? "never"))
        return TimeTrackFile(speeds: read.made.speeds)
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
        // `--speed <x>|<file>|auto` (#310, #311): the videos drawn along a time track, read once
        // against the massive take. A pace is read off the massive pass's curves here, so that the
        // checkpoint's identity holds the track it gives.
        let framing = try RecordingFile.read(from: framingURL)
        let speed = try argument("speed").map {
            try Self.speedFile(
                $0, folder: SceneFolder(framingURL.deletingLastPathComponent()), framing: framing)
        }
        // `--dt-switches <step>:<scale>,...` (#312): the steps its massive pass took, followed to
        // the bit, as is a resumed run.
        let switches = try argument("dt-switches").map { try StepSwitches(parsing: $0) }
        try switches?.check(settle: settle, frames: frames, perFrame: stepsPerFrame)

        let built = try scenes()
        let scene = built.scene
        if let draw = built.drawn.draw {
            print(
                "draw       \(draw.generator), batch \(draw.batchSeed) scene \(draw.index) (point \(draw.point)): "
                    + draw.families.map(\.rawValue).joined(separator: ", "))
        }
        for encounter in built.drawn.encounters {
            // How fast the pair would be far apart, or for a bound one, the speed its binding is worth.
            let mass =
                built.drawn.galaxies[encounter.primary].potential.mass
                + built.drawn.galaxies[encounter.secondary].potential.mass
            let speed =
                (abs(encounter.eccentricity - 1) * mass / encounter.pericentre).squareRoot()
                * Float(Physics.kilometersPerSecondPerVelocityUnit)
            print(
                String(
                    format:
                        "encounter  %d-%d, pericentre %.1f kpc at %.0f Myr, e %.2f (%@, %@ %.0f km/s), mass ratio %.2f",
                    encounter.primary, encounter.secondary, encounter.pericentre, encounter.pericentreTime,
                    encounter.eccentricity, encounter.orbit.rawValue,
                    encounter.eccentricity < 1 ? "binding" : "far out",
                    speed, encounter.massRatio))
        }
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
                code: RunCheckpoint.codeVersion(), engine: engineMaker.engine,
                track: speed.flatMap { try? String(decoding: $0.encoded(), as: UTF8.self) })
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

        // The videos, framed, painted and exposed as an export of the massive take is (#239).
        let track = try speed.map {
            try $0.track(megayears: TimeTrack.megayears(of: framing.recording), capturedRate: framesPerSecond)
        }
        let wanted = Self.videoFrames(track: track, frames: frames, framesPerSecond: framesPerSecond)
        var drawnLook =
            try url("look").map { try LookFile.decoded(from: Data(contentsOf: $0)) } ?? .standard
        if drawnLook.palette.isEmpty {
            drawnLook.palette = framing.scene.galaxies.map { GalaxyColours($0.color) }
        }
        let formats = try list.split(separator: ",").map { name in
            guard let preset = VideoPreset.named(String(name)) else { throw Failure.noPreset(String(name)) }
            return try RunVideos.Format(
                preset: preset, frames: wanted.count, framesPerSecond: framesPerSecond,
                url: out.appendingPathComponent("\(preset.name).\(preset.defaultCodec.fileExtension)"),
                divisor: Int(number("draw-divisor", 1)))
        }
        let framingFolder = SceneFolder(framingURL.deletingLastPathComponent())
        let metadata = VideoMetadata(sceneID: framingFolder.sceneID)
        // A look that measures its exposure (#340) takes it from the massive take's frames, once
        // for every preset, at the first one's size.
        if let first = formats.first,
            let measured = try engineMaker.exposure(
                of: drawnLook, framing: framing, capturedRate: framesPerSecond, track: track,
                frames: wanted, width: first.width, height: first.height)
        {
            drawnLook.look = measured.scale.applied(to: drawnLook.look)
            print("exposure   \(measured.summary), at \(first.preset.name)")
        }
        drawnLook.exposure = nil
        let look = drawnLook

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
        // The step in force where the run starts: a switch at that very step is still to come.
        let stepper = engine.solver as? StepChangingSolver
        if switches != nil && stepper == nil { throw Failure.notBarnesHut }
        let hiresStep = scene.timeStep
        let resumedAt = resumed.map { $0.frame > 0 ? settle + $0.frame * stepsPerFrame : $0.settled } ?? 0
        var scale = resumedAt > 0 ? switches?.scale(forStep: resumedAt - 1) ?? 1 : 1
        if let resumed, (resumed.solver.timeStep ?? hiresStep) != hiresStep * Float(scale) {
            throw Failure.otherRun("the checkpoint's step is not the one its switches give")
        }
        /// Takes the step own step `own` runs at, as the massive pass changed it.
        func align(to own: Int) {
            guard let switches, let stepper else { return }
            let wanted = switches.scale(forStep: own)
            guard wanted != scale else { return }
            stepper.changeStep(to: hiresStep * Float(wanted))
            scale = wanted
            print(String(format: "schedule   step x%d from step %d", wanted, own))
        }
        /// The steps run up to own step `own`, and in all.
        func runSteps(to own: Int) -> Int { switches?.steps(from: 0, to: own) ?? own }
        let everyFrames = resumed?.everyFrames ?? max(Int(number("checkpoint-frames", 0)), 0)
        let everySteps = resumed?.everySteps ?? max(Int(number("checkpoint-steps", 0)), 0)
        let resumes = resumed.map { $0.resumes + 1 } ?? 0

        let videos = try RunVideos(
            formats: formats, look: look, framing: framing, capturedRate: framesPerSecond,
            metadata: metadata, segments: checkpoint?.segments, resume: resumed?.videos, track: track,
            overlay: try framingFolder.overlayRequest(look: look),
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
        if let track {
            print(
                String(
                    format: "speed      %@: a %.1f s video of a %.1f s take, %d frames",
                    argument("speed") ?? "", track.seconds,
                    Double(max(frames - 1, 0)) / Double(max(framesPerSecond, 1)), wanted.count))
        }
        for line in videos.overlayNotes { print("overlay    \(line)") }
        fflush(nil)

        // `--draw-stills 12,300 --draw-stills-dir <dir>`: those frames of every preset as PNGs,
        // as the encoder took them.
        let stills = Set(argument("draw-stills")?.split(separator: ",").compactMap { Int($0) } ?? [])
        let stillsDirectory = url("draw-stills-dir", directory: true)
        // `--key-frames <path> --key-frame-curves <csv>`: every drawn particle at the key frames
        // of the massive pass's curves, in a take of their own. `--key-frames-at <Myr,...>` adds
        // the frames nearest those moments, `--key-frames-span N` frames from each (#379). Both
        // are in the checkpoint's command line, so a resumed run keeps the same frames.
        let keyFrameTake: KeyFrameTake? = try argument("key-frames").map { _ in
            let samples =
                argument("key-frame-curves").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .map(KeyFrames.samples) ?? []
            var keys = KeyFrames.pick(samples.filter { $0.frame < frames })
            if keys.isEmpty { keys = [KeyFrame(frame: frames / 2, role: .middle, timeMyr: 0)] }
            if let text = argument("key-frames-at") {
                keys = try KeyFrames.adding(
                    chosen: try KeyFrames.moments(text), span: max(Int(number("key-frames-span", 1)), 1),
                    to: keys, megayears: Array(TimeTrack.megayears(of: framing.recording).prefix(frames)))
            }
            return try KeyFrameTake(
                keys: keys, particleCount: drawnCount, galaxyCount: scene.galaxies.count,
                blocks: checkpoint?.keyFrames, taken: resumed?.keyFrames ?? [])
        }
        // `--stop-after-key-frames` (#379): the run ends once the frames `--key-frames-at` asked
        // for are kept, its videos left unfinished: a moment early in a long run, without the rest.
        var stopAfter: Int?
        if arguments.contains("--stop-after-key-frames") {
            guard let chosen = keyFrameTake?.keys.filter({ $0.role == .chosen }).map(\.frame).max() else {
                throw Failure.missing("--key-frames-at for --stop-after-key-frames")
            }
            stopAfter = chosen
        }
        var stoppedAfter: Int?

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
        let totalSteps = runSteps(to: settle + stepsPerFrame * frames)
        if settle > 0 && (resumed?.frame ?? 0) == 0 {
            let settleStart = Date()
            // In chunks, so a settle of minutes still reports, cut at the checkpoints' steps and
            // the switches; a coarser step crosses a checkpoint's step rather than splitting.
            let chunk = max(settle / 50, 1)
            var settled = resumed?.settled ?? 0
            while settled < settle {
                align(to: settled)
                var count = min(chunk, settle - settled)
                if let next = switches?.next(after: settled) { count = min(count, next - settled) }
                if everySteps > 0 { count = min(count, everySteps - settled % everySteps) }
                count = max(count / scale, 1) * scale
                solver.step(count: count / scale)
                try engine.check()
                let before = settled
                settled += count
                if everySteps > 0, settled / everySteps > before / everySteps, settled < settle {
                    try save(frame: 0, settled: settled)
                }
                let elapsed = Date().timeIntervalSince(settleStart)
                let progress = Double(runSteps(to: settled)) / Double(max(totalSteps, 1))
                reporter?.update(
                    progress: progress, detail: "settle \(settled)/\(settle)",
                    eta: RunStatus.eta(elapsed: elapsed, progress: progress, now: Date()))
                print(
                    String(
                        format: "settle     %d/%d steps, t=%.1f Myr, %.1f s", settled, settle,
                        Double(solver.time) * Physics.megayearsPerTimeUnit, elapsed))
                fflush(nil)
            }
        }

        let framesStart = Date()
        let firstFrame = resumed?.frame ?? 0
        var warned = false
        // The next frame of the videos, and whether the drawings read a drifted copy.
        var next = videos.frames
        var drifted = false
        for frame in firstFrame..<max(frames, firstFrame) {
            align(to: settle + frame * stepsPerFrame)
            let frameSteps = stepsPerFrame / scale
            /// Where video frame `index` falls, in the steps this frame takes.
            func placed(_ index: Int) -> Place {
                let place = Self.place(captured: wanted[index].captured, stepsPerFrame: stepsPerFrame)
                return place.taking(switches?.scale(forStep: settle + place.frame * stepsPerFrame) ?? 1)
            }
            var simulationMs = 0.0
            var smoothingMs = 0.0
            var stepped = 0
            var smoothed = false
            var drawnHere = 0
            func advance(to step: Int) throws {
                guard step > stepped else { return }
                let started = Date()
                solver.step(count: step - stepped)
                try engine.check()
                simulationMs += Date().timeIntervalSince(started) * 1000
                stepped = step
                smoothed = false
            }
            func draw(_ index: Int, fraction: Double) throws {
                if !smoothed {
                    let started = Date()
                    try engine.refreshSmoothing()
                    smoothingMs += Date().timeIntervalSince(started) * 1000
                    smoothed = true
                }
                if fraction > 0 {
                    try engine.drawDrifted(by: Float(fraction))
                    drifted = true
                } else if drifted {
                    try engine.drawDrifted(by: nil)
                    drifted = false
                }
                try videos.drawFrame(
                    wanted[index],
                    keeping: stills.contains(index) && stillsDirectory != nil
                        ? { format, still in
                            let url = stillsDirectory!.appendingPathComponent(
                                String(format: "%@-%04d.png", format.preset.name, index))
                            try FileManager.default.createDirectory(
                                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try still.writePNG(to: url)
                        } : nil)
                drawnHere += 1
            }
            // A slow track's frames between the captured frame before and this one, each drawn
            // between two steps.
            while next < wanted.count {
                let place = placed(next)
                guard place.frame == frame, place.step < frameSteps else { break }
                try advance(to: place.step)
                try draw(next, fraction: place.fraction)
                next += 1
            }
            try advance(to: frameSteps)
            videos.check(frame: frame, centres: solver.centers)
            // This captured frame, once or several times in a freeze; a fast track skips some.
            while next < wanted.count, placed(next) == Place(frame: frame, step: frameSteps, fraction: 0) {
                try draw(next, fraction: 0)
                next += 1
            }
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
                progress: Double(runSteps(to: settle + (frame + 1) * stepsPerFrame))
                    / Double(max(totalSteps, 1)),
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
            let drawing =
                drawnHere == 0
                ? ["none"]
                : zip(videos.formats, videos.lastSeconds).map {
                    String(format: "%@ %.1f ms", $0.preset.name, $1 * 1000)
                } + (drawnHere > 1 ? ["\(drawnHere) frames"] : [])
            let eta = Date().timeIntervalSince(framesStart) / max(done, 1e-9) * (1 - done)
            print(
                String(
                    format: "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms  draw %@"
                        + "  %.0f %%, %.0f s left",
                    frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
                    simulationMs / Double(frameSteps), smoothingMs, drawing.joined(separator: ", "),
                    done * 100, eta))
            fflush(nil)
            if everyFrames > 0, (frame + 1) % everyFrames == 0, frame + 1 < frames {
                try save(frame: frame + 1, settled: settle)
            }
            if let stop, stop(frame, checkpointIndex) { throw Failure.stopped(frame: frame) }
            if let stopAfter, frame >= stopAfter {
                stoppedAfter = frame
                break
            }
        }
        // No step comes after the last frame's smoothing to check it (#409).
        try engine.check()

        /// The key frames' take, and their list beside it.
        func writeKeyFrames() throws {
            guard let keyFrameTake, let path = argument("key-frames") else { return }
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
        if let stoppedAfter {
            // The videos closed as they stand, so that no encoder is left open, then dropped.
            _ = try videos.finish()
            try writeKeyFrames()
            if let (folder, _) = hires {
                try folder.commitFullPass([])
                folder.removePartialOutputs()
            }
            print(
                String(
                    format:
                        "stopped    after frame %d, the last key frame asked for: %.0f s, the videos dropped",
                    stoppedAfter, Date().timeIntervalSince(started)))
            checkpoint?.clear()
            return
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
        try writeKeyFrames()
        // `--state-out <path>`: what a checkpoint keeps of the particles at the end, and the
        // solver's state beside it as `<path>.json`, to compare two runs to the bit.
        if let url = url("state-out") {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
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
                memory: engine.peakMemory, track: speed)
        }
        // The run is whole: its checkpoint has nothing left to give.
        checkpoint?.clear()
    }

    private func finish(
        folder: SceneFolder, record done: SceneFolder.Hires, reports: [RunVideos.Report], videos: RunVideos,
        keyFrames: [Int], resumed: RunCheckpoint.Run?, resumes: Int, memory: (host: Int?, device: Int?),
        track: TimeTrackFile?
    ) throws {
        try folder.commitFullPass(reports.map(\.format.url))
        // Beside each video as an export writes it, so it can be drawn again exactly.
        if let track {
            for report in reports {
                try track.encoded().write(
                    to: report.format.url.deletingPathExtension().appendingPathExtension(
                        TimeTrackFile.fileExtension))
            }
        }
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
        full.track = track
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
