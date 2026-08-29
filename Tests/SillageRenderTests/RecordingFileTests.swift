import Foundation
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Recording files")
struct RecordingFileTests {
    private func take(particles: Int, frames: Int, galaxies: Int) -> (Recording, ParticleSystem) {
        let recording = Recording(particleCount: particles, galaxyCount: galaxies)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 5)
        for index in 0..<particles {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index % galaxies),
                radius: 1, population: generator.uniform(), luminosity: 1 + generator.uniform(),
                component: index % 7 == 0 ? .dust : .star)
        }
        for frame in 0..<frames {
            var positions = (0..<particles).map { index in
                SIMD3<Float>(
                    Float(index) * 0.01 + Float(frame), Float(index) * -0.02,
                    Float(frame) * 0.5)
            }
            let centers = (0..<galaxies).map { SIMD3<Float>(Float($0), Float(frame), 0) }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame) * 0.25, centers: centers)
            }
        }
        return (recording, system)
    }

    /// A take costs minutes to compute, so what comes back has to be what went in. The
    /// positions are quantised on the way in and stay quantised, so they survive exactly.
    @Test func aTakeSurvivesTheRoundTrip() throws {
        let (recording, system) = take(particles: 500, frames: 6, galaxies: 2)
        var scene = SceneConfig.merger(particleCount: 500)
        scene.galaxies[0].dissipationTime = 123

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-trip.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        let loaded = try RecordingFile.read(from: url)

        #expect(loaded.scene == scene)
        #expect(loaded.recording.count == recording.count)
        #expect(loaded.recording.particleCount == recording.particleCount)
        #expect(loaded.particles.population == system.population)
        #expect(loaded.particles.luminosity == system.luminosity)
        #expect(loaded.particles.component == system.component)
        #expect(loaded.particles.galaxyIndex == system.galaxyIndex)

        // Frames, and the galaxy centres the spiral pattern is painted about.
        for frame in 0..<recording.count {
            #expect(loaded.recording.frames[frame].time == recording.frames[frame].time)
            #expect(loaded.recording.centers(at: frame) == recording.centers(at: frame))
        }
        // And the positions themselves, which is the whole point of the file.
        for frame in [0, recording.count - 1] {
            let before = recording.positions(at: frame)
            let after = loaded.recording.positions(at: frame)
            var worst: Float = 0
            for index in before.indices { worst = max(worst, simd_length(before[index] - after[index])) }
            #expect(worst == 0)
        }
    }

    @Test func aFileThatIsNotATakeIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk.sillage")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 4096).write(to: url)
        #expect(throws: RecordingFile.Failure.self) { try RecordingFile.read(from: url) }
    }
}
