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
