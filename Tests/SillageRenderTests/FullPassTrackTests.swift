import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// The full pass along a time track (#310): frames skipped where the video runs fast, and drawn
/// between two steps from a copy drifted along the leapfrog's straight line where it runs slow.
/// Serialized: the runs share the solver's global settings and the GPU.
@Suite("Full pass along a time track", .serialized)
struct FullPassTrackTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repository.appendingPathComponent("Tests/Fixtures/engines")

    private func disk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    /// The drawn particles' positions in a buffer laid out `[tracers | massive visible]`.
    private func drawn(_ buffer: MTLBuffer, tracers: Int, visible: Int) -> [SIMD3<Float>] {
        let pointer = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: tracers + visible)
        return (0..<(tracers + visible)).map { SIMD3(pointer[$0].x, pointer[$0].y, pointer[$0].z) }
    }

    private func bits(_ values: [SIMD3<Float>]) -> [UInt32] {
        values.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
    }

    /// A copy drifted by a whole step is where the next step puts every drawn particle, to the
    /// bit, tracers included; drifted by part of one, it lies on the segment between the two.
    /// Drifting moves nothing of the run. With tracers and without, and with a black hole.
    @Test func aCopyDriftedByAWholeStepIsWhereTheNextStepPutsIt() throws {
        let hole = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 12_000)
        let massiveHole = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 3_000)
        for (drawnScene, massiveScene, traced) in [
            (disk(12_000), disk(3_000), true), (hole, massiveHole, true), (disk(3_000), disk(3_000), false),
        ] {
            let solver: MetalBarnesHutSolver
            if traced {
                let (split, tracers) = ParticleSystem.lightTracers(drawn: drawnScene, massive: massiveScene)
                solver = try MetalBarnesHutSolver(scene: massiveScene, particles: split, tracers: tracers)
            } else {
                solver = try MetalBarnesHutSolver(scene: massiveScene)
            }
            let tracers = solver.tracerCount
            let visible = solver.particles.visibleCount - tracers
            #expect(traced == (tracers > 0))
            solver.step(count: 6)
            let before = solver.particles
            let step = solver.scene.timeStep
            let whole = drawn(try solver.drawnDrift(by: step), tracers: tracers, visible: visible)
            let part = drawn(try solver.drawnDrift(by: step * 0.37), tracers: tracers, visible: visible)
            let still = solver.particles
            #expect(bits(still.positions) == bits(before.positions), "\(drawnScene.name)")
            #expect(bits(still.velocities) == bits(before.velocities), "\(drawnScene.name)")
            solver.step(count: 1)
            let after = Array(solver.particles.positions.prefix(tracers + visible))
            let start = Array(before.positions.prefix(tracers + visible))
            #expect(bits(whole) == bits(after), "\(drawnScene.name)")
            var furthest: Float = 0
            for index in start.indices {
                let line = start[index] + (after[index] - start[index]) * 0.37
                let scale = max(simd_length(start[index]), simd_length(after[index]), 1)
                furthest = max(furthest, simd_length(part[index] - line) / scale)
            }
            #expect(furthest < 1e-6, "\(drawnScene.name): \(furthest)")
            #expect(zip(part, start).contains { $0 != $1 })
        }
    }

    // MARK: - Whole full passes

    /// A scene folder explored and styled: scene-0031 of the engines' fixtures and a look.
    static func explored(mode: LookFile.CameraPlan.Mode = .director) throws -> SceneFolder {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent("track-\(UUID().uuidString)")
                .appendingPathComponent("2026-10-30-b").appendingPathComponent("scene-0031"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("scene/scene.json"), to: folder.scene)
        var clip = SceneFolder.Clip()
        clip.particles = 3_000
        clip.width = 256
        clip.height = 144
        clip.frames = 24
        clip.fps = 6
        clip.steps = 96
        clip.settle = 12
        try clip.encoded().write(to: folder.clip)
        var look = try LookFile.decoded(
            from: Data(contentsOf: fixtures.appendingPathComponent("frames/red-vs-cyan.look.json")))
        look.camera.mode = mode
        try look.encoded().write(to: folder.look)
        return folder
    }

    /// The folder after its massive pass, the Metal solver over the massive particles alone as
    /// `--massive-only` runs them: the massive take and `hires.json`.
    static func massivePass(frames: Int = 8) throws -> SceneFolder {
        let folder = try explored()
        let plan = try folder.hiresArguments(
            ["--particles", "3000", "--massive", "1500", "--frames", String(frames), "--pass", "massive"],
            maximumParticles: 1_000_000_000)
        let run = FullPassRun(arguments: plan.arguments, engine: MetalFullPassMaker())
        let scenes = try run.scenes()
        let split = try MetalBarnesHutSolver.lightTracers(drawn: scenes.drawn, massive: scenes.scene)
        let solver = try MetalBarnesHutSolver(scene: scenes.scene, massive: split.massive, tracers: nil)
        let visible = split.massive.visibleCount
        let take = Recording(
            particleCount: visible, galaxyCount: scenes.scene.galaxies.count,
            interval: Int(run.number("take-interval", 1)))
        solver.step(count: plan.record.settle)
        let perFrame = max(plan.record.steps / max(frames, 1), 1)
        for _ in 0..<frames {
            solver.step(count: perFrame)
            let positions = solver.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: visible)
            take.offer(
                positions: positions, time: solver.time, centers: solver.centers, disks: solver.diskFrames,
                budget: 0)
        }
        try RecordingFile.write(take, scene: scenes.scene, particles: solver.particles, to: folder.take)
        try plan.record.encoded().write(to: folder.hires)
        return folder
    }

    static func copy(_ folder: SceneFolder) throws -> SceneFolder {
        let other = folder.url.deletingLastPathComponent().appendingPathComponent(
            "scene-\(Int.random(in: 1000..<9999))")
        try FileManager.default.copyItem(at: folder.url, to: other)
        return SceneFolder(other)
    }

    /// The full pass in 4K and vertical a sixteenth of their size, through `UnencodedDrawing`:
    /// every frame of each preset, in the order drawn, also left in `kept`.
    @discardableResult
    static func fullPass(
        _ folder: SceneFolder, frames: Int = 8, options: [String] = [], kept: KeptFrames = KeptFrames(),
        stop: ((Int, Int) -> Bool)? = nil
    ) throws -> [String: [[UInt8]]] {
        let plan = try folder.hiresArguments(
            [
                "--particles", "3000", "--massive", "1500", "--frames", String(frames), "--pass", "full",
                "--export", "4k,vertical", "--draw-divisor", "16",
            ] + options, maximumParticles: 1_000_000_000)
        let run = FullPassRun(
            arguments: plan.arguments, engine: UnencodedFullPass(kept: kept), hires: (folder, plan.record))
        run.stop = stop
        try run.run()
        return kept.frames
    }

    /// A track that slows to 0.3 over the first captured frames, so that frames fall between
    /// two steps, then runs at 2.
    static func slowThenFast(_ folder: SceneFolder, speeds: [Double] = [0.3, 0.3, 0.3, 1, 2, 2, 2, 2]) throws
        -> (url: URL, file: TimeTrackFile)
    {
        let file = TimeTrackFile(ramp: 0, speeds: speeds)
        let url = folder.batch.deletingLastPathComponent().appendingPathComponent("slow-then-fast.time.json")
        try file.encoded().write(to: url)
        return (url, file)
    }

    /// Without a track and at 1x, the full pass draws the same frames, every one of them.
    @Test func atOneTheFullPassDrawsWhatItDrawsWithoutATrack() throws {
        let plain = try Self.massivePass()
        defer { try? FileManager.default.removeItem(at: plain.batch.deletingLastPathComponent()) }
        let once = try Self.copy(plain)
        let a = try Self.fullPass(plain, options: ["--checkpoint-every", "0"])
        let b = try Self.fullPass(once, options: ["--checkpoint-every", "0", "--speed", "1"])
        #expect(a["4k"]?.count == 8 && a["vertical"]?.count == 8 && a == b)
        #expect(plain.storedHires()?.full?.track == nil)
        #expect(once.storedHires()?.full?.track == TimeTrackFile(speed: 1))
        #expect(once.storedHires()?.full?.frames == 8)
        let beside = once.exports.appendingPathComponent("4k.time.json")
        #expect(try TimeTrackFile.decoded(from: Data(contentsOf: beside)) == TimeTrackFile(speed: 1))
        #expect(
            !FileManager.default.fileExists(atPath: plain.exports.appendingPathComponent("4k.time.json").path)
        )
    }

    /// Along a track the run skips frames where it runs fast and draws between two steps where it
    /// runs slow, its massive part still repeating the massive pass to the bit. Stopped after a
    /// checkpoint and resumed, it draws the same frames; resumed along another track, it refuses.
    @Test func aRunAlongATrackResumesToTheSameFramesAndRefusesAnotherTrack() throws {
        let straight = try Self.massivePass()
        defer { try? FileManager.default.removeItem(at: straight.batch.deletingLastPathComponent()) }
        let stopped = try Self.copy(straight)
        let (url, file) = try Self.slowThenFast(straight)
        let options = ["--checkpoint-frames", "3", "--checkpoint-steps", "5", "--speed", url.path]
        let a = try Self.fullPass(straight, options: options)

        let take = try RecordingFile.read(from: straight.take)
        let track = try file.track(megayears: TimeTrack.megayears(of: take.recording), capturedRate: 6)
        let wanted = FullPassRun.videoFrames(track: track, frames: 8, framesPerSecond: 6)
        let record = try #require(straight.storedHires())
        let full = try #require(record.full)
        #expect(wanted.count > 8 && full.frames == wanted.count && full.track == file)
        #expect(full.drift == 0 && full.checkedFrames >= 2)
        #expect(a["4k"]?.count == wanted.count && a["vertical"]?.count == wanted.count)
        // Some frames fell between two steps, and the fast end skipped captured frames.
        let perFrame = max(record.steps / max(record.frames, 1), 1)
        let places = wanted.map { FullPassRun.place(captured: $0.captured, stepsPerFrame: perFrame) }
        #expect(places.contains { $0.fraction > 0 })
        #expect(Set(places.filter { $0.step == perFrame && $0.fraction == 0 }.map(\.frame)).count < 8)
        #expect(Set(a["4k"] ?? []).count == wanted.count)

        let kept = KeptFrames()
        #expect(throws: FullPassRun.Failure.self) {
            try Self.fullPass(stopped, options: options, kept: kept) { frame, checkpoints in
                checkpoints >= 1 && frame == 4
            }
        }
        let before = kept.frames
        #expect(FileManager.default.fileExists(atPath: stopped.checkpoint.path))
        // The same path, another track: refused, the checkpoint left as it was.
        _ = try Self.slowThenFast(straight, speeds: [0.3, 0.3, 0.3, 1, 1, 2, 2, 2])
        do {
            try Self.fullPass(stopped, options: options + ["--resume"])
            Issue.record("a resume along another track ran")
        } catch let FullPassRun.Failure.otherRun(why) {
            #expect(why.contains("the time track"))
        }
        try file.encoded().write(to: url)
        let after = try Self.fullPass(stopped, options: options + ["--resume"])
        // The resumed run draws again from the start of the segment its checkpoint closed.
        for preset in ["4k", "vertical"] {
            let whole = try #require(a[preset])
            let first = try #require(before[preset])
            let rest = try #require(after[preset])
            #expect(!rest.isEmpty && rest.count < whole.count && first.count + rest.count > whole.count)
            #expect(Array(whole.prefix(first.count)) == first, "\(preset)")
            #expect(Array(whole.suffix(rest.count)) == rest, "\(preset)")
        }
        #expect(stopped.storedHires()?.full?.resumes == 1)
    }
}

