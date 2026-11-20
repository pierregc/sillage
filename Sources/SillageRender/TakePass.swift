import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What the pass that writes a take runs on (#376): the solver, the smoothing, the positions as
/// the CPU reads them, and the drawing of the run's own video and stills. Metal gives one
/// (`MetalTakePassEngine`); the flow that samples, settles, steps, frames, keeps the take and the
/// curves and reports is `TakePassRun`, the same for every engine.
public protocol TakePassEngine: AnyObject {
    var solver: any Solver { get }
    /// What a step schedule switches the step of; nil for a solver that cannot change it.
    var stepper: (any StepChangingSolver)? { get }
    /// The massive particles as sampled, `[visible | halo]`.
    var massive: ParticleSystem { get }
    var tracerCount: Int { get }
    /// The light tracers a `--massive-only` run drew to pick its massive set, then dropped.
    var droppedTracers: Int { get }
    /// The disks' states, empty for a solver that tracks none.
    var diskFrames: [DiskState] { get }
    /// The device it draws on, for the log.
    var device: String { get }
    /// Refreshes the smoothing lengths the drawing reads.
    func refreshSmoothing() throws
    /// Stars formed from `since` to just before `before`.
    func formed(since: Float, before: Float) -> Int
    /// The radius `plan` frames the run's particles at, from where they are now.
    func framedRadius(_ plan: LookFile.CameraPlan) -> Float
    /// Sets the look every frame builds on, or the one the director lights this frame with.
    func apply(_ look: RenderLook)
    /// Readies the drawing of a frame at `time` with the arms painted on `diskFrames`, the
    /// positions of a solver that keeps them on the CPU handed over.
    func prepareFrame(time: Float, diskFrames: [DiskFrame])
    /// The run's own video, `width` by `height`, begun at `url`.
    func video(url: URL, width: Int, height: Int, framesPerSecond: Int) throws -> any RunVideoDrawing
    /// A frame through `camera` as a still, when no video is drawn.
    func still(camera: Camera) throws -> (any RunVideoStill)?
    /// Writes a still as a PNG, scaled down to `maximumWidth` when given.
    func write(_ still: any RunVideoStill, to url: URL, maximumWidth: Int?) throws
    /// The GPU time of the last frame drawn, in seconds.
    var lastGPUTime: Double { get }
    /// Every position the solver holds, tracers first, `heldCount` of them.
    func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) rethrows
    var heldCount: Int { get }
    /// What a take keeps of the drawn particles, the formation times the run ended on.
    func capturedParticles() -> ParticleSystem
    /// The solver's state, nil for one that keeps none.
    var state: SolverState? { get }
    func writeParticles(to handle: FileHandle) throws
    /// The steps' profile since the last call, when the run is profiled.
    func takeProfile() -> StepProfile?
    /// The most the process held, and the device apart when it has memory of its own.
    var peakMemory: (host: Int?, device: Int?) { get }
}

/// Makes the engine of a take pass.
public protocol TakePassEngineMaker {
    /// `metal`, `cuda-gpu` or `cuda-cpu`.
    var engine: String { get }
    func make(_ start: TakePassRun.Start) throws -> any TakePassEngine
}

/// The measuring options of an engine (#376), which no take needs: called at the moments of a
/// frame where `sillage-render` always ran them. Each does nothing unless its engine says so.
public protocol TakePassMeasures: AnyObject {
    /// Once the engine is made, before the settle.
    func started(_ run: TakePassRun) throws
    /// After a frame's steps.
    func afterSteps(_ run: TakePassRun, frame: Int) throws
    /// After a frame is drawn through `camera`; `drew` when it was, to a video or a still.
    func afterDrawing(_ run: TakePassRun, frame: Int, camera: Camera, drew: Bool) throws
    /// After the take is offered the frame.
    func afterTake(_ run: TakePassRun, frame: Int) throws
    /// Once the last frame is done.
    func finish(_ run: TakePassRun) throws
}

