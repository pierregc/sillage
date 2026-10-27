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

    /// A run that outlasts its budget has to come back *whole*, at the cadence it was taken
    /// at. It used to come back at half of it, then a quarter, then an eighth — which keeps
    /// the duration and loses the run, since nothing between two snapshots ever happened.
    /// The budget bounds memory; the scratch file takes the rest.
    @Test func aLongTakeGoesToDiskInsteadOfThinning() {
        let particles = 400
        let recording = Recording(particleCount: particles, galaxyCount: 1)
        // Room for about twenty frames, offered two hundred.
        let budget = particles * 6 * 20
        var positions = [SIMD3<Float>](repeating: .zero, count: particles)
        for frame in 0..<200 {
            for index in positions.indices {
                positions[index] = SIMD3<Float>(Float(index), Float(frame), 0)
            }
            positions.withUnsafeBufferPointer {
                _ = recording.offer(
                    positions: $0.baseAddress!, time: Float(frame), centers: [.zero],
                    budget: budget)
            }
        }

        #expect(recording.spillFailure == nil)
        #expect(recording.isSpilling)
        // Memory stayed inside the budget — to within the frame that trips it and the frame
        // records, which are twenty bytes each — and every single frame is still there.
        #expect(
            recording.memoryByteCount
                <= budget + particles * 6 + 200 * MemoryLayout<Recording.Frame>.stride)
        #expect(recording.diskByteCount > 0)
        #expect(recording.count == 200)
        let span = recording.frames.last!.time - recording.frames.first!.time
        #expect(abs(span - 199) < 0.01)
        // In order, one megayear apart throughout — the cadence never coarsened.
        for index in 1..<recording.count {
            #expect(abs(recording.frames[index].time - recording.frames[index - 1].time - 1) < 0.01)
        }
        // And every one of them decodes, from memory and from the file alike.
        for frame in [0, 1, 19, 20, 100, 199] {
            let decoded = recording.positions(at: frame)
            #expect(decoded.count == particles)
            #expect(abs(decoded[10].y - Float(frame)) < 0.1, "image \(frame) relue de travers")
        }
    }

    /// Orbits at several speeds, one position per particle per captured frame.
    private func orbits(particles: Int, frames: Int) -> [[SIMD3<Float>]] {
        (0..<frames).map { frame in
            (0..<particles).map { index in
                let radius = 1 + Float(index % 10)
                // Tighter orbits turn faster, as they do in a disk: a quarter turn every
                // sixteen frames for the tightest.
                let angle = Float(frame) * (Float.pi / 32) / radius.squareRoot()
                return SIMD3<Float>(radius * cos(angle), radius * sin(angle), Float(index) * 0.01)
            }
        }
    }

    private func capture(
        _ frames: [[SIMD3<Float>]], interval: Int, galaxies: Int = 1
    ) -> Recording {
        let recording = Recording(
            particleCount: frames[0].count, galaxyCount: galaxies, interval: interval)
        for (index, positions) in frames.enumerated() {
            let centers = (0..<galaxies).map { _ in positions[0] }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(index) * 0.5, centers: centers)
            }
        }
        return recording
    }

    /// One frame in four is kept, and the last one whatever the interval says, so the take
    /// still ends where the run did.
    @Test func aTakeKeepsOneFrameInItsIntervalAndTheLast() throws {
        let frames = orbits(particles: 50, frames: 11)
        let recording = capture(frames, interval: 4)
        #expect(recording.count == 3)
        recording.finish()
        #expect(recording.count == 4)
        #expect(recording.capturedCount == 11)
        #expect(recording.frames.map(\.time) == [0, 2, 4, 5])

        var scene = SceneConfig.merger(particleCount: 50)
        scene.seed = 3
        var system = ParticleSystem()
        for _ in 0..<50 {
            system.append(
                position: .zero, velocity: .zero, galaxy: 0, radius: 1, population: 0.5,
                luminosity: 1, component: .star)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("interval.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        let loaded = try RecordingFile.read(from: url).recording
        #expect(loaded.interval == 4)
        #expect(loaded.capturedCount == 11)

        // Captured frames on a kept one land on it exactly; the others fall between.
        for (captured, key, fraction) in [(0, 0, 0), (4, 1, 0), (6, 1, 0.5), (9, 2, 0.5), (10, 2, 1)] {
            let blend = try #require(loaded.blend(atCaptured: captured))
            #expect(Int(blend.keys[1]) == key, "image \(captured)")
            #expect(abs(blend.fraction - Float(fraction)) < 1e-6, "image \(captured)")
            #expect(abs(blend.time - Float(captured) * 0.5) < 1e-5, "image \(captured)")
        }
    }

    /// Rewrites a take as an older version: the same layout without the birth radii.
    private func downgrade(_ url: URL, to version: UInt64, particles: Int) throws {
        var data = try Data(contentsOf: url)
        let header = Int(data[16..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        let radii = 24 + header + 16 * particles
        data.removeSubrange(radii..<(radii + 4 * particles))
        data.replaceSubrange(8..<16, with: withUnsafeBytes(of: version.littleEndian) { Data($0) })
        try data.write(to: url)
    }

    /// The colour ramps read the radius each particle was born at, about its own galaxy.
    @Test func aTakeKeepsTheBirthRadius() throws {
        var (recording, system) = take(particles: 120, frames: 3, galaxies: 2)
        system.birthRadius = (0..<120).map { Float($0) * 0.1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("birth-radius.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(
            recording, scene: SceneConfig.merger(particleCount: 120), particles: system, to: url)
        let loaded = try RecordingFile.read(from: url).particles
        #expect(loaded.birthRadius == system.birthRadius)
        #expect(loaded.colourRadius.isEmpty)
    }

    /// An old take keeps the radius it always replayed with, and gives the ramps the distance
    /// to its galaxy's centre on the first frame.
    @Test func anOldTakeRebuildsTheBirthRadiusFromTheFirstFrame() throws {
        var (recording, system) = take(particles: 120, frames: 3, galaxies: 2)
        system.birthRadius = (0..<120).map { Float($0) * 0.1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-5.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(
            recording, scene: SceneConfig.merger(particleCount: 120), particles: system, to: url)
        try downgrade(url, to: 5, particles: 120)
        let loaded = try RecordingFile.read(from: url)
        let positions = loaded.recording.positions(at: 0)
        let centres = loaded.recording.centers(at: 0)
        #expect(loaded.particles.birthRadius == positions.map { simd_length($0) })
        #expect(loaded.particles.population == system.population)
        for index in [0, 1, 77, 119] {
            let centre = centres[Int(system.galaxyIndex[index])]
            #expect(loaded.particles.colourRadius[index] == simd_distance(positions[index], centre))
        }
    }

    /// A take written before the interval existed has every frame, and says nothing about it.
    @Test func aVersionFourTakeStillReads() throws {
        let (recording, system) = take(particles: 100, frames: 5, galaxies: 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-4.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(
            recording, scene: SceneConfig.merger(particleCount: 100), particles: system, to: url)
        // Version 4 lacks the birth radii and two optional header fields.
        try downgrade(url, to: 4, particles: 100)

        let loaded = try RecordingFile.read(from: url).recording
        #expect(loaded.count == 5)
        #expect(loaded.interval == 1)
        #expect(loaded.capturedCount == 5)
        let blend = try #require(loaded.blend(atCaptured: 3))
        #expect(Int(blend.keys[1]) == 3 && blend.fraction == 0)
    }

    /// The frames a take no longer keeps come back off the curve the run followed, not off
    /// the chord between the kept ones. A straight line cuts every orbit short and kinks at
    /// each kept frame; that kink is the jump the interval must not show.
    @Test func theFramesInBetweenFollowTheOrbit() throws {
        let frames = orbits(particles: 40, frames: 33)
        let full = capture(frames, interval: 1)
        let thinned = capture(frames, interval: 4)
        thinned.finish()
        #expect(thinned.count == 9)

        var worstCubic: Float = 0
        var worstLine: Float = 0
        for captured in 0..<frames.count {
            let blend = try #require(thinned.blend(atCaptured: captured))
            let drawn = thinned.positions(at: blend)
            let first = thinned.positions(at: Int(blend.keys[1]))
            let second = thinned.positions(at: Int(blend.keys[2]))
            let truth = full.positions(at: captured)
            for index in truth.indices {
                worstCubic = max(worstCubic, simd_length(drawn[index] - truth[index]))
                let line = simd_mix(first[index], second[index], SIMD3(repeating: blend.fraction))
                worstLine = max(worstLine, simd_length(line - truth[index]))
            }
            // A kept frame is drawn exactly as it was kept.
            if captured % 4 == 0 {
                let kept = thinned.positions(at: captured / 4)
                let worst = truth.indices.map { simd_length(drawn[$0] - kept[$0]) }.max() ?? 0
                #expect(worst < 1e-4, "image \(captured)")
            }
        }
        // The tightest orbit turns two fifths of a radian between kept frames.
        #expect(worstLine > 0.015)
        #expect(worstCubic < worstLine / 4)
        #expect(worstCubic < 0.005)

        // And the galaxy centres, which the arms are painted about, come along the same curve.
        let blend = try #require(thinned.blend(atCaptured: 6))
        let centre = try #require(thinned.centers(at: blend).first)
        #expect(simd_length(centre - frames[6][0]) < 0.005)
    }

    @Test func aFileThatIsNotATakeIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk.sillage")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 4096).write(to: url)
        #expect(throws: RecordingFile.Failure.self) { try RecordingFile.read(from: url) }
    }
}
