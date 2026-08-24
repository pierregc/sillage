import Combine
import Metal
import MetalKit
import SillageCore
import SillageRender
import simd

@MainActor
final class SimulationModel: ObservableObject {
    @Published var scene: SceneConfig
    @Published var camera = OrbitCamera()
    @Published var isPlaying = true
    @Published var stepsPerFrame = 4
    @Published private(set) var particleCount = 0
    @Published private(set) var elapsedMyr = 0.0
    @Published private(set) var frameMilliseconds = 0.0
    private(set) var framesDrawn = 0
    @Published private(set) var failure: String?

    @Published var brightness: Float = 0.055 { didSet { renderer?.setBrightness(brightness) } }
    @Published var exposure: Float = 1.0 { didSet { renderer?.setExposure(exposure) } }
    @Published var stretch: Float = 18 { didSet { renderer?.setStretch(stretch) } }
    @Published var saturation: Float = 1.8 { didSet { renderer?.setSaturation(saturation) } }
    @Published var bloom: Float = 0.45 { didSet { renderer?.setBloomIntensity(bloom) } }
    @Published var pointSize: Float = 1.7 { didSet { renderer?.setPointSize(pointSize) } }
    @Published var supersample = 1 { didSet { rebuildRenderer() } }

    let device: MTLDevice
    private(set) var solver: MetalSolver?
    private(set) var renderer: Renderer?
    private var seeded = ParticleSystem()
    private var drawableSize = CGSize(width: 1280, height: 720)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.scene = .merger(particleCount: 3_000_000)
        restart()
    }

    var gpuName: String { device.name }

    /// Rebuilds the whole simulation. Sampling several million particles takes a moment, so
    /// the panel only calls this when a control is released, never mid-drag.
    func restart() {
        failure = nil
        seeded = RestrictedSolver.sampleParticles(for: scene)
        particleCount = seeded.count
        do {
            solver = try MetalSolver(device: device, scene: scene, particles: seeded)
        } catch {
            failure = "\(error)"
            solver = nil
        }
        elapsedMyr = 0
        rebuildRenderer()
    }

    /// Scales every galaxy's share so the preset's own ratio between galaxies is preserved.
    func setTotalParticles(_ total: Int) {
        let current = scene.totalParticleCount
        guard current > 0, total > 0 else { return }
        let ratio = Double(total) / Double(current)
        for index in scene.galaxies.indices {
            scene.galaxies[index].particleCount =
                max(Int(Double(scene.galaxies[index].particleCount) * ratio), 1)
        }
        scene.galaxies[0].particleCount += total - scene.totalParticleCount
        restart()
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
        let settings = RenderSettings(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            supersample: supersample,
            pointSize: pointSize,
            exposure: exposure,
            brightness: brightness,
            colorRadius: max(scene.galaxies.map { $0.diskScaleLength * $0.diskTruncation }.max() ?? 14, 1),
            bloomIntensity: bloom,
            stretch: stretch,
            saturation: saturation)
        do {
            renderer = try Renderer(
                device: device, particles: seeded, settings: settings,
                externalPositions: solver.positions)
        } catch {
            failure = "\(error)"
            renderer = nil
        }
    }

    /// Runs the exact model path a frame takes, but offscreen. Used by `--selftest` so the
    /// wiring can be checked without a window.
    func snapshot(steps: Int) -> [UInt8]? {
        guard let renderer, let solver else { return nil }
        solver.step(count: steps)
        elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
        return renderer.render(camera: camera.camera)
    }

    func draw(in view: MTKView) {
        guard let renderer, let solver, let drawable = view.currentDrawable else { return }
        let start = CACurrentMediaTime()
        if isPlaying {
            solver.step(count: stepsPerFrame)
            elapsedMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
        }
        renderer.present(camera: camera.camera, drawable: drawable)
        frameMilliseconds = (CACurrentMediaTime() - start) * 1000
        framesDrawn += 1
    }
}