/// The pass of a run that writes a take (#376), from the command line of a plain render, an
/// exploration or a hires (`SceneFolder.hiresArguments`, `--pass massive` among them): the scene
/// sampled, the settle, the frames stepped through the step schedule, framed by the director or
/// the camera the look asks for, drawn into the run's video and stills, offered to the take and
/// written as curves, the story followed past the planned frames, and at the end the take,
/// `hires.json` and what the status files say. `sillage-render` runs it on Metal; a change here is
/// a change on every engine.
public final class TakePassRun {
    /// What an engine starts from.
    public struct Start {
        public var scene: SceneConfig
        public var drawn: SceneConfig
        public var massive: Int?
        public var backend: String
        public var settings: RenderSettings
        public var look: LookFile
        /// `--massive-only` (#239): the massive particles of the draw run alone.
        public var massiveOnly: Bool
        public var tracerOpeningAngle: Float?
        public var profiling: Bool
    }

    public enum Outcome: Equatable {
        case done
        /// `--check-only`: the scene was judged and nothing ran.
        case checked
        /// A generated scene that would show nothing.
        case rejected
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    public let arguments: [String]
    public let options: RunOptions
    public let engineMaker: any TakePassEngineMaker
    public let measures: (any TakePassMeasures)?
    public let started: Date
    public let reporter: StageReporter?
    public let hires: (folder: SceneFolder, record: SceneFolder.Hires)?
    public let explore: SceneFolder?

    // What the run is, once `run()` has built it, for the measures.
    public private(set) var built: RunScenes!
    public private(set) var engine: (any TakePassEngine)!
    public private(set) var look: LookFile = .standard
    /// The drawn count's scene, or the massive count's when the massive particles run alone.
    public private(set) var drawnScene: SceneConfig!
    public private(set) var frames = 1
    public private(set) var width = 1920
    public private(set) var height = 1080
    public private(set) var framesPerSecond = 30
    public private(set) var settle = 0
    public private(set) var stepsPerFrame = 1
    public private(set) var takeBudget = 0
    public private(set) var takeInterval = 1
    /// Whether a frame draws a video, and whether frame `frame` is read off as a still.
    public private(set) var drawsVideo = false
    public private(set) var stillFrames: (Int) -> Bool = { _ in false }
    /// Where each galaxy's disk ends, and past which a star is in a tail or a bridge.
    public private(set) var reach: [Float] = []
    public private(set) var tidalReach: [Float] = []

    public init(
        arguments: [String], engine: any TakePassEngineMaker, measures: (any TakePassMeasures)? = nil,
        started: Date = Date(), reporter: StageReporter? = nil,
        hires: (folder: SceneFolder, record: SceneFolder.Hires)? = nil, explore: SceneFolder? = nil
    ) {
        self.arguments = arguments
        options = RunOptions(arguments)
        engineMaker = engine
        self.measures = measures
        self.started = started
        self.reporter = reporter
        self.hires = hires
        self.explore = explore
    }

    public func argument(_ name: String) -> String? { options.argument(name) }
    public func number(_ name: String, _ fallback: Double) -> Double { options.number(name, fallback) }

    /// A take of `particles` at this run's interval, reserved for its frames within the budget.
    public func reel(_ particles: Int, bitsPerAxis: Int = Recording.defaultBitsPerAxis) -> Recording {
        let reel = Recording(
            particleCount: particles, galaxyCount: built.scene.galaxies.count, interval: takeInterval,
            bitsPerAxis: bitsPerAxis)
        reel.reserve(frames: min(frames / takeInterval + 1, takeBudget / reel.frameBytes + 1))
        return reel
    }

