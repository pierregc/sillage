import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Recording")
struct RecordingTests {
    private func captured(frames: Int) throws -> (
        Recording, [[SIMD3<Float>]], Int
    ) {
        let scene = SceneConfig.merger(particleCount: 20_000)
        let seeded = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalSolver(scene: scene, particles: seeded)
        let count = seeded.count
        let recording = Recording(particleCount: count)
        let pointer = solver.positions.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: count)

        var originals: [[SIMD3<Float>]] = []
        for index in 0..<frames {
            recording.append(positions: pointer, time: solver.time)
            originals.append(Array(UnsafeBufferPointer(start: pointer, count: count)))
            if index < frames - 1 { solver.step(count: 60) }
        }
        return (recording, originals, count)
    }

    /// A capture that runs past its memory budget keeps every frame, on disk.
    ///
    /// It used to throw away every other one and capture half as often from then on, which
    /// keeps the duration and loses the run: ten thousand megayears would come back at a
    /// cadence coarse enough that nothing between two snapshots ever happened. The budget
    /// bounds memory now, and nothing bounds the take but the volume.
    @Test func spilledFramesComeBackUnchanged() throws {
        let count = 4_000
        let recording = Recording(particleCount: count)
        var frames: [[SIMD3<Float>]] = []
        var generator = SeededGenerator(seed: 41)
        // Small enough that the first few frames spend it, so most of this take is spilled.
        let budget = count * 6 * 3

        for index in 0..<40 {
            var positions = [SIMD3<Float>](repeating: .zero, count: count)
            for slot in 0..<count {
                positions[slot] =
                    SIMD3<Float>(
                        generator.normal(), generator.normal(), generator.normal()) * 20
            }
            frames.append(positions)
            positions.withUnsafeBufferPointer {
                recording.offer(
                    positions: $0.baseAddress!, time: Float(index) * 0.25, centers: [],
                    budget: budget)
            }
        }

        #expect(recording.spillFailure == nil)
        #expect(recording.isSpilling)
        // Every frame, in order, at the cadence it was taken at.
        #expect(recording.count == 40)
        for (index, frame) in recording.frames.enumerated() {
            #expect(abs(frame.time - Float(index) * 0.25) < 1e-5)
        }
        // The budget bounded memory — to within the one frame that trips it, which lands
        // where the take still had room — and the rest went to the file, whole frames only.
        let perFrame = count * 6
        let records = 40 * MemoryLayout<Recording.Frame>.stride
        #expect(recording.memoryByteCount <= budget + perFrame + records)
        #expect(recording.diskByteCount > 0)
        #expect(recording.diskByteCount % perFrame == 0)
        // Nothing fell between the two: every frame is in one place or the other.
        #expect(recording.memoryByteCount - records + recording.diskByteCount == 40 * perFrame)

        // The positions come back, quantisation aside, from wherever they ended up.
        for index in [0, 1, 7, 25, 39] {
            let decoded = recording.positions(at: index)
            #expect(decoded.count == count)
            let box = try #require(recording.frame(at: index))
            let step = box.extent / 65535
            var worst: Float = 0
            for slot in 0..<count {
                worst = max(worst, simd_reduce_max(abs(decoded[slot] - frames[index][slot])))
            }
            #expect(worst <= step * 1.5, "image \(index) relue à \(worst) pour un pas de \(step)")
        }
    }

    /// And a spilled take writes itself out whole, so the file is the run and not the part
    /// of it that happened to still be in memory.
    @Test func aSpilledTakeWritesAndReadsBack() throws {
        let count = 2_000
        let recording = Recording(particleCount: count, galaxyCount: 1)
        var generator = SeededGenerator(seed: 9)
        var first: [SIMD3<Float>] = []
        var last: [SIMD3<Float>] = []
        for index in 0..<24 {
            var positions = [SIMD3<Float>](repeating: .zero, count: count)
            for slot in 0..<count {
                positions[slot] =
                    SIMD3<Float>(
                        generator.normal(), generator.normal(), generator.normal()) * 11
            }
            if index == 0 { first = positions }
            if index == 23 { last = positions }
            positions.withUnsafeBufferPointer {
                recording.offer(
                    positions: $0.baseAddress!, time: Float(index), centers: [.zero],
                    budget: count * 6 * 2)
            }
        }
        #expect(recording.isSpilling)

        var particles = ParticleSystem()
        particles.population = [Float](repeating: 0.5, count: count)
        particles.luminosity = [Float](repeating: 1, count: count)
        particles.formation = [Float](repeating: ParticleSystem.ancient, count: count)
        particles.kernelScale = [Float](repeating: 1, count: count)
        particles.component = [UInt32](repeating: 0, count: count)
        particles.galaxyIndex = [UInt32](repeating: 0, count: count)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("debord-\(UUID().uuidString).sillage")
        defer { try? FileManager.default.removeItem(at: url) }
        let scene = SceneConfig.isolatedDisk(particleCount: count)
        try RecordingFile.write(recording, scene: scene, particles: particles, to: url)
        let reloaded = try RecordingFile.read(from: url)

        #expect(reloaded.recording.count == 24)
        for (originals, index) in [(first, 0), (last, 23)] {
            let decoded = reloaded.recording.positions(at: index)
            let box = try #require(reloaded.recording.frame(at: index))
            let step = box.extent / 65535
            var worst: Float = 0
            for slot in 0..<count {
                worst = max(worst, simd_reduce_max(abs(decoded[slot] - originals[slot])))
            }
            #expect(worst <= step * 1.5, "image \(index) du fichier écartée de \(worst)")
        }
    }

    /// Sixteen bits over each snapshot's own bounding box has to be indistinguishable from the
    /// full precision positions, otherwise halving the memory would cost accuracy.
    @Test func quantisationStaysBelowOneStepOfTheBox() throws {
        let (recording, originals, count) = try captured(frames: 3)
        #expect(recording.count == 3)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let expander = try SnapshotExpander(device: device, particleCount: count)
        let output = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride))

        let stream = try #require(SnapshotStream(device: device, recording: recording))
        for index in 0..<2 {
            let offset = try #require(stream.fetch(index))
            let frame = try #require(recording.frame(at: index))
            let pair = (frame, frame)
            expander.expand(
                first: frame, at: offset, second: frame, at: offset, from: stream.buffer,
                blend: 0, into: output)
            let decoded = output.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            var worst: Float = 0
            for particle in 0..<count {
                worst = max(worst, simd_length(decoded[particle] - originals[index][particle]))
            }
            #expect(worst < pair.0.extent / 65535 * 3)
        }
    }

    /// The cache hands back the snapshot that was asked for, whether the reader had already
    /// fetched it or not. A direct-mapped cache that returned a neighbour would show up as
    /// playback jumping, so the test walks the indices in both directions and past the wrap.
    @Test func theSnapshotCacheNeverHandsBackTheWrongFrame() throws {
        let (recording, originals, count) = try captured(frames: 6)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let expander = try SnapshotExpander(device: device, particleCount: count)
        let output = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride))
        // Four slots against six frames, so the walk wraps and evicts.
        let stream = try #require(SnapshotStream(device: device, recording: recording, slots: 4))

        func check(_ index: Int) throws {
            stream.prepare(from: index)
            let offset = try #require(stream.fetch(index))
            let frame = try #require(recording.frame(at: index))
            expander.expand(
                first: frame, at: offset, second: frame, at: offset, from: stream.buffer,
                blend: 0, into: output)
            let decoded = output.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            var worst: Float = 0
            for particle in 0..<count {
                worst = max(worst, simd_length(decoded[particle] - originals[index][particle]))
            }
            #expect(worst < frame.extent / 65535 * 3, "image \(index)")
        }

        for index in 0..<6 { try check(index) }
        for index in stride(from: 5, through: 0, by: -1) { try check(index) }
        for index in [0, 4, 1, 5, 2] { try check(index) }
    }

    @Test func blendReachesBothEndsOfThePair() throws {
        let (recording, originals, count) = try captured(frames: 2)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let expander = try SnapshotExpander(device: device, particleCount: count)
        let output = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride))
        let stream = try #require(SnapshotStream(device: device, recording: recording))
        let firstOffset = try #require(stream.fetch(0))
        let secondOffset = try #require(stream.fetch(1))
        let pair = (try #require(recording.frame(at: 0)), try #require(recording.frame(at: 1)))

        func worstAgainst(_ reference: [SIMD3<Float>], blend: Float) -> Float {
            expander.expand(
                first: pair.0, at: firstOffset, second: pair.1, at: secondOffset,
                from: stream.buffer, blend: blend, into: output)
            let decoded = output.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            var worst: Float = 0
            for particle in 0..<count {
                worst = max(worst, simd_length(decoded[particle] - reference[particle]))
            }
            return worst
        }
        let tolerance = max(pair.0.extent, pair.1.extent) / 65535 * 3
        #expect(worstAgainst(originals[0], blend: 0) < tolerance)
        #expect(worstAgainst(originals[1], blend: 1) < tolerance)
        // Halfway sits between the two, not on either.
        #expect(worstAgainst(originals[0], blend: 0.5) > tolerance)
    }

    @Test func memoryEstimateMatchesWhatIsStored() throws {
        let (recording, _, count) = try captured(frames: 4)
        let expected = Recording.estimatedBytes(particleCount: count, frames: 4)
        #expect(abs(recording.byteCount - expected) < count)
        #expect(recording.duration > 0)
    }
}
