import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

@Suite("Black hole close up files")
struct HoleFilesTests {
    func temporaryFolder() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hole-\(UUID())/batch/hole-0001", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SceneFolder(url)
    }

    func header(tracers: Int = 2, steps: [Int] = [0, 1000, 1500]) -> HoleTakeFile.Header {
        var scene = TidalDisruption()
        scene.tracers = tracers
        return HoleTakeFile.Header(
            scene: HoleSceneFile(name: "test", blackHole: scene), tracers: tracers, releaseTime: -21.5,
            steps: steps)
    }

    @Test func aTakeReadsBackAsItWasWritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let header = header()
        let writer = try HoleTakeFile.Writer(header: header, to: folder.take)
        var frames: [TidalFrame] = []
        for (index, step) in header.steps.enumerated() {
            let base = Float(index)
            let frame = TidalFrame(
                time: header.time(step: step),
                positions: [SIMD4<Float>(base, 2, 3, 0.25), SIMD4<Float>(5, base, 7, 8)],
                velocities: [SIMD4<Float>(-1, -2, -3, -1), SIMD4<Float>(0, 0, base, 0.5)])
            try writer.append(frame)
            frames.append(frame)
        }
        try writer.finish()
        #expect(HoleTakeFile.isHoleTake(folder.take))
        let read = try HoleTakeFile.Loaded(contentsOf: folder.take)
        #expect(read.header == header)
        for index in frames.indices { #expect(read.frame(index) == frames[index]) }
        #expect(read.frame(1).time == -21.5 + 1000 * 0.25)
        #expect(read.frameIndex(before: 999) == 0)
        #expect(read.frameIndex(before: 1000) == 1)
        #expect(read.frameIndex(before: 4000) == 2)
    }

    @Test func aTakeCutShortIsRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let writer = try HoleTakeFile.Writer(header: header(steps: [0, 10]), to: folder.take)
        try writer.append(
            TidalFrame(time: 0, positions: [.zero, .zero], velocities: [.zero, .zero]))
        #expect(throws: HoleTakeFile.Failure.self) { try writer.finish() }
        #expect(throws: HoleTakeFile.Failure.self) { try HoleTakeFile.Loaded(contentsOf: folder.take) }
        #expect(throws: HoleTakeFile.Failure.self) {
            try writer.append(TidalFrame(time: 0, positions: [.zero], velocities: [.zero]))
        }
    }

    @Test func aTakeKeepsAFrameEveryIntervalAndTheLast() {
        var scene = TidalDisruption()
        scene.duration = 1000
        scene.frameInterval = 250
        let planned = HoleTakeFile.Header.planned(scene, releaseTime: -21)
        #expect(planned.total == 4084)
        #expect(planned.kept == [0, 1000, 2000, 3000, 4000, 4084])
    }

    @Test func aVideoLandsOnStepsOfTheRun() throws {
        let header = header(steps: [0, 1000, 2000])
        let whole = try HolePlan(header: header, seconds: 1, framesPerSecond: 5)
        #expect(whole.steps == [0, 500, 1000, 1500, 2000])
        #expect(whole.progress(4) == 1)
        let span = try HolePlan(header: header, from: 228.5, to: 1e9, seconds: 0.4, framesPerSecond: 5)
        #expect(span.steps == [1000, 2000])
        let frozen = try HolePlan(header: header, from: 100, to: 100, seconds: 0.6, framesPerSecond: 5)
        #expect(Set(frozen.steps) == [486])
        #expect(throws: HolePlan.Failure.self) {
            try HolePlan(header: header, from: 300, to: 100, seconds: 1, framesPerSecond: 5)
        }
    }

    /// The shipped looks are the built in ones, physics the default and film Interstellar's.
    @Test func theShippedLooksAreTheCatalogue() throws {
        let looks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("looks")
        for look in HoleLookFile.catalogue {
            let url = looks.appendingPathComponent("\(look.name).\(HoleLookFile.fileExtension)")
            #expect(try HoleLookFile.decoded(from: Data(contentsOf: url)) == look)
        }
        #expect(HoleLookFile.defaultName == "physics")
        #expect(HoleLookFile.physics.temperature == .crossing && HoleLookFile.physics.beaming == 1)
        #expect(HoleLookFile.film.temperature == .radius && HoleLookFile.film.beaming == 0)
        #expect(HoleLookFile.film.hottest == 6500)
    }

    @Test func aLookIsStrict() throws {
        var text = String(decoding: try HoleLookFile.physics.encoded(), as: UTF8.self)
        #expect(try HoleLookFile.decoded(from: Data(text.utf8)) == .physics)
        text = text.replacingOccurrences(of: "\"images\"", with: "\"imagez\"")
        #expect(throws: (any Error).self) { try HoleLookFile.decoded(from: Data(text.utf8)) }
        var look = HoleLookFile.film
        look.images = 4
        #expect(throws: HoleLookFile.ReadError.self) { try HoleLookFile.decoded(from: look.encoded()) }
        // Null holds no reference moment: each frame is normalised on its own.
        look = .film
        look.exposureAt = nil
        #expect(try HoleLookFile.decoded(from: look.encoded()).exposureAt == nil)
    }

    @Test func aCameraFliesInEvenlyInItsDistancesLogarithm() throws {
        var look = HoleLookFile.physics
        look.camera.distance = 200
        look.camera.toDistance = 20
        let read = try HoleLookFile.decoded(from: look.encoded())
        #expect(read.camera.toDistance == 20)
        #expect(read.camera.distance(progress: 0) == 200)
        #expect(abs(read.camera.distance(progress: 1) - 20) < 1e-9)
        #expect(abs(read.camera.distance(progress: 0.5) - 200 * 0.1.squareRoot()) < 1e-9)
        let distances = (0...100).map { read.camera.distance(progress: Double($0) / 100) }
        #expect(zip(distances, distances.dropFirst()).allSatisfy { $0 > $1 })
        let eye = read.camera.camera(progress: 0.5).eye
        let length = (eye.x * eye.x + eye.y * eye.y + eye.z * eye.z).squareRoot()
        #expect(abs(length - Float(200 * 0.1.squareRoot())) < 1e-3)
        look.camera.toDistance = 1
        #expect(throws: HoleLookFile.ReadError.self) { try HoleLookFile.decoded(from: look.encoded()) }
        look.thinning = -1
        look.camera.toDistance = nil
        #expect(throws: HoleLookFile.ReadError.self) { try HoleLookFile.decoded(from: look.encoded()) }
    }

    @Test func aFolderDrawsWithItsLookElsePhysics() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        #expect(!folder.isBlackHole)
        try folder.create(HoleSceneFile(name: "close up", blackHole: TidalDisruption()))
        #expect(folder.isBlackHole)
        #expect(try folder.holeScene().blackHole == TidalDisruption())
        #expect(try folder.holeLook(nil) == .physics)
        #expect(try folder.holeLook("film") == .film)
        var kept = HoleLookFile.film
        kept.name = "gold"
        kept.hottest = 5000
        try FileManager.default.createDirectory(at: folder.looks, withIntermediateDirectories: true)
        try kept.encoded().write(to: folder.holeLookFile(named: "gold"))
        #expect(try folder.holeLook("gold") == kept)
        try kept.encoded().write(to: folder.look)
        #expect(try folder.holeLook(nil) == kept)
        #expect(throws: SceneFolder.HoleError.self) { try folder.holeLook("hubble") }
    }

    @Test func anExportRefusesWhatIsForGalaxies() throws {
        let options = try HoleExportOptions([
            "--preset", "4k", "--look", "film", "--from", "500", "--seconds", "10",
        ])
        #expect(options.preset.name == "4k")
        #expect(options.look == "film")
        #expect(options.from == 500)
        #expect(options.seconds == 10)
        #expect(throws: SceneFolder.ExportError.self) { try HoleExportOptions(["--speed", "2"]) }
        #expect(throws: SceneFolder.ExportError.self) { try HoleExportOptions(["--preset", "8k"]) }
        #expect(throws: SceneFolder.ExportError.self) { try HoleExportOptions(["--seconds", "0"]) }
    }
}
