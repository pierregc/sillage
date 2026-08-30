import AppKit
import Combine
import Metal
import MetalKit
import SillageCore
import SillageRender
import simd

enum Stage {
    case setup
    case running
}

/// What the viewer is showing. Live steps the solver inside the draw loop, which is fine when
/// a step costs a millisecond and unusable when it costs half a second. Recording runs the
/// solver on its own queue and captures snapshots; playback replays them at display rate.
/// What the canvas is showing. There is no separate recording mode: a run captures itself
/// from the moment it starts, because a scene that has already been computed once should
/// never have to be computed again to be watched.
enum ViewerMode {
    case running
    case playback
}

/// A Metal buffer handed to the simulation queue. `MTLBuffer` carries no Sendable promise,
/// and the compiler cannot see that the queue reading this one is the only thing writing it.
private struct SendableBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}

@MainActor
final class SimulationModel: ObservableObject {
    @Published var stage: Stage = .setup
    @Published var scene: SceneConfig
    /// Edited by the setup screen. Applied to `scene` only when the user starts the run.
    @Published var draft: SceneConfig
    @Published var camera = OrbitCamera()
    /// Free flight. Only the flag is published: the rig itself moves on every frame, and
    /// publishing that would rebuild the panel sixty times a second.
    @Published var isFlying = false
    var flight = FlyCamera()
    private var lastDrawTime: CFTimeInterval?

    /// Whichever rig is driving, for the renderer.
    var activeCamera: Camera { isFlying ? flight.camera : camera.camera }

    /// Swaps rigs without the view jumping: each takes up where the other left off.
    func toggleFlight() {
        if isFlying {
            flight.handBack(&camera)
        } else {
            flight.adopt(camera)
        }
        isFlying.toggle()
        lastDrawTime = nil
    }

    /// One frame of held-key flight. Reads the keys the canvas is holding rather than acting
    /// on key events, so the speed follows the frame time instead of the key repeat rate.
    private func flyOneFrame(_ view: MTKView, seconds: Float) {
        guard isFlying, let canvas = view as? CanvasView else { return }
        let held = canvas.held
        func axis(_ positive: UInt16, _ negative: UInt16) -> Float {
            (held.contains(positive) ? 1 : 0) - (held.contains(negative) ? 1 : 0)
        }
        var demand = FlyCamera.Demand()
        demand.move = SIMD3<Float>(
            axis(CanvasView.Key.w, CanvasView.Key.s),
            axis(CanvasView.Key.d, CanvasView.Key.a),
            axis(CanvasView.Key.space, CanvasView.Key.c)
                + axis(CanvasView.Key.e, CanvasView.Key.q))
        demand.turn = SIMD2<Float>(
            axis(CanvasView.Key.left, CanvasView.Key.right) * 1.4,
            axis(CanvasView.Key.up, CanvasView.Key.down) * 1.4)
        let modifiers = canvas.modifiers
        if modifiers.contains(.shift) { demand.boost = 5 }
        if modifiers.contains(.control) { demand.boost = 0.2 }
        flight.advance(demand, seconds: seconds)
    }
    @Published var stepsPerFrame = 4 {
        didSet {
            guard mode == .running, isPlaying, stepsPerFrame != oldValue else { return }
            startLiveStepping()
        }
    }
    @Published private(set) var particleCount = 0
    @Published private(set) var elapsedMyr = 0.0
    @Published private(set) var frameMilliseconds = 0.0
    /// Simulated time per second of wall clock, measured rather than estimated. This is the
    /// number that decides whether a scene is worth waiting for.
    @Published private(set) var megayearsPerSecond = 0.0
    /// Sampling and solver construction are in flight; there is no scene to draw yet.
    @Published private(set) var isPreparing = false
    /// Arms the automatic save. The run stops at its finish and writes there by itself.
    func saveWhenFinished(to url: URL) {
        finishDestination = url
        if stopAtMyr <= 0 { stopAtMyr = max(elapsedMyr * 2, 500) }
    }

    func cancelSaveWhenFinished() { finishDestination = nil }

    /// Called on the main actor after each batch. Stops the run at its finish, replays it,
    /// and writes it out if that was asked for.
    private func checkFinish() {
        guard mode == .running, stopAtMyr > 0, elapsedMyr >= stopAtMyr else { return }
        reachedFinish = true
        stopLiveStepping()
        isPlaying = false
        guard canReplay else {
            if quitWhenFinished { NSApplication.shared.terminate(nil) }
            return
        }
        let destination = finishDestination
        stopAndReplay()
        if let destination {
            finishDestination = nil
            saveTake(to: destination)
        } else if quitWhenFinished {
            NSApplication.shared.terminate(nil)
        }
    }

    /// What the disk is doing, while it is doing it.
    @Published private(set) var fileActivity: String?
    /// A take opened from a file has no solver, so nothing can be advanced from it.
    var isOpenedTake: Bool { solver == nil && recording != nil }
    private(set) var framesDrawn = 0
    private(set) var drawAttempts = 0
    private weak var canvas: MTKView?