/// Frames drawn, by preset, in the order drawn.
final class KeptFrames {
    var frames: [String: [[UInt8]]] = [:]
}

/// A video drawn as a run draws it and read back as RGBA, never encoded: tests that open
/// VideoToolbox sessions side by side can leave `VideoWriter.finish()` waiting for good, every
/// thread of the pool in it, so these stay off the encoder. Where the video would be, an empty
/// file.
final class UnencodedDrawing: RunVideoDrawing {
    let renderer: Renderer
    let name: String
    let kept: KeptFrames

    init(renderer: Renderer, name: String, kept: KeptFrames) {
        self.renderer = renderer
        self.name = name
        self.kept = kept
    }

    var styling: any FramePreparing { renderer }
    func begin(_ url: URL) throws { FileManager.default.createFile(atPath: url.path, contents: Data()) }
    func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
        kept.frames[name, default: []].append(renderer.render(camera: camera))
    }
    func end() throws {}
}

/// The Metal engine of a full pass, its presets drawn through `UnencodedDrawing`.
final class UnencodedFullPass: FullPassEngineMaker {
    let kept: KeptFrames
    init(kept: KeptFrames = KeptFrames()) { self.kept = kept }
    var engine: String { "metal" }
    func refuseUnchecked() throws {}
    func make(_ start: FullPassRun.Start) throws -> any FullPassEngine {
        Engine(base: try MetalFullPassEngine(start), kept: kept)
    }

