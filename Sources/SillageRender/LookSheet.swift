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
    private var cameras: [String: [Camera]] = [:]
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
    public var capturedFrames: Int { take.recording.capturedFrames }

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
        try cells(
            looks: looks, frames: frames, width: width, height: height, cellWidth: cellWidth,
            cellHeight: cellHeight, framesPerSecond: framesPerSecond
        ).map { $0.map(\.pixels) }
    }

    /// A drawn cell, and with `owners` asked which galaxy each of its pixels shows.
    public struct Cell: Sendable {
        public var pixels: [UInt8]
        /// Galaxy plus one per pixel, 0 where none or several share it.
        public var owners: [UInt8]?
    }

    /// As `render`, with each cell's owners when `owners` is set.
    public func cells(
        looks: [LookFile], frames: [Int], width: Int, height: Int, cellWidth: Int,
        cellHeight: Int, framesPerSecond: Int, owners: Bool = false
    ) throws -> [[Cell]] {
        var cells = [[Cell]](repeating: [], count: looks.count)
        try draw(
            looks: looks, frames: frames, width: width, height: height, cellWidth: cellWidth,
            cellHeight: cellHeight, framesPerSecond: framesPerSecond, owners: owners
        ) { row, _, cell in cells[row].append(cell) }
        return cells
    }

    /// Hands each cell to `each` with its look and frame indices as it is drawn, frame by
    /// frame, so many looks need not all be held at once.
    public func draw(
        looks: [LookFile], frames: [Int], width: Int, height: Int, cellWidth: Int,
        cellHeight: Int, framesPerSecond: Int, owners: Bool = false,
        each: (_ look: Int, _ frame: Int, _ cell: Cell) throws -> Void
    ) throws {
        let recording = take.recording
        let shots = looks.map { self.shots(of: $0, at: frames, fps: framesPerSecond) }
        for (column, frame) in frames.enumerated() {
            guard let blend = recording.blend(atCaptured: frame) else { continue }
            try expand(blend)
            smoothing.update(from: positions)
            var owned: [String: [UInt8]] = [:]
            for (row, file) in looks.enumerated() {
                let renderer = try renderer(for: file, width: width, height: height)
                let shot = shots[row][column]
                renderer.prepare(file, shot: shot, take: take, at: blend)
                var cell = Cell(
                    pixels: LookGrid.scaled(
                        renderer.render(camera: shot.camera), from: (width, height),
                        to: (cellWidth, cellHeight)))
                if owners {
                    let c = shot.camera
                    let key = "\(c.eye) \(c.target) \(c.up) \(c.fieldOfView)"
                    if owned[key] == nil {
                        owned[key] = self.owners(
                            camera: c, aspectRatio: Float(width) / Float(height),
                            width: cellWidth, height: cellHeight)
                    }
                    cell.owners = owned[key]
                }
                try each(row, column, cell)
            }
        }
    }

    /// Which galaxy each pixel of a `width` by `height` image shows, from a sample of the
    /// visible particles at the frame last expanded: the galaxy holding three quarters of the
    /// pixel's particles, plus one, else 0.
    func owners(camera: Camera, aspectRatio: Float, width: Int, height: Int) -> [UInt8] {
        let particles = take.particles
        let galaxies = Int(particles.galaxyIndex.max() ?? 0) + 1
        guard galaxies < 255 else { return [UInt8](repeating: 0, count: width * height) }
        let matrix = camera.viewProjection(aspectRatio: aspectRatio)
        let count = particles.count
        let step = max(count / 400_000, 1)
        let points = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        var counts = [UInt32](repeating: 0, count: width * height * galaxies)
        for i in stride(from: 0, to: count, by: step) {
            guard ParticleComponent(rawValue: particles.component[i])?.isVisible ?? true else {
                continue
            }
            let clip = matrix * SIMD4(points[i], 1)
            guard clip.w > 0 else { continue }
            let x = Int((clip.x / clip.w * 0.5 + 0.5) * Float(width))
            let y = Int((0.5 - clip.y / clip.w * 0.5) * Float(height))
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            counts[(y * width + x) * galaxies + Int(particles.galaxyIndex[i])] += 1
        }
        return (0..<(width * height)).map { pixel in
            let slice = counts[(pixel * galaxies)..<((pixel + 1) * galaxies)]
            let total = slice.reduce(0, +)
            guard total > 0, let top = slice.indices.max(by: { slice[$0] < slice[$1] }),
                slice[top] * 4 >= total * 3
            else { return 0 }
            return UInt8(top - pixel * galaxies + 1)
        }
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

    /// Replayed once per camera: outside the director's modes the shot's look is the file's
    /// own and only the camera plan and the field of view place the camera.
    private func shots(of file: LookFile, at frames: [Int], fps: Int) -> [ShotReplay.Shot] {
        let directed = file.camera.mode == .director || file.camera.mode == .immersed
        let key = "\(file.camera) \(file.look.fieldOfView) \(frames) \(fps)"
        if !directed, let cameras = cameras[key] { return cameras.map { ($0, file.look) } }
        let replay = ShotReplay(
            file: file, take: take, capturedFrames: capturedFrames, framesPerSecond: fps)
        var shots: [Int: ShotReplay.Shot] = [:]
        for frame in Set(frames).sorted() { shots[frame] = replay.shot(atCaptured: frame) }
        let out = frames.map { shots[$0]! }
        if !directed { cameras[key] = out.map(\.camera) }
        return out
    }
}
