import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

private let onAGPU = CUDAContext.runsEveryKernel
/// A take of millions of particles with a flight inside one of its arms and its look, on the
/// box: `SILLAGE_CUDA_FLIGHT=<take>,<look>,<flight>[,<framing take>]`.
private let rentedFlight = ProcessInfo.processInfo.environment["SILLAGE_CUDA_FLIGHT"]
private let needsARentedFlight: Comment =
    "needs an NVIDIA GPU, libsillagecuda.a and SILLAGE_CUDA_FLIGHT=<take>,<look>,<flight>: #424 runs it"

/// A flight's video on CUDA (#382), `sillage-cuda export`, on the fixture every engine is
/// checked on: the take of `Tests/Fixtures/engines/frames` and its flight from the whole galaxy
/// to the inside of its disk.
/// Serialized: the videos go through ffmpeg.
@Suite("CUDA flight export", .serialized)
struct CUDAFlightExportTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/frames")
    static let look = fixtures.appendingPathComponent("webb.look.json")
    static let (width, height, fps) = (64, 36, 2)

    /// A folder that holds the fixture's take and nothing else, as a box holds a take alone.
    static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "flight-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("take.sillage"),
            to: url.appendingPathComponent("take.sillage"))
        return url
    }

    /// The fixture's flight in two seconds, with fewer point stars and renders a frame;
    /// `exposure` 0 turns the automatic exposure off, and `paced` times its second half by the
    /// distance to the nearest matter (#406).
    static func shortFlight(in folder: URL, exposure: Double = 0.16, paced: Bool = false) throws -> URL {
        let pace = paced ? #", "pace": "nearness""# : ""
        let text = """
            {
              "version": 1,
              "near": 0.001,
              "inside": {"stars": 16, "exposure": \(exposure), "subframes": 2, "clusters": 0},
              "keys": [
                {"at": 0, "myr": 12.388, "look": true},
                {"at": 1, "eye": {"galaxy": 0, "offset": [3, -6, 4], "disk": true}, "aim": {"galaxy": 0}\(pace)},
                {"at": 2, "myr": 12.388, "eye": {"galaxy": 0, "offset": [1.5, 0.5, 0.05], "disk": true},
                 "aim": {"galaxy": 0, "offset": [-2, 3, 0], "disk": true}}
              ]
            }
            """
        let name = "short-\(exposure > 0 ? "exposed" : "plain")\(paced ? "-paced" : "")"
        let url = folder.appendingPathComponent("\(name).flight.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    static func export(
        _ folder: URL, take: String = "take.sillage", flight: URL, out: String = "flight.mp4",
        _ more: [String] = [], context: CUDAContext, stop: ((Int) -> Bool)? = nil
    ) throws -> CUDAExport.Report {
        try CUDAExport.run(
            folder.appendingPathComponent(take).path,
            // The first of an option given twice is the one read: `more` goes before the rest.
            options: more + [
                "--look", look.path, "--flight", flight.path, "--rate", "30", "--width", String(width),
                "--height", String(height), "--fps", String(fps), "--segment-frames", "2", "--out",
                folder.appendingPathComponent(out).path,
            ], context: context, threads: 4, laceTexels: 256, stop: stop)
    }

    /// The stills of the same flight, as `sillage-cuda still --flight` draws them.
    static func stills(_ folder: URL, flight: URL, context: CUDAContext) throws -> CUDATakeStills {
        let take = try RecordingFile.read(from: folder.appendingPathComponent("take.sillage"))
        return try CUDATakeStills(
            context: context, take: take,
            look: CUDAExport.look(look.path, folder: SceneFolder(folder), take: take), capturedRate: 30,
            width: width, height: height, laceTexels: 256,
            flight: FlightFile.decoded(from: Data(contentsOf: flight)))
    }

    /// A still's bytes, copied while its stills are alive: the picture is in their memory.
    static func still(
        _ stills: CUDATakeStills, atSeconds seconds: Double, frame: Int, interval: Double = 0
    ) throws -> [UInt8] {
        try withExtendedLifetime(stills) {
            [UInt8](
                try stills.flightStill(
                    atSeconds: seconds, frame: frame, interval: interval, format: .rgb, threads: 4))
        }
    }

    static func decoded(_ url: URL) throws -> Data { try CUDAFullPassTests.decoded(url) }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - On the CPU target, in every check

    /// The fixture's flight as it is: every frame in the video, from the whole galaxy to the
    /// inside of its disk, the segments gone once joined, and the frame at its look key the
    /// still `sillage-cuda still --flight` draws there.
    @Test func theFixturesFlightExportsWithEveryFrame() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = Self.fixtures.appendingPathComponent("inside.flight.json")
        let kept = folder.appendingPathComponent("stills")
        let report = try Self.export(
            folder, flight: flight, ["--segment-frames", "4", "--stills", kept.path, "--still-frames", "0"],
            context: context)
        let out = folder.appendingPathComponent("flight.mp4")
        #expect(report.joined && report.out.path == out.path)
        #expect(report.frames == 9 && report.drawn == 9 && report.segments == 3 && report.segmentsDone == 3)
        #expect(try FFmpegVideo.frameCount(out) == 9)
        #expect(try Self.decoded(out).count == 9 * Self.width * Self.height * 3)
        #expect(!Self.exists(CUDAExport.segments(of: out)))
        // It ends inside the disk: the eye near matter, the frames averaged, the exposure held.
        #expect(report.inside.nearest < 1 && report.inside.mostRenders > 1 && report.inside.mostStars > 0)
        let trims = try #require(report.exposure?.trims)
        #expect(trims.stops.count == 17 && trims.deepest > 0 && report.inside.deepestTrim > 0)

        let first = try PNG.decode(Data(contentsOf: kept.appendingPathComponent("1080p-0000.png")))
        let drawn = try Self.still(
            Self.stills(folder, flight: flight, context: context), atSeconds: 0, frame: 0,
            interval: 1 / Double(Self.fps))
        #expect(first.bytes == drawn)
    }

    /// An export drawn in one go, one stopped after a segment and resumed, and one split in two
    /// parts are the same video: the frames as drawn, and the file ffmpeg leaves. A resume
    /// draws the missing segments alone, and refuses the segments of another export.
    @Test func anExportStoppedResumedOrSplitIsTheSameVideo() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder)

        let whole = try Self.export(folder, flight: flight, out: "whole.mp4", context: context)
        #expect(whole.joined && whole.frames == 5 && whole.segments == 3 && whole.pixels.count == 3)
        let video = try Data(contentsOf: whole.out)
        let frames = try Self.decoded(whole.out)

        let out = folder.appendingPathComponent("stopped.mp4")
        let stopped = try Self.export(folder, flight: flight, out: "stopped.mp4", context: context) {
            $0 == 1
        }
        #expect(!stopped.joined && stopped.segmentsDone == 1 && stopped.drawn == 2)
        #expect(!Self.exists(out))
        let work = CUDAExport.segments(of: out)
        #expect(Self.exists(work.appendingPathComponent("plan.json")))
        #expect(Self.exists(work.appendingPathComponent("segment-00000.mp4")))
        #expect(throws: CUDAExport.Failure.self) {
            try Self.export(
                folder, flight: flight, out: "stopped.mp4", ["--resume", "--fps", "4"], context: context)
        }
        let resumed = try Self.export(
            folder, flight: flight, out: "stopped.mp4", ["--resume"], context: context)
        #expect(resumed.joined && resumed.drawn == 3 && resumed.segmentsDone == 3)
        #expect(resumed.pixels == whole.pixels)
        #expect(resumed.exposure == whole.exposure)
        #expect(resumed.inside == whole.inside)
        #expect(try Self.decoded(out) == frames)
        #expect(try Data(contentsOf: out) == video)
        #expect(!Self.exists(work))
        // The same line once more, as a box that restarts runs it: the video is left alone.
        let settled = try Self.export(
            folder, flight: flight, out: "stopped.mp4", ["--resume"], context: context)
        #expect(settled.joined && settled.drawn == 0 && !Self.exists(work))
        #expect(try Data(contentsOf: out) == video)

        let odd = try Self.export(
            folder, flight: flight, out: "parts.mp4", ["--part", "1/2"], context: context)
        #expect(!odd.joined && odd.segmentsDone == 2 && odd.drawn == 3)
        let even = try Self.export(
            folder, flight: flight, out: "parts.mp4", ["--part", "2/2"], context: context)
        #expect(even.joined && even.drawn == 2 && even.pixels == whole.pixels)
        #expect(try Self.decoded(even.out) == frames)

        // Without --resume an export starts again over the segments left.
        let again = try Self.export(folder, flight: flight, out: "again.mp4", context: context) { $0 == 1 }
        #expect(again.segmentsDone == 1)
        let over = try Self.export(
            folder, flight: flight, out: "again.mp4", ["--start", "1"], context: context)
        #expect(over.joined && over.frames == 3 && over.drawn == 3)
    }

    /// With the automatic exposure off, nothing of a frame depends on the frames around it:
    /// every frame of the video is the still `sillage-cuda still --flight` draws at its second,
    /// at the keys and between them. With it on, a still takes the trim of its moment alone
    /// and the video eases the trims along the flight, so only the look keys are held equal.
    @Test func withoutTheAutomaticExposureEveryFrameIsItsStill() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder, exposure: 0)
        let report = try Self.export(folder, flight: flight, ["--segment-frames", "1"], context: context)
        #expect(report.joined && report.frames == 5 && report.pixels.count == 5)
        #expect(report.exposure?.trims == nil && report.exposure?.target == 0)
        let still = try Self.stills(folder, flight: flight, context: context)
        for frame in 0..<5 {
            let drawn = try Self.still(
                still, atSeconds: Double(frame) / Double(Self.fps), frame: frame,
                interval: 1 / Double(Self.fps))
            #expect(CUDAExport.digest(Data(drawn)) == report.pixels[frame], "frame \(frame)")
        }
        // A frozen moment is decoded once: the flight's time stands at the fixture's one frame.
        #expect(still.stagings == 1)
    }

    /// The large splats set aside for a block of threads, as a GPU draws a flight, leave the
    /// bits of the splats drawn each from its own thread.
    @Test func bothWaysForLargeSplatsDrawTheSameFrames() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder, exposure: 0)
        let span = ["--start", "1.5", "--duration", "0.5"]
        let first = try Self.export(
            folder, flight: flight, out: "first.mp4", span + ["--large-splats", "off"], context: context)
        let second = try Self.export(
            folder, flight: flight, out: "second.mp4", span + ["--large-splats", "64"], context: context)
        #expect(first.joined && second.joined && first.frames == 1)
        #expect(first.pixels == second.pixels)
    }

    /// The words over a video are the Mac's (#317): an export that asks for them is refused,
    /// and drawn without them when told to.
    @Test func anOverlayIsRefusedOrLeftOut() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder, exposure: 0)
        #expect(throws: CUDAExport.Failure.self) {
            try Self.export(folder, flight: flight, ["--overlay", "title"], context: context)
        }
        #expect(!Self.exists(folder.appendingPathComponent("flight.mp4")))
        let report = try Self.export(
            folder, flight: flight, ["--overlay", "title", "--no-overlay", "--duration", "0.5"],
            context: context)
        #expect(report.joined && report.frames == 1)
    }

    /// `--flight-keys`: the frame at every key, or at the seconds asked, as stills and no video.
    /// Each is the still of its moment, whatever was drawn before it.
    @Test func theKeysOfAFlightAreDrawnAsStills() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder)
        let keys = folder.appendingPathComponent("keys")
        let report = try Self.export(folder, flight: flight, ["--flight-keys", keys.path], context: context)
        #expect(
            report.keys.map(\.lastPathComponent) == [
                "key-00-000.00s.png", "key-01-001.00s.png", "key-02-002.00s.png",
            ])
        #expect(!Self.exists(folder.appendingPathComponent("flight.mp4")))
        #expect(!Self.exists(CUDAExport.segments(of: folder.appendingPathComponent("flight.mp4"))))
        let last = try PNG.decode(Data(contentsOf: report.keys[2]))
        #expect(last.width == Self.width && last.height == Self.height && last.channels == 3)
        let alone = try Self.still(
            Self.stills(folder, flight: flight, context: context), atSeconds: 2, frame: 2 * Self.fps)
        #expect(last.bytes == alone)

        let asked = try Self.export(
            folder, flight: flight, ["--flight-keys", keys.path, "--flight-at", "0.5,1.5"], context: context)
        #expect(asked.keys.map(\.lastPathComponent) == ["key-00-000.50s.png", "key-01-001.50s.png"])
    }

    /// A run of `frames` captured frames made of the fixture's one, its particles turning a
    /// little from each to the next, as `run.sillage`; megayears of each frame.
    static func run(in folder: URL, frames: Int) throws -> (take: RecordingFile.Loaded, megayears: [Double]) {
        let fixture = try RecordingFile.read(from: folder.appendingPathComponent("take.sillage"))
        let first = fixture.recording.positions(at: 0)
        let start = fixture.recording.frames[0].time
        let recording = Recording(
            particleCount: fixture.recording.particleCount, galaxyCount: fixture.recording.galaxyCount)
        for frame in 0..<frames {
            let angle = Float(frame) * 0.03
            let (c, s) = (Float(cos(Double(angle))), Float(sin(Double(angle))))
            let turned = first.map { SIMD3<Float>(c * $0.x - s * $0.y, s * $0.x + c * $0.y, $0.z) }
            turned.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: start + Float(frame) * 0.05,
                    centers: fixture.recording.centers(at: 0))
            }
        }
        let url = folder.appendingPathComponent("run.sillage")
        try RecordingFile.write(recording, scene: fixture.scene, particles: fixture.particles, to: url)
        let take = try RecordingFile.read(from: url)
        return (take, TimeTrack.megayears(of: take.recording))
    }

    /// A flight from outside the galaxy towards it, between two moments of a run.
    static func visit(in folder: URL, _ name: String, from: Double, to: Double) throws -> URL {
        var inside = InsideSettings()
        inside.exposure = 0
        inside.subframes = 1
        let file = FlightFile(
            inside: inside,
            keys: [
                .init(
                    at: 0, myr: from, eye: .world(SIMD3(0, -80, 30)),
                    aim: .galaxy(0, offset: .zero, disk: false)),
                .init(at: 1, myr: to, eye: .world(SIMD3(0, -20, 8))),
            ])
        let url = folder.appendingPathComponent("\(name).flight.json")
        try file.encoded().write(to: url)
        return url
    }

    /// A take that holds some moments of a run, an extract or key frames (#379), is drawn with
    /// `--framing` as the Mac draws it: a moment it holds is the picture the whole run gives,
    /// time flows between the frames of a span, and a flight that leaves them is refused before
    /// anything is drawn.
    @Test func aFlightIsDrawnFromTheFramesATakeHolds() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (run, megayears) = try Self.run(in: folder, frames: 6)
        try TakeExtract.write(run, frames: [3], to: folder.appendingPathComponent("one.sillage"))
        try TakeExtract.write(run, frames: [2, 3, 4], to: folder.appendingPathComponent("span.sillage"))
        let framing = [
            "--framing", folder.appendingPathComponent("run.sillage").path, "--segment-frames", "1",
        ]

        let frozen = try Self.visit(in: folder, "frozen", from: megayears[3], to: megayears[3])
        let whole = try Self.export(
            folder, take: "run.sillage", flight: frozen, out: "whole.mp4", ["--segment-frames", "1"],
            context: context)
        let held = try Self.export(
            folder, take: "one.sillage", flight: frozen, out: "held.mp4", framing, context: context)
        #expect(whole.joined && held.joined && whole.frames == 3)
        #expect(held.pixels == whole.pixels && Set(held.pixels).count == 3)

        let flowing = try Self.visit(in: folder, "flowing", from: megayears[2], to: megayears[4])
        let span = try Self.export(
            folder, take: "span.sillage", flight: flowing, out: "span.mp4", framing, context: context)
        #expect(span.joined && span.frames == 3 && Set(span.pixels).count == 3)
        #expect(span.pixels != held.pixels)

        #expect(throws: HeldFrames.Failure.self) {
            try Self.export(
                folder, take: "one.sillage", flight: flowing, out: "refused.mp4", framing, context: context)
        }
        #expect(!Self.exists(folder.appendingPathComponent("refused.mp4")))
    }

    /// A stretch paced by the distance to the nearest matter (#406) reads the take's particles
    /// as the Mac's export does, and the report says its pace.
    @Test func aPacedFlightSaysItsPace() throws {
        let context = try CUDAContext()
        let folder = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flight = try Self.shortFlight(in: folder, exposure: 0, paced: true)
        let report = try Self.export(folder, flight: flight, ["--start", "1.5"], context: context)
        #expect(report.joined && report.frames == 2)
        #expect(report.inside.paces.count == 1 && report.inside.paces[0] > 0)
        #expect(report.inside.summary.contains("paced at"))
    }

    /// The exposure a flight is measured at is kept beside its segments to the bit.
    @Test func thePlanKeepsTheExposureToTheBit() throws {
        let identity = CUDAExport.Identity(
            take: "take.sillage", takeBytes: 1, particles: 2, capturedFrames: 3, framing: nil,
            framingBytes: nil, look: "a", flight: "b", capturedRate: 30, width: 64, height: 36,
            framesPerSecond: 2, start: 0, duration: nil, frames: 5, segmentFrames: 2, codec: "hevc",
            bitsPerSecond: nil, laceTexels: 256, engine: "cuda cpu")
        let exposures = [
            FlightFrames.Exposure(scale: nil, target: 0),
            FlightFrames.Exposure(
                scale: ExposureScale(brightness: 0.1 + 0.2, stretch: .pi), target: Float(0.1) + Float(0.06),
                trims: InsideExposure.Track(
                    step: 0.25, stops: [0, 0.1 + 0.2, 1 / 3, .leastNonzeroMagnitude], ease: 0.7,
                    still: [0...0.1, (1 / 3)...(2 / 3)])),
        ]
        for exposure in exposures {
            let plan = CUDAExport.Plan(
                identity: identity, exposure: exposure, summary: "", seconds: 1, device: "CPU")
            let read = try JSONDecoder().decode(
                CUDAExport.Plan.self, from: CUDAExport.encoded(plan))
            #expect(read.exposure == exposure)
            #expect(read.identity == identity)
        }
        var other = identity
        other.framesPerSecond = 4
        other.frames = 9
        #expect(other.differences(from: identity) == ["framesPerSecond", "frames"])
    }

    // MARK: - On a rented GPU

    /// The measure #382 leaves for the first rented session: frames from inside an arm of a
    /// take of millions of particles, in 4K, drawn both ways for large splats to the same bits,
    /// with the time of each phase and the device memory held, beside the M4 Max's 94 to 360 ms
    /// a render (`docs/notes/inside-a-galaxy.md`).
    @Test(.enabled(if: onAGPU && rentedFlight != nil, needsARentedFlight))
    func aFlightInsideAnArmIsTimedIn4K() throws {
        let files = (rentedFlight ?? "").split(separator: ",").map(String.init)
        try #require(files.count >= 3)
        let context = try CUDAContext()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "flight-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var pixels: [[String]] = []
        for way in ["off", String(CUDATakeStills.flightLargeSplatPixels)] {
            let started = Date()
            let report = try CUDAExport.run(
                files[0],
                options: [
                    "--look", files[1], "--flight", files[2], "--preset", "4k", "--duration", "1",
                    "--profile",
                    "--large-splats", way, "--out", folder.appendingPathComponent("\(way).mp4").path,
                ] + (files.count > 3 ? ["--framing", files[3]] : []), context: context)
            let memory = context.memoryHeld
            print(
                "CUDAFLIGHT large splats \(way): \(report.drawn) frames in",
                Date().timeIntervalSince(started), "s,", report.inside.renders, "renders,",
                Double(memory.peak) / 1e9, "GB held at most on", context.name)
            #expect(report.joined)
            pixels.append(report.pixels)
        }
        #expect(pixels[0] == pixels[1])
    }
}
