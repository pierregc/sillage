import Foundation
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Disk probe")
struct DiskProbeTests {
    static let scaleLength: Float = 4

    static func galaxy(spin: Spin = .prograde) -> GalaxyConfig {
        GalaxyConfig(
            name: "probe", particleCount: 100_000,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
            diskScaleLength: scaleLength, spin: spin)
    }

    /// A synthetic disk: exponential, azimuthally uniform unless a two-armed modulation of
    /// density contrast `contrast` is asked for, turning at unit speed, some of it gathered
    /// into small clumps. Every star is a thin-disk star.
    struct Disk {
        var positions: [SIMD3<Float>] = []
        var velocities: [SIMD3<Float>] = []
        var component: [UInt32] = []

        init(
            count: Int, seed: UInt64, contrast: Float = 0, phase: Float = 0, clumps: Int = 0,
            clumpShare: Float = 0, radialDispersion: Float = 0, arms: Float = 2
        ) {
            var generator = SeededGenerator(seed: seed)
            let h = DiskProbeTests.scaleLength
            var centres: [(radius: Float, phi: Float)] = []
            for _ in 0..<clumps {
                centres.append(
                    (
                        h * DiskSampler.inverseExponentialCDF(generator.uniform(), truncation: 4),
                        generator.uniform() * 2 * .pi
                    ))
            }
            while positions.count < count {
                var radius = h * DiskSampler.inverseExponentialCDF(generator.uniform(), truncation: 4)
                var phi = generator.uniform() * 2 * .pi
                if contrast > 0 {
                    // Accept and reject against 1 + contrast cos m(phi - phase).
                    let weight = (1 + contrast * cos(arms * (phi - phase))) / (1 + contrast)
                    if generator.uniform() > weight { continue }
                }
                if !centres.isEmpty, generator.uniform() < clumpShare {
                    let clump = centres[Int(generator.uniform() * Float(centres.count)) % centres.count]
                    radius = max(clump.radius + generator.normal() * 0.03 * h, 0.05)
                    phi = clump.phi + generator.normal() * 0.03 * h / max(radius, 0.3)
                }
                let z = generator.normal() * 0.3
                positions.append(SIMD3<Float>(radius * cos(phi), radius * sin(phi), z))
                let along = SIMD3<Float>(-sin(phi), cos(phi), 0)
                let outward = SIMD3<Float>(cos(phi), sin(phi), 0)
                velocities.append(along + outward * (generator.normal() * radialDispersion))
                component.append(ParticleComponent.star.rawValue)
            }
        }

        func measure(
            galaxy: GalaxyConfig = DiskProbeTests.galaxy(), frame: DiskProbe.Frame? = nil,
            timeMyr: Double = 0, patternMode: Int = 2
        ) -> (DiskProbe.Measurement, DiskProbe.PolarMap, DiskProbe.Frame) {
            DiskProbe.withParticles(
                positions: positions, velocities: velocities, component: component
            ) { particles in
                let found = DiskProbe.frame(
                    of: particles, galaxy: galaxy, previous: frame ?? .natal(galaxy))
                let (reading, map) = DiskProbe.measure(
                    particles, frame: found, galaxy: galaxy,
                    equilibrium: DiskEquilibrium(config: galaxy, selfGravitating: true),
                    solverCentre: .zero, timeMyr: timeMyr, patternMode: patternMode)
                return (reading, map, found)
            }
        }

        /// The same stars turned rigidly by `angle` about the axis.
        func turned(by angle: Float) -> Disk {
            var copy = self
            let c = cos(angle)
            let s = sin(angle)
            copy.positions = positions.map { SIMD3<Float>($0.x * c - $0.y * s, $0.x * s + $0.y * c, $0.z) }
            copy.velocities = velocities.map { SIMD3<Float>($0.x * c - $0.y * s, $0.x * s + $0.y * c, $0.z) }
            return copy
        }
    }

