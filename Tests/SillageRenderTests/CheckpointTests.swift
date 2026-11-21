import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// Checkpoints of long runs (#240): a run stopped and resumed goes on as if it never stopped.
@Suite("Checkpoints", .serialized)
struct CheckpointTests {
    func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func selfGravitatingDisk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    func disks(_ states: [DiskState]) -> [Float] {
        states.flatMap {
            [
                $0.axis.x, $0.axis.y, $0.axis.z, $0.coherence, $0.reference, $0.thickness,
                $0.thicknessReference, $0.disruption, $0.thinnest, $0.fullest, $0.layered, $0.torn,
            ]
        }
    }

    func identity(_ arguments: [String], step: Float = 0.021, look: String = "{}")
        -> RunCheckpoint.Identity
    {
        RunCheckpoint.Identity(
            arguments: arguments, scene: "{}", look: look, framing: "1 bytes, 0", particles: 8_000_000,
            massive: 2_000_000, timeStep: step, presets: ["4k"], code: "abc")
    }

    func run(
        _ index: Int, frame: Int, identity: RunCheckpoint.Identity,
        solver: SolverState = SolverState(
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

    /// Two galaxies drifting apart over `frames` captured frames, written and read back.
    func take(frames: Int = 12) throws -> RecordingFile.Loaded {
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
    func content(of url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        let length = Int(data[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let header = try JSONSerialization.jsonObject(with: data[24..<(24 + length)])
        let sorted = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return [sorted, Data(data[(24 + length)...])]
    }
}
