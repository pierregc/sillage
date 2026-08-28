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

@MainActor
final class SimulationModel: ObservableObject {
    @Published var stage: Stage = .setup
    @Published var scene: SceneConfig
    /// Edited by the setup screen. Applied to `scene` only when the user starts the run.
    @Published var draft: SceneConfig
    @Published var camera = OrbitCamera()
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
    private(set) var framesDrawn = 0
    private(set) var drawAttempts = 0
    private weak var canvas: MTKView?

    /// Held so the verification mode can drive the view itself. MTKView pauses its display
    /// link whenever the window is occluded, which a window opened behind another app always
    /// is, and that would otherwise make the render path untestable from a script.
    func attach(canvas view: MTKView) { canvas = view }

    func drawOnce() { canvas?.draw() }
    @Published private(set) var failure: String?

    @Published private(set) var mode: ViewerMode = .running
    @Published private(set) var capturedFrames = 0
    @Published private(set) var capturedBytes = 0
    /// Where the capture stopped, once it has. The run keeps going either way.
    @Published private(set) var captureIsFull = false
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
    private var smoothing: SmoothingField?
    /// Smoothing lengths track density, which changes slowly, so they are refreshed every so
    /// many frames rather than every one: rebuilding the tree costs tens of milliseconds.
    private var framesSinceSmoothing = 0

    // The setup screen renders the draft scene as it stands, without ever stepping it, so the
    // effect of a parameter can be seen while it is being set rather than after a run.
    @Published private(set) var previewParticleCount = 0
    @Published var previewCamera = OrbitCamera()
    private var previewRenderer: Renderer?
    private var previewSmoothing: SmoothingField?
    private var previewPositions: MTLBuffer?
    private var previewSize = CGSize(width: 900, height: 900)
    var previewCanvasSize: CGSize { previewSize }
    var previewViewFrame: CGRect { previewCanvas?.frame ?? .zero }
    private weak var previewCanvas: MTKView?

