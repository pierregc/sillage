import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment = "needs an NVIDIA GPU and libsillagecuda.a: #283 runs it"
/// The Mac's side of the comparison, from branch `assets/cuda-checks`.
private let macFullPass = ProcessInfo.processInfo.environment["SILLAGE_CUDA_FULL_PASS"]
private let needsMacFullPass: Comment =
    "needs the Mac's full pass of branch assets/cuda-checks: SILLAGE_CUDA_FULL_PASS names its folder"
/// #283's comparison at 8 M, with the Mac's full pass at that size.
private let macFullPass8M = ProcessInfo.processInfo.environment["SILLAGE_CUDA_FULL_PASS_8M"]

/// The full pass on CUDA (#278): what `sillage-cuda hires` runs, through the flow the Mac's
/// `sillage-render` runs (`FullPassRun`), on a scene folder whose massive pass is made here by
/// the CUDA solver over the massive particles alone, as `--massive-only` does on Metal.
/// Serialized: the solver's settings are global, and the videos go through ffmpeg.
@Suite("CUDA full pass", .serialized)
struct CUDAFullPassTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repository.appendingPathComponent("Tests/Fixtures/engines")

    /// The engine's check, run once for the suite and kept aside from the build's own record.
    static let checked: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "engine-check-\(UUID().uuidString).json")
        if let context = try? CUDAContext() {
            try? CUDAEngineCheck.write(CUDAEngineCheck.run(context: context, fixtures: fixtures), to: url)
        }
        return url
    }()

    static func maker(_ context: CUDAContext) -> CUDAFullPassMaker {
        CUDAFullPassMaker(context: context, threads: 4, checkRecord: checked)
    }

    /// A scene folder as the Mac leaves it after the massive pass and the style: scene-0031 of
    /// the engines' fixtures drawn at `particles` from `massive`, a look with the director, the
    /// massive take, `massive.bin` and `hires.json`. The massive pass is the CUDA solver's here.
    static func massivePass(
        particles: Int = 3_000, massive: Int = 1_500, frames: Int = 8, context: CUDAContext
    ) throws -> SceneFolder {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent("full-pass-\(UUID().uuidString)")
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

        let plan = try folder.hiresArguments(
            [
                "--particles", String(particles), "--massive", String(massive), "--frames", String(frames),
                "--pass", "massive",
            ], maximumParticles: 1_000_000_000)
        let run = FullPassRun(arguments: plan.arguments, engine: maker(context))
        let scenes = try run.scenes()
        let split = try CUDABarnesHutSolver.lightTracers(
            context: context, drawn: scenes.drawn, massive: scenes.scene)
        try RunCheckpoint.writeMassiveSet(split.massive, to: folder.massiveSet)
        let solver = try CUDABarnesHutSolver(context: context, scene: scenes.scene, massive: split.massive)
        let visible = split.massive.visibleCount
        let interval = Int(run.number("take-interval", 1))
        let take = Recording(
            particleCount: visible, galaxyCount: scenes.scene.galaxies.count, interval: interval)
        try solver.advance(steps: plan.record.settle)
        let perFrame = max(plan.record.steps / max(frames, 1), 1)
        for _ in 0..<frames {
            try solver.advance(steps: perFrame)
            let positions = try solver.positions.download(SIMD3<Float>.self, count: visible)
            positions.withUnsafeBufferPointer {
                take.offer(
                    positions: $0.baseAddress!, time: solver.time, centers: solver.centers,
                    disks: solver.diskFrames, budget: 0)
            }
        }
        try RecordingFile.write(take, scene: scenes.scene, particles: solver.particles, to: folder.take)
        try plan.record.encoded().write(to: folder.hires)
        return folder
    }

    /// A copy of a scene folder, for a second run of the same massive pass.
    static func copy(_ folder: SceneFolder) throws -> SceneFolder {
        let other = folder.url.deletingLastPathComponent().appendingPathComponent(
            "scene-\(Int.random(in: 1000..<9999))")
        try FileManager.default.copyItem(at: folder.url, to: other)
        return SceneFolder(other)
    }

    static func fullPass(
        _ folder: SceneFolder, context: CUDAContext, frames: Int = 8, options: [String] = [],
        stop: ((Int, Int) -> Bool)? = nil
    ) throws {
        let plan = try folder.hiresArguments(
            [
                "--particles", "3000", "--massive", "1500", "--frames", String(frames), "--pass", "full",
                "--export", "4k,vertical", "--draw-divisor", "32",
            ] + options, maximumParticles: 1_000_000_000)
        let run = FullPassRun(
            arguments: plan.arguments, engine: maker(context), hires: (folder, plan.record))
        run.stop = stop
        try run.run()
    }

    /// Every frame of a video, decoded to 8-bit RGB.
    static func decoded(_ url: URL) throws -> Data {
        let out = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).rgb")
        try FFmpegVideo.run(
            FFmpegVideo.ffmpeg,
            ["-v", "error", "-y", "-i", url.path, "-f", "rawvideo", "-pix_fmt", "rgb24", out.path])
        defer { try? FileManager.default.removeItem(at: out) }
        return try Data(contentsOf: out)
    }

    // MARK: - On the CPU target, in every check

    /// The run writes what the Mac's full pass writes: both videos with every frame, the key
    /// frames and the full section of `hires.json`. Its massive part repeats the massive pass
    /// it follows to the bit, on one engine as on Metal.
    @Test func aFullPassWritesWhatTheMacsWritesAndRepeatsItsMassivePass() throws {
        let context = try CUDAContext()
        let folder = try Self.massivePass(context: context)
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        try Self.fullPass(folder, context: context, options: ["--checkpoint-every", "0"])
        for name in ["4k.mp4", "vertical.mp4"] {
            #expect(try FFmpegVideo.frameCount(folder.exports.appendingPathComponent(name)) == 8)
        }
        #expect(FileManager.default.fileExists(atPath: folder.keyFrames.path))
        let keyFrames = try RecordingFile.read(from: folder.keyFrames)
        #expect(keyFrames.recording.particleCount == 3_000)
        let record = try #require(folder.storedHires())
        let full = try #require(record.full)
        #expect(record.pass == .massive)
        #expect(full.presets == ["4k", "vertical"] && full.frames == 8)
        #expect(full.engine == CUDAEngineCheck.engine)
        #expect(full.checkedFrames >= 2 && full.drift == 0)
        #expect(full.gaps?.count == full.checkedFrames && full.gaps?.allSatisfy { $0.kpc == 0 } == true)
        #expect(full.driftBound == FullPassRun.driftBound)
        #expect((full.peakMemoryBytes ?? 0) > 0 && (full.peakDeviceBytes ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: folder.checkpoint.path))
    }

    /// #240's test on the CPU target: a run stopped after a checkpoint, a frame into its next
    /// segment, and resumed gives every frame of both videos, once decoded, as a run never
    /// stopped, and the same key frames and end state.
    @Test func aRunStoppedAfterACheckpointAndResumedDrawsTheSameFrames() throws {
        let context = try CUDAContext()
        let straight = try Self.massivePass(context: context)
        defer { try? FileManager.default.removeItem(at: straight.batch.deletingLastPathComponent()) }
        let stopped = try Self.copy(straight)
        let options = ["--checkpoint-frames", "3", "--checkpoint-steps", "5"]
        try Self.fullPass(
            straight, context: context, options: options + ["--state-out", straight.url.path + "/state.bin"])
        #expect(throws: FullPassRun.Failure.self) {
            try Self.fullPass(stopped, context: context, options: options) { frame, checkpoints in
                checkpoints >= 1 && frame == 4
            }
        }
        #expect(FileManager.default.fileExists(atPath: stopped.checkpoint.path))
        try Self.fullPass(
            stopped, context: context,
            options: options + ["--resume", "--state-out", stopped.url.path + "/state.bin"])
        for name in ["4k.mp4", "vertical.mp4"] {
            let a = try Self.decoded(straight.exports.appendingPathComponent(name))
            let b = try Self.decoded(stopped.exports.appendingPathComponent(name))
            #expect(!a.isEmpty && a == b, "\(name)")
        }
        #expect(
            try Data(contentsOf: straight.url.appendingPathComponent("state.bin"))
                == Data(contentsOf: stopped.url.appendingPathComponent("state.bin")))
        #expect(try Data(contentsOf: straight.keyFrameList) == Data(contentsOf: stopped.keyFrameList))
        #expect(try stopped.storedHires()?.full?.resumes == 1)
    }

    /// The encoder's path: each codec through ffmpeg, segments joined without encoding them
    /// again, the frame count checked, and a join that comes short refused.
    @Test(arguments: [VideoCodec.hevc, .h264, .prores])
    func segmentsJoinIntoOneVideoOfEveryFrame(_ codec: VideoCodec) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ffmpeg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (width, height) = (64, 36)
        var frames: [[UInt8]] = []
        for index in 0..<9 {
            var bytes = [UInt8](repeating: 0, count: width * height * 3)
            for pixel in 0..<(width * height) {
                bytes[pixel * 3] = UInt8((pixel % width) * 4 % 256)
                bytes[pixel * 3 + 1] = UInt8((pixel / width) * 7 % 256)
                bytes[pixel * 3 + 2] = UInt8(index * 25)
            }
            frames.append(bytes)
        }
        let metadata = VideoMetadata(sceneID: "2026-10-30-b/scene-0031")
        var parts: [URL] = []
        for segment in 0..<3 {
            let url = folder.appendingPathComponent("wide-\(segment).\(codec.fileExtension)")
            let writer = try FFmpegVideoWriter(
                url: url, width: width, height: height, framesPerSecond: 3, codec: codec, bitsPerSecond: nil,
                metadata: metadata)
            for frame in frames[(segment * 3)..<(segment * 3 + 3)] {
                try frame.withUnsafeBytes { try writer.append($0) }
            }
            try writer.finish()
            parts.append(url)
        }
        let joined = folder.appendingPathComponent("wide.\(codec.fileExtension)")
        try FFmpegVideo.join(parts, into: joined, frames: 9, framesPerSecond: 3, metadata: metadata)
        #expect(try FFmpegVideo.frameCount(joined) == 9)
        let decoded = try Self.decoded(joined)
        #expect(decoded.count == 9 * width * height * 3)
        let measure = CUDAStillChecks.measure(
            [UInt8](decoded), channels: 3, frames.flatMap { $0 }, channels: 3)
        #expect(measure.psnr > 30, "\(codec): \(measure)")
        #expect(throws: RunVideos.Failure.self) {
            try FFmpegVideo.join(parts, into: joined, frames: 10, framesPerSecond: 3, metadata: metadata)
        }
    }

    /// An engine never checked, checked on other libraries, or whose check failed, is refused,
    /// and so is a massive set of another draw.
    @Test func aFullPassRefusesAnUncheckedEngineAndAnotherDraw() throws {
        let context = try CUDAContext()
        let folder = try Self.massivePass(frames: 2, context: context)
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let plan = try folder.hiresArguments(
            [
                "--particles", "3000", "--massive", "1500", "--frames", "2", "--pass", "full",
                "--draw-divisor", "32",
            ],
            maximumParticles: 1_000_000_000)
        let elsewhere = folder.url.appendingPathComponent("check.json")
        func refused(_ record: URL) -> Bool {
            let run = FullPassRun(
                arguments: plan.arguments, engine: CUDAFullPassMaker(context: context, checkRecord: record))
            do {
                try run.run()
                return false
            } catch is CUDAEngineCheck.Refusal {
                return true
            } catch {
                return false
            }
        }
        #expect(refused(elsewhere))
        var record = try #require(CUDAEngineCheck.read(from: Self.checked))
        record.build = "another build"
        try CUDAEngineCheck.write(record, to: elsewhere)
        #expect(refused(elsewhere))
        record = try #require(CUDAEngineCheck.read(from: Self.checked))
        record.items[0].passed = false
        try CUDAEngineCheck.write(record, to: elsewhere)
        #expect(refused(elsewhere))

        var other = try RunCheckpoint.readMassiveSet(from: folder.massiveSet)
        other.positions[10].x += 1
        try RunCheckpoint.writeMassiveSet(other, to: folder.massiveSet)
        let error = #expect(throws: CUDAFullPassEngine.Failure.self) {
            try FullPassRun(arguments: plan.arguments, engine: Self.maker(context)).run()
        }
        #expect(error?.description.contains("particle 10") == true)
    }

    // MARK: - Against the Mac

    /// The ticket's comparison: scene-0031 at 200 k drawn from 50 k massive, the massive pass
    /// and the style on the Mac, the full pass on the Mac and here over the same span, in both
    /// presets at an eighth of their size, the Mac's stills against these by PSNR, and the
    /// centres' gap from the Mac's massive take on every stored frame. They differ by the
    /// dynamics parting, measured, not by rounding alone. About fifty minutes on the CPU target.
    @Test(.enabled(if: macFullPass != nil, needsMacFullPass))
    func theFullPassAgreesWithTheMacs() throws {
        let mac = URL(fileURLWithPath: try #require(macFullPass), isDirectory: true)
        let out = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SILLAGE_CUDA_CHECKS_OUT"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("full-pass-compare").path,
            isDirectory: true)
        let folder = SceneFolder(
            out.appendingPathComponent("library/2026-10-30-b/scene-0031", isDirectory: true))
        // A run `sillage-cuda hires` already made there is measured as it is.
        let ranHere = folder.storedHires()?.full?.engine == CUDAEngineCheck.engine
        if !ranHere {
            try? FileManager.default.removeItem(at: folder.url)
            try FileManager.default.createDirectory(
                at: folder.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: mac.appendingPathComponent("scene"), to: folder.url)
        }
        // The Mac's own options, from what it wrote: its record, its presets and its stills.
        let record = try #require(folder.storedHires())
        let written = try? Data(contentsOf: mac.appendingPathComponent("full/hires.json"))
        let full = try #require(
            written.flatMap { try? JSONDecoder().decode(SceneFolder.Hires.self, from: $0) }?.full
                ?? record.full)
        let macStills = mac.appendingPathComponent("full/stills", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: macStills.path).filter {
            $0.hasSuffix(".png")
        }
        let frames = Set(names.compactMap { Int($0.split(separator: "-").last?.prefix(4) ?? "") }).sorted()
        let first = try #require(names.first { $0.hasPrefix("\(full.presets[0])-") })
        let width = try PNG.decode(Data(contentsOf: macStills.appendingPathComponent(first))).width
        let divisor = try #require(VideoPreset.named(full.presets[0])).width / width
        let stills = out.appendingPathComponent("stills", isDirectory: true)
        let options = [
            "--particles", String(record.particles), "--massive", String(try #require(record.massive)),
            "--frames", String(record.frames), "--dt-scale", String(record.timeStepScale), "--pass", "full",
            "--export", full.presets.joined(separator: ","), "--draw-divisor", String(divisor),
            "--draw-stills", frames.map(String.init).joined(separator: ","), "--draw-stills-dir", stills.path,
            "--checkpoint-every", "0",
        ]
        print("CUDAFULLPASS sillage-cuda hires <folder> " + options.joined(separator: " "))
        if !ranHere {
            let context = try CUDAContext()
            let plan = try folder.hiresArguments(options, maximumParticles: 1_000_000_000)
            try FullPassRun(
                arguments: plan.arguments, engine: Self.maker(context), hires: (folder, plan.record)
            )
            .run()
        }

        var lines = ["still,psnr,mean_difference,largest,over_eight"]
        for name in try FileManager.default.contentsOfDirectory(atPath: stills.path).sorted()
        where name.hasSuffix(".png") {
            let theirs = try PNG.decode(Data(contentsOf: macStills.appendingPathComponent(name)))
            let mine = try PNG.decode(Data(contentsOf: stills.appendingPathComponent(name)))
            let measure = CUDAStillChecks.measure(
                mine.bytes, channels: mine.channels, theirs.bytes, channels: theirs.channels)
            print("CUDAFULLPASS", name, measure)
            lines.append(
                String(
                    format: "%@,%.2f,%.4f,%d,%.6f", name, measure.psnr, measure.meanDifference,
                    measure.largest,
                    measure.overEight))
            #expect(measure.psnr > 25, "\(name): \(measure)")
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: out.appendingPathComponent("stills.csv"), atomically: true, encoding: .utf8)
        let ran = try #require(folder.storedHires()?.full)
        let gaps = ["frame,kpc"] + (ran.gaps ?? []).map { String(format: "%d,%.6f", $0.frame, $0.kpc) }
        try gaps.joined(separator: "\n").appending("\n").write(
            to: out.appendingPathComponent("drift.csv"), atomically: true, encoding: .utf8)
        print("CUDAFULLPASS drift", ran.drift, "kpc at most over", ran.checkedFrames, "stored frames")
        #expect(ran.engine == CUDAEngineCheck.engine)
        #expect(ran.checkedFrames > 0 && ran.drift < FullPassRun.driftBound)
    }

    // MARK: - Written now, run on a GPU in #283

    /// The comparison at 8 M drawn from 2 M massive, with the 13 stills of
    /// `docs/notes/render-during-hires.md` (frames 0, 50, 120, 200, 260, 330, 400, 480, 560, 650,
    /// 750, 850, 922), from the Mac's full pass at that size: `SILLAGE_CUDA_FULL_PASS_8M`.
    @Test(.enabled(if: onAGPU && macFullPass8M != nil, needsAGPU))
    func theFullPassAt8MAgreesWithTheMacs() throws {
        let mac = URL(fileURLWithPath: try #require(macFullPass8M), isDirectory: true)
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "full-pass-8m/2026-10-30-b/scene-0031"))
        try? FileManager.default.removeItem(at: folder.url)
        try FileManager.default.createDirectory(
            at: folder.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: mac.appendingPathComponent("scene"), to: folder.url)
        let stills = folder.url.appendingPathComponent("stills")
        let context = try CUDAContext()
        let plan = try folder.hiresArguments(
            [
                "--particles", "8000000", "--massive", "2000000", "--pass", "full", "--export", "4k,vertical",
                "--draw-stills", "0,50,120,200,260,330,400,480,560,650,750,850,922", "--draw-stills-dir",
                stills.path,
            ], maximumParticles: 1_000_000_000)
        try FullPassRun(arguments: plan.arguments, engine: Self.maker(context), hires: (folder, plan.record))
            .run()
        for name in try FileManager.default.contentsOfDirectory(atPath: stills.path)
        where name.hasSuffix(".png") {
            let theirs = try PNG.decode(Data(contentsOf: mac.appendingPathComponent("full/stills/\(name)")))
            let mine = try PNG.decode(Data(contentsOf: stills.appendingPathComponent(name)))
            let measure = CUDAStillChecks.measure(
                mine.bytes, channels: mine.channels, theirs.bytes, channels: theirs.channels)
            print("CUDAFULLPASS8M", name, measure)
            #expect(measure.psnr > 25, "\(name): \(measure)")
        }
        let full = try #require(folder.storedHires()?.full)
        print(
            "CUDAFULLPASS8M drift", full.drift, "peak", full.peakMemoryBytes ?? 0, full.peakDeviceBytes ?? 0)
    }

    /// #240's resume test on a GPU, at 2 M drawn from 500 k massive.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aRunOnTheGPUStoppedAndResumedDrawsTheSameFrames() throws {
        let context = try CUDAContext()
        let straight = try Self.massivePass(
            particles: 2_000_000, massive: 500_000, frames: 12, context: context)
        defer { try? FileManager.default.removeItem(at: straight.batch.deletingLastPathComponent()) }
        let stopped = try Self.copy(straight)
        let options = ["--checkpoint-frames", "4", "--checkpoint-steps", "50"]
        func pass(_ folder: SceneFolder, _ more: [String], stop: ((Int, Int) -> Bool)? = nil) throws {
            let plan = try folder.hiresArguments(
                [
                    "--particles", "2000000", "--massive", "500000", "--frames", "12", "--pass", "full",
                    "--export", "4k,vertical",
                ] + options + more, maximumParticles: 1_000_000_000)
            let run = FullPassRun(
                arguments: plan.arguments, engine: Self.maker(context), hires: (folder, plan.record))
            run.stop = stop
            try run.run()
        }
        try pass(straight, [])
        #expect(throws: FullPassRun.Failure.self) { try pass(stopped, []) { $1 >= 2 && $0 == 5 } }
        try pass(stopped, ["--resume"])
        for name in ["4k.mp4", "vertical.mp4"] {
            #expect(
                try Self.decoded(straight.exports.appendingPathComponent(name))
                    == Self.decoded(stopped.exports.appendingPathComponent(name)), "\(name)")
        }
    }

    /// A frame of the run and of each preset timed at 8 M drawn from 2 M massive, with the peak
    /// device and host memory, on `CUDAFULLPASS` lines against the Mac's full pass (#239: 2.0 s
    /// a frame for the run, 101 ms 4K and 50 ms vertical, a peak of 12.1 GB).
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aFrameOfTheFullPassIsTimed() throws {
        let context = try CUDAContext()
        let folder = try Self.massivePass(
            particles: 8_000_000, massive: 2_000_000, frames: 20, context: context)
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let started = Date()
        let plan = try folder.hiresArguments(
            [
                "--particles", "8000000", "--massive", "2000000", "--frames", "20", "--pass", "full",
                "--export", "4k,vertical", "--checkpoint-every", "0",
            ], maximumParticles: 1_000_000_000)
        try FullPassRun(arguments: plan.arguments, engine: Self.maker(context), hires: (folder, plan.record))
            .run()
        let full = try #require(folder.storedHires()?.full)
        print(
            String(
                format:
                    "CUDAFULLPASS 8 M: %.2f s a frame in all, 4k %.1f ms, vertical %.1f ms a frame, peak %.2f GB"
                    + " host, %.2f GB device",
                Date().timeIntervalSince(started) / 20, (full.drawSeconds["4k"] ?? 0) * 50,
                (full.drawSeconds["vertical"] ?? 0) * 50, Double(full.peakMemoryBytes ?? 0) / 1e9,
                Double(full.peakDeviceBytes ?? 0) / 1e9))
    }
}