    /// Held so the verification mode can drive the view itself. MTKView pauses its display
    /// link whenever the window is occluded, which a window opened behind another app always
    /// is, and that would otherwise make the render path untestable from a script.
    func attach(canvas view: MTKView) { canvas = view }

    func drawOnce() { canvas?.draw() }

    /// Presses or releases a key on the canvas, for the headless checks.
    func hold(key: UInt16, _ down: Bool) { (canvas as? CanvasView)?.hold(key, down) }
    @Published private(set) var failure: String?

    @Published private(set) var mode: ViewerMode = .running
    @Published private(set) var capturedFrames = 0
    @Published private(set) var capturedBytes = 0
    /// Whether the take has had to coarsen to stay inside its budget.
    @Published private(set) var captureIsFull = false
    /// Batches between captured frames. One until the budget is reached, then doubling.
    @Published private(set) var captureStride = 1
    /// Whether the canvas is on screen while the solver works.
    ///
    /// Drawing a few million particles takes a real share of the same GPU the solver is on.
    /// When a scene is being computed to be watched later rather than now, the picture is
    /// worth nothing and the panel says everything.
    @Published var showCanvasWhileRunning = true
    /// Quit once the run has finished and written itself out. For a scene left overnight
    /// there is nothing left to do or to show.
    @Published var quitWhenFinished = false

    /// Simulated time to stop at, in Myr. Zero runs until stopped by hand.
    ///
    /// A run has no natural end: it goes until someone presses something, and long after a
    /// scene has stopped changing it is still taking the machine. Giving it a finish means a
    /// big scene can be started and left.
    @Published var stopAtMyr = 0.0
    /// Where to write the take when the run reaches its finish, if anywhere.
    @Published private(set) var finishDestination: URL?
    /// Set once a run has reached its finish, so the panel can say so.
    @Published private(set) var reachedFinish = false

    /// How much memory the capture may take before it stops adding to itself.
    @Published var memoryBudgetGigabytes = 4.0 {
        didSet {
            guard mode == .running, isPlaying, memoryBudgetGigabytes != oldValue else { return }
            startLiveStepping()
        }
    }
    @Published var playbackSpeed: Float = 30
    @Published var playbackPosition: Double = 0
    @Published var isPlaying = true {
        didSet {
            guard mode == .running, isPlaying != oldValue else { return }
            isPlaying ? startLiveStepping() : stopLiveStepping()
        }
    }
    private(set) var recording: Recording?
    private var expander: SnapshotExpander?
    private var snapshots: SnapshotStream?
    private var smoothing: SmoothingField?
    /// Smoothing lengths track density, which changes slowly, so they are refreshed every so
    /// many frames rather than every one. The refresh builds a tree over every particle, which
    /// is half a second at five million: it belongs on the simulation queue, not in the draw
    /// call, and the buffer it writes is read by the renderer the same way positions are.
    private var framesSinceSmoothing = 0
    private var smoothingInFlight = false

    // The setup screen renders the draft scene as it stands, without ever stepping it, so the
    // effect of a parameter can be seen while it is being set rather than after a run.
    @Published private(set) var previewParticleCount = 0
    @Published var previewCamera = OrbitCamera()
    private var previewRenderer: Renderer?
    private var previewSmoothing: SmoothingField?
    private var previewPositions: MTLBuffer?
    private var previewSize = CGSize(width: 900, height: 900)
    private var previewGeneration = 0
    var previewCanvasSize: CGSize { previewSize }
    var previewViewFrame: CGRect { previewCanvas?.frame ?? .zero }
    private weak var previewCanvas: MTKView?

    /// Particles the preview draws. Enough to judge a shape, few enough to resample on the
    /// release of a slider.
    static let previewBudget = 350_000
    private var playbackPositions: MTLBuffer?
    private var playbackCenters: [SIMD3<Float>] = []
    /// Identifies the current live stepping chain. Bumping it retires whatever is running.
    private var liveGeneration = 0
    /// Same idea for the sampling job, which a second launch can supersede mid-flight.
    private var preparation = 0
    private var reframeWhenReady = false
    /// Utility rather than default. The tree build fans out over every core through
    /// `concurrentPerform`, which inherits the calling thread's class, and at full priority a
    /// large scene makes the whole machine unusable rather than just this window. Measured at
    /// a million particles: 112.7 ms a step against 116.7, so it costs nothing. Background
    /// would cost 70 %.
    private let simulationQueue = DispatchQueue(
        label: "dev.pierregc.sillage.simulation", qos: .utility)

    var capturedMegabytes: Double { Double(capturedBytes) / 1_048_576 }
    var capturedMyr: Double { Double(recording?.duration ?? 0) * Physics.megayearsPerTimeUnit }
    var captureFraction: Double {
        min(Double(capturedBytes) / max(memoryBudgetGigabytes * 1_073_741_824, 1), 1)
    }
    /// Playback interpolates between snapshots, so it needs two of them.
    var canReplay: Bool { capturedFrames >= 2 }