    final class Engine: FullPassEngine {
        let base: MetalFullPassEngine
        let kept: KeptFrames

        init(base: MetalFullPassEngine, kept: KeptFrames) {
            self.base = base
            self.kept = kept
        }

        var solver: any Solver { base.solver }
        var massive: ParticleSystem { base.massive }
        var tracerCount: Int { base.tracerCount }
        var diskFrames: [DiskState] { base.diskFrames }
        var device: String { base.device }
        func refreshSmoothing() throws { try base.refreshSmoothing() }
        func drawDrifted(by interval: Float?) throws { try base.drawDrifted(by: interval) }
        func drawing(
            for format: RunVideos.Format, look: LookFile, exposure: Float, drawn: Int, framesPerSecond: Int,
            metadata: VideoMetadata?
        ) throws -> any RunVideoDrawing {
            let made = try base.drawing(
                for: format, look: look, exposure: exposure, drawn: drawn, framesPerSecond: framesPerSecond,
                metadata: metadata)
            guard let metal = made as? MetalRunVideoDrawing else { throw RenderError.noDevice }
            return UnencodedDrawing(renderer: metal.renderer, name: format.preset.name, kept: kept)
        }
        func join(
            _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
        ) throws {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) throws {
            try base.withPositions(body)
        }
        func drawnAttributes() throws -> ParticleSystem { try base.drawnAttributes() }
        var state: SolverState { base.state }
        func writeParticles(to handle: FileHandle) throws { try base.writeParticles(to: handle) }
        func restore(_ state: SolverState, from handle: FileHandle) throws {
            try base.restore(state, from: handle)
        }
        func takeProfile() -> StepProfile? { base.takeProfile() }
        func check() throws { try base.check() }
        var peakMemory: (host: Int?, device: Int?) { base.peakMemory }
    }
}
