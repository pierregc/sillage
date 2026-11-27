import Foundation
import Testing

@testable import SillageRender

/// Metal's frames of the Sombrero fixture (#513), which `CUDASombreroTests` holds the CUDA engine
/// to on Linux. With `SILLAGE_WRITE_SOMBRERO=1` it writes them (`SombreroFixture.command`); once
/// they are there, it holds Metal to them to the bit, as `EngineFixtureTests` does its own.
@Suite("Sombrero fixture, Metal")
struct SombreroFixtureTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/sombrero")

    @Test func metalDrawsTheSombreroFrames() throws {
        let fixture = try SombreroFixture.load(from: Self.folder)
        #expect(fixture.width == EngineFixtures.insideWidth && fixture.height == EngineFixtures.insideHeight)
        #expect(fixture.framesPerSecond == EngineFixtures.insideRate)
        let writing = ProcessInfo.processInfo.environment["SILLAGE_WRITE_SOMBRERO"] == "1"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sombrero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        for frame in fixture.frames {
            let drawn = try EngineFixtures.insideFrame(
                take: fixture.url(fixture.take), look: fixture.url(fixture.look),
                flight: fixture.flight(frame.flight, into: work), seconds: frame.seconds)
            #expect(drawn.count == fixture.width * fixture.height * 4)
            #expect(drawn.contains { $0 > 32 }, "\(frame.file): a black frame checks nothing")
            let white = drawn.enumerated().filter { $0.offset % 4 != 3 && $0.element == 255 }.count
            #expect(white < drawn.count * 3 / 40, "\(frame.file): a white frame checks nothing")
            let reference = fixture.url(frame.file)
            if writing {
                try drawn.write(to: reference)
                print("SOMBRERO wrote \(reference.path)")
            } else if let expected = try? Data(contentsOf: reference) {
                let differing = zip(drawn, expected).filter { $0 != $1 }.count
                #expect(
                    drawn.count == expected.count && differing == 0,
                    "\(frame.file): \(differing) bytes differ; if the change is meant, \(SombreroFixture.command)"
                )
            } else {
                print("SOMBRERO \(frame.file) is not written yet: \(SombreroFixture.command)")
            }
        }
    }
}
