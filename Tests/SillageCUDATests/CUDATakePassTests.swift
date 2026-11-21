import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment =
    "needs an NVIDIA GPU and libsillagecuda.a: #283 and the first rented scene run it"
/// The Mac's massive pass of the full pass's comparison, from branch `assets/cuda-checks`.
private let macFullPass = ProcessInfo.processInfo.environment["SILLAGE_CUDA_FULL_PASS"]
private let needsMacFullPass: Comment =
    "needs the Mac's massive pass of branch assets/cuda-checks: SILLAGE_CUDA_FULL_PASS names its folder"

/// The pass that writes a take on CUDA (#378): what `sillage-cuda hires` runs without `--pass
/// full`, through the flow the Mac's `sillage-render` runs (`TakePassRun`), on scene-0031 of the
/// fixtures drawn at 3,000 particles, as `TakePassCheckpointTests` holds Metal's.
/// Serialized: the solver's settings are global, and the videos go through ffmpeg.
@Suite("CUDA take pass", .serialized)
struct CUDATakePassTests {
    static let fixtures = CUDAFullPassTests.fixtures

    /// A scene folder as exploration leaves it on the Mac: the scene, its clip and a look with
    /// the director.
    static func explored() throws -> SceneFolder {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent("take-pass-\(UUID().uuidString)")
                .appendingPathComponent("2026-10-30-b").appendingPathComponent("scene-0031"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("scene/scene.json"), to: folder.scene)
        var clip = SceneFolder.Clip()
        clip.particles = 3_000
        clip.width = 256
        clip.height = 144
        clip.frames = 24
        clip.fps = 6
        clip.steps = 96
        clip.settle = 12
        try clip.encoded().write(to: folder.clip)
        var look = try LookFile.decoded(
            from: Data(contentsOf: fixtures.appendingPathComponent("frames/red-vs-cyan.look.json")))
        look.camera.mode = .director
        try look.encoded().write(to: folder.look)
        return folder
    }

    /// The options of a short hires of `folder` that checkpoints often, keeps its last state and
    /// writes every frame as its encoder took it.
    static func asked(_ folder: SceneFolder, _ options: [String]) -> [String] {
        options + [
            "--frames", "12", "--checkpoint-frames", "5", "--checkpoint-steps", "4", "--state-out",
            folder.url.appendingPathComponent("state.bin").path, "--out",
            folder.url.appendingPathComponent("frames/f.png").path,
        ]
    }

    /// `sillage-cuda hires <folder>` with `options`, as the command runs it.
    static func hires(
        _ folder: SceneFolder, _ options: [String], context: CUDAContext,
        stop: ((Int?, Int) -> Bool)? = nil
    ) throws {
        try CUDAHires.run(
            folder, options: options, context: context, threads: 4, checkRecord: CUDAFullPassTests.checked,
            maximumParticles: 1_000_000_000, stop: stop)
    }

    /// A take as its header reads and the bytes after it: the header's keys come in no fixed
    /// order.
    static func take(_ url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        let length = Int(data[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let header = try JSONSerialization.jsonObject(with: data[24..<(24 + length)])
        return [
            try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
            Data(data[(24 + length)...]),
        ]
    }

    static func remove(_ folders: SceneFolder...) {
        for folder in folders {
            try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent())
        }
    }

    // MARK: - On the CPU target, in every check

    /// A one-pass hires writes what the Mac's writes: a take the portable reader opens with every
    /// frame, its curves, `hires.json` with the engine, and a video with every frame; run twice,
    /// the same take, curves and end state, and the same frames once decoded.
    @Test func aOnePassHiresWritesWhatTheMacsWritesTheSameTwice() throws {
        let context = try CUDAContext()
        let first = try Self.explored()
        let second = try Self.explored()
        defer { Self.remove(first, second) }
        let options = ["--particles", "3000", "--checkpoint-every", "0"]
        try Self.hires(first, Self.asked(first, options), context: context)
        try Self.hires(second, Self.asked(second, options), context: context)

        let take = try RecordingFile.read(from: first.take)
        #expect(take.recording.particleCount == 3_000 && take.recording.capturedFrames == 12)
        let curves = try String(contentsOf: first.hiresCurves, encoding: .utf8)
        #expect(curves.split(separator: "\n").count == 13)
        #expect(try FFmpegVideo.frameCount(first.hiresVideo) == 12)
        let record = try #require(first.storedHires())
        #expect(record.engine == CUDAEngineCheck.engine && record.pass == nil && record.resumes == nil)
        #expect((record.peakMemoryBytes ?? 0) > 0 && (record.peakDeviceBytes ?? 0) > 0)
        #expect(record.stepSwitches?.map(\.scale) == [2, 1] && record.takeBytes != nil)
        #expect(!FileManager.default.fileExists(atPath: first.checkpoint.path))
        #expect(!FileManager.default.fileExists(atPath: SceneFolder.partial(first.take).path))
        let status = ActivityFile.read(from: RunStatusFiles.activity(library: first.library))
        #expect(status?.state != .running)

        #expect(try Self.take(first.take) == Self.take(second.take))
        for name in ["curves-hires.csv", "state.bin", "state.bin.json"] {
            #expect(
                try Data(contentsOf: first.url.appendingPathComponent(name))
                    == Data(contentsOf: second.url.appendingPathComponent(name)), "\(name)")
        }
        let decoded = try CUDAFullPassTests.decoded(first.hiresVideo)
        let again = try CUDAFullPassTests.decoded(second.hiresVideo)
        #expect(!decoded.isEmpty && decoded == again)
    }

