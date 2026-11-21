import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

/// A take's video on CUDA without a flight (#429), `sillage-cuda export` with the look's camera
/// along a time track, on a run of eight captured frames made from the fixture every engine is
/// checked on, turning a little each frame.
/// Serialized: the videos go through ffmpeg.
@Suite("CUDA take export", .serialized)
struct CUDATakeExportTests {
    static let (width, height, fps) = (64, 36, 30)

    /// The fixture's look with the director's plan, and with an exposure of its own when asked.
    static func look(in folder: URL, measured: Bool = false) throws -> URL {
        let fixture = CUDAFlightExportTests.look
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        var camera = json["camera"] as? [String: Any] ?? [:]
        camera["mode"] = "director"
        json["camera"] = camera
        json["name"] = measured ? "measured" : "directed"
        if measured { json["exposure"] = ["median": 0.47, "top": 0.93] }
        let url = folder.appendingPathComponent("\(json["name"]!).look.json")
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    @discardableResult
    static func export(
        _ folder: URL, look: URL, out: String = "take.mp4", _ more: [String] = [], context: CUDAContext,
        stop: ((Int) -> Bool)? = nil
    ) throws -> CUDAExport.Report {
        try CUDAExport.run(
            folder.appendingPathComponent("run.sillage").path,
            options: more + [
                "--look", look.path, "--rate", "30", "--width", String(width), "--height", String(height),
                "--fps", String(fps), "--segment-frames", "2", "--out",
                folder.appendingPathComponent(out).path,
            ], context: context, threads: 4, laceTexels: 256, stop: stop)
    }

    /// Every frame of the take's video is the still `sillage-cuda still --frames` draws at that
    /// frame: the camera of the director's plan, the take's moment and the grain of the frame.
    @Test func everyFrameOfATakesVideoIsItsStill() throws {
        let context = try CUDAContext()
        let folder = try CUDAFlightExportTests.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = try CUDAFlightExportTests.run(in: folder, frames: 8).take
        let look = try Self.look(in: folder)
        let report = try Self.export(folder, look: look, ["--segment-frames", "1"], context: context)
        let file = try CUDAExport.look(look.path, folder: SceneFolder(folder), take: take)
        let planned = try TakeFrames(
            take: take, look: file, capturedRate: 30, width: Self.width, height: Self.height)
        let frames = planned.videoFrames(framesPerSecond: Self.fps)
        #expect(report.joined && report.frames == frames.count && report.frames == 8)
        #expect(report.exposure?.scale == nil && report.exposure?.trims == nil)
        #expect(try FFmpegVideo.frameCount(report.out) == frames.count)
        let stills = try CUDATakeStills(
            context: context, take: take, look: file, capturedRate: 30, width: Self.width,
            height: Self.height, laceTexels: 256)
        try withExtendedLifetime(stills) {
            for (index, frame) in frames.enumerated() {
                #expect(stills.position(ofFrame: index, framesPerSecond: Self.fps) == frame.captured)
                let drawn = [UInt8](try stills.still(atCaptured: frame.captured, frame: index, threads: 4))
                #expect(CUDAExport.digest(Data(drawn)) == report.pixels[index], "frame \(index)")
            }
        }
    }

    /// Drawn in one go, stopped after a segment and resumed, or split in two parts: the same
    /// frames and the same file, the look's exposure measured once over the video and kept.
    @Test func aTakesVideoStoppedResumedOrSplitIsTheSameVideo() throws {
        let context = try CUDAContext()
        let folder = try CUDAFlightExportTests.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try CUDAFlightExportTests.run(in: folder, frames: 8).take
        let look = try Self.look(in: folder, measured: true)
        let whole = try Self.export(folder, look: look, out: "whole.mp4", context: context)
        #expect(whole.joined && whole.segments == 4)
        #expect(whole.exposure?.scale != nil && whole.exposure?.target == 0)
        let stopped = try Self.export(folder, look: look, out: "stopped.mp4", context: context) { $0 == 1 }
        #expect(!stopped.joined && stopped.segmentsDone == 1)
        let resumed = try Self.export(folder, look: look, out: "stopped.mp4", ["--resume"], context: context)
        #expect(resumed.joined && resumed.pixels == whole.pixels && resumed.exposure == whole.exposure)
        #expect(try Data(contentsOf: resumed.out) == Data(contentsOf: whole.out))
        _ = try Self.export(folder, look: look, out: "parts.mp4", ["--part", "1/2"], context: context)
        let even = try Self.export(folder, look: look, out: "parts.mp4", ["--part", "2/2"], context: context)
        #expect(even.joined && even.pixels == whole.pixels)
        #expect(try CUDAFlightExportTests.decoded(even.out) == CUDAFlightExportTests.decoded(whole.out))
    }

    /// `--speed`: the video along a time track, the track written beside it; what goes with a
    /// flight or with a pace alone is refused.
    @Test func aSpeedDrawsTheVideoAlongItsTrack() throws {
        let context = try CUDAContext()
        let folder = try CUDAFlightExportTests.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try CUDAFlightExportTests.run(in: folder, frames: 8).take
        let look = try Self.look(in: folder)
        let plain = try Self.export(folder, look: look, out: "plain.mp4", context: context)
        let fast = try Self.export(folder, look: look, out: "fast.mp4", ["--speed", "2"], context: context)
        #expect(plain.frames == 8 && fast.joined && fast.frames == 4)
        let track = folder.appendingPathComponent("fast.\(TimeTrackFile.fileExtension)")
        #expect(try TimeTrackFile.decoded(from: Data(contentsOf: track)).speed == 2)
        let again = try Self.export(
            folder, look: look, out: "again.mp4", ["--speed", track.path], context: context)
        #expect(again.pixels == fast.pixels)

        let flight = try CUDAFlightExportTests.shortFlight(in: folder, exposure: 0)
        #expect(throws: SceneFolder.ExportError.self) {
            try Self.export(folder, look: look, ["--speed", "2", "--flight", flight.path], context: context)
        }
        #expect(throws: SceneFolder.ExportError.self) {
            try Self.export(folder, look: look, ["--speed", "2", "--slow", "0:5:0.5"], context: context)
        }
        #expect(throws: SceneFolder.ExportError.self) {
            try Self.export(folder, look: look, ["--speed", "visual"], context: context)
        }
        #expect(throws: SceneFolder.ExportError.self) {
            try Self.export(folder, look: look, ["--flight-keys", folder.path], context: context)
        }
    }
}
