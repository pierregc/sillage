import AVFoundation
import CoreGraphics
import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender
#if canImport(simd)
    import simd
#endif

/// Checkpoints of long runs (#240): a run stopped and resumed goes on as if it never stopped.
@Suite("Checkpoints")
struct CheckpointTests {
    private func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func selfGravitatingDisk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    private func disks(_ states: [DiskState]) -> [Float] {
        states.flatMap {
            [
                $0.axis.x, $0.axis.y, $0.axis.z, $0.coherence, $0.reference, $0.thickness,
                $0.thicknessReference, $0.disruption, $0.thinnest, $0.fullest, $0.layered, $0.torn,
            ]
        }
    }

    /// A black hole's pull to the bit (#274): `Archetype.blackHolePass` at 12,000, alone and with
    /// light tracers, stepped 50 times, and what a checkpoint keeps of the particles then,
    /// against its digest from before the solver's kernels were shared with CUDA. The hole's
    /// acceleration is all summed reactions, so a bit that moves in the pull shows here; no
    /// other reference of the check has a black hole. Metal's bits are a GPU's own: on a GPU
    /// with no digest here, the test prints the ones to add.
    @Test func aBlackHolePassKeepsItsBits() throws {
        let references = [
            "Apple M4 Max": [
                "fa59aca28531f27b132d401d44562f488bcb8bf7e6c153e1fa2bedbb522b0376",
                "36384d48f900e9af93403f8b7b08dd0e9e36451bd9540881662aaf445c591812",
            ]
        ]
        let folder = try temporary("hole")
        defer { try? FileManager.default.removeItem(at: folder) }
        let drawn = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 12_000)
        let massive = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 3_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
        let solvers = [
            try MetalBarnesHutSolver(scene: drawn),
            try MetalBarnesHutSolver(scene: massive, particles: split, tracers: tracers),
        ]
        var digests: [String] = []
        for (index, solver) in solvers.enumerated() {
            solver.step(count: 50)
            let file = folder.appendingPathComponent("particles-\(index).bin")
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try solver.writeParticles(to: handle)
            try handle.close()
            var hash = PortableSHA256()
            hash.update(data: try Data(contentsOf: file))
            digests.append(hash.hex())
        }
        let gpu = solvers[0].device.name
        guard let expected = references[gpu] else {
            print("aBlackHolePassKeepsItsBits: no digest for \(gpu) yet, its own are \(digests)")
            return
        }
        #expect(digests == expected, "\(gpu)")
    }

    /// Restored from its checkpoint, a run with tracers, star formation and a black hole goes
    /// on to the bit as the run that never stopped, though it samples nothing: its massive set
    /// comes back from the checkpoint and its tracers from their 32 bytes (#238).
    @Test func aSolverRestoredFromItsCheckpointGoesOnToTheBit() throws {
        let folder = try temporary("solver")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenes = [
            (selfGravitatingDisk(12_000), selfGravitatingDisk(3_000)),
            (
                Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 12_000),
                Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 3_000)
            ),
        ]
        var last: MetalBarnesHutSolver.State?
        for (index, (drawn, massive)) in scenes.enumerated() {
            let checkpoint = RunCheckpoint(directory: folder.appendingPathComponent("run-\(index)"))
            let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
            #expect(tracers > 0)
            try checkpoint.saveMassive(split.slice(tracers..<split.count))
            let straight = try MetalBarnesHutSolver(scene: massive, particles: split, tracers: tracers)
            straight.step(count: 25)
            last = straight.state
            let first = run(1, frame: 1, identity: identity([]), solver: straight.state)
            let saved = try checkpoint.save(first) { try straight.writeParticles(to: $0) }
            #expect(
                saved.bytes == straight.particleBytes
                    && saved.bytes == split.count * 32 + (split.count - tracers) * 4)
            straight.step(count: 25)

            // A new process: nothing sampled, the massive set and the state read back.
            let seeded = try checkpoint.massiveSet()
            let kept = split.slice(tracers..<split.count)
            #expect(seeded.positions == kept.positions && seeded.velocities == kept.velocities)
            #expect(seeded.mass == kept.mass && seeded.formation == kept.formation)
            #expect(seeded.galaxyIndex == kept.galaxyIndex && seeded.component == kept.component)
            #expect(seeded.luminosity == kept.luminosity && seeded.kernelScale == kept.kernelScale)
            #expect(seeded.birthRadius == kept.birthRadius && seeded.population == kept.population)
            #expect(seeded.visibleCount == kept.visibleCount)
            let resumed = try MetalBarnesHutSolver(
                scene: massive, massive: seeded,
                tracers: LightTracerStore(capacity: tracers + seeded.count, awaiting: tracers))
            let (stored, reading) = try #require(try checkpoint.load())
            try resumed.restore(stored.solver, from: reading)
            try reading.close()
            resumed.step(count: 25)
            let (a, b) = (straight.particles, resumed.particles)
            #expect(a.positions == b.positions, "\(drawn.name)")
            #expect(a.velocities == b.velocities, "\(drawn.name)")
            #expect(a.formation == b.formation, "\(drawn.name)")
            #expect(a.luminosity == b.luminosity && a.birthRadius == b.birthRadius, "\(drawn.name)")
            #expect(straight.time == resumed.time && straight.centers == resumed.centers)
            #expect(disks(straight.diskFrames) == disks(resumed.diskFrames))
        }
        // A state of another run is refused.
        let other = try MetalBarnesHutSolver(scene: selfGravitatingDisk(2_000))
        let reading = try FileHandle(
            forReadingFrom: folder.appendingPathComponent("run-0").appendingPathComponent("particles-1.bin"))
        let state = try #require(last)
        #expect(throws: MetalBarnesHutSolver.CheckpointError.self) { try other.restore(state, from: reading) }
    }

    private func identity(_ arguments: [String], step: Float = 0.021, look: String = "{}")
        -> RunCheckpoint.Identity
    {
        RunCheckpoint.Identity(
            arguments: arguments, scene: "{}", look: look, framing: "1 bytes, 0", particles: 8_000_000,
            massive: 2_000_000, timeStep: step, presets: ["4k"], code: "abc")
    }

    private func run(
        _ index: Int, frame: Int, identity: RunCheckpoint.Identity,
        solver: MetalBarnesHutSolver.State = MetalBarnesHutSolver.State(
            count: 4, tracers: 1, time: 0.5, stepsSinceTree: 0, stepsSinceFormation: 7,
            haloCenters: [SIMD3(1, 2, 3)], massCenters: [SIMD3(1, 2, 3.5)], galaxyMotion: [.zero],
            diskStates: [DiskState(axis: SIMD3(0, 0, 1))])
    ) -> RunCheckpoint.Run {
        RunCheckpoint.Run(
            identity: identity, index: index, frame: frame, settled: 100, elapsed: 60, resumes: 0,
            everyFrames: 10, everySteps: 500, solver: solver, videos: nil, keyFrames: [])
    }

    /// Each checkpoint is written aside and renamed into place, `current` last; the one before
    /// stays until then, and what a crash leaves half written is never read.
    @Test func aCheckpointReplacesThePreviousOnlyOnceItIsWhole() throws {
        let folder = try temporary("checkpoint")
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = RunCheckpoint(directory: folder.appendingPathComponent(".checkpoint"))
        #expect(try checkpoint.load() == nil)
        let me = identity(["--particles", "8000000", "--checkpoint-frames", "10", "--resume"])
        try checkpoint.saveMassive(ParticleSystem())
        try checkpoint.save(run(1, frame: 10, identity: me)) { try $0.write(contentsOf: Data([1, 2, 3])) }
        try checkpoint.save(run(2, frame: 20, identity: me)) { try $0.write(contentsOf: Data([4, 5, 6, 7])) }
        let names = try FileManager.default.contentsOfDirectory(atPath: checkpoint.directory.path).sorted()
        #expect(names == ["current", "massive.bin", "particles-2.bin", "state-2.json"])
        // A third cut short before its rename: the second is the one read.
        try Data([9]).write(to: checkpoint.directory.appendingPathComponent("particles-3.bin.partial"))
        let (stored, handle) = try #require(try checkpoint.load())
        #expect(stored.index == 2 && stored.frame == 20)
        #expect(try handle.readToEnd() == Data([4, 5, 6, 7]))
        #expect(stored.solver.diskStates[0].axis == SIMD3(0, 0, 1) && stored.solver.stepsSinceFormation == 7)
        // What runs is kept, not where a check writes or how often to checkpoint.
        #expect(stored.identity.arguments == ["--particles", "8000000"])
        // Without the massive set it was taken over, it is no checkpoint at all.
        try FileManager.default.removeItem(at: checkpoint.directory.appendingPathComponent("massive.bin"))
        #expect(try checkpoint.load() == nil && checkpoint.stored() == nil)
        checkpoint.clear()
        #expect(!FileManager.default.fileExists(atPath: checkpoint.directory.path))
    }

    /// `--resume` refuses a checkpoint of another run, a step changed by `--dt-scale` among
    /// them, and goes on across a rebuild of the same code.
    @Test func aCheckpointOfAnotherRunIsRefused() {
        let run = identity(["--particles", "8000000", "--dt", "0.021"])
        #expect(
            run.differences(from: identity(["--particles", "8000000", "--dt", "0.021", "--resume"])).isEmpty)
        var rebuilt = run
        rebuilt.code = "def"
        #expect(run.differences(from: rebuilt).isEmpty)
        let stepped = identity(["--particles", "8000000", "--dt", "0.0105"], step: 0.0105)
        #expect(run.differences(from: stepped).count == 2)
        #expect(run.differences(from: stepped)[0].contains("0.0105"))
        #expect(
            run.differences(from: identity(["--particles", "8000000", "--dt", "0.021"], look: "x")) == [
                "the look"
            ])
    }

    /// Two galaxies drifting apart over `frames` captured frames, written and read back.
    private func take(frames: Int = 12) throws -> RecordingFile.Loaded {
        let particles = 2000
        let scene = SceneConfig.merger(particleCount: particles)
        let recording = Recording(particleCount: particles, galaxyCount: 2, interval: 1)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 3)
        var start: [SIMD3<Float>] = []
        for index in 0..<particles {
            let position = SIMD3<Float>(
                generator.uniform() * 20 - 10, generator.uniform() * 20 - 10, generator.uniform() - 0.5)
            start.append(position)
            system.append(
                position: position, velocity: .zero, galaxy: UInt32(index % 2), radius: 1,
                population: generator.uniform(), luminosity: 1)
        }
        for frame in 0..<frames {
            let drift = Float(frame) * 0.4
            let positions = start.enumerated().map { index, position in
                position + SIMD3<Float>(index % 2 == 0 ? -drift : drift, 0, 0)
            }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame) * 0.1,
                    centers: [SIMD3(-drift - 5, 0, 0), SIMD3(drift + 5, 0, 0)])
            }
        }
        recording.finish()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-take-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        return try RecordingFile.read(from: url)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    /// Videos written in segments, cut at checkpoints: a drawing resumed from a checkpoint draws
    /// the frames after it as the one that never stopped, its grain and its camera caught up, and
    /// the segments join into one video of every frame, without encoding them again.
    @Test(arguments: [LookFile.CameraPlan.Mode.auto, .immersed])
    func videosResumedFromACheckpointJoinIntoTheSameFrames(_ mode: LookFile.CameraPlan.Mode) throws {
        let loaded = try take()
        var file = LookFile.standard
        file.camera.mode = mode
        file.camera.azimuthEnd = 1
        file.palette = loaded.scene.galaxies.map { GalaxyColours($0.color) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = try temporary("segments")
        defer { try? FileManager.default.removeItem(at: folder) }
        let preset = VideoPreset(name: "wide", width: 96, height: 54)
        let count = loaded.recording.particleCount
        let positions = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared))
        let expander = try SnapshotExpander(device: device, recording: loaded.recording)
        let stream = try #require(SnapshotStream(device: device, recording: loaded.recording))
        let smoothing = try SmoothingField(device: device, particleCount: count)
        let drawing = try Renderer(
            device: device, particles: loaded.particles,
            settings: file.renderSettings(width: 16, height: 16), externalPositions: positions)
        func videos(_ name: String, resume: RunVideos.Progress? = nil) throws -> RunVideos {
            try RunVideos(
                formats: [
                    try RunVideos.Format(
                        preset: preset, frames: 12, framesPerSecond: 10,
                        url: folder.appendingPathComponent("\(name)/wide.mp4"))
                ],
                look: file, framing: loaded, capturedRate: 10, drawing: drawing,
                smoothing: smoothing.buffer, segments: folder.appendingPathComponent("\(name)-segments"),
                resume: resume)
        }
        func draw(_ run: RunVideos, _ frames: Range<Int>, into stills: inout [Int: [UInt8]]) throws {
            for frame in frames {
                let blend = try #require(loaded.recording.blend(atCaptured: frame))
                #expect(expander.expand(blend, of: loaded.recording, through: stream, into: positions))
                smoothing.update(from: positions)
                var still: [UInt8] = []
                try run.draw(frame: frame, centres: loaded.recording.centers(at: blend)) { _, image in
                    still = bytes(image)
                }
                stills[frame] = still
            }
        }

        var straight: [Int: [UInt8]] = [:]
        let whole = try videos("straight")
        try draw(whole, 0..<5, into: &straight)
        try whole.cut()
        try draw(whole, 5..<12, into: &straight)
        _ = try whole.finish()

        // Stopped after the checkpoint at frame 5, with two frames of the next segment lost.
        var stopped: [Int: [UInt8]] = [:]
        let first = try videos("stopped")
        try draw(first, 0..<5, into: &stopped)
        try first.cut()
        let saved = first.state
        try draw(first, 5..<7, into: &stopped)
        let again = try videos("stopped", resume: saved)
        try draw(again, 5..<12, into: &stopped)
        let reports = try again.finish()
        #expect(reports[0].frames == 12)
        for frame in 0..<12 { #expect(stopped[frame] == straight[frame], "\(mode) frame \(frame)") }

        for name in ["straight", "stopped"] {
            let joined = SceneFolder.partial(folder.appendingPathComponent("\(name)/wide.mp4"))
            let asset = AVURLAsset(url: joined)
            let track = try #require(try awaitTrack(asset))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            #expect(reader.startReading())
            var decoded = 0
            while output.copyNextSampleBuffer() != nil { decoded += 1 }
            #expect(decoded == 12, "\(name)")
            let data = try Data(contentsOf: joined)
            #expect(data.range(of: Data("hvc1".utf8)) != nil && data.range(of: Data("hev1".utf8)) == nil)
        }
    }

    private func awaitTrack(_ asset: AVURLAsset) throws -> AVAssetTrack? {
        final class Box: @unchecked Sendable { var track: AVAssetTrack? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            box.track = tracks?.first
            done.signal()
        }
        done.wait()
        return box.track
    }

    /// Key frames on disk as they are taken: a run resumed keeps those taken before its
    /// checkpoint, drops one taken after it, and writes the same take as the run that never
    /// stopped.
    @Test func keyFramesTakenBeforeACheckpointSurviveIt() throws {
        let loaded = try take()
        let folder = try temporary("keyblocks")
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = [0, 4, 9].map { KeyFrame(frame: $0, role: .chosen, timeMyr: 0) }
        let count = loaded.recording.particleCount
        func offer(_ take: KeyFrameTake, _ frames: Range<Int>) throws {
            for frame in frames where take.wants(frame: frame) {
                let positions = loaded.recording.positions(at: frame)
                try positions.withUnsafeBufferPointer {
                    try take.offer(
                        frame: frame, positions: $0.baseAddress!, time: Float(frame) * 0.1,
                        centers: loaded.recording.centers(at: frame), disks: [])
                }
            }
        }
        let straight = try KeyFrameTake(
            keys: keys, particleCount: count, galaxyCount: 2, blocks: folder.appendingPathComponent("a"))
        try offer(straight, 0..<12)
        let first = try KeyFrameTake(
            keys: keys, particleCount: count, galaxyCount: 2, blocks: folder.appendingPathComponent("b"))
        try offer(first, 0..<6)
        // The checkpoint was at frame 3: frame 4's block is the lost interval's.
        let kept = Array(first.entries.prefix(1))
        let resumed = try KeyFrameTake(
            keys: keys, particleCount: count, galaxyCount: 2, blocks: folder.appendingPathComponent("b"),
            taken: kept)
        #expect(!resumed.wants(frame: 0) && resumed.wants(frame: 4))
        try offer(resumed, 3..<12)
        for (name, take) in [("a", straight), ("b", resumed)] {
            try take.write(
                scene: loaded.scene, particles: loaded.particles,
                to: folder.appendingPathComponent("\(name).sillage"),
                list: folder.appendingPathComponent("\(name).json"))
        }
        let a = try content(of: folder.appendingPathComponent("a.sillage"))
        #expect(a == (try content(of: folder.appendingPathComponent("b.sillage"))))
        let read = try RecordingFile.read(from: folder.appendingPathComponent("a.sillage"))
        #expect(read.recording.count == 3)
        // And as one held in memory writes it.
        let memory = try KeyFrameTake(keys: keys, particleCount: count, galaxyCount: 2)
        try offer(memory, 0..<12)
        try memory.write(
            scene: loaded.scene, particles: loaded.particles, to: folder.appendingPathComponent("c.sillage"),
            list: folder.appendingPathComponent("c.json"))
        #expect(a == (try content(of: folder.appendingPathComponent("c.sillage"))))
    }

    /// A take as its header reads and the bytes after it: the header's JSON keys come in no
    /// fixed order.
    private func content(of url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        let length = Int(data[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let header = try JSONSerialization.jsonObject(with: data[24..<(24 + length)])
        let sorted = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return [sorted, Data(data[(24 + length)...])]
    }
}