    /// #240's test, for the take pass on the CPU target: a hires never stopped against one
    /// stopped just after a checkpoint in its settle, resumed, stopped again two frames after a
    /// checkpoint in its frames, a segment of its video open, and resumed to the end. One pass of
    /// every particle, one with light tracers, and a massive pass, each with the standard step
    /// schedule judged on the run's centres, and the director. The same take past its header,
    /// curves, massive set, solver state and step switches, the same frames handed to the
    /// encoder and the same video once decoded. After the resumed massive pass, a full pass on
    /// the same engine repeats it with a drift of 0.
    @Test(arguments: [
        ["--particles", "3000"], ["--particles", "3000", "--massive", "1500"],
        ["--particles", "3000", "--massive", "1500", "--pass", "massive"],
    ])
    func aTakePassKilledTwiceAndResumedWritesTheSameFiles(_ draw: [String]) throws {
        let context = try CUDAContext()
        let straight = try Self.explored()
        let stopped = try Self.explored()
        defer { Self.remove(straight, stopped) }
        try Self.hires(straight, Self.asked(straight, draw), context: context)
        let whole = try #require(straight.storedHires())
        #expect(whole.resumes == nil && whole.stepSwitches?.map(\.scale) == [2, 1])
        #expect(!FileManager.default.fileExists(atPath: straight.checkpoint.path))

        // Stopped in the settle, right after its first checkpoint.
        #expect(throws: TakePassRun.Failure.self) {
            try Self.hires(stopped, Self.asked(stopped, draw), context: context) { frame, checkpoints in
                frame == nil && checkpoints == 1
            }
        }
        #expect(stopped.resumesHires(Self.asked(stopped, draw), maximumParticles: 1_000_000_000))
        // Resumed, and stopped two frames after the checkpoint before frame 5.
        #expect(throws: TakePassRun.Failure.self) {
            try Self.hires(stopped, Self.asked(stopped, draw + ["--resume"]), context: context) { frame, _ in
                frame == 6
            }
        }
        #expect(!FileManager.default.fileExists(atPath: stopped.take.path))

        // Another command line is another run; a take cut short is refused.
        #expect {
            try Self.hires(
                stopped, Self.asked(stopped, draw + ["--resume", "--take-interval", "2"]), context: context)
        } throws: { error in
            "\(error)".contains("its command line")
        }
        let positions = RunCheckpoint(directory: stopped.checkpoint).takePositions
        let held = try Data(contentsOf: positions)
        let recorded = try #require(RunCheckpoint(directory: stopped.checkpoint).stored()?.take?.take)
        #expect(recorded.frames.count == 2 && recorded.offered == 5)
        try held.prefix(recorded.bytes - 1).write(to: positions)
        #expect {
            try Self.hires(stopped, Self.asked(stopped, draw + ["--resume"]), context: context)
        } throws: { error in
            "\(error)".contains("holds fewer")
        }
        try held.write(to: positions)

        try Self.hires(stopped, Self.asked(stopped, draw + ["--resume"]), context: context)
        let resumed = try #require(stopped.storedHires())
        #expect(resumed.resumes == 2 && resumed.engine == CUDAEngineCheck.engine)
        #expect(resumed.stepSwitches == whole.stepSwitches && resumed.stepsRun == whole.stepsRun)
        #expect(!FileManager.default.fileExists(atPath: stopped.checkpoint.path))
        #expect(try Self.take(stopped.take) == Self.take(straight.take))
        #expect(try RecordingFile.read(from: stopped.take).recording.capturedFrames == 12)
        for name in ["curves-hires.csv", "state.bin", "state.bin.json"] {
            #expect(
                try Data(contentsOf: stopped.url.appendingPathComponent(name))
                    == Data(contentsOf: straight.url.appendingPathComponent(name)), "\(name)")
        }
        #expect(try FFmpegVideo.frameCount(stopped.hiresVideo) == 12)
        let decoded = try CUDAFullPassTests.decoded(straight.hiresVideo)
        let resumedVideo = try CUDAFullPassTests.decoded(stopped.hiresVideo)
        #expect(!decoded.isEmpty && decoded == resumedVideo)
        for frame in 0..<12 {
            let name = String(format: "frames/f.%04d.png", frame)
            let drawn = try Data(contentsOf: stopped.url.appendingPathComponent(name))
            #expect(drawn == (try Data(contentsOf: straight.url.appendingPathComponent(name))), "\(name)")
        }
        guard draw.contains("--pass") else { return }
        #expect(try Data(contentsOf: stopped.massiveSet) == Data(contentsOf: straight.massiveSet))
        // A full pass after the resumed massive pass repeats it, through the same command.
        try Self.hires(
            stopped,
            [
                "--particles", "3000", "--massive", "1500", "--frames", "12", "--pass", "full", "--export",
                "4k,vertical", "--draw-divisor", "32", "--checkpoint-every", "0",
            ], context: context)
        let full = try #require(stopped.storedHires()?.full)
        #expect(full.drift == 0 && full.checkedFrames == 4 && full.engine == CUDAEngineCheck.engine)
        #expect(stopped.storedHires()?.engine == CUDAEngineCheck.engine)
    }

    /// `--no-video` writes the take, the curves and `hires.json` and no video, and takes away
    /// the one an earlier run left, which would not be this take's.
    @Test func aRunWithoutItsVideoLeavesNone() throws {
        let context = try CUDAContext()
        let folder = try Self.explored()
        defer { Self.remove(folder) }
        try Data("an earlier run's".utf8).write(to: folder.hiresVideo)
        try Self.hires(
            folder, ["--particles", "3000", "--frames", "6", "--no-video", "--checkpoint-frames", "2"],
            context: context)
        #expect(try RecordingFile.read(from: folder.take).recording.capturedFrames == 6)
        #expect(FileManager.default.fileExists(atPath: folder.hiresCurves.path))
        #expect(!FileManager.default.fileExists(atPath: folder.hiresVideo.path))
        #expect(!FileManager.default.fileExists(atPath: SceneFolder.partial(folder.hiresVideo).path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("out").path))
    }

    /// An engine never checked is refused before anything runs, and so is a solver the engine
    /// does not have.
    @Test func aTakePassRefusesAnUncheckedEngineAndAnotherSolver() throws {
        let context = try CUDAContext()
        let folder = try Self.explored()
        defer { Self.remove(folder) }
        #expect(throws: CUDAEngineCheck.Refusal.self) {
            try CUDAHires.run(
                folder, options: ["--particles", "3000", "--frames", "2"], context: context,
                checkRecord: folder.url.appendingPathComponent("never.json"), maximumParticles: 1_000_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.take.path))
        #expect(throws: CUDATakePassEngine.Failure.self) {
            try Self.hires(
                folder,
                [
                    "--particles", "3000", "--frames", "2", "--solver", "restricted", "--checkpoint-every",
                    "0",
                ],
                context: context)
        }
    }

    // MARK: - Against the Mac

    /// The ticket's comparison: the Mac's massive pass of the full pass's comparison (scene-0031
    /// at 200 k drawn from 50 k massive, 24 frames through the first pericentre) run again here
    /// from its scene, clip and look, with its options. The sample drawn here is the Mac's to
    /// rounding, so the runs part as two engines do: the centres within `FullPassRun.driftBound`
    /// of the Mac's on every frame, the curves' separation within twice that and their extent
    /// within a percent, and three frames of each take drawn by the same renderer above 25 dB.
    /// About twenty minutes on the CPU target.
    @Test(.enabled(if: macFullPass != nil, needsMacFullPass))
    func theTakePassAgreesWithTheMacs() throws {
        let mac = URL(fileURLWithPath: try #require(macFullPass), isDirectory: true)
            .appendingPathComponent("scene")
        let out = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SILLAGE_CUDA_CHECKS_OUT"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("take-pass-compare").path,
            isDirectory: true)
        let folder = SceneFolder(
            out.appendingPathComponent("library/2026-10-30-b/scene-0031", isDirectory: true))
        let options = [
            "--particles", "200000", "--massive", "50000", "--dt-scale", "3.5", "--frames", "24",
            "--take-interval", "1", "--pass", "massive", "--dt-schedule", "off", "--checkpoint-every", "0",
        ]
        print("CUDATAKEPASS sillage-cuda hires <folder> " + options.joined(separator: " "))
        // A run `sillage-cuda hires` already made there is measured as it is.
        if folder.storedHires()?.engine != CUDAEngineCheck.engine {
            try? FileManager.default.removeItem(at: folder.url)
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            for name in ["scene.json", "clip.json", "look.json"] {
                try FileManager.default.copyItem(
                    at: mac.appendingPathComponent(name), to: folder.url.appendingPathComponent(name))
            }
            try Self.hires(folder, options, context: try CUDAContext())
        }
        let theirs = try RecordingFile.read(from: mac.appendingPathComponent("take.sillage"))
        let mine = try RecordingFile.read(from: folder.take)
        #expect(mine.recording.capturedFrames == theirs.recording.capturedFrames)
        #expect(mine.recording.particleCount == theirs.recording.particleCount)

        var lines = ["frame,centre_gap_kpc,separation_gap_kpc,extent_ratio"]
        let macCurves = mac.appendingPathComponent("curves-hires.csv")
        let separations = try Self.column("separation_kpc", of: folder.hiresCurves)
        let macSeparations = try Self.column("separation_kpc", of: macCurves)
        let extents = try Self.column("extent_kpc", of: folder.hiresCurves)
        let macExtents = try Self.column("extent_kpc", of: macCurves)
        #expect(extents.count == macExtents.count && extents.count == mine.recording.capturedFrames)
        var widest: Float = 0
        for frame in 0..<min(extents.count, macExtents.count) {
            let gap =
                zip(mine.recording.centers(at: frame), theirs.recording.centers(at: frame))
                .map { simd_length($0 - $1) }.max() ?? 0
            widest = max(widest, gap)
            let separation = abs(separations[frame] - macSeparations[frame])
            let extent = extents[frame] / macExtents[frame]
            lines.append(String(format: "%d,%.6f,%.6f,%.6f", frame, gap, separation, extent))
            #expect(gap < FullPassRun.driftBound, "frame \(frame): \(gap) kpc")
            #expect(separation < 2 * Double(FullPassRun.driftBound), "frame \(frame): \(separation) kpc")
            #expect(abs(extent - 1) < 0.01, "frame \(frame): extent \(extent) of the Mac's")
        }
        print("CUDATAKEPASS centres at most", widest, "kpc from the Mac's")

        let look = try LookFile.decoded(from: Data(contentsOf: folder.look))
        let context = try CUDAContext()
        let (width, height) = (240, 136)
        let drawMine = try CUDATakeStills(
            context: context, take: mine, look: look, capturedRate: 3, width: width, height: height)
        let drawTheirs = try CUDATakeStills(
            context: context, take: theirs, look: look, capturedRate: 3, width: width, height: height)
        lines.append("still,psnr,mean_difference,largest,over_eight")
        try FileManager.default.createDirectory(
            at: out.appendingPathComponent("stills"), withIntermediateDirectories: true)
        for frame in [0, 12, 19] {
            let a = [UInt8](try drawMine.still(atCaptured: Double(frame), frame: frame, threads: 4))
            let b = [UInt8](try drawTheirs.still(atCaptured: Double(frame), frame: frame, threads: 4))
            let measure = CUDAStillChecks.measure(a, channels: 3, b, channels: 3)
            print("CUDATAKEPASS frame", frame, measure)
            lines.append(
                String(
                    format: "%d,%.2f,%.4f,%d,%.6f", frame, measure.psnr, measure.meanDifference,
                    measure.largest, measure.overEight))
            #expect(measure.psnr > 25, "frame \(frame): \(measure)")
            for (name, bytes) in [("cuda", a), ("mac", b)] {
                try PNG.write(
                    PNG.Image(width: width, height: height, channels: 3, bytes: bytes),
                    to: out.appendingPathComponent(String(format: "stills/%@-%04d.png", name, frame)))
            }
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: out.appendingPathComponent("take-pass.csv"), atomically: true, encoding: .utf8)
    }

    /// A column of a run's curves.
    static func column(_ name: String, of url: URL) throws -> [Double] {
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        guard let column = rows.first?.split(separator: ",").firstIndex(of: Substring(name)) else {
            return []
        }
        return rows.dropFirst().compactMap { row in
            let fields = row.split(separator: ",")
            return column < fields.count ? Double(fields[column]) : nil
        }
    }

    // MARK: - Written now, run on a GPU in #283 and the first rented scene

    /// #240's resume test on a GPU, at 2 M visible on 3 M of dark matter: stopped in the settle
    /// and in the frames, resumed, the same take, curves and end state as a run never stopped.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aTakePassOnTheGPUKilledTwiceAndResumedWritesTheSameFiles() throws {
        let context = try CUDAContext()
        let straight = try Self.explored()
        let stopped = try Self.explored()
        defer { Self.remove(straight, stopped) }
        let draw = [
            "--particles", "2000000", "--frames", "24", "--checkpoint-frames", "8", "--checkpoint-steps",
            "100",
        ]
        func state(_ folder: SceneFolder) -> [String] {
            ["--state-out", folder.url.appendingPathComponent("state.bin").path]
        }
        try Self.hires(straight, draw + state(straight), context: context)
        #expect(throws: TakePassRun.Failure.self) {
            try Self.hires(stopped, draw + state(stopped), context: context) { $0 == nil && $1 == 1 }
        }
        #expect(throws: TakePassRun.Failure.self) {
            try Self.hires(stopped, draw + state(stopped) + ["--resume"], context: context) { frame, _ in
                frame == 10
            }
        }
        try Self.hires(stopped, draw + state(stopped) + ["--resume"], context: context)
        #expect(try Self.take(stopped.take) == Self.take(straight.take))
        for name in ["curves-hires.csv", "state.bin", "state.bin.json"] {
            #expect(
                try Data(contentsOf: stopped.url.appendingPathComponent(name))
                    == Data(contentsOf: straight.url.appendingPathComponent(name)), "\(name)")
        }
        #expect(
            try CUDAFullPassTests.decoded(stopped.hiresVideo)
                == CUDAFullPassTests.decoded(straight.hiresVideo))
    }

    /// A scene of today's size, 8 M visible on 12 M of dark matter: a step phase by phase, a
    /// frame with its take and its video, and the host's and the device's peak memory, on a
    /// `CUDATAKEPASS` line against the Mac's (#377: 0.45 s a step on the M4 Max, a peak of 6.5 GB
    /// with checkpoints).
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aTakePassIsTimed() throws {
        let context = try CUDAContext()
        let folder = try Self.explored()
        defer { Self.remove(folder) }
        var clip = try folder.storedClip()
        clip.width = 1920
        clip.height = 1080
        try clip.encoded().write(to: folder.clip)
        let started = Date()
        // Each frame's `profile` line gives its steps phase by phase, its `frame` line the step,
        // the smoothing and the drawing.
        try Self.hires(
            folder, ["--particles", "8000000", "--frames", "20", "--profile", "--checkpoint-frames", "10"],
            context: context)
        let record = try #require(folder.storedHires())
        print(
            String(
                format: "CUDATAKEPASS 20 M simulated: %.2f s a frame in all (7 steps, its take, 1080p), peak"
                    + " %.2f GB host, %.2f GB device",
                Date().timeIntervalSince(started) / 20, Double(record.peakMemoryBytes ?? 0) / 1e9,
                Double(record.peakDeviceBytes ?? 0) / 1e9))
    }
}