    /// A path's file, its folder made.
    public static func prepared(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// The run, to its end.
    public func run() throws -> Outcome {
        frames = Int(number("frames", 1))
        width = Int(number("width", 1920))
        height = Int(number("height", 1080))
        // A PNG sequence is still the default, but a run asked for a video does not need one too.
        let videoPath = argument("video")
        let outputPath = argument("out") ?? (videoPath == nil ? "out/sillage.png" : nil)

        let built = try RunScenes(arguments, look: try RunScenes.look(arguments))
        self.built = built
        let steps = built.steps
        for line in built.drawLines { print(line) }
        // A generated scene is judged from its centres before any particle is drawn, so one that
        // would show nothing costs a moment rather than a night's slot. A scene read from a file
        // was judged when it was drawn; `--check` judges it again and `--no-check` spares a
        // generated one. `--check-only` stops here with the numbers.
        if built.generatedHaste != nil && !options.contains("--no-check")
            || options.contains("--check") || options.contains("--check-only")
        {
            let checkStart = Date()
            let verdict = built.planned.sanityCheck(settleSteps: Int(number("settle", 0)), steps: steps)
            if options.contains("--check-only") {
                print(
                    String(
                        format: "check      closest %@, Toomre %@, start clearance %@, frame %.1f, "
                            + "step %.5f Myr, %.0f ms",
                        verdict.closestApproach.map {
                            String(format: "%.1f kpc at %.0f Myr", $0.distance, $0.time)
                        }
                            ?? "none",
                        verdict.toomre.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) }
                            ?? "none",
                        verdict.startClearance.map { String(format: "%.2f", $0) } ?? "none",
                        verdict.fieldRatio, Double(built.planned.timeStep) * Physics.megayearsPerTimeUnit,
                        Date().timeIntervalSince(checkStart) * 1000))
            }
            if !verdict.accepted {
                print("rejected   " + verdict.reasons.map(\.description).joined(separator: "; "))
                return .rejected
            }
            if options.contains("--check-only") { return .checked }
        }
        let look = built.painted
        self.look = look
        let settings = look.renderSettings(width: width, height: height)
        let scene = built.scene
        var drawnScene = built.drawn
        print(
            "scene      \(scene.name), \(drawnScene.totalParticleCount) visible"
                + (scene.hasLiveHalos
                    ? ", \(scene.simulatedParticleCount - scene.totalParticleCount) halo" : ""))
        // Only the full pass checkpoints (#240), and it does not run here.
        if options.contains("--checkpoint") {
            throw Failure.message("--checkpoint: only the full pass checkpoints, with --draw")
        }
        if built.massive != nil, built.backend != "barnes-hut" {
            throw Failure.message("--massive needs the Barnes-Hut solver")
        }
        // `--tracer-sort N` and `--tracer-sort-chunk N`: how often the tracers' walk order is
        // sorted, and how many are sorted together, to measure them.
        if let interval = argument("tracer-sort").flatMap(Int.init) {
            BarnesHutHost.tracerSortInterval = interval
        }
        if let chunk = argument("tracer-sort-chunk").flatMap(Int.init) {
            BarnesHutHost.tracerSortChunk = chunk
        }
        let massiveOnly = options.contains("--massive-only")
        let engine = try engineMaker.make(
            Start(
                scene: scene, drawn: drawnScene, massive: built.massive, backend: built.backend,
                settings: settings, look: look, massiveOnly: massiveOnly,
                tracerOpeningAngle: argument("theta-tracers").flatMap(Float.init),
                profiling: options.contains("--profile")))
        self.engine = engine
        let seeded = engine.massive
        if massiveOnly, engine.droppedTracers > 0 {
            drawnScene = scene
            print("massive    \(seeded.visibleCount) visible run alone, without the tracers")
        }
        self.drawnScene = drawnScene
        // `--massive-set <path>` (#278): the massive set as sampled, which a full pass on another
        // machine reads rather than sampling it again.
        if let path = argument("massive-set") {
            let saved = try RunCheckpoint.writeMassiveSet(seeded, to: Self.prepared(path))
            print(
                String(
                    format: "massive    the massive set, %.2f GB in %.2f s", Double(saved.bytes) / 1e9,
                    saved.seconds))
        }
        let tracerCount = engine.tracerCount
        let solver = engine.solver
        // Each particle's kernel spans its own local interparticle spacing, so the surface stays
        // continuous instead of resolving the sampling. A tracer reads its own off the massive tree.
        let massiveDrawn = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
        let drawnCount = tracerCount + massiveDrawn
        print("solver     \(built.backend) (\(scene.solver.rawValue))")
        print("gpu        \(engine.device)")

