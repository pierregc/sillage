import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// Key frames kept where asked by a full pass, and a visit drawn from them (#379), on Metal.
/// Serialized: the runs share the solver's global settings and the GPU.
@Suite("Visits drawn from key frames", .serialized)
struct KeyFrameVisitTests {
    private func entries(_ url: URL) throws -> [KeyFrameEntry] {
        try JSONDecoder().decode([KeyFrameEntry].self, from: Data(contentsOf: url))
    }

    private func flight(_ keys: [(at: Double, myr: Double, eye: SIMD3<Double>)]) -> FlightFile {
        var inside = InsideSettings()
        inside.exposure = 0
        inside.subframes = 1
        return FlightFile(
            inside: inside,
            keys: keys.enumerated().map { index, key in
                index == 0
                    ? .init(
                        at: key.at, myr: key.myr, eye: .world(key.eye),
                        aim: .galaxy(0, offset: .zero, disk: false))
                    : .init(at: key.at, myr: key.myr, eye: .world(key.eye))
            })
    }

    @Test func keyFramesAskedForSurviveAResumeAndAVisitIsDrawnFromThem() throws {
        let straight = try FullPassTrackTests.massivePass(frames: 16)
        defer { try? FileManager.default.removeItem(at: straight.batch.deletingLastPathComponent()) }
        let stopped = try FullPassTrackTests.copy(straight)
        let early = try FullPassTrackTests.copy(straight)
        let massive = try RecordingFile.read(from: straight.take)
        let megayears = TimeTrack.megayears(of: massive.recording)
        let options = ["--checkpoint-frames", "3", "--checkpoint-steps", "5"]
        let asked = [
            "--key-frames-at", String(format: "%.6f,%.6f", megayears[1], megayears[13] + 0.01),
            "--key-frames-span", "3",
        ]
        try FullPassTrackTests.fullPass(straight, frames: 16, options: options + asked)
        let kept = try entries(straight.keyFrameList)
        // The middle frame, as without curves, and the two spans asked for.
        #expect(kept.map(\.frame) == [1, 2, 3, 8, 13, 14, 15])
        #expect(kept.filter { $0.role == "chosen" }.map(\.frame) == [1, 2, 3, 13, 14, 15])
        #expect(try straight.storedHires()?.full?.keyFrames == [1, 2, 3, 8, 13, 14, 15])

        // Stopped after a checkpoint and resumed: the same frames, to the byte.
        #expect(throws: FullPassRun.Failure.self) {
            try FullPassTrackTests.fullPass(stopped, frames: 16, options: options + asked) {
                frame, checkpoints in
                checkpoints >= 1 && frame == 7
            }
        }
        try FullPassTrackTests.fullPass(stopped, frames: 16, options: options + asked + ["--resume"])
        #expect(try Data(contentsOf: straight.keyFrameList) == Data(contentsOf: stopped.keyFrameList))
        #expect(try Data(contentsOf: straight.keyFrames) == Data(contentsOf: stopped.keyFrames))
        #expect(throws: SceneFolder.HiresError.self) {
            try straight.hiresArguments(
                ["--particles", "3000", "--massive", "1500", "--pass", "massive"] + asked,
                maximumParticles: 1_000_000_000)
        }

        // Cut short once the first span is kept: the same frames as the whole run's, to the byte,
        // and no video.
        try FullPassTrackTests.fullPass(
            early, frames: 16,
            options: [
                "--checkpoint-every", "0", "--key-frames-at", String(format: "%.6f", megayears[1]),
                "--key-frames-span", "3", "--stop-after-key-frames",
            ])
        #expect(try entries(early.keyFrameList).map(\.frame) == [1, 2, 3])
        let span = straight.url.appendingPathComponent("span.sillage")
        _ = try TakeExtract.command([
            "extract", straight.keyFrames.path, "--at", "\(megayears[1])", "--span", "3", span.path,
        ])
        #expect(try Data(contentsOf: span) == Data(contentsOf: early.keyFrames))
        #expect(try early.storedHires()?.full == nil)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: early.exports.path)) ?? []
        #expect(left.isEmpty, "\(left)")

        let keyFrames = try RecordingFile.read(from: straight.keyFrames)
        let look = try LookFile.decoded(from: Data(contentsOf: straight.look))
        func export(_ flight: FlightFile, take: RecordingFile.Loaded = keyFrames) throws -> TakeExport {
            try TakeExport(take: take, look: look, capturedRate: 6, framing: massive, flight: flight)
        }
        // Frozen on the middle frame while the camera comes in: one expansion of the take.
        let frozen = try export(
            flight([(0, megayears[8], SIMD3(0, -80, 30)), (1, megayears[8], SIMD3(0, -20, 8))]))
        #expect(frozen.held?.runs.count == 3)
        let still = try frozen.frames(width: 64, height: 36, framesPerSecond: 6)
        #expect(still.count == 7 && frozen.expansions == 1 && Set(still).count > 1)
        // The same frame cut out of the key frames on its own draws the same pictures.
        let alone = straight.url.appendingPathComponent("middle.sillage")
        _ = try TakeExtract.command([
            "extract", straight.keyFrames.path, "--at", "\(megayears[8])", alone.path,
        ])
        let cut = try export(
            flight([(0, megayears[8], SIMD3(0, -80, 30)), (1, megayears[8], SIMD3(0, -20, 8))]),
            take: RecordingFile.read(from: alone))
        #expect(try cut.frames(width: 64, height: 36, framesPerSecond: 6) == still)

        // Slow: time flows through the three frames of the last span, between them on the way.
        let slow = try export(
            flight([(0, megayears[13], SIMD3(0, -80, 30)), (2, megayears[15], SIMD3(0, -20, 8))]))
        let positions = slow.positions(framesPerSecond: 6, start: 0, duration: nil)
        #expect(positions.contains { $0 != $0.rounded() })
        let flowing = try slow.frames(width: 64, height: 36, framesPerSecond: 6)
        #expect(flowing.count == 13 && slow.expansions == Set(positions).count)

        // A time that leaves the frames held is refused with what is there, before any frame.
        do {
            _ = try export(
                flight([(0, megayears[3], SIMD3(0, -80, 30)), (1, megayears[8], SIMD3(0, -20, 8))]))
            Issue.record("a flight between two spans was taken")
        } catch let failure as HeldFrames.Failure {
            #expect(failure.description.contains("(3 frames)"))
        }
        #expect(throws: TakeExport.Failure.self) {
            try TakeExport(take: keyFrames, look: look, capturedRate: 6, framing: massive)
        }
    }
}
