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

    /// A take written without measuring its disks held a placeholder for every galaxy on every
    /// frame, which painted the arms in the xy plane: read back, it paints the natal planes.
    @Test func aTakeWithoutMeasuredDisksPaintsTheNatalPlanes() throws {
        let (recording, system) = take(particles: 200, frames: 3, galaxies: 2)
        let scene = SceneConfig.merger(particleCount: 200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-disks.\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        #expect(try RecordingFile.read(from: url).recording.disks(at: 0).isEmpty)

        let measured = Recording(particleCount: 200, galaxyCount: 2)
        let disks = [
            DiskState(axis: SIMD3(1, 0, 0), disruption: 0.25),
            DiskState(axis: SIMD3(0, 1, 0), disruption: 0),
        ]
        let positions = [SIMD3<Float>](repeating: SIMD3(1, 2, 3), count: 200)
        for frame in 0..<3 {
            positions.withUnsafeBufferPointer {
                measured.append(
                    positions: $0.baseAddress!, time: Float(frame), centers: [.zero, .zero],
                    disks: disks)
            }
        }
        try RecordingFile.write(measured, scene: scene, particles: system, to: url)
        let back = try RecordingFile.read(from: url).recording.disks(at: 1)
        #expect(back.map(\.axis) == disks.map(\.axis))
        #expect(back.map(\.disruption) == disks.map(\.disruption))
    }

    /// A scene folder holding a take as `hires` writes one: two galaxies over eleven captured
    /// frames, one in four kept and the last (0, 4, 8 and 10), with the disk states given or,
    /// as before #186, none.
    private func hiresTake(disks: [DiskState] = []) throws -> (SceneFolder, SceneConfig) {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "old-take-\(UUID().uuidString)/scene-0001"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let scene = SceneConfig.merger(particleCount: 200)
        let recording = Recording(particleCount: 200, galaxyCount: 2, interval: 4)
        var system = ParticleSystem()
        for index in 0..<200 {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index % 2), radius: 1,
                population: 0.5, luminosity: 1, component: .star)
        }
        for frame in 0..<11 {
            let y = Float(frame)
            let positions = (0..<200).map { SIMD3<Float>(Float($0 % 2) * 20 - 10, y, 0) }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: 30 + y * 0.25,
                    centers: [SIMD3(-10, y, 0), SIMD3(10, y, 0)], disks: disks)
            }
        }
        try RecordingFile.write(recording, scene: scene, particles: system, to: folder.take)
        return (folder, scene)
    }

    /// `curves-hires.csv` for that take as the run writes it: a row per captured frame, the time
    /// to a thousandth of a megayear, each disk's disruption.
    private func hiresCurves(_ disruption: (Int) -> [Float], shift: Double = 0) -> String {
        var csv =
            "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction,"
            + "disruption_0,disruption_1,x_0,y_0,z_0,x_1,y_1,z_1\n"
        for frame in 0..<11 {
            let myr = Double(30 + Float(frame) * 0.25) * Physics.megayearsPerTimeUnit + shift
            csv +=
                String(format: "%d,%.3f,20.0000,12.0000,0,20.0000,0.0000", frame, myr)
                + disruption(frame).map { String(format: ",%.3f", $0) }.joined()
                + String(format: ",-10.0000,%d.0000,0.0000,10.0000,%d.0000,0.0000\n", frame, frame)
        }
        return csv
    }

    /// A take `hires` wrote before #186 holds no disk state, but the same run wrote each disk's
    /// disruption beside it in `curves-hires.csv`: read from there, the take tears its disks
    /// where the curves say (#198). The painted arms read the take's own layers instead (#210).
    @Test func aTakeWithoutDiskStatesReadsTheirDisruptionFromItsCurves() throws {
        let (folder, scene) = try hiresTake()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        // The first disk tears from captured frame 3 to 7, the second never does.
        let torn = { (frame: Int) -> [Float] in [min(max(Float(frame - 3) / 4, 0), 1), 0] }
        try hiresCurves(torn).write(to: folder.hiresCurves, atomically: true, encoding: .utf8)

        let loaded = try RecordingFile.read(from: folder.take)
        let recording = loaded.recording
        #expect(recording.count == 4)
        let natal = DiskState.natal(scene).map(\.axis)
        for (stored, captured) in [(0, 0), (1, 4), (2, 8), (3, 10)] {
            let disks = recording.disks(at: stored)
            #expect(disks.map(\.disruption) == torn(captured), "image \(captured)")
            #expect(disks.map(\.axis) == natal, "image \(captured)")
        }

        // Every captured frame as the look stage, the export and the canvas draw it.
        let arms = try (0..<11).map { frame in
            let blend = try #require(recording.blend(atCaptured: frame))
            return DiskFrame.make(
                scene: loaded.scene, centers: recording.centers(at: blend), time: blend.time,
                strength: 1, disks: recording.disks(at: blend)
            ).map(\.axisV.w)
        }
        // These disks never leave their layer, so their arms stay whatever the curves say.
        #expect(arms.allSatisfy { $0 == scene.galaxies.map(\.armStrength) })
        // And the director's plan, which films the least torn disk at the end.
        #expect(ShotPlan.Track(take: loaded).disruption.last == [1, 0])
    }

    /// The painted arms fade as a disk's material leaves its layer, measured on the take's own
    /// positions, and stay on a disk that is only bent (#210).
    @Test func aTakeFadesTheArmsOfADiskThatLeavesItsLayer() throws {
        let scene = SceneConfig.merger(particleCount: 6_000)
        let galaxies = scene.galaxies
        var system = ParticleSystem()
        for index in 0..<6_000 {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index / 3_000), radius: 1,
                population: 0.5, luminosity: 1, component: .star)
        }
        var generator = SeededGenerator(seed: 210)
        let local = (0..<3_000).map { _ -> SIMD3<Float> in
            let radius = min(-4 * log(max(generator.uniform() * generator.uniform(), 1e-6)), 19)
            let angle = 2 * Float.pi * generator.uniform()
            return SIMD3(radius * cos(angle), radius * sin(angle), 0.2 * generator.normal())
        }
        let directions = (0..<3_000).map { _ -> SIMD3<Float> in
            let z = 2 * generator.uniform() - 1
            let angle = 2 * Float.pi * generator.uniform()
            return SIMD3((1 - z * z).squareRoot() * cos(angle), (1 - z * z).squareRoot() * sin(angle), z)
        }
        // The first disk is stirred into a spheroid from frame 5 to 7, the second only bent.
        let recording = Recording(particleCount: 6_000, galaxyCount: 2)
        for frame in 0..<9 {
            let stirred = Int(Float(3_000) * min(max(Float(frame - 4) / 3, 0), 1))
            let bend = min(Float(frame) / 8, 1)
            let first = local.indices.map { index in
                index < stirred ? simd_length(local[index]) * directions[index] : local[index]
            }
            let second = local.map { point -> SIMD3<Float> in
                let radius = (point.x * point.x + point.y * point.y).squareRoot()
                return point + SIMD3(0, 0, bend * max(radius - 8, 0) * 0.35 * sin(atan2(point.y, point.x)))
            }
            let positions =
                first.map { galaxies[0].position + galaxies[0].orientation * $0 }
                + second.map { galaxies[1].position + galaxies[1].orientation * $0 }
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame), centers: galaxies.map(\.position),
                    disks: DiskState.natal(scene))
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layers-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)

        let back = try RecordingFile.read(from: url).recording
        let torn = (0..<9).map { back.disks(at: $0).map(\.torn) }
        #expect(torn[0...4].allSatisfy { $0 == [0, 0] })
        #expect(torn[6][0] == 1 && torn[8][0] == 1)
        #expect(torn.allSatisfy { $0[1] == 0 })
        let arms = (0..<9).map { frame in
            DiskFrame.make(
                scene: scene, centers: galaxies.map(\.position), time: 0, strength: 1,
                disks: back.disks(at: frame)
            ).map(\.axisV.w)
        }
        #expect(arms[0] == galaxies.map(\.armStrength))
        #expect(arms[8] == [0, galaxies[1].armStrength])
    }

    /// A take written since #186 reads its own disk states, whatever curves sit beside it.
    @Test func aTakeWithItsOwnDiskStatesKeepsThem() throws {
        let measured = [
            DiskState(axis: simd_normalize(SIMD3(0.2, 0, 1)), disruption: 0.4),
            DiskState(axis: SIMD3(0, 1, 0), disruption: 0),
        ]
        let (folder, _) = try hiresTake(disks: measured)
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        try hiresCurves { _ in [1, 1] }.write(
            to: folder.hiresCurves, atomically: true, encoding: .utf8)

        let recording = try RecordingFile.read(from: folder.take).recording
        #expect(recording.count == 4)
        for stored in 0..<recording.count {
            let disks = recording.disks(at: stored)
            #expect(disks.map(\.axis) == measured.map(\.axis))
            #expect(disks.map(\.disruption) == measured.map(\.disruption))
        }
    }

    /// Curves that are not the take's own are not read: another run's, whose frames fall
    /// elsewhere, ones without a disk's disruption, or ones that stop short of the take.
    @Test func curvesThatAreNotTheTakesAreLeftAlone() throws {
        let (folder, _) = try hiresTake()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let torn = { (_: Int) -> [Float] in [1, 1] }
        let short = hiresCurves(torn).split(separator: "\n").dropLast(2).joined(separator: "\n")
        for csv in [
            hiresCurves(torn, shift: 0.4),
            hiresCurves(torn).replacingOccurrences(of: "disruption_1", with: "spread_1"),
            short,
        ] {
            try csv.write(to: folder.hiresCurves, atomically: true, encoding: .utf8)
            #expect(try RecordingFile.read(from: folder.take).recording.disks(at: 0).isEmpty)
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
