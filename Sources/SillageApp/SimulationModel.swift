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
/// A cancellation flag the recording queue can read without hopping back to the main actor.
/// Asking the main queue synchronously from a worker is how a background job deadlocks.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

enum ViewerMode {
    case live
    case recording
    case playback
}

@MainActor
final class SimulationModel: ObservableObject {
    @Published var stage: Stage = .setup
    @Published var scene: SceneConfig
    /// Edited by the setup screen. Applied to `scene` only when the user starts the run.
    @Published var draft: SceneConfig
    @Published var camera = OrbitCamera()
    @Published var stepsPerFrame = 4
    @Published private(set) var particleCount = 0
    @Published private(set) var elapsedMyr = 0.0
    @Published private(set) var frameMilliseconds = 0.0
    private(set) var framesDrawn = 0
    private(set) var drawAttempts = 0
    private weak var canvas: MTKView?

    /// Held so the verification mode can drive the view itself. MTKView pauses its display
    /// link whenever the window is occluded, which a window opened behind another app always
    /// is, and that would otherwise make the render path untestable from a script.
    func attach(canvas view: MTKView) { canvas = view }

    func drawOnce() { canvas?.draw() }
    @Published private(set) var failure: String?

    @Published private(set) var mode: ViewerMode = .live
    @Published private(set) var recordedFrames = 0
    @Published var targetFrames = 300
    @Published var playbackSpeed: Float = 30
    @Published var playbackPosition: Double = 0
    @Published var isPlaying = true
    private(set) var recording: Recording?
    private var expander: SnapshotExpander?
    private var smoothing: SmoothingField?
    /// Smoothing lengths track density, which changes slowly, so they are refreshed every so
    /// many frames rather than every one: rebuilding the tree costs tens of milliseconds.
    private var framesSinceSmoothing = 0
    private var playbackPositions: MTLBuffer?
    private let cancelRecording = CancellationFlag()
    private let simulationQueue = DispatchQueue(label: "dev.pierregc.sillage.simulation")

    var recordedSeconds: Double { Double(recordedFrames) / 60 }
    var recordingMegabytes: Double {
        Double(Recording.estimatedBytes(particleCount: particleCount, frames: recordedFrames))
            / 1_048_576
    }
    var projectedGigabytes: Double {
        Double(Recording.estimatedBytes(particleCount: draft.totalParticleCount, frames: targetFrames))
            / 1_073_741_824
    }

    @Published var brightness: Float = 0.15 { didSet { renderer?.setBrightness(brightness) } }
    @Published var exposure: Float = 1.0 { didSet { renderer?.setExposure(exposure) } }
    @Published var stretch: Float = 18 { didSet { renderer?.setStretch(stretch) } }
    @Published var saturation: Float = 1.8 { didSet { renderer?.setSaturation(saturation) } }
    @Published var bloom: Float = 0.45 { didSet { renderer?.setBloomIntensity(bloom) } }
    @Published var pointSize: Float = 1.7 { didSet { renderer?.setPointSize(pointSize) } }
    @Published var dustStrength: Float = 0.16 { didSet { renderer?.setDustStrength(dustStrength) } }
    @Published var spikeIntensity: Float = 0.38 {
        didSet { renderer?.setSpikeIntensity(spikeIntensity) }
    }
    @Published var skyLevel: Float = 0.0018 { didSet { renderer?.setSkyLevel(skyLevel) } }
    @Published var noiseLevel: Float = 0.0016 { didSet { renderer?.setNoiseLevel(noiseLevel) } }
    @Published var smoothingScale: Float = 1.0 {
        didSet {
            smoothing?.scale = smoothingScale
            framesSinceSmoothing = 99
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
        let start = SceneConfig.merger(particleCount: 3_000_000)
        self.scene = start
        self.draft = start
    }

    /// Commits the setup screen's draft and moves to the live view. Nothing heavy is built
    /// until this runs, so the setup screen opens instantly.
    func start() {
        scene = draft
        restart()
        frameCamera()
        stage = .running
    }

    func returnToSetup() {
        cancelRecording.set()
        stage = .setup
        mode = .live
        recording = nil
        playbackPositions = nil
        isPlaying = false
    }

    /// Runs the solver on its own queue, capturing one snapshot per requested frame. The
    /// canvas keeps drawing the live buffer, so the encounter can be watched as it is built.
    func startRecording() {
        guard let solver, mode != .recording else { return }
        cancelRecording.reset()
        mode = .recording
        recordedFrames = 0
        isPlaying = true

        let target = max(targetFrames, 2)
        let steps = max(stepsPerFrame, 1)
        let count = particleCount
        let capture = solver
        let cancelled = cancelRecording
        simulationQueue.async { [weak self] in
            let reel = Recording(particleCount: count)
            let positions = capture.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: count)
            reel.append(positions: positions, time: capture.time)
            for _ in 1..<target {
                if cancelled.isSet { break }
                capture.step(count: steps)
                reel.append(positions: positions, time: capture.time)
                DispatchQueue.main.async { self?.recordedFrames = reel.count }
            }
            DispatchQueue.main.async { self?.finishRecording(reel) }
        }
    }

    func stopRecording() { cancelRecording.set() }

    private func finishRecording(_ reel: Recording) {
        guard reel.count >= 2 else {
            mode = .live
            return
        }
        recording = reel
        recordedFrames = reel.count
        playbackPosition = 0
        do {
            expander = try SnapshotExpander(device: device, particleCount: reel.particleCount)
            playbackPositions = device.makeBuffer(
                length: reel.particleCount * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared)
            mode = .playback
            rebuildRenderer()
        } catch {
            failure = "\(error)"
            mode = .live
        }
    }

    func discardRecording() {
        recording = nil
        playbackPositions = nil
        expander = nil
        mode = .live
        rebuildRenderer()
    }

    var gpuName: String { device.name }

    /// Rebuilds the whole simulation. Sampling several million particles takes a moment, so
    /// the panel only calls this when a control is released, never mid-drag.
    func restart() {
        failure = nil
        seeded = RestrictedSolver.sampleParticles(for: scene)
        particleCount = seeded.count
        do {
            solver = try GPUSolverFactory.make(device: device, scene: scene, particles: seeded)
        } catch {
            failure = "\(error)"
            solver = nil
        }
        elapsedMyr = 0
        rebuildRenderer()
    }

    func loadPreset(_ preset: SceneConfig) {
        draft = preset
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
        let millions = Double(draft.totalParticleCount) / 1_000_000
        let perStep = draft.solver == .barnesHut ? 110 * pow(millions, 1.15) : 0.18 * millions
        return perStep * Double(stepsPerFrame)
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
            pointSize: pointSize,
            exposure: exposure,
            brightness: brightness,
            dustStrength: dustStrength,
            bloomIntensity: bloom,
            stretch: stretch,
            saturation: saturation,
            spikeIntensity: spikeIntensity,
            skyLevel: skyLevel,
            noiseLevel: noiseLevel)
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
        guard let renderer, let solver else { return nil }
        solver.step(count: steps)
        elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
        framesSinceSmoothing += 1
        if framesSinceSmoothing >= 20, mode != .recording {
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
        case .live:
            if isPlaying {
                solver.step(count: stepsPerFrame)
                elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
            }
        case .recording:
            // The solver is being advanced on its own queue; just show where it has got to.
            elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
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
