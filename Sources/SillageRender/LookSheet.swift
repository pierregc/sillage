import Foundation
import Metal
import SillageCore
import simd

/// Draws a few frames of a take with several looks, headless and with no solver: what the
/// look stage puts in its grid.
public final class LookSheet {
    public let take: RecordingFile.Loaded
    private let device: MTLDevice
    private let expander: SnapshotExpander
    private let snapshots: MTLBuffer
    private let positions: MTLBuffer
    private let smoothing: SmoothingField
    private var renderers: [(file: LookFile, renderer: Renderer)] = []

    public init(take: RecordingFile.Loaded, device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.take = take
        self.device = device
        let count = take.recording.particleCount
        let snapshotBytes = count * 3 * MemoryLayout<UInt16>.size
        guard
            let snapshots = device.makeBuffer(
                length: 4 * snapshotBytes, options: .storageModeShared),
            let positions = device.makeBuffer(
                length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        else { throw RenderError.noDevice }
        self.snapshots = snapshots
        self.positions = positions
        expander = try SnapshotExpander(device: device, particleCount: count)
        smoothing = try SmoothingField(device: device, particleCount: count)
    }

    /// Frames the run captured, of which the take keeps one in `interval`.
    public var capturedFrames: Int {
        let recording = take.recording
        return max(recording.capturedCount, (recording.count - 1) * recording.interval + 1)
    }

    /// Whether a captured frame is one the take kept, or is drawn through the cubic between
    /// the kept ones around it.
    public func isStored(frame: Int) -> Bool {
        guard let blend = take.recording.blend(atCaptured: frame) else { return false }
        return blend.fraction == 0 || blend.fraction == 1
    }

    public func timeMyr(atCaptured frame: Int) -> Double {
        Double(take.recording.blend(atCaptured: frame)?.time ?? 0) * Physics.megayearsPerTimeUnit
    }

    /// `cells[look][frame]`, each `cellWidth` by `cellHeight` RGBA. Drawn at the clip's own
    /// `width` and `height` and scaled down, since stars, spikes and kernels are sized in
    /// pixels and a small render would show them three times too large. Every camera is
    /// replayed from the first frame up to each key frame, so a still is framed as the full
    /// render frames it.
    public func render(
        looks: [LookFile], frames: [Int], width: Int, height: Int, cellWidth: Int,
        cellHeight: Int, framesPerSecond: Int
    ) throws -> [[[UInt8]]] {
        let recording = take.recording
        let last = frames.max() ?? 0
        let centres = (0...last).map { frame in
            recording.blend(atCaptured: frame).map { recording.centers(at: $0) } ?? []
        }
        let shots = looks.map { self.shots(of: $0, at: frames, centres: centres, fps: framesPerSecond) }

        var cells = [[[UInt8]]](repeating: [], count: looks.count)
        for (column, frame) in frames.enumerated() {
            guard let blend = recording.blend(atCaptured: frame) else { continue }
            try expand(blend)
            smoothing.update(from: positions)
            let disks = recording.disks(at: blend)
            for (row, file) in looks.enumerated() {
                let renderer = try renderer(for: file, width: width, height: height)
                let shot = shots[row][column]
                renderer.apply(shot.look)
                renderer.time = blend.time
                var scene = take.scene
                file.paint(&scene)
                renderer.setDiskFrames(
                    DiskFrame.make(
                        scene: scene, centers: centres[frame], time: blend.time,
                        strength: LookFile.diskStrength(file.armStrength, shot.look),
                        disks: disks))
                cells[row].append(
                    LookGrid.scaled(
                        renderer.render(camera: shot.camera), from: (width, height),
                        to: (cellWidth, cellHeight)))
            }
        }
        return cells
    }

    private func expand(_ blend: Recording.Blend) throws {
        let recording = take.recording
        let stride = recording.particleCount * 3 * MemoryLayout<UInt16>.size
        let keys = (0..<4).map { Int(blend.keys[$0]) }
        let frames = keys.enumerated().compactMap { slot, key in
            recording.copy(frame: key, into: snapshots, atByteOffset: slot * stride)
        }
        guard frames.count == 4 else { throw RecordingFile.Failure.truncated }
        expander.expand(
            frames: frames, at: (0..<4).map { $0 * stride }, blend: blend, from: snapshots,
            into: positions)
    }

    private func renderer(for file: LookFile, width: Int, height: Int) throws -> Renderer {
        if let built = renderers.first(where: { !file.rebuildsRenderer(from: $0.file) }) {
            return built.renderer
        }
        let renderer = try Renderer(
            device: device, particles: take.particles,
            settings: file.renderSettings(width: width, height: height),
            externalPositions: positions)
        renderer.setSmoothing(smoothing.buffer)
        renderers.append((file, renderer))
        return renderer
    }

    /// The camera and the look on each key frame, the camera moved through every frame
    /// before it: the auto camera eases and the director cuts, so neither can be placed on a
    /// frame without the ones that led there.
    private func shots(
        of file: LookFile, at frames: [Int], centres: [[SIMD3<Float>]], fps: Int
    ) -> [(camera: Camera, look: RenderLook)] {
        let plan = file.camera
        let scene = take.scene
        let span = Float(max(capturedFrames - 1, 1))
        let radius = plan.framedRadius(positions: take.particles.positions)
        let reach = scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) }
        let directed = plan.mode == .director || plan.mode == .immersed
        let director = directed ? Cinematographer(seed: scene.seed) : nil
        director?.beginScene(seed: scene.seed, base: file.look, immersed: plan.mode == .immersed)
        var auto = AutoCamera()

        var shots: [Int: (camera: Camera, look: RenderLook)] = [:]
        let wanted = Set(frames)
        for frame in 0...(frames.max() ?? 0) {
            let around = centres[frame]
            var shot: (camera: Camera, look: RenderLook)
            if let director {
                director.advance(seconds: 1 / Double(fps), of: Subject(centres: around, radius: radius))
                shot = (director.camera, director.look)
            } else {
                var framed = (center: SIMD3<Float>.zero, radius: radius)
                if plan.mode == .auto {
                    framed = auto.frame(centres: around, margins: reach)
                    framed.radius /= plan.zoom
                }
                shot = (
                    plan.camera(
                        progress: Float(frame) / span, radius: framed.radius,
                        center: framed.center, fieldOfView: file.look.fieldOfView),
                    file.look
                )
            }
            if wanted.contains(frame) { shots[frame] = shot }
        }
        return frames.map { shots[$0]! }
    }
}
