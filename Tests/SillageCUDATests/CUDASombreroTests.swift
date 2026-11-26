import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

/// What the Sombrero film draws on CUDA (#513), on the CPU target at small sizes: the deep sky
/// behind the dust (#512), the look's dust reddening and dither, the bloom's share of the point
/// stars and of the sky (#509, #510), the held kernel lengths, and the dust screen refused by
/// name. The fixture's frames are held to Metal's once the Mac has written them.
@Suite("CUDA engine, the Sombrero film")
struct CUDASombreroTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/sombrero")

    static func fixture() throws -> SombreroFixture { try SombreroFixture.load(from: folder) }

    static func look(_ change: (inout LookFile) -> Void = { _ in }) throws -> LookFile {
        let fixture = try fixture()
        var look = try LookFile.decoded(from: Data(contentsOf: fixture.url(fixture.look)))
        change(&look)
        return look
    }

    static func stills(_ look: LookFile, flight: URL? = nil, take: RecordingFile.Loaded? = nil) throws
        -> CUDATakeStills
    {
        let fixture = try fixture()
        return try CUDATakeStills(
            context: CUDAContext(), take: take ?? RecordingFile.read(from: fixture.url(fixture.take)),
            look: look, capturedRate: fixture.framesPerSecond, width: fixture.width, height: fixture.height,
            flight: try flight.map { try FlightFile.decoded(from: Data(contentsOf: $0)) })
    }

    /// The take's still through the look's camera, and its linear light.
    static func still(_ look: LookFile) throws -> (picture: [UInt8], light: [Float]) {
        let stills = try stills(look)
        return try withExtendedLifetime(stills) {
            let picture = [UInt8](try stills.still(atCaptured: 0, frame: 0, format: .rgba, threads: 4))
            return (picture, try stills.renderer.target(.light))
        }
    }

    static func flightStill(_ stills: CUDATakeStills, _ frame: SombreroFixture.Frame, rate: Int) throws
        -> [UInt8]
    {
        try withExtendedLifetime(stills) {
            [UInt8](
                try stills.flightStill(
                    atSeconds: frame.seconds, frame: Int((frame.seconds * Double(rate)).rounded()),
                    interval: 1 / Double(rate), format: .rgb, threads: 4))
        }
    }

    static func work() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sombrero-\(UUID().uuidString)")
    }

    @Test func theSkyAddsLightBehindTheDustAndNoneAtZeroBrightness() throws {
        let without = try Self.still(try Self.look { $0.sky = nil })
        let with = try Self.still(try Self.look())
        let dark = try Self.still(try Self.look { $0.sky?.brightness = 0 })
        #expect(dark.light == without.light, "a sky of no brightness changes the light")
        #expect(dark.picture == without.picture, "a sky of no brightness changes the picture")
        var lower = 0
        var lit = 0
        for (a, b) in zip(with.light, without.light) {
            if a < b { lower += 1 }
            if a > b { lit += 1 }
        }
        print("CUDASOMBRERO the sky lights \(lit) of \(with.light.count) values")
        #expect(lower == 0, "the sky takes light away somewhere")
        #expect(lit > 0, "the sky adds no light")
    }

    @Test func theDustReddensAsTheLookSays() throws {
        let plain = try Self.still(try Self.look { $0.look.dustReddening = 1 })
        let asIs = try Self.still(
            try Self.look {
                $0.look.dustReddening = 1
                $0.sky = nil
            })
        let browner = try Self.still(
            try Self.look {
                $0.look.dustReddening = 2.5
                $0.sky = nil
            })
        #expect(plain.light != asIs.light, "the fixture's sky is not drawn")
        #expect(browner.light != asIs.light, "the look's dust reddening changes nothing")
        // Above one the dust takes more of the blue than of the red: the light it leaves is redder.
        let ratio = { (light: [Float]) -> Double in
            var red = 0.0
            var blue = 0.0
            for index in stride(from: 0, to: light.count, by: 4) {
                red += Double(light[index])
                blue += Double(light[index + 2])
            }
            return red / max(blue, 1e-30)
        }
        #expect(ratio(browner.light) > ratio(asIs.light), "browner lanes are not redder")
    }

    @Test func theDitherIsWithinItsStepsAndNoneAtZero() throws {
        let plain = try Self.still(try Self.look { $0.dither = nil })
        let zero = try Self.still(try Self.look { $0.dither = 0 })
        let dithered = try Self.still(try Self.look { $0.dither = 2 })
        #expect(zero.picture == plain.picture, "a dither of zero changes the picture")
        #expect(dithered.light == plain.light, "the dither reaches the light")
        let widest = zip(dithered.picture, plain.picture).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(dithered.picture != plain.picture, "a dither of two steps changes nothing")
        #expect(widest <= 3, "the dither moves a pixel by \(widest) levels")
    }

    /// From inside, a share of the point stars' light, and of the sky's, just under one resolves
    /// what the bloom sees apart, and gives the frame drawn without the split within a level.
    @Test func theBloomsSharesAddUpToTheWholeFrame() throws {
        let fixture = try Self.fixture()
        let work = Self.work()
        defer { try? FileManager.default.removeItem(at: work) }
        let frame = fixture.frames[2]
        func picture(starBloom: Float, skyBloom: Float) throws -> [UInt8] {
            let source = try FlightFile.decoded(
                from: Data(contentsOf: fixture.flight(frame.flight, into: work)))
            var flight = source
            flight.inside?.starBloom = starBloom
            let url = work.appendingPathComponent("bloom-\(starBloom)-\(skyBloom).flight.json")
            try JSONEncoder().encode(flight).write(to: url)
            let stills = try Self.stills(try Self.look { $0.sky?.bloom = skyBloom }, flight: url)
            return try Self.flightStill(stills, frame, rate: fixture.framesPerSecond)
        }
        let whole = try picture(starBloom: 1, skyBloom: 1)
        let split = try picture(starBloom: 0.999_999, skyBloom: 0.999_999)
        let kept = try picture(starBloom: 0.12, skyBloom: 0)
        let widest = zip(whole, split).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(widest <= 1, "the bloom's shares do not add up to the frame: \(widest) levels apart")
        #expect(kept != whole, "the bloom's shares change nothing")
    }

    /// Held lengths (#510): every frame takes the lengths of one captured frame, so a frame there
    /// is drawn as without them and a frame elsewhere is not.
    @Test func aFlightHoldsTheLengthsOfOneFrame() throws {
        let work = Self.work()
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        try FileManager.default.copyItem(
            at: fixture.url(fixture.take), to: work.appendingPathComponent("take.sillage"))
        let (take, megayears) = try CUDAFlightExportTests.run(in: work, frames: 4)
        func flight(held: Double?) throws -> URL {
            let heldText = held.map { #", "heldLengths": \#($0)"# } ?? ""
            let text = """
                {"version": 1, "near": 0.001,
                 "inside": {"stars": 16, "exposure": 0, "subframes": 1, "clusters": 0\(heldText)},
                 "keys": [
                   {"at": 0, "myr": \(megayears[0]), "eye": {"galaxy": 0, "offset": [3, -6, 4], "disk": true}, "aim": {"galaxy": 0}},
                   {"at": 3, "myr": \(megayears[3]), "eye": {"galaxy": 0, "offset": [2, -4, 2], "disk": true}, "aim": {"galaxy": 0}}
                 ]}
                """
            let url = work.appendingPathComponent("held-\(held.map { "\($0)" } ?? "none").flight.json")
            try Data(text.utf8).write(to: url)
            return url
        }
        func picture(_ url: URL, at seconds: Double) throws -> [UInt8] {
            let stills = try Self.stills(try Self.look { $0.sky = nil }, flight: url, take: take)
            return try Self.flightStill(
                stills, SombreroFixture.Frame(flight: "", seconds: seconds, file: "", what: ""), rate: 30)
        }
        let eased = try flight(held: nil)
        let held = try flight(held: megayears[0])
        #expect(try picture(held, at: 0) == picture(eased, at: 0), "held at its own frame, the frame changes")
        #expect(try picture(held, at: 2.5) != picture(eased, at: 2.5), "the lengths are not held")
    }

    @Test func aFlightWithTheDustScreenIsRefusedByName() throws {
        let fixture = try Self.fixture()
        let work = Self.work()
        defer { try? FileManager.default.removeItem(at: work) }
        let screen = try fixture.flight("screen.flight.json", into: work)
        #expect(CUDATakeStills.notDrawn(try FlightFile.decoded(from: Data(contentsOf: screen))) != nil)
        do {
            _ = try Self.stills(try Self.look(), flight: screen)
            Issue.record("a flight with a dust screen was not refused")
        } catch {
            #expect("\(error)".contains("inside.dustScreen"), "\(error)")
        }
        let plain = try fixture.flight("sombrero.flight.json", into: work)
        #expect(CUDATakeStills.notDrawn(try FlightFile.decoded(from: Data(contentsOf: plain))) == nil)
    }

    /// The fixture's frames, within the tolerance `sillage-cuda check` holds the inside frames to,
    /// once Metal's are written; until then each is drawn, and the test says it waits for them.
    @Test(arguments: [0, 1, 2])
    func theFramesAreMetalsWithinTheTolerance(index: Int) throws {
        let fixture = try Self.fixture()
        let frame = fixture.frames[index]
        let work = Self.work()
        defer { try? FileManager.default.removeItem(at: work) }
        let stills = try Self.stills(try Self.look(), flight: fixture.flight(frame.flight, into: work))
        let drawn = try Self.flightStill(stills, frame, rate: fixture.framesPerSecond)
        #expect(drawn.count == fixture.width * fixture.height * 3)
        #expect(drawn.contains { $0 > 32 }, "\(frame.file): a black frame checks nothing")
        #expect(
            drawn.filter { $0 == 255 }.count < drawn.count / 10, "\(frame.file): a white frame checks nothing"
        )
        guard let reference = try? Data(contentsOf: fixture.url(frame.file)) else {
            print(
                "CUDASOMBRERO waiting for Metal's \(frame.file) (\(frame.what)): run on the Mac "
                    + SombreroFixture.command)
            return
        }
        let measure = CUDAStillChecks.measure(drawn, channels: 3, [UInt8](reference), channels: 4)
        let tolerance = CUDAEngineCheck.insideTolerance
        print("CUDASOMBRERO", frame.file, measure)
        #expect(measure.psnr >= tolerance.psnr, "\(measure)")
        #expect(measure.largest <= tolerance.largest, "\(measure)")
        #expect(measure.overEight <= tolerance.overEight, "\(measure)")
        #expect(abs(measure.meanA - measure.meanB) < tolerance.mean, "the exposure moved")
    }
}