        let outputURL = try outputPath.map(Self.prepared)
        // One still, small enough for a grid of a few hundred scenes, from the middle of the clip
        // unless a frame is named.
        let thumbnailURL = try argument("thumbnail").map(Self.prepared)
        let thumbnailFrame = min(Int(number("thumbnail-frame", Double(frames / 2))), frames - 1)

        // Named after the main output, so `x.mov` and `x.sillage` both get `x.scene.json` and
        // `x.look.json`.
        func beside(_ suffix: String) -> String? {
            guard !options.contains("--no-sidecars") else { return nil }
            return [argument("take"), videoPath, outputPath].compactMap { $0 }.first.map { path in
                let url = URL(fileURLWithPath: path)
                let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? "scene"
                return url.deletingLastPathComponent().appendingPathComponent(stem + suffix).path
            }
        }
        if let sceneOutPath = argument("scene-out") ?? beside(".scene.json") {
            try built.file.encoded().write(to: Self.prepared(sceneOutPath))
            print("scene file \(sceneOutPath)")
        }

        stepsPerFrame = max(steps / max(frames, 1), 1)
        let stepsPerFrame = self.stepsPerFrame
        // `--dt-schedule 0:2,162:1` (#307, #312): a coarser step for stretches of the run,
        // switched on frame boundaries; with `--dt-judge <Myr>` the run holds the fine step while
        // its own centres say a pair is engaged, or was within that margin.
        // docs/notes/variable-time.md.
        let stepSchedule = try argument("dt-schedule").map(StepSchedule.init(parsing:)).map { given in
            var given = given
            given.margin = argument("dt-judge").flatMap(Double.init)
            return given
        }
        try stepSchedule?.check(stepsPerFrame: stepsPerFrame)
        let stepper = engine.stepper
        if stepSchedule != nil && stepper == nil {
            throw Failure.message("--dt-schedule needs the Barnes-Hut solver")
        }
        let ownStep = scene.timeStep
        var scheduler = stepSchedule.map {
            StepScheduler(
                schedule: $0, stepMyr: Double(ownStep) * Physics.megayearsPerTimeUnit,
                story: Story(scene: scene))
        }
        /// Steps through `count` of the run's own steps, at the scale the schedule gives the
        /// stretch starting here, and shows the run's centres to its judge. Returns how many steps
        /// that took.
        @discardableResult
        func advance(_ count: Int, frame: Int?) -> Int {
            guard var current = scheduler, let stepper else {
                solver.step(count: count)
                return count
            }
            let (run, switched) = current.step(count, frame: frame, on: stepper, ownStep: ownStep)
            if switched, let last = current.switches.last {
                print(
                    String(
                        format: "schedule   step x%d from t=%.2f Myr%@", last.scale, last.myr,
                        frame.map { " (frame \($0))" } ?? ", settling"))
            }
            scheduler = current
            return run
        }
        let zoom = look.camera.zoom
        let clock = Date()

        // Framing is fixed once so the camera does not drift as the tails grow.
        var frozenRadius = look.camera.radius

        framesPerSecond = Int(number("fps", 30))
        let framesPerSecond = self.framesPerSecond

        // The director re-applies a look every frame, so it is handed this one to build on;
        // without it, it would pick one of its own named looks and every look flag would be
        // silently ignored.
        engine.apply(look.look)