    @Published var brightness: Float = 0.15 { didSet { renderer?.setBrightness(brightness) } }
    @Published var stretch: Float = 18 { didSet { renderer?.setStretch(stretch) } }
    @Published var saturation: Float = 1.8 { didSet { renderer?.setSaturation(saturation) } }
    /// 0 colours every star by its population alone, which is the physical answer. A little
    /// of the galaxy's own tint on top is what keeps stars torn out of one disk recognisable
    /// once they are inside the other.
    @Published var galaxyTint: Float = 0.35 {
        didSet {
            renderer?.setGalaxyTint(galaxyTint)
            previewRenderer?.setGalaxyTint(galaxyTint)
        }
    }
    @Published var bloom: Float = 0.22 { didSet { renderer?.setBloomIntensity(bloom) } }
    @Published var dustStrength: Float = 0.16 { didSet { renderer?.setDustStrength(dustStrength) } }
    @Published var spikeIntensity: Float = 0.38 {
        didSet { renderer?.setSpikeIntensity(spikeIntensity) }
    }
    @Published var skyLevel: Float = 0.0018 { didSet { renderer?.setSkyLevel(skyLevel) } }
    @Published var noiseLevel: Float = 0.0016 { didSet { renderer?.setNoiseLevel(noiseLevel) } }
    /// Pure uniform now, so it applies on the next frame with no tree rebuild.
    @Published var smoothingScale: Float = 1.9 {
        didSet {
            renderer?.setSmoothingScale(smoothingScale)
            previewRenderer?.setSmoothingScale(smoothingScale)
            redrawPreview()
        }
    }
    @Published var supersample = 1 { didSet { rebuildRenderer() } }

