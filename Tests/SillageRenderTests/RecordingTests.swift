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

        for index in 0..<2 {
            let pair = recording.upload(pair: index, into: expander.stagingBuffer)
            expander.expand(first: pair.0, second: pair.1, blend: 0, into: output)
            let decoded = output.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            var worst: Float = 0
            for particle in 0..<count {
                worst = max(worst, simd_length(decoded[particle] - originals[index][particle]))
            }
            #expect(worst < pair.0.extent / 65535 * 3)
        }
    }

    @Test func blendReachesBothEndsOfThePair() throws {
        let (recording, originals, count) = try captured(frames: 2)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let expander = try SnapshotExpander(device: device, particleCount: count)
        let output = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride))
        let pair = recording.upload(pair: 0, into: expander.stagingBuffer)

        func worstAgainst(_ reference: [SIMD3<Float>], blend: Float) -> Float {
            expander.expand(first: pair.0, second: pair.1, blend: blend, into: output)
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