    /// Radius holding a given share of a truncated exponential disk.
    static func quantile(_ share: Double, truncation: Double = 4) -> Double {
        func held(_ x: Double) -> Double { 1 - (1 + x) * exp(-x) }
        let wanted = share * held(truncation)
        var low = 0.0
        var high = truncation
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if held(middle) < wanted { low = middle } else { high = middle }
        }
        return (low + high) / 2 * Double(scaleLength)
    }

    @Test func aSmoothDiskReadsAsSmooth() {
        let (reading, _, _) = Disk(count: 200_000, seed: 1).measure()
        // What is left of the noise after the correction scales as the fourth root of the
        // zone's ring count over the root of its star count: about 0.006 inside, 0.014 in
        // the sparse outer zone.
        for zone in DiskProbe.zones.indices {
            for order in 0..<DiskProbe.modes {
                #expect(reading.amplitudes[zone][order] < (zone == 2 ? 0.035 : 0.015))
            }
        }
        #expect(reading.lumpiness < 0.03)
        #expect(reading.polarLumpiness < 0.03)
        #expect(abs(reading.deciles[4] - Self.quantile(0.5)) < 0.05)
        #expect(abs(reading.deciles[0] - Self.quantile(0.1)) < 0.05)
        #expect(abs(reading.deciles[8] - Self.quantile(0.9)) < 0.08)
        #expect(abs(reading.zRms - 0.3) < 0.01)
        #expect(reading.thicknessRatio > 0.02 && reading.thicknessRatio < 0.06)
        #expect(reading.counts[1] > 50_000)
    }

    /// A density of 1 + c cos 2 phi has a relative m = 2 amplitude of c / 2.
    @Test func aTwoArmedDiskReadsItsAmplitudeAndPhase() {
        let (reading, _, _) = Disk(count: 200_000, seed: 2, contrast: 0.4, phase: 0.7).measure()
        #expect(abs(reading.amplitude2Mid - 0.2) < 0.015)
        #expect(abs(reading.amplitudes[0][1] - 0.2) < 0.02)
        #expect(reading.amplitudes[1][0] < 0.012)
        #expect(reading.amplitudes[1][3] < 0.012)
        var phase = reading.patternAngle - 0.7
        while phase > .pi / 2 { phase -= .pi }
        while phase < -.pi / 2 { phase += .pi }
        #expect(abs(phase) < 0.02)
    }

    /// An odd pattern reads its own phase too: the sectors' phasors are the azimuths the
    /// measurement bins, so no order is turned by half a period.
    @Test func aThreeArmedDiskReadsItsPhase() {
        let disk = Disk(count: 200_000, seed: 12, contrast: 0.4, phase: 0.5, arms: 3)
        let (reading, _, _) = disk.measure(patternMode: 3)
        #expect(abs(reading.amplitudes[1][2] - 0.2) < 0.015)
        let period = 2 * Double.pi / 3
        var phase = reading.patternAngle - 0.5
        while phase > period / 2 { phase -= period }
        while phase < -period / 2 { phase += period }
        #expect(abs(phase) < 0.03)
    }

    /// A retrograde disk turns the other way in the same plane, and reads exactly the same:
    /// its azimuth grows with its own rotation, so its rates come out positive too.
    @Test func aRetrogradeDiskReadsLikeAProgradeOne() {
        let disk = Disk(count: 100_000, seed: 2, contrast: 0.4, phase: 0.7)
        var reversed = disk
        reversed.velocities = disk.velocities.map { -$0 }
        let forward = disk.measure().0
        let backward = reversed.measure(galaxy: Self.galaxy(spin: .retrograde)).0
        #expect(abs(forward.amplitude2Mid - backward.amplitude2Mid) < 0.005)
        #expect(abs(forward.streaming - 1) < 0.01 && abs(backward.streaming - 1) < 0.01)
        #expect(forward.materialRate > 0 && backward.materialRate > 0)
        #expect(abs(forward.materialRate - backward.materialRate) < 1e-4)
        #expect(backward.axisTilt < 0.1)
    }

    /// The expectation of a random sample is taken out, so a sparse run does not read as
    /// structured, and the clumps it does hold read the same at four times the count.
    @Test func shotNoiseIsTakenOutAtEveryCount() {
        let sparse = Disk(count: 25_000, seed: 3).measure().0
        let dense = Disk(count: 400_000, seed: 4).measure().0
        #expect(sparse.amplitude2Mid < 0.015 && dense.amplitude2Mid < 0.008)
        #expect(sparse.lumpiness < 0.05 && dense.lumpiness < 0.02)
        #expect(sparse.polarLumpiness < 0.05 && dense.polarLumpiness < 0.02)

        let few = Disk(count: 100_000, seed: 5, clumps: 300, clumpShare: 0.25).measure().0
        let many = Disk(count: 400_000, seed: 5, clumps: 300, clumpShare: 0.25).measure().0
        #expect(few.lumpiness > 0.1 && few.polarLumpiness > 0.05)
        #expect(abs(few.lumpiness - many.lumpiness) / many.lumpiness < 0.25)
        #expect(abs(few.polarLumpiness - many.polarLumpiness) / many.polarLumpiness < 0.25)
    }

    @Test func theDispersionIsRead() {
        let (reading, _, _) = Disk(count: 100_000, seed: 6, radialDispersion: 0.1).measure()
        #expect(abs(reading.sigmaR[1] - 0.1) < 0.006)
        #expect(abs(reading.streaming - 1) < 0.01)
        #expect(reading.sigmaPhi < 0.01)
    }

    /// The frame finds a disk that has moved and tilted, and reads the same structure there.
    @Test func theFrameFollowsTheNucleusAndTheAxis() {
        let disk = Disk(count: 100_000, seed: 7, contrast: 0.4)
        let still = disk.measure().0
        var moved = disk
        let tilt: Float = 20 * .pi / 180
        let shift = SIMD3<Float>(3, -2, 1)
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(p.x, p.y * cos(tilt) - p.z * sin(tilt), p.y * sin(tilt) + p.z * cos(tilt))
        }
        moved.positions = disk.positions.map { rotate($0) + shift }
        moved.velocities = disk.velocities.map(rotate)
        let (reading, _, frame) = moved.measure()
        #expect(simd_length(frame.centre - shift) < 0.05)
        #expect(simd_dot(frame.axis, rotate(SIMD3<Float>(0, 0, 1))) > 0.9995)
        #expect(abs(simd_dot(frame.u, frame.v)) < 1e-4)
        #expect(simd_dot(simd_cross(frame.u, frame.v), frame.axis) > 0.999)
        #expect(abs(reading.axisTilt - 20) < 0.3)
        #expect(abs(reading.amplitude2Mid - still.amplitude2Mid) < 0.01)
        #expect(abs(reading.deciles[4] - still.deciles[4]) < 0.03)
        #expect(abs(reading.zRms - still.zRms) < 0.02)
    }

    /// A pattern turned rigidly is coherent with itself in the frame turning at its own
    /// speed, and that speed is read off its phase ring by ring with no spread.
    @Test func aTurningPatternIsCoherentAtItsOwnSpeed() throws {
        let disk = Disk(count: 200_000, seed: 8, contrast: 0.5)
        let speed: Float = 0.02
        let equilibrium = DiskEquilibrium(config: Self.galaxy(), selfGravitating: true)
        var tracker = DiskProbe.Tracker(lagMyr: 50, equilibrium: equilibrium)
        var last: DiskProbe.Measurement?
        for myr in stride(from: 0.0, through: 50, by: 10) {
            var (reading, map, _) = disk.turned(by: speed * Float(myr)).measure(timeMyr: myr)
            tracker.fold(&reading, map: map)
            last = reading
        }
        let reading = try #require(last)
        #expect(abs(reading.patternSpeed - Double(speed)) < 0.002)
        #expect(reading.patternSpread < 0.003)
        #expect(reading.coherencePattern > 0.95)
        #expect(reading.coherenceStatic < reading.coherencePattern - 0.1)
        // The material turns faster than the pattern here, so its frame is the wrong one.
        #expect(reading.coherenceMaterial < reading.coherencePattern - 0.05)
        #expect(reading.mapSignalToNoise > 1.5)
        let corotation = Float(reading.corotation) * Self.scaleLength
        #expect(corotation.isFinite)
        let speedThere = Double(equilibrium.circularSpeed(atRadius: corotation) / corotation)
        let rate = speedThere / Physics.megayearsPerTimeUnit
        #expect(abs(rate - reading.patternSpeed) < 1e-4)
    }

    /// Shot noise that stays put must not read as a pattern that stays put: the lagged pair
    /// is taken from two halves of the sample, so a star never meets its own earlier place.
    @Test func noiseThatDoesNotMoveIsNotCoherent() throws {
        let disk = Disk(count: 100_000, seed: 9)
        var tracker = DiskProbe.Tracker(lagMyr: 50)
        var last: DiskProbe.Measurement?
        for myr in stride(from: 0.0, through: 50, by: 10) {
            var (reading, map, _) = disk.measure(timeMyr: myr)
            tracker.fold(&reading, map: map)
            last = reading
        }
        let reading = try #require(last)
        #expect(abs(reading.coherenceStatic) < 0.1)
        #expect(abs(reading.coherenceMaterial) < 0.1)
        #expect(reading.mapSignalToNoise < 0.5)
    }

    @Test func aRunWritesItsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two galaxies, so the probe has to pick one out of the scene's sample.
        var scene = SceneConfig.encounter(particleCount: 24_000)
        scene.galaxies[1].kind = .spiral
        let sceneURL = folder.appendingPathComponent("pair.scene.json")
        try SceneFile(scene).encoded().write(to: sceneURL)

        var options = DiskProbe.Options(scene: sceneURL.path, galaxy: 1)
        options.particles = 24_000
        options.durationMyr = 4
        options.frameMyr = 2
        options.width = 96
        options.height = 96
        options.stillsMyr = [0]
        options.output = folder.appendingPathComponent("probe").path
        options.clumpiness = 0.05
        let report = try DiskProbe.run(options) { _ in }
        #expect(report.frames == 3)
        #expect(report.galaxyParticles == scene.galaxies[1].particleCount)
        #expect(report.simulatedParticles > report.galaxyParticles)
        #expect(abs((report.overrides["clumpiness"] ?? 0) - 0.05) < 1e-6)
        #expect(report.summary.medianStartKpc > 2 && report.summary.medianStartKpc < 12)
        #expect(report.facts.x2[1] > 0.5 && report.facts.x2[1] < 20)
        #expect(report.facts.paintedPatternSpeed > 0)

        let output = URL(fileURLWithPath: options.output!)
        let csv = try String(contentsOf: output.appendingPathComponent("probe.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("frame,time_myr,"))
        #expect(lines[0].split(separator: ",").count == lines[1].split(separator: ",").count)
        let json = try Data(contentsOf: output.appendingPathComponent("probe.json"))
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let read = try decoder.decode(DiskProbe.Report.self, from: json)
        #expect(read.steps == report.steps)
        for name in ["still-0000.png", "probe.mov", "probe.scene.json"] {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path))
        }
        // The probe's disk starts where the scene put it, at rest at the origin.
        let first = lines[1].split(separator: ",").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let cx = try #require(header.firstIndex(of: "cx"))
        #expect(abs(Double(first[cx]) ?? 9) < 1.5)
    }
}