    /// Particles the preview draws. Enough to judge a shape, few enough to resample on the
    /// release of a slider.
    static let previewBudget = 350_000
    private var playbackPositions: MTLBuffer?
    /// Identifies the current live stepping chain. Bumping it retires whatever is running.
    private var liveGeneration = 0
    /// Same idea for the sampling job, which a second launch can supersede mid-flight.
    private var preparation = 0
    private var reframeWhenReady = false
    private let simulationQueue = DispatchQueue(label: "dev.pierregc.sillage.simulation")

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
        // Self-gravity is the default now, and a live halo multiplies the simulated count,
        // so the starting scene is sized for it rather than for the tracer solver.
        var start = SceneConfig.merger(particleCount: 400_000)
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
    func rebuildPreview() {
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

        let particles = RestrictedSolver.sampleParticles(for: scene)
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

            var radii = particles.positions.map { simd_length($0) }
            radii.sort()
            previewCamera.frame(
                radius: radii[min(Int(Double(radii.count) * 0.98), radii.count - 1)] * 1.3)
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
        stage = .setup
        mode = .running
        recording = nil
        capturedFrames = 0
        capturedBytes = 0
        captureIsFull = false
        playbackPositions = nil
        expander = nil
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
            if let reel {
                // Capturing costs six bytes a particle a frame, so it stops at the budget
                // rather than at whatever point the machine runs out of memory. Two frames
                // always get through: playback interpolates between a pair, so a budget too
                // small for two would leave a run that can never be replayed at all.
                if reel.byteCount < budget || reel.count < 2 {
                    let positions = solver.positions.contents().bindMemory(
                        to: SIMD3<Float>.self, capacity: reel.particleCount)
                    reel.append(positions: positions, time: time)
                } else {
                    full = true
                }
                frames = reel.count
                bytes = reel.byteCount
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
                self.pumpLive(
                    generation: generation, solver: solver, steps: steps, budget: budget)
            }
        }
    }

    /// Starts a capture from wherever the solver has got to. Called on every restart, so a
    /// run is always its own recording.
    private func beginCapture() {
        guard let solver else { return }
        let reel = Recording(particleCount: particleCount)
        let positions = solver.positions.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: particleCount)
        reel.append(positions: positions, time: solver.time)
        recording = reel
        capturedFrames = reel.count
        capturedBytes = reel.byteCount
        captureIsFull = false
        playbackPosition = 0
    }

    /// Ends the capture and plays it back. The solver keeps its state, so the run can be
    /// picked up again where it stopped.
    func stopAndReplay() {
        guard canReplay, let reel = recording else { return }
        stopLiveStepping()
        do {
            expander = try SnapshotExpander(device: device, particleCount: reel.particleCount)
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
        guard mode == .playback else { return }
        mode = .running
        isPlaying = true
        rebuildRenderer()
        startLiveStepping()
    }

    /// Throws the capture away and starts a new one from where the run stands.
    func restartCapture() {
        stopLiveStepping()
        playbackPositions = nil
        expander = nil
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

        guard !waiting else {
            let sampled = RestrictedSolver.sampleParticles(for: scene)
            install(sampled, try? GPUSolverFactory.make(device: device, scene: scene, particles: sampled))
            return
        }
        simulationQueue.async { [weak self] in
            let sampled = RestrictedSolver.sampleParticles(for: scene)
            let built = try? GPUSolverFactory.make(device: device, scene: scene, particles: sampled)
            DispatchQueue.main.async {
                guard let self, self.preparation == generation else { return }
                self.install(sampled, built)
            }
        }
    }

    private func install(_ sampled: ParticleSystem, _ built: (any GPUSolver)?) {
        seeded = sampled
        particleCount = sampled.count
        solver = built
        if built == nil { failure = "Le solveur n'a pas pu être construit" }
        elapsedMyr = 0
        megayearsPerSecond = 0
        // A restart invalidates the capture along with the solver it came from.
        mode = .running
        playbackPositions = nil
        expander = nil
        isPreparing = false
        beginCapture()
        rebuildRenderer()
        if reframeWhenReady {
            reframeWhenReady = false
            frameCamera()
        }
        startLiveStepping()
    }

    func loadPreset(_ preset: SceneConfig) {
        draft = preset
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
        var radii = seeded.positions.map { simd_length($0) }
        guard !radii.isEmpty else { return }
        radii.sort()
        camera.frame(radius: radii[Int(Double(radii.count) * 0.98)] * 1.3)
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

    private func rebuildRenderer() {
        guard let solver else { return }
        let bound = mode == .playback ? playbackPositions : solver.positions
        let settings = RenderSettings(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
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
        do {
            if smoothing == nil || smoothing?.buffer.length != particleCount * 4 {
                smoothing = try SmoothingField(device: device, particleCount: particleCount)
            }
            renderer = try Renderer(
                device: device, particles: seeded, settings: settings, externalPositions: bound)
            renderer?.setSmoothing(smoothing?.buffer)
            if let bound { smoothing?.update(from: bound) }
        } catch {
            failure = "\(error)"
            renderer = nil
        }
    }

    /// Steps the playback cursor and blends the two surrounding snapshots into the buffer the
    /// renderer draws from.
    private func advancePlayback() {
        guard let recording, let expander, let positions = playbackPositions,
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
        let pair = recording.upload(pair: index, into: expander.stagingBuffer)
        expander.expand(first: pair.0, second: pair.1, blend: blend, into: positions)
        elapsedMyr = Double(pair.0.time) * Physics.megayearsPerTimeUnit
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
            if let bound = mode == .playback ? playbackPositions : solver.positions {
                smoothing?.update(from: bound)
            }
        }
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: solver.centers, time: solver.time,
                strength: renderer.armPersistence))
        return renderer.render(camera: camera.camera)
    }

    func draw(in view: MTKView) {
        drawAttempts += 1
        guard let renderer, let solver, let drawable = view.currentDrawable else { return }
        let start = CACurrentMediaTime()

        switch mode {
        case .running:
            // Advanced on the simulation queue; just show where it has got to.
            break
        case .playback:
            advancePlayback()
        }
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: solver.centers, time: solver.time,
                strength: renderer.armPersistence))
        renderer.present(camera: camera.camera, drawable: drawable)
        frameMilliseconds = (CACurrentMediaTime() - start) * 1000
        framesDrawn += 1
    }
}