        // The director places the camera and lights the scene on its own. Without it a hundred
        // generated scenes come out framed identically, which is the thing that makes a library
        // dull.
        let directed = look.camera.mode == .director || look.camera.mode == .immersed
        let director: Cinematographer? = directed ? Cinematographer(seed: scene.seed) : nil
        var autoCamera = AutoCamera()
        reach = scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) }
        let reach = self.reach
        director?.beginScene(seed: scene.seed, base: look.look, immersed: look.camera.mode == .immersed)

        if let lookOutPath = argument("look-out") ?? beside(".look.json") {
            try (director?.lookFile(look) ?? look).encoded().write(to: Self.prepared(lookOutPath))
            print("look file  \(lookOutPath)")
        }

        let video = try videoPath.map {
            try engine.video(
                url: Self.prepared($0), width: width, height: height, framesPerSecond: framesPerSecond)
        }
        drawsVideo = video != nil

        // A take holds the run rather than the picture, so a scene can be rendered again at
        // another size, another exposure or another camera without simulating it a second time.
        // Past its budget it carries on in a scratch file, which is what lets a take of tens of
        // gigabytes be captured on a machine with less memory than that.
        takeBudget = Int(
            number("take-memory", Double(ProcessInfo.processInfo.physicalMemory / 4) / 1e6) * 1e6)
        let takeBudget = self.takeBudget
        // `--take-interval n` keeps one frame in n, and whatever draws the take again
        // interpolates the rest.
        takeInterval = max(Int(number("take-interval", 1)), 1)
        let take: Recording? = argument("take").map { _ in reel(drawnCount) }

        /// Per frame scalars, written for whoever scores the result later: a curve to drive a
        /// filter with is worth more than a picture of one.
        let curvesHeader =
            "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction"
            + scene.galaxies.indices.map { ",disruption_\($0)" }.joined()
            + scene.galaxies.indices.map { ",x_\($0),y_\($0),z_\($0)" }.joined()
            + scene.galaxies.indices.map { ",torn_\($0)" }.joined() + "\n"
        let curves: FileHandle? = try argument("curves").map { path in
            let url = try Self.prepared(path)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data(curvesHeader.utf8))
            return handle
        }
        // `--story-cap <Myr>` keeps capturing past the planned frames while the story goes on, up
        // to that much simulated time; `explore` asks for it. It reads the curves as written, so
        // judging the file again afterwards gives the same answer.
        let storyCap = argument("story-cap").flatMap(Double.init) ?? 0
        // Frames kept after the story ends, to see that nothing happens next. For measuring only.
        let storyAfter = number("story-after", 0)
        var storySettings = Story.Settings()
        storySettings.horizon = storyCap
        var story =
            storyCap > 0 && curves != nil
            ? Story.Tracker(story: Story(scene: scene, settings: storySettings)) : nil
        var previousTime = solver.time
        var curvesSeconds: Double = 0
        var takeSeconds: Double = 0
        // A sampled star farther than this from every centre is in a tail or a bridge, not a
        // disk. A black hole holds no disk, so the stars it carries off count as torn from the
        // host.
        tidalReach = zip(reach, scene.galaxies).map { $1.kind == .blackHole ? 0 : $0 * 1.5 }
        let tidalReach = self.tidalReach

        // Steps run before the first frame is written. A sampled disk is not born in equilibrium
        // and settles over its first few hundred megayears, which is worth simulating and not
        // worth watching.
        settle = Int(number("settle", 0))
        let settle = self.settle
        // The cost of a step is flat (#19), so what has been done so far says what is left: while
        // settling, from the pace of the steps; once frames come, from the pace of the frames,
        // which the drawing of each one is part of.
        let totalSteps = settle + stepsPerFrame * frames
        /// The run's steps done and left once `ownDone` of its own are done: a schedule's coarser
        /// steps cover more of its time, which the progress and the estimated end count.
        func runSteps(ownDone: Int) -> (done: Int, left: Int) {
            guard let scheduler, let stepSchedule else { return (ownDone, max(totalSteps - ownDone, 0)) }
            let left = stepSchedule.steps(
                settle: settle, frames: frames, perFrame: stepsPerFrame, stepMyr: scheduler.stepMyr,
                from: ownDone)
            return (scheduler.stepsRun, left)
        }
        let wantsStillAt: (Int) -> Bool = { frame in
            outputURL != nil || (thumbnailURL != nil && frame == thumbnailFrame)
        }
        stillFrames = wantsStillAt
        try measures?.started(self)
        if settle > 0 {
            let settleStart = Date()
            // In chunks, so a settle of minutes still reports; a schedule's in frames, the last
            // one ending where the first frame starts.
            let chunk = stepSchedule == nil ? max(settle / 50, 1) : stepsPerFrame
            var settled = 0
            while settled < settle {
                let count =
                    stepSchedule == nil || settled > 0
                    ? min(chunk, settle - settled) : (settle - 1) % stepsPerFrame + 1
                advance(count, frame: nil)
                settled += count
                let elapsed = Date().timeIntervalSince(settleStart)
                let (done, left) = runSteps(ownDone: settled)
                let progress = Double(done) / Double(max(done + left, 1))
                reporter?.update(
                    progress: progress, detail: "settle \(settled)/\(settle)",
                    eta: RunStatus.eta(elapsed: elapsed, progress: progress, now: Date()))
            }
            print(
                String(
                    format: "settle     %d steps, t=%.1f Myr, %.1f s", settle,
                    Double(solver.time) * Physics.megayearsPerTimeUnit,
                    Date().timeIntervalSince(settleStart)))
            // Stars formed while settling are not the clip's, and would read as a burst on frame 0.
            previousTime = solver.time
        }
        let settleRun = scheduler?.stepsRun ?? settle

        /// Past the planned frames, whether the story still wants more.
        func storyGoesOn() -> Bool {
            guard let story, let last = story.samples.last, last.timeMyr < storyCap else { return false }
            guard let quiet = story.quietFrom else { return true }
            return last.timeMyr < story.samples[quiet].timeMyr + storyAfter
        }

        let framesStart = Date()
        let firstFrame = 0
        var frame = firstFrame
        while frame < frames || storyGoesOn() {
            defer { frame += 1 }
            let simulationStart = Date()
            let frameSteps = advance(stepsPerFrame, frame: frame)
            let simulationMs = Date().timeIntervalSince(simulationStart) * 1000
            try measures?.afterSteps(self, frame: frame)

            if frozenRadius <= 0 && look.camera.mode != .auto {
                frozenRadius = engine.framedRadius(look.camera)
            }

            let smoothingStart = Date()
            // Plain points have no kernel to size.
            if !look.plain { try engine.refreshSmoothing() }
            let smoothingMs = Date().timeIntervalSince(smoothingStart) * 1000
            engine.prepareFrame(
                time: solver.time,
                diskFrames: DiskFrame.make(
                    scene: scene, centers: solver.centers, time: solver.time,
                    strength: LookFile.diskStrength(look.armStrength, director?.look ?? look.look)))
            let camera: Camera
            if let director {
                // Advanced by one frame of playback rather than by wall clock, so the move reads
                // the same however long the frame took to compute.
                director.advance(
                    seconds: 1 / Double(framesPerSecond),
                    of: Subject(centres: scene.framedCentres(solver.centers), radius: frozenRadius))
                engine.apply(director.look)
                camera = director.camera
            } else {
                var framed = (center: look.camera.center ?? .zero, radius: frozenRadius)
                if look.camera.mode == .auto {
                    framed = autoCamera.frame(centres: scene.framedCentres(solver.centers), margins: reach)
                    framed.radius /= zoom
                }
                camera = look.camera.camera(
                    progress: Float(frame) / Float(max(frames - 1, 1)), radius: framed.radius,
                    center: framed.center, fieldOfView: look.look.fieldOfView)
            }
            let renderStart = Date()
            // The video is drawn straight into the encoder's buffers; a still is read off the same
            // frame rather than drawn twice.
            let wantsStill = wantsStillAt(frame)
            var still: (any RunVideoStill)?
            if let video {
                try video.append(camera: camera, still: wantsStill ? { still = $0 } : nil)
            } else if wantsStill {
                still = try engine.still(camera: camera)
            }
            let renderMs = Date().timeIntervalSince(renderStart) * 1000
            try measures?.afterDrawing(self, frame: frame, camera: camera, drew: video != nil || wantsStill)
            if let outputURL {
                let url =
                    frames == 1
                    ? outputURL
                    : outputURL.deletingPathExtension().appendingPathExtension(
                        String(format: "%04d.png", frame))
                if let still { try engine.write(still, to: url, maximumWidth: nil) }
            }
            if let thumbnailURL, frame == thumbnailFrame {
                if let still { try engine.write(still, to: thumbnailURL, maximumWidth: 480) }
                print("thumbnail  \(thumbnailURL.path)")
            }

            if let take {
                let takeStart = Date()
                engine.withPositions { positions in
                    take.offer(
                        positions: positions, time: solver.time, centers: solver.centers,
                        disks: engine.diskFrames, budget: takeBudget)
                }
                takeSeconds += Date().timeIntervalSince(takeStart)
            }
            try measures?.afterTake(self, frame: frame)

            if let curves {
                let curvesStart = Date()
                let centres = solver.centers
                let separation =
                    centres.count >= 2 ? simd_length(centres[1] - centres[0]) : Float(0)
                var closest = Float.infinity
                for i in centres.indices {
                    for j in centres.indices where j > i {
                        closest = min(closest, simd_length(centres[j] - centres[i]))
                    }
                }
                if !closest.isFinite { closest = 0 }
                var sum: Float = 0
                var counted = 0
                var tidal = 0
                func tally(_ position: SIMD3<Float>) {
                    sum += simd_length_squared(position)
                    counted += 1
                    for (centre, limit) in zip(centres, tidalReach)
                    where simd_length_squared(position - centre) < limit * limit {
                        return
                    }
                    tidal += 1
                }
                // Root mean square radius over a subsample: a smooth measure of how far the thing
                // has spread, for a fraction of the cost of sorting every radius. Read straight
                // out of the position buffer: `particles` on a GPU solver rebuilds the whole
                // system on every access, and calling it once per sample made each frame nine
                // seconds slower.
                engine.withPositions { positions in
                    for index in stride(from: 0, to: drawnCount, by: 64) { tally(positions[index]) }
                }
                let extent = counted > 0 ? (sum / Float(counted)).squareRoot() : 0
                let tidalFraction = counted > 0 ? Float(tidal) / Float(counted) : 0
                let states = engine.diskFrames
                let disks = scene.galaxies.indices.map {
                    String(format: ",%.3f", $0 < states.count ? states[$0].disruption : 0)
                }.joined()
                let torn = scene.galaxies.indices.map {
                    String(format: ",%.3f", $0 < states.count ? states[$0].torn : 0)
                }.joined()
                // From the frame's start, the time its first step's knots carry, to just before
                // now: counted from just after the start, that step never showed (#306).
                let formed = engine.formed(since: previousTime, before: solver.time)
                let myr = Double(solver.time) * Physics.megayearsPerTimeUnit
                let track = centres.map { String(format: ",%.4f,%.4f,%.4f", $0.x, $0.y, $0.z) }.joined()
                let line =
                    String(
                        format: "%d,%.3f,%.4f,%.4f,%d,%.4f,%.4f", frame, myr, separation, extent, formed,
                        closest, tidalFraction) + disks + track + torn + "\n"
                try curves.write(contentsOf: Data(line.utf8))
                if let sample = Story.samples(csv: curvesHeader + line).first { story?.append(sample) }
                curvesSeconds += Date().timeIntervalSince(curvesStart)
            }
            previousTime = solver.time

            if frame < frames {
                let (done, left) = runSteps(ownDone: settle + (frame + 1) * stepsPerFrame)
                var framesDone = Double(frame + 1 - firstFrame) / Double(max(frames - firstFrame, 1))
                if scheduler != nil {
                    framesDone = Double(done - settleRun) / Double(max(done - settleRun + left, 1))
                }
                reporter?.update(
                    progress: Double(done) / Double(max(done + left, 1)),
                    detail: "frame \(frame + 1)/\(frames)",
                    eta: RunStatus.eta(
                        elapsed: Date().timeIntervalSince(framesStart), progress: framesDone, now: Date()))
            } else {
                // How long a story still has is not known until it ends.
                reporter?.update(
                    progress: 0.99,
                    detail: String(
                        format: "frame %d, story going on at %.0f Myr", frame + 1,
                        Double(solver.time) * Physics.megayearsPerTimeUnit))
            }

            if let profile = engine.takeProfile() {
                let phases = StepProfile.phases.compactMap { phase -> String? in
                    let value = profile.perStep(phase)
                    return value > 0 ? String(format: "%@ %.2f", phase, value) : nil
                }
                print("profile    " + phases.joined(separator: ", "))
            }
            print(
                String(
                    format:
                        "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms"
                        + "  render %5.1f ms (gpu %5.2f)",
                    frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
                    simulationMs / Double(frameSteps), smoothingMs, renderMs, engine.lastGPUTime * 1000))
        }

        reporter?.update(progress: 1, detail: "finishing", eta: Date())
        try video?.end()
        try curves?.close()
        // `--state-out <path>`: what a checkpoint keeps of the particles at the end, and the
        // solver's state beside it as `<path>.json`, to compare two runs to the bit.
        if let path = argument("state-out"), let state = engine.state {
            let url = try Self.prepared(path)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try engine.writeParticles(to: handle)
            try handle.close()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url.appendingPathExtension("json"))
            print("state      \(url.path)")
        }
        if let story, let span = story.span(plannedFrames: frames) {
            print(
                String(
                    format: "story      %.0f to %.0f Myr (frames %d to %d of %d), %@", span.startMyr,
                    span.endMyr, span.startFrame, span.endFrame, frame,
                    span.complete
                        ? "over"
                        : "still going at the cap: "
                            + story.activity.map(\.description).joined(separator: "; ")))
            // The clip as it ran, so a rerun and every later stage see the same stretch of time.
            if let folder = explore {
                var clip = try folder.storedClip()
                clip.frames = frame
                clip.steps = frame * stepsPerFrame
                clip.story = span
                try clip.encoded().write(to: folder.clip)
            }
        }
        try measures?.finish(self)
        if curves != nil {
            print(
                String(
                    format: "curves     %.1f ms in all, %.3f ms a frame", curvesSeconds * 1000,
                    curvesSeconds * 1000 / Double(max(frames, 1))))
        }
        if let take, let path = argument("take") {
            if let failure = take.spillFailure { print("take       held in memory: \(failure)") }
            print(
                String(
                    format: "take       %.1f ms a frame quantising, %d bits an axis",
                    takeSeconds * 1000 / Double(max(take.capturedCount, 1)), take.bitsPerAxis))
            try RecordingFile.write(
                take, scene: drawnScene, particles: engine.capturedParticles(), to: Self.prepared(path))
        }
        if let (folder, done) = hires {
            do {
                try folder.commitHires()
            } catch {
                throw Failure.message("hires: could not put the take in place: \(error)")
            }
            var record = done
            record.seconds = Date().timeIntervalSince(started)
            if let scheduler {
                record.stepsRun = scheduler.stepsRun
                record.stepSwitches = scheduler.switches
                print("schedule   \(scheduler.stepsRun) steps run for \(scheduler.ownSteps) of the run's own")
            }
            record.peakMemoryBytes = engine.peakMemory.host
            record.takeBytes =
                (try? FileManager.default.attributesOfItem(atPath: folder.take.path)[.size] as? Int)
                ?? nil
            try record.encoded().write(to: folder.hires)
            print(
                String(
                    format: "hires      %.0f s, peak %.2f GB, take %.2f GB", record.seconds ?? 0,
                    Double(record.peakMemoryBytes ?? 0) / 1e9, Double(record.takeBytes ?? 0) / 1e9))
            var finished = RunEvent(RunEvent.Kind.hiresDone)
            finished.particles = record.particles
            finished.massive = record.massive
            finished.steps = record.steps
            finished.minutes = (record.seconds ?? 0) / 60
            finished.takeGB = Double(record.takeBytes ?? 0) / 1e9
            finished.pass = record.pass?.rawValue
            reporter?.record(finished)
        }
        print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
        return .done
    }
}
