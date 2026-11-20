import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Black hole close up flights")
struct HoleFlightTests {
    /// The default scene's run, kept every 1000 steps: released at -21.5, a step of 0.25.
    func header(steps: [Int] = [0, 1000, 12_086, 20_086]) -> HoleTakeFile.Header {
        var scene = TidalDisruption()
        scene.tracers = 2
        return HoleTakeFile.Header(
            scene: HoleSceneFile(name: "test", blackHole: scene), tracers: 2, releaseTime: -21.5, steps: steps
        )
    }

    func key(_ at: Double, time: Double? = nil, eye: SIMD3<Double>? = nil) -> FlightFile.Key {
        FlightFile.Key(at: at, time: time, eye: eye.map { .world($0) }, aim: eye.map { _ in .world(.zero) })
    }

    @Test func aHoleFlightGivesTimeAndNoGalaxy() throws {
        let good = FlightFile(keys: [key(0, time: 100, eye: SIMD3(0, -30, 5)), key(4, time: 200)])
        #expect(good.isBlackHole)
        try good.validate()
        let mixed = FlightFile(keys: [
            key(0, time: 100, eye: SIMD3(0, -30, 5)), FlightFile.Key(at: 4, myr: 200),
        ])
        #expect(throws: FlightFile.ReadError.self) { try mixed.validate() }
        var anchored = good
        anchored.keys[0].aim = .galaxy(0, offset: .zero, disk: false)
        #expect(throws: FlightFile.ReadError.self) { try anchored.validate() }
        var inside = good
        inside.inside = InsideSettings()
        #expect(throws: FlightFile.ReadError.self) { try inside.validate() }
        let galaxies = FlightFile(keys: [
            FlightFile.Key(at: 0, myr: 100, eye: .world(SIMD3(0, -30, 5)), aim: .world(.zero)),
            FlightFile.Key(at: 4, myr: 200),
        ])
        #expect(!galaxies.isBlackHole)
        #expect(throws: HoleFlight.Failure.galaxyFlight) {
            try HoleFlight.resolve(galaxies, header: header(), camera: .init())
        }
    }

    @Test func aHoleFlightKeepsItsTimeThroughAFile() throws {
        let file = FlightFile(keys: [key(0, time: 100, eye: SIMD3(0, -30, 5)), key(4, time: 200)])
        let read = try FlightFile.decoded(from: file.encoded())
        #expect(read == file)
        #expect(String(decoding: try file.encoded(), as: UTF8.self).contains("\"time\""))
    }

    @Test func framesLandOnTheStepsOfTheFlightsTime() throws {
        // Time runs from 100 to 600 over 10 s, then holds for 5.
        let file = FlightFile(keys: [
            key(0, time: 100, eye: SIMD3(0, -40, 10)), key(10, time: 600, eye: SIMD3(0, -20, 2)),
            key(15, time: 600),
        ])
        let header = header()
        let flight = try HoleFlight.resolve(file, header: header, camera: .init())
        let plan = try HolePlan(flight: flight, framesPerSecond: 10)
        #expect(plan.frames == 151)
        func time(_ index: Int) -> Double {
            header.time(step: plan.steps[index]) + plan.fraction(index) * header.timeStep
        }
        #expect(header.time(step: plan.steps[0]) == 100)
        #expect(plan.fraction(0) == 0)
        #expect(abs(time(100) - 600) < 1e-6)
        #expect(Set(plan.steps[100...]).count == 1)
        #expect(plan.fractions.allSatisfy { (0..<1).contains($0) })
        // Slowing into the hold, time glides: it never runs back, and frames between two steps
        // are drawn there rather than on the step before.
        #expect((1..<plan.frames).allSatisfy { time($0) >= time($0 - 1) })
        #expect(plan.fractions[90..<100].contains { $0 > 0.01 })
        // The camera holds the last key that places it.
        let end = flight.camera(atSeconds: 15).camera
        #expect(simd_distance(end.eye, SIMD3<Float>(0, -20, 2)) < 1e-4)
        #expect(plan.seconds(150) == 15)
    }

    @Test func aFrozenFlightDrawsOneMoment() throws {
        let file = FlightFile(keys: [
            key(0, time: 3000, eye: SIMD3(-6, -44, 16)), key(6, time: 3000, eye: SIMD3(0, -14, 0)),
        ])
        let flight = try HoleFlight.resolve(file, header: header(), camera: .init())
        let plan = try HolePlan(flight: flight, framesPerSecond: 30)
        #expect(Set(plan.steps).count == 1)
        #expect(Set(plan.fractions).count == 1)
    }

    @Test func aMomentOutsideTheRunIsRefused() throws {
        let file = FlightFile(keys: [key(0, time: -100, eye: SIMD3(0, -30, 5)), key(4, time: 200)])
        #expect(throws: HoleFlight.Failure.self) {
            try HoleFlight.resolve(file, header: header(), camera: .init())
        }
    }

    @Test func aLookKeyTakesTheLooksCamera() throws {
        var camera = HoleLookFile.CameraPlan()
        camera.distance = 50
        camera.elevation = 10
        let file = FlightFile(keys: [
            FlightFile.Key(at: 0, time: 1000, look: true), key(5, time: 1000, eye: SIMD3(0, -20, 2)),
        ])
        let flight = try HoleFlight.resolve(file, header: header(), camera: camera)
        let start = flight.camera(atSeconds: 0).camera
        #expect(abs(simd_length(start.eye) - 50) < 1e-3)
        #expect(abs(start.eye.z - 50 * Float(sin(10 * Double.pi / 180))) < 1e-3)
    }

    @Test func theSamplesAreValidAndStayOutsideTheHole() throws {
        let header = header()
        #expect(HoleFlight.samples.map(\.name) == ["orbit", "descent", "plane"])
        for (name, file) in HoleFlight.samples {
            try file.validate()
            let flight = try HoleFlight.resolve(file, header: header, camera: .init())
            var nearest = Float.infinity
            for n in 0...Int(flight.seconds * 10) {
                let camera = flight.camera(atSeconds: Double(n) / 10).camera
                nearest = min(nearest, simd_length(camera.eye))
                #expect(simd_length(camera.target) < 1e-4, "\(name) looks at the hole")
            }
            #expect(nearest > 10, "\(name) comes \(nearest) r_s from the hole")
        }
        // The orbit keeps its distance between its keys.
        let orbit = try HoleFlight.resolve(HoleFlight.orbit, header: header, camera: .init())
        for n in 0...400 {
            let distance = simd_length(orbit.camera(atSeconds: Double(n) / 10).camera.eye)
            #expect(abs(distance - 35) < 0.35)
        }
        // The plane pass goes through the disk's plane inside the disk.
        let plane = try HoleFlight.resolve(HoleFlight.plane, header: header, camera: .init())
        let crossing = plane.camera(atSeconds: 12).camera.eye
        #expect(abs(crossing.z) < 1e-4)
        #expect(simd_length(crossing) < 20)
    }

    @Test func aNewFolderHoldsTheSamplesAndKeepsItsOwn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hole-\(UUID())/hole-0001", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let folder = SceneFolder(url)
        try FileManager.default.createDirectory(at: folder.flights, withIntermediateDirectories: true)
        let own = FlightFile(keys: [key(0, time: 1, eye: SIMD3(0, -30, 5)), key(4, time: 2)])
        try own.encoded().write(to: folder.flight("orbit"))
        try HoleFlight.writeSamples(in: folder)
        #expect(try FlightFile.decoded(from: Data(contentsOf: folder.flight("orbit"))) == own)
        #expect(try FlightFile.decoded(from: Data(contentsOf: folder.flight("plane"))) == HoleFlight.plane)
    }

    @Test func anExportTakesAFlightInsteadOfASpan() throws {
        let options = try HoleExportOptions(["--flight", "descent", "--fps", "60"])
        #expect(options.flight == "descent")
        for asked in [["--from", "100"], ["--to", "100"], ["--seconds", "10"]] {
            #expect(throws: SceneFolder.ExportError.self) {
                try HoleExportOptions(["--flight", "orbit"] + asked)
            }
        }
    }
}
