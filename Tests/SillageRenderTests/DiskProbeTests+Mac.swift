import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

extension DiskProbeTests {
    /// The generators' response is read at the wave the probe's `facts` name, and asks a softer
    /// or thicker disk for a lower Q.
    @Test func theResponseIsReadAtTheProbesWavenumber() {
        var galaxy = Self.galaxy()
        galaxy.diskThickness = 0.2
        let facts = DiskProbe.facts(
            of: galaxy, equilibrium: DiskEquilibrium(config: galaxy, selfGravitating: true))
        let k = DiskResponse.wavenumber(galaxy)
        #expect(abs(k * Self.scaleLength / Float(facts.x2[1]) - 2 / 1.44) < 1e-3)
        let q = DiskResponse.toomreQ(effective: 1.85, of: galaxy, softening: 0.12)
        galaxy.toomreQ = q
        #expect(abs(DiskResponse.effectiveToomreQ(galaxy, softening: 0.12) - 1.85) < 1e-4)
        #expect(DiskResponse.toomreQ(effective: 1.85, of: galaxy, softening: 0.24) < q)
        galaxy.diskThickness = 0.4
        #expect(DiskResponse.toomreQ(effective: 1.85, of: galaxy, softening: 0.12) < q)
        #expect(DiskResponse.toomreQ(effective: 1.85, of: galaxy, softening: 5) == DiskResponse.lowestToomreQ)
    }

    @Test func aRunWritesItsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two galaxies, so the probe has to pick one out of the scene's sample.
        var scene = SceneConfig.encounter(particleCount: 24_000)
        scene.galaxies[1].kind = .spiral
        scene.galaxies[1].effectiveToomreQ = 2.5
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
        options.diskThickness = 0.25
        options.softening = 0.2
        options.effectiveToomreQ = 3
        let report = try DiskProbe.run(options) { _ in }
        #expect(report.frames == 3)
        #expect(report.galaxyParticles == scene.galaxies[1].particleCount)
        #expect(report.simulatedParticles > report.galaxyParticles)
        #expect(abs((report.overrides["clumpiness"] ?? 0) - 0.05) < 1e-6)
        #expect(abs((report.overrides["diskThickness"] ?? 0) - 0.25) < 1e-6)
        #expect(abs(report.softening - 0.2) < 1e-6)
        #expect(report.summary.medianStartKpc > 2 && report.summary.medianStartKpc < 12)
        #expect(report.facts.x2[1] > 0.5 && report.facts.x2[1] < 20)
        #expect(report.facts.paintedPatternSpeed > 0)
        // Solved for the response asked for in place of the file's, at the softening the run
        // uses, after the thickness.
        #expect(abs(report.facts.effectiveToomreQ - 3) < 1e-3)
        #expect(abs((report.overrides["toomreQ"] ?? 0) - report.facts.gravityLeft * 3) < 1e-3)

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