    let device: MTLDevice
    private(set) var solver: (any GPUSolver)?
    private(set) var renderer: Renderer?
    private var seeded = ParticleSystem()
    private var drawableSize = CGSize(width: 1280, height: 720)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        // Sized so the app opens on something that gets somewhere. Self-gravity with a live
        // halo simulates two and a half particles for every one drawn, and at 400 000 visible
        // and the tuned step a 500 Myr encounter took half an hour: measurement says four
        // times that step is indistinguishable, so the opening scene takes it.
        var start = SceneConfig.merger(particleCount: 250_000)
        start.timeStepScale = 4
        start.retune()
        self.scene = start
        self.draft = start
    }

    /// Commits the setup screen's draft and moves to the running view. Nothing heavy is built
    /// until this runs, so the setup screen opens instantly.
    ///
    /// `waiting` samples on the calling thread instead of the simulation queue. The headless
    /// checks need the scene to exist the moment they return; a window does not.
    func start(waiting: Bool = false) {
        scene = draft
        // returnToSetup pauses, so without this a second launch sits still.
        isPlaying = true
        stage = .running
        reframeWhenReady = true
        restart(waiting: waiting)
    }

    func attachPreview(canvas view: MTKView) { previewCanvas = view }

    /// The preview draws on demand, so anything that changes what it should show has to say so.
    private func redrawPreview() { previewCanvas?.needsDisplay = true }

    func resizePreview(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard
            Int(size.width) != Int(previewSize.width)
                || Int(size.height) != Int(previewSize.height)
        else { return }
        previewSize = size
        rebuildPreview()
    }

    /// Resamples the draft and reframes. Called when a control is released, never mid-drag.
    ///
    /// Sampling the preview's three hundred thousand particles takes 140 ms, and every slider
    /// in the setup screen asks for it on release, so it happens on the simulation queue and
    /// the old preview stays on screen until the new one is ready.
    func rebuildPreview(waiting: Bool = false) {
        previewGeneration &+= 1
        let generation = previewGeneration
        let scene = previewScene()
        guard !waiting else {
            installPreview(RestrictedSolver.sampleParticles(for: scene))
            return
        }
        simulationQueue.async { [weak self] in
            let particles = RestrictedSolver.sampleParticles(for: scene)
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.installPreview(particles)
            }
        }
    }

    /// The draft as the preview draws it: tracers, and no more than the preview's budget.
    private func previewScene() -> SceneConfig {
        var scene = draft
        // Sampled as tracers: the preview never integrates, so it needs no masses and no halo
        // particles, which would only slow the resample down.
        scene.solver = .restricted
        let total = max(scene.totalParticleCount, 1)
        if total > Self.previewBudget {
            let ratio = Double(Self.previewBudget) / Double(total)
            for index in scene.galaxies.indices {
                scene.galaxies[index].particleCount = max(
                    Int(Double(scene.galaxies[index].particleCount) * ratio), 500)
            }
        }

        return scene
    }

    private func installPreview(_ particles: ParticleSystem) {
        defer { redrawPreview() }
        previewParticleCount = particles.count
        guard particles.count > 0 else { return }

        do {
            let settings = RenderSettings(
                width: Int(previewSize.width), height: Int(previewSize.height),
                supersample: 1, brightness: brightness, dustStrength: dustStrength,
                smoothingScale: smoothingScale,
                bloomIntensity: bloom, stretch: stretch, saturation: saturation,
                spikeIntensity: spikeIntensity, skyLevel: skyLevel, noiseLevel: noiseLevel,
                galaxyTint: galaxyTint)
            let buffer = device.makeBuffer(
                length: particles.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared)
            previewPositions = buffer
            previewSmoothing = try SmoothingField(device: device, particleCount: particles.count)
            previewRenderer = try Renderer(
                device: device, particles: particles, settings: settings,
                externalPositions: buffer)
            previewRenderer?.upload(positions: particles.positions)
            previewRenderer?.setSmoothing(previewSmoothing?.buffer)
            previewSmoothing?.update(positions: particles.positions)

            if let radius = Self.framingRadius(particles) {
                previewCamera.frame(radius: radius * 1.3)
            }
            previewCamera.elevation = 1.2
        } catch {
            failure = "\(error)"
            previewRenderer = nil
        }
    }

    /// Renders the setup preview offscreen. The particle count alone says nothing about
    /// whether the preview draws, which is how a black one went unnoticed.
    func previewSnapshot() -> [UInt8]? {
        guard let previewRenderer else { return nil }
        previewRenderer.setDiskFrames(
            DiskFrame.make(
                scene: draft, centers: draft.galaxies.map(\.position), time: 0, strength: 1))
        return previewRenderer.render(camera: previewCamera.camera)
    }

    private(set) var previewDrawAttempts = 0
    private(set) var previewFramesDrawn = 0
    private(set) var previewNoDrawable = 0
    private(set) var previewNoRenderer = 0

    /// Rebuilds the smoothing lengths on the simulation queue. One at a time: a second
    /// request while the first is still walking the particles would only queue up work that
    /// is about to be thrown away.
    private func refreshSmoothing() {
        guard !smoothingInFlight, let field = smoothing else { return }
        guard let bound = mode == .playback ? playbackPositions : solver?.positions else { return }
        smoothingInFlight = true
        let positions = SendableBuffer(bound)
        simulationQueue.async { [weak self] in
            field.update(from: positions.buffer)
            DispatchQueue.main.async { self?.smoothingInFlight = false }
        }
    }

    func drawPreview(in view: MTKView) {
        previewDrawAttempts += 1
        guard let previewRenderer else {
            previewNoRenderer += 1
            return
        }
        guard let drawable = view.currentDrawable else {
            previewNoDrawable += 1
            return
        }
        previewFramesDrawn += 1
        previewRenderer.setDiskFrames(
            DiskFrame.make(
                scene: draft, centers: draft.galaxies.map(\.position), time: 0,
                strength: 1))
        previewRenderer.present(camera: previewCamera.camera, drawable: drawable)
    }

    func returnToSetup() {
        stopLiveStepping()
        // A launch may still be sampling. Retire it, or it lands after the user has left.
        preparation &+= 1
        isPreparing = false
        stage = .setup
        mode = .running
        recording = nil
        capturedFrames = 0
        capturedBytes = 0
        captureIsFull = false
        playbackPositions = nil
        expander = nil
        snapshots = nil
        isPlaying = false
    }

    /// Advances the solver on the simulation queue, one batch at a time, and hops back to
    /// the main actor to publish the clock and queue the next batch.
    ///
    /// Live mode used to step inside the draw call. A self-gravitating step costs about a
    /// hundred milliseconds, so four of them per frame held the main actor for close to half
    /// a second at a time and every control on the window went dead between frames. The
    /// solver already ran off the main actor while recording; this puts live mode on the same
    /// footing, and the canvas draws whatever the position buffer holds when the frame comes
    /// round rather than waiting for the physics.
    ///
    /// Each start supersedes the last through the generation counter: a batch already in
    /// flight finishes, finds itself stale on its way back, and stops there.
    private func startLiveStepping() {
        guard mode == .running, isPlaying, let solver else { return }
        liveGeneration &+= 1
        pumpLive(
            generation: liveGeneration, solver: solver, steps: max(stepsPerFrame, 1),
            budget: Int(max(memoryBudgetGigabytes, 0) * 1_073_741_824))
    }

    private func stopLiveStepping() { liveGeneration &+= 1 }

    private func pumpLive(generation: Int, solver: any GPUSolver, steps: Int, budget: Int) {
        let reel = recording
        simulationQueue.async { [weak self] in
            let clock = Date()
            let before = solver.time
            solver.step(count: steps)
            let time = solver.time
            let rate =
                Double(time - before) * Physics.megayearsPerTimeUnit
                / max(Date().timeIntervalSince(clock), 1e-6)
            var frames = 0
            var bytes = 0
            var full = false
            var interval = 1
            if let reel {
                // The take decides for itself. Past its budget it keeps every other frame and
                // captures half as often, so a long run comes back whole at a coarser cadence
                // instead of stopping partway through.
                let positions = solver.positions.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: reel.particleCount)
                full = reel.offer(
                    positions: positions, time: time, centers: solver.centers, budget: budget)
                frames = reel.count
                bytes = reel.byteCount
                interval = reel.stride
            }
            DispatchQueue.main.async {
                guard let self, self.liveGeneration == generation else { return }
                self.elapsedMyr = Double(time) * Physics.megayearsPerTimeUnit
                // Smoothed, or a batch that happened to land behind a render makes the
                // number jump around too much to read.
                self.megayearsPerSecond =
                    self.megayearsPerSecond > 0
                    ? self.megayearsPerSecond * 0.8 + rate * 0.2 : rate
                self.capturedFrames = frames
                self.capturedBytes = bytes
                self.captureIsFull = full
                self.captureStride = interval
                self.checkFinish()
                guard self.liveGeneration == generation else { return }
                self.pumpLive(
                    generation: generation, solver: solver, steps: steps, budget: budget)
            }
        }
    }

    /// Starts a capture from wherever the solver has got to. Called on every restart, so a
    /// run is always its own recording.
    private func beginCapture() {
        guard let solver else { return }
        let reel = Recording(particleCount: drawnCount, galaxyCount: scene.galaxies.count)
        reel.reserve(frames: budgetedFrames)
        let positions = solver.positions.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: particleCount)
        reel.append(positions: positions, time: solver.time, centers: solver.centers)
        recording = reel
        capturedFrames = reel.count
        capturedBytes = reel.byteCount
        captureIsFull = false
        captureStride = 1
        playbackPosition = 0
    }

    /// Ends the capture and plays it back. The solver keeps its state, so the run can be
    /// picked up again where it stopped.
    func stopAndReplay() {
        guard canReplay, let reel = recording else { return }
        stopLiveStepping()
        // Settles the count before anything reads it: a batch in flight would otherwise add
        // one more frame after the stop.
        reel.close()
        capturedFrames = reel.count
        capturedBytes = reel.byteCount
        do {
            expander = try SnapshotExpander(device: device, particleCount: reel.particleCount)
            snapshots = SnapshotStream(device: device, recording: reel)
            playbackPositions = device.makeBuffer(
                length: reel.particleCount * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared)
            playbackPosition = 0
            isPlaying = true
            mode = .playback
            rebuildRenderer()
        } catch {
            failure = "\(error)"
        }
    }

    /// Back to advancing the solver, appending to the same capture.
    func resumeRunning() {
        // A take opened from a file has no solver to pick back up.
        guard mode == .playback, solver != nil else { return }
        recording?.reopen()
        mode = .running
        isPlaying = true
        rebuildRenderer()
        startLiveStepping()
    }

    /// Writes the take to disk. Three quarters of a gigabyte is a normal size for one, so
    /// it goes out on the simulation queue like everything else that would hold the window.
    func saveTake(to url: URL) {
        guard let reel = recording, canReplay else { return }
        fileActivity = "Enregistrement de la prise…"
        let scene = self.scene
        let particles = seeded
        simulationQueue.async { [weak self] in
            var failure: String?
            do {
                try RecordingFile.write(reel, scene: scene, particles: particles, to: url)
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                self?.fileActivity = nil
                if let failure { self?.failure = failure }
            }
        }
    }

    /// Renders the take to a video file, at whatever size is asked for.
    ///
    /// The take itself is the better thing to keep, since it comes back as the run. A video is
    /// what leaves the application, and it is rendered here rather than grabbed from the
    /// window: the resolution has nothing to do with the display and no frame is dropped.
    func exportVideo(to url: URL, width: Int, height: Int, framesPerSecond: Int) {
        guard let reel = recording, canReplay else { return }
        reel.close()
        let scene = self.scene
        let particles = seeded
        let camera = self.camera.camera
        let arms = renderer?.armPersistence ?? 1
        var settings = renderSettings(width: width, height: height)
        settings.supersample = max(supersample, 1)
        let total = reel.count
        fileActivity = "Export de la vidéo…"

        simulationQueue.async { [weak self] in
            var failure: String?
            do {
                try VideoExport.write(
                    recording: reel, particles: particles, scene: scene, settings: settings,
                    camera: camera, armStrength: arms,
                    framesPerSecond: Int32(max(framesPerSecond, 1)), to: url
                ) { fraction in
                    DispatchQueue.main.async {
                        self?.fileActivity = String(
                            format: "Export de la vidéo… %.0f %% (%d images)", fraction * 100,
                            total)
                    }
                }
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileActivity = nil
                if let failure { self.failure = failure }
                // Everything asked for has happened: the run reached its finish and is on
                // disk. Nothing is left to compute or to look at.
                if failure == nil, self.quitWhenFinished, self.reachedFinish {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    /// Opens a take and plays it, with no solver behind it.
    ///
    /// Nothing about how a run looks is baked into the file: exposure, colour, the telescope
    /// and the camera are all decided at draw time, so reopening one is not watching a video.
    func openTake(from url: URL) {
        stopLiveStepping()
        preparation &+= 1
        fileActivity = "Ouverture de la prise…"
        let device = self.device
        simulationQueue.async { [weak self] in
            let loaded: RecordingFile.Loaded?
            var failure: String?
            do {
                loaded = try RecordingFile.read(from: url)
            } catch {
                loaded = nil
                failure = "\(error)"
            }
            let expander =
                loaded.flatMap {
                    try? SnapshotExpander(device: device, particleCount: $0.recording.particleCount)
                }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileActivity = nil
                guard let loaded, let expander else {
                    self.failure = failure ?? "La prise n'a pas pu être ouverte"
                    return
                }
                self.installTake(loaded, expander: expander)
            }
        }
    }

    private func installTake(_ loaded: RecordingFile.Loaded, expander: SnapshotExpander) {
        failure = nil
        isPreparing = false
        solver = nil
        scene = loaded.scene
        draft = loaded.scene
        seeded = loaded.particles
        particleCount = loaded.particles.count
        recording = loaded.recording
        capturedFrames = loaded.recording.count
        capturedBytes = loaded.recording.byteCount
        captureIsFull = true
        self.expander = expander
        snapshots = SnapshotStream(device: device, recording: loaded.recording)
        playbackPositions = device.makeBuffer(
            length: loaded.recording.particleCount * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared)
        playbackPosition = 0
        playbackCenters = loaded.recording.centers(at: 0)
        elapsedMyr = Double(loaded.recording.frames.first?.time ?? 0) * Physics.megayearsPerTimeUnit
        mode = .playback
        isPlaying = true
        stage = .running
        smoothing = nil
        rebuildRenderer()
        frameCamera()
    }

    /// Throws the capture away and starts a new one from where the run stands.
    func restartCapture() {
        guard solver != nil else { return }
        stopLiveStepping()
        playbackPositions = nil
        expander = nil
        snapshots = nil
        mode = .running
        beginCapture()
        isPlaying = true
        rebuildRenderer()
        startLiveStepping()
    }

    var gpuName: String { device.name }

    /// Rebuilds the whole simulation.
    ///
    /// Sampling four million visible particles takes four seconds and building the solver
    /// another five, and both used to run on the main actor: launching a large scene froze
    /// every control on the window for nine seconds with nothing on screen to say why. It
    /// happens on the simulation queue now, and `isPreparing` says so while it does.
    func restart(waiting: Bool = false) {
        // Whatever is stepping is stepping the solver about to be replaced.
        stopLiveStepping()
        failure = nil
        isPreparing = true
        preparation &+= 1
        let generation = preparation
        let scene = self.scene
        let device = self.device
        let budget = memoryBudgetGigabytes

        guard !waiting else {
            let prepared = Self.prepare(scene: scene, device: device, budget: budget)
            install(prepared.0, prepared.1, prepared.2)
            return
        }
        simulationQueue.async { [weak self] in
            let prepared = Self.prepare(scene: scene, device: device, budget: budget)
            DispatchQueue.main.async {
                guard let self, self.preparation == generation else { return }
                self.install(prepared.0, prepared.1, prepared.2)
            }
        }
    }

    /// Everything a launch needs that does not have to happen on the main actor, which is all
    /// of it. The first captured frame belongs here too: quantising several million particles
    /// is a full pass over every one of them, and doing it on the way in cost close to half a
    /// second of dead window.
    /// Frames a capture will hold before it fills its budget. Reserved up front: growing a
    /// gigabyte-scale buffer a frame at a time doubles it whenever it fills, and for a moment
    /// both copies are resident.
    nonisolated static func budgetedFrames(particles: Int, gigabytes: Double) -> Int {
        let perFrame = max(particles * 6, 1)
        return max(Int(gigabytes * 1_073_741_824) / perFrame, 2)
    }

    private var budgetedFrames: Int {
        Self.budgetedFrames(particles: drawnCount, gigabytes: memoryBudgetGigabytes)
    }

    /// Particles that reach a pixel, which is what a take and the smoothing field work over.
    var drawnCount: Int { seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count }

    private nonisolated static func prepare(
        scene: SceneConfig, device: MTLDevice, budget: Double
    ) -> (ParticleSystem, (any GPUSolver)?, Recording?) {
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let built = try? GPUSolverFactory.make(device: device, scene: scene, particles: sampled)
        guard let built else { return (sampled, nil, nil) }
        // Only what is drawn goes into a take: the dark matter is three particles in five and
        // reaches no pixel, so recording it costs memory and copying for nothing.
        let drawn = sampled.visibleCount > 0 ? sampled.visibleCount : sampled.count
        let reel = Recording(particleCount: drawn, galaxyCount: scene.galaxies.count)
        reel.reserve(frames: Self.budgetedFrames(particles: drawn, gigabytes: budget))
        reel.append(
            positions: built.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: sampled.count),
            time: built.time, centers: built.centers)
        return (sampled, built, reel)
    }

    private func install(
        _ sampled: ParticleSystem, _ built: (any GPUSolver)?, _ reel: Recording?
    ) {
        seeded = sampled
        particleCount = sampled.count
        solver = built
        if built == nil { failure = "Le solveur n'a pas pu être construit" }
        elapsedMyr = 0
        megayearsPerSecond = 0
        // A restart invalidates the capture along with the solver it came from.
        mode = .running
        reachedFinish = false
        playbackPositions = nil
        expander = nil
        snapshots = nil
        isPreparing = false
        recording = reel
        capturedFrames = reel?.count ?? 0
        capturedBytes = reel?.byteCount ?? 0
        captureIsFull = false
        captureStride = 1
        playbackPosition = 0
        rebuildRenderer()
        if reframeWhenReady {
            reframeWhenReady = false
            frameCamera()
        }
        startLiveStepping()
    }

    func loadPreset(_ preset: SceneConfig) {
        // The exploration speed is how the user wants to watch, not part of the scene, so a
        // preset must not quietly undo it.
        let speed = draft.timeStepScale
        draft = preset
        draft.timeStepScale = speed
    }

    /// Softening and time step follow from the particle count and the disk size, so anything
    /// that changes either has to retune them before the preview is rebuilt.
    func commitDraftChange() {
        draft.retune()
        rebuildPreview()
    }

    func addGalaxy() {
        let share = max(draft.totalParticleCount / max(draft.galaxies.count, 1), 100_000)
        draft.galaxies.append(
            GalaxyConfig(
                name: "Galaxie \(draft.galaxies.count + 1)",
                particleCount: share,
                kind: .spiral,
                potential: GalaxyPotential(profile: .hernquist, mass: 30, scaleRadius: 4),
                diskScaleLength: 3,
                diskTruncation: 5,
                position: SIMD3<Float>(0, 60, 0),
                velocity: SIMD3<Float>(-0.5, 0, 0)))
    }

    func removeGalaxy(at index: Int) {
        guard draft.galaxies.count > 1, draft.galaxies.indices.contains(index) else { return }
        draft.galaxies.remove(at: index)
    }

    /// Rough simulation cost per frame on this GPU, measured at about 0.18 ms per million
    /// particles per step for the restricted solver and about 110 ms for Barnes-Hut, which
    /// also scales a little worse than linearly. Shown in the setup screen so the particle
    /// count can be chosen knowing what it costs.
    var estimatedStepMilliseconds: Double {
        let millions = Double(draft.simulatedParticleCount) / 1_000_000
        let perStep = draft.solver == .barnesHut ? 110 * pow(millions, 1.15) : 0.18 * millions
        return perStep * Double(stepsPerFrame)
    }

    /// What the draft would advance at, before it is run. The measured rate replaces this
    /// as soon as there is one.
    var estimatedMegayearsPerSecond: Double {
        let perStep = estimatedStepMilliseconds / Double(max(stepsPerFrame, 1))
        guard perStep > 0 else { return 0 }
        return Double(draft.timeStep) * Physics.megayearsPerTimeUnit * (1000 / perStep)
    }

    /// Scales every galaxy's share of the draft so the preset's own ratio is preserved.
    func setTotalParticles(_ total: Int) {
        let current = draft.totalParticleCount
        guard current > 0, total > 0 else { return }
        let ratio = Double(total) / Double(current)
        for index in draft.galaxies.indices {
            draft.galaxies[index].particleCount =
                max(Int(Double(draft.galaxies[index].particleCount) * ratio), 1)
        }
        draft.galaxies[0].particleCount += total - draft.totalParticleCount
    }

    func frameCamera() {
        guard let radius = Self.framingRadius(seeded) else { return }
        camera.frame(radius: radius * 1.3)
    }

    /// Radius holding 96 % of the light, from a subsample.
    ///
    /// Counting particles instead framed on the wrong thing: a run throws a faint halo of
    /// tracers well outside the galaxies, and nothing of it reaches a pixel, so the camera
    /// pulled back to hold material nobody can see and left the galaxies filling a third of
    /// the frame. Weighting by emission keeps a bright tidal tail and ignores the debris.
    ///
    /// Subsampled because sorting every radius cost four hundred milliseconds of frozen
    /// window at five million particles, to place a camera.
    static func framingRadius(_ system: ParticleSystem, fraction: Float = 0.96) -> Float? {
        guard !system.positions.isEmpty else { return nil }
        let step = max(system.positions.count / 50_000, 1)
        var samples: [(radius: Float, light: Float)] = []
        samples.reserveCapacity(system.positions.count / step + 1)
        for index in stride(from: 0, to: system.positions.count, by: step) {
            let radius = simd_length(system.positions[index])
            guard radius.isFinite else { continue }
            // Dust absorbs and dark matter does neither, so neither one frames anything.
            let emits =
                index < system.component.count
                ? ParticleComponent(rawValue: system.component[index])?.emits ?? true
                : true
            let light = emits && index < system.luminosity.count ? system.luminosity[index] : 0
            samples.append((radius, light))
        }
        guard !samples.isEmpty else { return nil }
        samples.sort { $0.radius < $1.radius }

        let total = samples.reduce(Float(0)) { $0 + $1.light }
        guard total > 0 else { return samples[Int(Float(samples.count) * 0.9)].radius }
        var running: Float = 0
        for sample in samples {
            running += sample.light
            if running >= total * fraction { return sample.radius }
        }
        return samples[samples.count - 1].radius
    }

    func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard
            Int(size.width) != Int(drawableSize.width)
                || Int(size.height) != Int(drawableSize.height)
        else { return }
        drawableSize = size
        rebuildRenderer()
    }

    /// Every setting that decides the image, at whatever size is asked for. One place, so an
    /// exported video looks like what is on screen rather than like a second guess at it.
    func renderSettings(width: Int, height: Int) -> RenderSettings {
        RenderSettings(
            width: max(width, 16),
            height: max(height, 16),
            supersample: supersample,
            brightness: brightness,
            dustStrength: dustStrength,
            smoothingScale: smoothingScale,
            bloomIntensity: bloom,
            stretch: stretch,
            saturation: saturation,
            spikeIntensity: spikeIntensity,
            skyLevel: skyLevel,
            noiseLevel: noiseLevel,
            galaxyTint: galaxyTint)
    }

    private func rebuildRenderer() {
        guard solver != nil || playbackPositions != nil else { return }
        let bound = mode == .playback ? playbackPositions : solver?.positions
        let settings = renderSettings(
            width: Int(drawableSize.width), height: Int(drawableSize.height))
        do {
            // Over the drawn particles only: a smoothing length is read by the vertex shader
            // and nothing reads the dark matter's.
            if smoothing == nil || smoothing?.buffer.length != drawnCount * 4 {
                smoothing = try SmoothingField(device: device, particleCount: drawnCount)
            }
            renderer = try Renderer(
                device: device, particles: seeded, settings: settings, externalPositions: bound)
            renderer?.setSmoothing(smoothing?.buffer)
            refreshSmoothing()
        } catch {
            failure = "\(error)"
            renderer = nil
        }
    }

    /// Steps the playback cursor and blends the two surrounding snapshots into the buffer the
    /// renderer draws from.
    private func advancePlayback() {
        guard let recording, let expander, let snapshots, let positions = playbackPositions,
            recording.count >= 2
        else { return }
        let last = Double(recording.count - 1)
        if isPlaying {
            playbackPosition += Double(playbackSpeed) / 60
            if playbackPosition >= last { playbackPosition -= last }
        }
        playbackPosition = min(max(playbackPosition, 0), last)

        let index = Int(playbackPosition)
        let blend = Float(playbackPosition - Double(index))
        let next = min(index + 1, recording.count - 1)
        // Tell the reader where the playhead is before asking for anything, so the snapshots
        // after this one are on their way while this frame is drawn.
        snapshots.prepare(from: index)
        guard let firstOffset = snapshots.fetch(index),
            let secondOffset = snapshots.fetch(next),
            let first = recording.frame(at: index), let second = recording.frame(at: next)
        else { return }
        expander.expand(
            first: first, at: firstOffset, second: second, at: secondOffset,
            from: snapshots.buffer, blend: blend, into: positions)
        elapsedMyr = Double(first.time) * Physics.megayearsPerTimeUnit
        playbackCenters = recording.centers(at: index)
    }

    /// Runs the exact model path a frame takes, but offscreen. Used by `--selftest` so the
    /// wiring can be checked without a window.
    func snapshot(steps: Int) -> [UInt8]? {
        // This path steps the solver itself, so it has to own it outright.
        stopLiveStepping()
        guard let renderer, let solver else { return nil }
        solver.step(count: steps)
        elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
        framesSinceSmoothing += 1
        if framesSinceSmoothing >= 20 {
            framesSinceSmoothing = 0
            refreshSmoothing()
        }
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: solver.centers, time: solver.time,
                strength: renderer.armPersistence))
        return renderer.render(camera: activeCamera)
    }

    func draw(in view: MTKView) {
        drawAttempts += 1
        // Asked not to draw. The view is taken out of the hierarchy too, but it outlives that
        // by a frame or two and the whole point is to stop feeding the GPU.
        guard showCanvasWhileRunning || mode == .playback else { return }
        let start = CACurrentMediaTime()
        // The real interval, so flight speed does not depend on how fast this machine draws.
        let seconds = Float(start - (lastDrawTime ?? start - 1.0 / 60))
        lastDrawTime = start
        // Ahead of everything that can decline to draw: a window that is briefly occluded
        // hands back no drawable, and a camera that stopped dead every time that happened
        // would be worse than one that keeps flying with nothing to show for a frame.
        flyOneFrame(view, seconds: seconds)
        // A take opened from a file has no solver behind it, and does not need one.
        guard let renderer, solver != nil || mode == .playback,
            let drawable = view.currentDrawable
        else { return }

        switch mode {
        case .running:
            // Advanced on the simulation queue; just show where it has got to.
            break
        case .playback:
            advancePlayback()
        }
        // Where the galaxies were on the frame being shown, so the spiral pattern is painted
        // about them rather than about wherever the run happened to end.
        let centers =
            mode == .playback && !playbackCenters.isEmpty
            ? playbackCenters : (solver?.centers ?? scene.galaxies.map(\.position))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: centers,
                time: Float(elapsedMyr / Physics.megayearsPerTimeUnit),
                strength: renderer.armPersistence))
        renderer.present(camera: activeCamera, drawable: drawable)
        frameMilliseconds = (CACurrentMediaTime() - start) * 1000
        framesDrawn += 1
    }
}
