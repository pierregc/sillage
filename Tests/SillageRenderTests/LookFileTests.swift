import Foundation
import Testing
import simd

@testable import SillageRender

@Suite("Look file")
struct LookFileTests {
    private func decoded(_ json: String) throws -> LookFile {
        try LookFile.decoded(from: Data(json.utf8))
    }

    @Test func anEmptyFileIsTheStandardLook() throws {
        #expect(try decoded(#"{"version": 1}"#) == .standard)
        #expect(try decoded(#"{"version": 1, "look": {}, "camera": {}}"#) == .standard)
    }

    @Test func aFileChangesOnlyWhatItNames() throws {
        var expected = LookFile.standard
        expected.look.brightness = 0.3
        expected.camera.azimuthEnd = 2
        #expect(
            try decoded(#"{"version": 1, "look": {"brightness": 0.3}, "camera": {"azimuthEnd": 2}}"#)
                == expected)
    }

    @Test func readingThenWritingGivesAnIdenticalFile() throws {
        var file = LookFile.raw
        file.camera = .init(
            mode: .immersed, elevation: 0.4, elevationEnd: 0.9, azimuth: 1, azimuthEnd: 3,
            zoom: 1.3, percentile: 0.9, radius: 80)
        for look in [LookFile.standard, .raw, file] {
            let written = try look.encoded()
            #expect(try LookFile.decoded(from: written) == look)
            #expect(try LookFile.decoded(from: written).encoded() == written)
        }
    }

    @Test func aMisspeltFieldOrAnUnknownVersionIsRefused() throws {
        #expect(throws: DecodingError.self) { try decoded(#"{"version": 1, "brigthness": 1}"#) }
        #expect(throws: DecodingError.self) {
            try decoded(#"{"version": 1, "look": {"brigthness": 1}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decoded(#"{"version": 1, "camera": {"mode": "spinning"}}"#)
        }
        #expect(throws: DecodingError.self) { try decoded(#"{"look": {}}"#) }
        #expect(throws: LookFile.ReadError.self) { try decoded(#"{"version": 2}"#) }
    }

    /// A field added to the look cannot be silently left out of the file that replays it.
    @Test func everyFieldOfTheLookIsWritten() throws {
        func keys(_ data: Data) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        }
        func fields(_ value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
        let file = LookFile.raw
        #expect(try keys(JSONEncoder().encode(file.look)) == fields(file.look))
        #expect(try keys(file.encoded()) == fields(file))
    }

    @Test func theShippedRawFileIsTheRawLook() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("looks/raw.look.json")
        let raw = try LookFile.decoded(from: Data(contentsOf: url))
        #expect(raw == .raw)
        #expect(raw.look.bloomIntensity == 0 && raw.look.spikeIntensity == 0)
        #expect(raw.look.dustStrength == 0 && raw.look.skyLevel == 0 && raw.look.noiseLevel == 0)
        #expect(raw.starCount == 0 && raw.armStrength == 0 && raw.camera.mode == .auto && raw.plain)
        #expect(raw.look.minimumKernel == raw.look.maximumKernel)
    }

    /// What the director writes is enough to begin the same scene again and get every frame
    /// back, including a look it picked itself.
    @Test(arguments: [false, true])
    func theDirectorWritesWhatItPicked(immersed: Bool) throws {
        let subject = Subject(centres: [SIMD3(-30, 0, 0), SIMD3(30, 6, -4)], radius: 46)
        let first = Cinematographer(seed: 11)
        first.beginScene(seed: 11, immersed: immersed)
        let file = try LookFile.decoded(from: first.lookFile().encoded())
        #expect(RenderLook.all.contains(file.look))
        #expect(file.camera.mode == (immersed ? .immersed : .director))

        let second = Cinematographer(seed: 11)
        second.beginScene(seed: 11, base: file.look, immersed: file.camera.mode == .immersed)
        for _ in 0..<600 {
            first.advance(seconds: 1.0 / 30, of: subject)
            second.advance(seconds: 1.0 / 30, of: subject)
            #expect(first.look == second.look)
            #expect(first.camera.eye == second.camera.eye)
            #expect(first.camera.target == second.camera.target)
        }
    }
}
