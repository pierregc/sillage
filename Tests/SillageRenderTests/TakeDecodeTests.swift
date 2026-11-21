import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// A take decoded between its frames on every core (#382): to the bit what one particle at a
/// time gives, each frame decoded alone and the four weighed, which is what the expander's
/// kernel is checked against.
@Suite("Take decode")
struct TakeDecodeTests {
    /// More than two shares of the decode, and not a multiple of them.
    static let particles = 2 * 65_536 + 4_099

    private func take(particles: Int, frames: Int, bitsPerAxis: Int) -> Recording {
        let recording = Recording(particleCount: particles, galaxyCount: 2, bitsPerAxis: bitsPerAxis)
        var generator = SeededGenerator(seed: 11)
        var positions = (0..<particles).map { _ in
            SIMD3<Float>(generator.uniform(), generator.uniform(), generator.uniform()) * 60 - 30
        }
        for frame in 0..<frames {
            for index in positions.indices {
                let drift = SIMD3<Float>(generator.uniform(), generator.uniform(), generator.uniform()) - 0.5
                positions[index] += drift * Float(1 + frame % 3)
            }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame) * 0.25 + Float(frame * frame) * 0.01,
                    centers: [.zero, SIMD3(Float(frame), 0, 0)])
            }
        }
        return recording
    }

    private func reference(_ recording: Recording, _ blend: Recording.Blend) -> [SIMD3<Float>] {
        let around = (0..<4).map { recording.positions(at: Int(blend.keys[$0])) }
        return (0..<recording.particleCount).map { index in blend.mix(around.map { $0[index] }) }
    }

    private func bits(_ positions: [SIMD3<Float>]) -> [UInt32] {
        positions.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
    }

    private func blends(of recording: Recording) -> [Recording.Blend] {
        let last = Double(recording.capturedFrames - 1)
        var blends = [0, 0.37, 1, 1.5, 2.999, last - 0.25, last].compactMap {
            recording.blend(atCaptured: $0)
        }
        // A take that holds some moments of another's run reads its frames a run at a time.
        blends += [(1.25, 1...3), (2.0, 2...2), (3.6, 3...4)].compactMap {
            recording.blend(atStored: $0.0, within: $0.1)
        }
        return blends
    }

    @Test(arguments: [16, 21])
    func everyCoreDecodesTheBitsOfOne(bitsPerAxis: Int) throws {
        let recording = take(particles: Self.particles, frames: 5, bitsPerAxis: bitsPerAxis)
        let blends = blends(of: recording)
        #expect(blends.count == 10)
        for blend in blends {
            let decoded = recording.positions(at: blend)
            #expect(decoded.count == Self.particles)
            #expect(bits(decoded) == bits(reference(recording, blend)))
        }
    }

    /// A take read from a file is decoded from its mapping, with no copy.
    @Test func aTakeReadFromAFileDecodesTheSameBits() throws {
        let recording = take(particles: Self.particles, frames: 4, bitsPerAxis: 21)
        var system = ParticleSystem()
        for index in 0..<Self.particles {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index % 2), radius: 1, population: 0.5,
                luminosity: 1, component: .star)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(
            recording, scene: SceneConfig.merger(particleCount: Self.particles), particles: system, to: url)
        let loaded = try RecordingFile.read(from: url).recording
        for blend in blends(of: loaded) {
            #expect(bits(loaded.positions(at: blend)) == bits(reference(recording, blend)))
        }
    }

    /// The fixture every engine is checked on, small enough for one share.
    @Test func theFixtureTakeDecodesTheSameBits() throws {
        let root = try RepositoryRoot.resolve()
        let url = root.appendingPathComponent("Tests/Fixtures/engines/frames/take.sillage")
        let recording = try RecordingFile.read(from: url).recording
        let blend = try #require(recording.blend(atCaptured: 0))
        #expect(bits(recording.positions(at: blend)) == bits(reference(recording, blend)))
    }

    @Test func aDestinationTooSmallIsRefused() throws {
        let recording = take(particles: 64, frames: 2, bitsPerAxis: 21)
        let blend = try #require(recording.blend(atCaptured: 0.5))
        var short = [SIMD3<Float>](repeating: .zero, count: 63)
        let filled = short.withUnsafeMutableBufferPointer { recording.positions(at: blend, into: $0) }
        #expect(!filled)
        #expect(Recording(particleCount: 64).positions(at: blend).isEmpty)
    }
}
