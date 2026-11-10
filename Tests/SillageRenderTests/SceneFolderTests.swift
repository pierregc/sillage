import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Scene folder")
struct SceneFolderTests {
    private func temporaryFolder() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)")
            .appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SceneFolder(url)
    }

    private func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
    }

    @Test func everyPathIsDerivedFromTheFolder() {
        let folder = SceneFolder(path: "/library/2026-10-23/scene-0007")
        #expect(folder.batch.path == "/library/2026-10-23")
        #expect(folder.scene.path == "/library/2026-10-23/scene-0007/scene.json")
        #expect(folder.look.lastPathComponent == "look.json")
        #expect(folder.preview.lastPathComponent == "preview.mov")
        #expect(folder.thumbnail.lastPathComponent == "thumbnail.png")
        #expect(folder.curves.lastPathComponent == "curves.csv")
        #expect(folder.take.lastPathComponent == "take.sillage")
        #expect(folder.exports.lastPathComponent == "exports")
        #expect(folder.lookGrid.path == "/library/2026-10-23/scene-0007/looks/grid.png")
        #expect(SceneFolder(path: "/library/b/s/") == SceneFolder(path: "/library/b/s"))
    }

    @Test func theClipTakesItsOwnOptionsAndLeavesTheRest() {
        let (clip, rest) = SceneFolder.Clip().updated(with: [
            "--frames", "300", "--seed", "42", "--director", "--particles", "5e6", "--fps",
        ])
        #expect(clip.frames == 300 && clip.particles == 5_000_000)
        #expect(clip.fps == SceneFolder.Clip().fps && clip.steps == SceneFolder.Clip().steps)
        #expect(rest == ["--seed", "42", "--director", "--fps"])
        #expect(value("--frames", in: clip.arguments) == "300")
    }

    /// The scene's look by default, then a file, a row of the grid, a catalogue look.
    @Test func exportPicksItsLook() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let catalogue = [LookFile(name: "nebula")]
        #expect(try folder.exportLook(nil, catalogue: catalogue) == .standard)

        try folder.promote(LookFile(name: "scene"))
        try FileManager.default.createDirectory(at: folder.looks, withIntermediateDirectories: true)
        try LookFile(name: "row").encoded().write(to: folder.lookFile(named: "row"))
        let file = folder.url.appendingPathComponent("hand.look.json")
        try LookFile(name: "hand").encoded().write(to: file)

        #expect(try folder.exportLook(nil, catalogue: catalogue).name == "scene")
        #expect(try folder.exportLook("row", catalogue: catalogue).name == "row")
        #expect(try folder.exportLook(file.path, catalogue: catalogue).name == "hand")
        #expect(try folder.exportLook("nebula", catalogue: catalogue).name == "nebula")
        #expect(throws: SceneFolder.ExportError.self) {
            try folder.exportLook("missing", catalogue: catalogue)
        }
        #expect(folder.export(preset: "4k").path.hasSuffix("/exports/4k.mp4"))
    }

    /// A first run generates the scene; a second reads back what the first wrote, so it can
    /// be redone at will, and the options given still override it.
    @Test func exploreStartsAFreshSceneThenReplaysTheOneItWrote() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }

        let first = folder.exploreArguments(["--seed", "42"], clip: .init())
        #expect(value("--preset", in: first) == "free")
        #expect(value("--solver", in: first) == "barnes-hut")
        #expect(value("--seed", in: first) == "42")
        #expect(value("--scene", in: first) == nil && value("--look", in: first) == nil)
        #expect(value("--video", in: first) == folder.preview.path)
        #expect(value("--scene-out", in: first) == folder.scene.path)
        #expect(value("--thumbnail", in: first) == folder.thumbnail.path)

        try Data("{}".utf8).write(to: folder.scene)
        try Data("{}".utf8).write(to: folder.look)
        let again = folder.exploreArguments(["--brightness", "0.3"], clip: .init())
        #expect(value("--scene", in: again) == folder.scene.path)
        #expect(value("--look", in: again) == folder.look.path)
        #expect(value("--preset", in: again) == nil && value("--solver", in: again) == nil)
        #expect(value("--brightness", in: again) == "0.3")

        let redirected = folder.exploreArguments(["--video", "/elsewhere.mov"], clip: .init())
        #expect(value("--video", in: redirected) == folder.preview.path)
    }

    @Test func theClipIsKeptBetweenRuns() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(try folder.storedClip() == SceneFolder.Clip())
        var clip = SceneFolder.Clip()
        clip.frames = 120
        try clip.encoded().write(to: folder.clip)
        #expect(try folder.storedClip() == clip)
    }

    /// A preview at 400 000 particles explored the way a night batch does.
    private func explored() throws -> SceneFolder {
        let folder = try temporaryFolder()
        var scene = SceneConfig.merger(particleCount: 400_000)
        scene.solver = .barnesHut
        scene.timeStepScale = 3.5
        try SceneFile(scene).encoded().write(to: folder.scene)
        var clip = SceneFolder.Clip()
        clip.particles = 400_000
        clip.frames = 900
        clip.steps = 7_200
        clip.settle = 400
        try clip.encoded().write(to: folder.clip)
        try Data("{}".utf8).write(to: folder.look)
        return folder
    }

    @Test func aShorterStepStillLandsEveryFrameWhereThePreviewDid() {
        var clip = SceneFolder.Clip()
        clip.frames = 900
        clip.steps = 7_200
        clip.settle = 400
        let span = clip.spanning(previewStep: 0.1, maximumStep: 0.063)
        // Two frames' worth of preview time, 1.6, now needs 13 steps of 0.0615.
        #expect(span.steps == 13 * 900)
        #expect(abs(span.timeStep - 0.8 / 13) < 1e-12)
        #expect(span.timeStep <= 0.063)
        #expect(abs(Double(span.steps) * span.timeStep - 720) < 1e-9)
        #expect(abs(Double(span.settle) * span.timeStep - 40) <= span.timeStep / 2)

        let same = clip.spanning(previewStep: 0.1, maximumStep: 0.1)
        #expect(same.steps == 7_200 && same.settle == 400 && same.timeStep == 0.1)
        #expect(clip.spanning(previewStep: 0.1, maximumStep: 0.063, frames: 30).steps == 13 * 30)
    }

    @Test func hiresRerunsTheSameTimeAtMoreParticlesBesideThePreview() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let (arguments, record) = try folder.hiresArguments(
            ["--particles", "2e6", "--brightness", "0.2"], maximumParticles: 10_000_000)

        #expect(record.particles == 2_000_000 && record.previewParticles == 400_000)
        #expect(record.timeStepMyr < record.previewTimeStepMyr)
        #expect(record.timeStepScale == 3.5)
        let preview = record.previewTimeStepMyr
        #expect(abs(record.clipEndMyr - record.clipStartMyr - 7_200 * preview) < 1e-6)
        #expect(abs(record.clipStartMyr - 400 * preview) <= record.timeStepMyr / 2)
        #expect(record.steps % 900 == 0)

        #expect(value("--particles", in: arguments) == "2000000")
        #expect(value("--steps", in: arguments) == String(record.steps))
        #expect(value("--settle", in: arguments) == String(record.settle))
        #expect(value("--width", in: arguments) == "1600" && value("--frames", in: arguments) == "900")
        #expect(value("--video", in: arguments) == SceneFolder.partial(folder.hiresVideo).path)
        #expect(value("--curves", in: arguments) == SceneFolder.partial(folder.hiresCurves).path)
        #expect(value("--take", in: arguments) == SceneFolder.partial(folder.take).path)
        #expect(value("--scene", in: arguments) == folder.scene.path)
        #expect(value("--look", in: arguments) == folder.look.path)
        #expect(value("--brightness", in: arguments) == "0.2")
        #expect(arguments.contains("--no-sidecars"))
        #expect(value("--take-interval", in: arguments) == String(SceneFolder.hiresTakeInterval))
        let every = try folder.hiresArguments(
            ["--take-interval", "1"], maximumParticles: 10_000_000
        ).arguments
        #expect(value("--take-interval", in: every) == "1")
        #expect(every.filter { $0 == "--take-interval" }.count == 1)
        #expect(value("--scene-out", in: arguments) == nil && value("--thumbnail", in: arguments) == nil)
        #expect(!arguments.contains(folder.preview.path) && !arguments.contains(folder.curves.path))
    }

    /// With light tracers the run is drawn at `--particles` and stepped at `--massive`: the
    /// step, the settle and the softening are those of a hires of the massive count alone.
    @Test func hiresWithTracersStepsAtTheMassiveCount() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func hires(_ options: [String]) throws -> (arguments: [String], record: SceneFolder.Hires) {
            try folder.hiresArguments(options, maximumParticles: 10_000_000)
        }
        let traced = try hires(["--particles", "8e6", "--massive", "2e6"])
        let massive = try hires(["--particles", "2e6"])
        let real = try hires(["--particles", "8e6"])
        #expect(traced.record.particles == 8_000_000 && traced.record.massive == 2_000_000)
        #expect(traced.record.massiveParticles == 2_000_000 && traced.record.tracers == 6_000_000)
        #expect(traced.record.timeStep == massive.record.timeStep)
        #expect(traced.record.settle == massive.record.settle && traced.record.steps == massive.record.steps)
        #expect(traced.record.softening == massive.record.softening)
        #expect(real.record.timeStep < traced.record.timeStep && real.record.massive == nil)
        #expect(value("--particles", in: traced.arguments) == "8000000")
        #expect(value("--massive", in: traced.arguments) == "2000000")
        #expect(traced.arguments.filter { $0 == "--massive" }.count == 1)
        #expect(value("--dt", in: traced.arguments) == value("--dt", in: massive.arguments))
        #expect(!real.arguments.contains("--massive"))
        // As many massive as are drawn, or more, is a run without tracers.
        let all = try hires(["--particles", "2e6", "--massive", "8e6"])
        #expect(all.record == massive.record && all.arguments == massive.arguments)
        #expect(throws: SceneFolder.HiresError.self) { try hires(["--massive", "many"]) }
        #expect(throws: SceneFolder.HiresError.self) { try hires(["--massive"]) }
        // The tracers walk at the scene's angle: a looser one drifts them off the mass.
        #expect(throws: SceneFolder.HiresError.self) {
            try hires(["--massive", "2e6", "--theta-tracers", "1.3"])
        }

        // The record keeps both counts, and one written before tracers reads as all massive.
        let read = try JSONDecoder().decode(SceneFolder.Hires.self, from: traced.record.encoded())
        #expect(read == traced.record)
        let plain = try massive.record.encoded()
        #expect(!String(decoding: plain, as: UTF8.self).contains("massive"))
        let old = try JSONDecoder().decode(SceneFolder.Hires.self, from: plain)
        #expect(old.massive == nil && old.massiveParticles == 2_000_000 && old.tracers == 0)
        // A real run stands for one with tracers, not the other way round.
        #expect(real.record.covers(particles: 8_000_000, massive: 2_000_000, frames: nil))
        #expect(traced.record.covers(particles: 8_000_000, massive: 2_000_000, frames: nil))
        #expect(!traced.record.covers(particles: 8_000_000, massive: nil, frames: nil))
        #expect(!traced.record.covers(particles: 4_000_000, massive: 2_000_000, frames: nil))
        #expect(!traced.record.covers(particles: 8_000_000, massive: 2_000_000, frames: 30))
        #expect(SceneFolder.massive(in: ["--particles", "8e6", "--massive", "2e6"]) == 2_000_000)
        #expect(SceneFolder.massive(in: ["--massive", "inf"]) == nil)

        // A hires queued with tracers is priced with them.
        let model = CostModel.fallback()
        let job = QueueJob(
            id: 0, kind: .hires, path: folder.url.path,
            options: ["--particles", "8000000", "--massive", "2000000"], added: Date())
        let priced = try model.hiresSeconds(folder, particles: 8_000_000, massive: 2_000_000)
        #expect(JobEstimate.seconds(job, cost: model) == priced)
        #expect(priced < (try model.hiresSeconds(folder, particles: 8_000_000)) * 0.6)
    }

    /// Two passes (#239): the massive particles of the draw alone, then the whole draw again,
    /// drawing the videos as it goes, framed on the first's take.
    @Test func aHiresInTwoPassesRunsTheMassiveParticlesThenDrawsTheVideos() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func hires(_ options: [String]) throws -> (arguments: [String], record: SceneFolder.Hires) {
            try folder.hiresArguments(options, maximumParticles: 10_000_000)
        }
        let draw = ["--particles", "8e6", "--massive", "2e6"]
        let whole = try hires(draw)
        let massive = try hires(draw + ["--pass", "massive"])
        #expect(massive.arguments.contains("--massive-only") && !whole.arguments.contains("--massive-only"))
        #expect(massive.record.pass == .massive && whole.record.pass == nil)
        #expect(value("--take", in: massive.arguments) == value("--take", in: whole.arguments))
        #expect(value("--dt", in: massive.arguments) == value("--dt", in: whole.arguments))
        #expect(!massive.arguments.contains("--pass"))
        // Without tracers there is nothing to draw in a second pass.
        #expect(throws: SceneFolder.HiresError.self) {
            try hires(["--particles", "2e6", "--pass", "massive"])
        }
        #expect(throws: SceneFolder.HiresError.self) { try hires(draw + ["--pass", "twice"]) }

        // The full pass follows a massive pass of the same draw and steps, and only that.
        #expect(throws: SceneFolder.HiresError.self) { try hires(draw + ["--pass", "full"]) }
        try whole.record.encoded().write(to: folder.hires)
        try Data().write(to: folder.take)
        #expect(throws: SceneFolder.HiresError.self) { try hires(draw + ["--pass", "full"]) }
        try massive.record.encoded().write(to: folder.hires)
        #expect(throws: SceneFolder.HiresError.self) {
            try hires(["--particles", "8e6", "--massive", "1e6", "--pass", "full"])
        }
        let full = try hires(draw + ["--pass", "full"])
        #expect(full.record == massive.record)
        #expect(value("--draw", in: full.arguments) == "4k,vertical")
        #expect(value("--draw-take", in: full.arguments) == folder.take.path)
        #expect(value("--draw-out", in: full.arguments) == folder.exports.path)
        #expect(value("--key-frames", in: full.arguments) == SceneFolder.partial(folder.keyFrames).path)
        #expect(value("--key-frame-curves", in: full.arguments) == folder.hiresCurves.path)
        for flag in ["--video", "--curves", "--take", "--massive-only"] {
            #expect(!full.arguments.contains(flag))
        }
        for flag in ["--particles", "--massive", "--dt", "--settle", "--steps", "--frames", "--scene"] {
            #expect(value(flag, in: full.arguments) == value(flag, in: massive.arguments))
        }
        let square = try hires(draw + ["--pass", "full", "--export", "square,4k"])
        #expect(value("--draw", in: square.arguments) == "square,4k")
        #expect(throws: SceneFolder.HiresError.self) {
            try hires(draw + ["--pass", "full", "--export", "webp"])
        }

        // A massive pass stands for the first of two passes only, and a full pass is done once
        // it has drawn.
        #expect(massive.record.covers(particles: 8_000_000, massive: 2_000_000, frames: nil, passes: 2))
        #expect(!massive.record.covers(particles: 8_000_000, massive: 2_000_000, frames: nil))
        #expect(whole.record.covers(particles: 8_000_000, massive: 2_000_000, frames: nil, passes: 2))
        #expect(massive.record.simulatedTracers == 0 && massive.record.tracers == 6_000_000)
        #expect(folder.hiresDone(draw + ["--pass", "massive"], maximumParticles: 10_000_000))
        #expect(!folder.hiresDone(draw, maximumParticles: 10_000_000))
        #expect(!folder.hiresDone(draw + ["--pass", "full"], maximumParticles: 10_000_000))
        var drawn = massive.record
        drawn.full = SceneFolder.Hires.FullPass(
            presets: ["4k"], frames: 900, seconds: 3_000, drawSeconds: ["4k": 90])
        try drawn.encoded().write(to: folder.hires)
        #expect(folder.hiresDone(draw + ["--pass", "full"], maximumParticles: 10_000_000))
        let read = try JSONDecoder().decode(SceneFolder.Hires.self, from: drawn.encoded())
        #expect(read == drawn && read.full?.drawingSeconds == 90)
        // A record of one pass writes neither field.
        let text = String(decoding: try whole.record.encoded(), as: UTF8.self)
        #expect(!text.contains("\"pass\"") && !text.contains("\"full\""))

        // Queued, the massive pass is priced as its massive particles alone, the full pass as
        // the whole run and each preset's frames drawn.
        let model = CostModel.fallback()
        func job(_ options: [String]) -> QueueJob {
            QueueJob(id: 0, kind: .hires, path: folder.url.path, options: options, added: Date())
        }
        let alone = try model.hiresSeconds(folder, particles: 2_000_000)
        let run = try model.hiresSeconds(folder, particles: 8_000_000, massive: 2_000_000)
        #expect(JobEstimate.seconds(job(draw + ["--pass", "massive"]), cost: model) == alone)
        let uhd = try #require(VideoPreset.named("4k"))
        let drawing = model.drawSeconds(preset: uhd, particles: 8_000_000, frames: massive.record.frames)
        let priced = try #require(
            JobEstimate.seconds(job(draw + ["--pass", "full", "--export", "4k"]), cost: model))
        #expect(abs(priced - (run + drawing)) < 1e-6)
    }

    /// A full pass checkpoints about every hour by the cost model's prices, unless told
    /// otherwise, and resumes only a checkpoint of its own run (#240).
    @Test func aFullPassCheckpointsAboutEveryHourAndResumesOnlyItsOwnCheckpoint() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func hires(_ options: [String]) throws -> (arguments: [String], record: SceneFolder.Hires) {
            try folder.hiresArguments(options, maximumParticles: 10_000_000)
        }
        let draw = ["--particles", "8e6", "--massive", "2e6"]
        let massive = try hires(draw + ["--pass", "massive"])
        #expect(!massive.arguments.contains("--checkpoint"))
        try massive.record.encoded().write(to: folder.hires)
        try Data().write(to: folder.take)
        let full = try hires(draw + ["--pass", "full"])
        #expect(value("--checkpoint", in: full.arguments) == folder.checkpoint.path)
        let model = CostModel.current(library: folder.library)
        let step = model.hires.secondsPerUnit * 2e6 + model.tracers.secondsPerUnit * 6e6
        let steps = try #require(value("--checkpoint-steps", in: full.arguments).flatMap(Int.init))
        let frames = try #require(value("--checkpoint-frames", in: full.arguments).flatMap(Int.init))
        #expect(abs(Double(steps) * step - 3_600) <= step)
        #expect(frames >= 1 && frames * (massive.record.steps / massive.record.frames) <= steps)
        let off = try hires(draw + ["--pass", "full", "--checkpoint-every", "0"])
        #expect(!off.arguments.contains("--checkpoint"))
        let exact = try hires(
            draw + ["--pass", "full", "--checkpoint-frames", "5", "--checkpoint-steps", "50"])
        #expect(value("--checkpoint-frames", in: exact.arguments) == "5")
        #expect(exact.arguments.filter { $0 == "--checkpoint-frames" }.count == 1)
        #expect(throws: SceneFolder.HiresError.self) {
            try hires(draw + ["--pass", "full", "--checkpoint-every", "soon"])
        }

        // Nothing to resume, then a checkpoint of this very run, then the look changed.
        let options = draw + ["--pass", "full"]
        #expect(!folder.resumesFullPass(options, maximumParticles: 10_000_000))
        let identity = RunCheckpoint.Identity(
            arguments: full.arguments, scene: try String(contentsOf: folder.scene, encoding: .utf8),
            look: try String(contentsOf: folder.look, encoding: .utf8),
            framing: RunCheckpoint.stamp(folder.take),
            particles: 8_000_000, massive: 2_000_000, timeStep: 0.02, presets: ["4k", "vertical"], code: "")
        let run = RunCheckpoint.Run(
            identity: identity, index: 1, frame: 10, settled: 0, elapsed: 1, resumes: 0, everyFrames: frames,
            everySteps: steps,
            solver: MetalBarnesHutSolver.State(
                count: 1, tracers: 0, time: 0, stepsSinceTree: 0, stepsSinceFormation: 0, haloCenters: [],
                massCenters: [], galaxyMotion: [], diskStates: []),
            videos: nil, keyFrames: [])
        let checkpoint = RunCheckpoint(directory: folder.checkpoint)
        try checkpoint.saveMassive(ParticleSystem())
        try checkpoint.save(run) { _ in }
        #expect(folder.resumesFullPass(options, maximumParticles: 10_000_000))
        #expect(
            !folder.resumesFullPass(
                draw + ["--pass", "full", "--export", "4k"], maximumParticles: 10_000_000))
        try Data(#"{"name": "another"}"#.utf8).write(to: folder.look)
        #expect(!folder.resumesFullPass(options, maximumParticles: 10_000_000))
    }

    @Test func anOutputIsWrittenHiddenAndPutInPlaceWhole() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(SceneFolder.partial(folder.take).path == folder.url.path + "/.take.sillage")
        try Data("old".utf8).write(to: folder.take)
        for url in [folder.take, folder.hiresVideo, folder.hiresCurves] {
            try Data("new".utf8).write(to: SceneFolder.partial(url))
        }
        try folder.commitHires()
        #expect(try String(contentsOf: folder.take, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: SceneFolder.partial(folder.take).path))
        #expect(throws: POSIXError.self) { try SceneFolder.commit(folder.preview) }
    }

    @Test func whatAnInterruptedStageLeftIsRemovedAndNothingElse() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let manager = FileManager.default
        try manager.createDirectory(at: folder.exports, withIntermediateDirectories: true)
        let exploring = folder.batch.appendingPathComponent(".scene-0002")
        try manager.createDirectory(at: exploring, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: folder.batch.appendingPathComponent(".logs"), withIntermediateDirectories: true)
        let partials = [
            SceneFolder.partial(folder.take), SceneFolder.partial(folder.hiresVideo),
            folder.exports.appendingPathComponent(".4k.mp4"),
        ]
        let kept = [
            folder.take, folder.exports.appendingPathComponent("4k.mp4"),
            folder.exports.appendingPathComponent(".DS_Store"),
        ]
        for url in partials + kept { try Data("x".utf8).write(to: url) }

        let removed = SceneFolder.removePartialOutputs(inBatch: folder.batch)
        #expect(
            Set(removed.map(\.lastPathComponent)) == [
                ".scene-0002", ".take.sillage", ".hires.mov", ".4k.mp4",
            ])
        #expect(partials.allSatisfy { !manager.fileExists(atPath: $0.path) })
        #expect(kept.allSatisfy { manager.fileExists(atPath: $0.path) })
        #expect(manager.fileExists(atPath: folder.batch.appendingPathComponent(".logs").path))
        #expect(folder.removePartialOutputs().isEmpty)
    }

    @Test func hiresReplaysTheStoryExploreFollowed() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        var clip = try folder.storedClip()
        clip.frames = 1_200
        clip.steps = 9_600
        clip.story = Story.Span(startFrame: 100, endFrame: 1_099, startMyr: 0, endMyr: 0, complete: true)
        try clip.encoded().write(to: folder.clip)
        #expect(try folder.storedClip() == clip)

        let same = try folder.hiresArguments(["--particles", "400000"], maximumParticles: 10_000_000)
        #expect(same.record.frames == 1_000 && same.record.steps == 8_000)
        #expect(same.record.settle == 400 + 100 * 8)
        #expect(value("--frames", in: same.arguments) == "1000")
        let first = try folder.hiresArguments(
            ["--particles", "400000", "--frames", "30"], maximumParticles: 10_000_000)
        #expect(first.record.frames == 30 && first.record.settle == same.record.settle)
    }

    @Test func aShorterStoryCostsLessAtHighResolution() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let model = CostModel.fallback()
        let whole = try model.hiresSeconds(folder, particles: 2_000_000)
        var clip = try folder.storedClip()
        clip.story = Story.Span(startFrame: 300, endFrame: 599, startMyr: 0, endMyr: 0, complete: true)
        try clip.encoded().write(to: folder.clip)
        let story = try model.hiresSeconds(folder, particles: 2_000_000)
        #expect(story < whole * 0.75 && story > whole * 0.5)
    }

    @Test func exploreFollowsTheStoryUnlessCapped() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(value("--story-cap", in: folder.exploreArguments([], clip: .init())) == String(Story.capMyr))
        let capped = folder.exploreArguments(["--story-cap", "0"], clip: .init())
        #expect(value("--story-cap", in: capped) == "0" && capped.filter { $0 == "--story-cap" }.count == 1)
    }

    /// Without `--particles` a hires draws what a night draws (#243): 8 M from 2 M massive, or
    /// the machine's maximum below that. `--particles N` alone is a real N.
    @Test func hiresDrawsAsANightUnlessGivenACount() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func hires(_ options: [String], maximum: Int = 10_000_000) throws -> (
            arguments: [String], record: SceneFolder.Hires
        ) {
            try folder.hiresArguments(options, maximumParticles: maximum)
        }
        let drawn = try hires([])
        #expect(drawn.record.particles == 8_000_000 && drawn.record.massive == 2_000_000)
        #expect(value("--particles", in: drawn.arguments) == "8000000")
        #expect(value("--massive", in: drawn.arguments) == "2000000")
        let night = NightFolder(batch: folder.batch, recipe: NightRecipe(), maximumParticles: 10_000_000)
        #expect(try hires(night.hiresOptions).arguments == drawn.arguments)
        let fewer = try hires(["--massive", "1e6"]).record
        #expect(fewer.particles == 8_000_000 && fewer.massive == 1_000_000)
        let small = try hires([], maximum: 1_500_000)
        #expect(small.record.particles == 1_500_000 && small.record.massive == nil)
        #expect(!small.arguments.contains("--massive"))
        let real = try hires(["--particles", "8e6"])
        #expect(real.record.particles == 8_000_000 && real.record.massive == nil)
        #expect(!real.arguments.contains("--massive"))

        // A batch asked again skips a scene done so, or done at a real 8 M.
        #expect(!folder.hiresDone([], maximumParticles: 10_000_000))
        try drawn.record.encoded().write(to: folder.hires)
        #expect(folder.hiresDone([], maximumParticles: 10_000_000))
        #expect(!folder.hiresDone(["--particles", "8e6"], maximumParticles: 10_000_000))
        try real.record.encoded().write(to: folder.hires)
        #expect(folder.hiresDone([], maximumParticles: 10_000_000))
        #expect(!folder.hiresDone(["--frames", "30"], maximumParticles: 10_000_000))

        // A job queued without a count is priced and named as it will run.
        let job = QueueJob(id: 0, kind: .hires, path: folder.url.path, added: Date())
        let planned = try hires([], maximum: SceneFolder.maximumParticles()).record
        let model = CostModel.fallback()
        #expect(
            JobEstimate.seconds(job, cost: model)
                == (try model.hiresSeconds(folder, particles: planned.particles, massive: planned.massive)))
        #expect(StageJobs.title(of: job) == StageJobs.particles(planned.particles, massive: planned.massive))
    }

    /// A preview explored at 7 in half the steps runs the same hires as one explored at 3.5.
    @Test func hiresRunsAtItsOwnScaleWhateverThePreviewRanAt() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let options = ["--particles", "8e6", "--massive", "2e6"]
        let reference = try folder.hiresArguments(options, maximumParticles: 10_000_000)
        var file = try SceneFile.decoded(from: Data(contentsOf: folder.scene))
        file.timeStepScale = 7
        try file.encoded().write(to: folder.scene)
        var clip = try folder.storedClip()
        clip.steps /= 2
        clip.settle /= 2
        try clip.encoded().write(to: folder.clip)
        let doubled = try folder.hiresArguments(options, maximumParticles: 10_000_000)

        #expect(reference.record.timeStepScale == SceneFolder.hiresTimeStepScale)
        #expect(doubled.record.timeStepScale == SceneFolder.hiresTimeStepScale)
        #expect(doubled.record.previewTimeStepMyr == 2 * reference.record.previewTimeStepMyr)
        #expect(doubled.record.timeStep == reference.record.timeStep)
        #expect(doubled.record.settle == reference.record.settle)
        #expect(doubled.record.steps == reference.record.steps)
        #expect(value("--dt", in: doubled.arguments) == value("--dt", in: reference.arguments))
        let given = try folder.hiresArguments(options + ["--dt-scale", "7"], maximumParticles: 10_000_000)
        #expect(given.record.timeStepScale == 7 && given.record.timeStep > doubled.record.timeStep)
    }

    @Test func hiresNeverRunsAboveTheMaximum() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(throws: SceneFolder.HiresError.self) {
            try folder.hiresArguments(["--particles", "3e6"], maximumParticles: 2_000_000)
        }
        #expect(throws: SceneFolder.HiresError.self) {
            try folder.hiresArguments(["--steps", "100"], maximumParticles: 2_000_000)
        }
        let scaled = try folder.hiresArguments(
            ["--particles", "1e6", "--dt-scale", "1"], maximumParticles: 2_000_000)
        let kept = try folder.hiresArguments(["--particles", "1e6"], maximumParticles: 2_000_000)
        #expect(scaled.record.timeStep < kept.record.timeStep && scaled.record.timeStepScale == 1)
        #expect(SceneFolder.maximumParticles(environment: [:]) == SceneFolder.defaultMaximumParticles)
        #expect(SceneFolder.maximumParticles(environment: ["SILLAGE_MAX_PARTICLES": "5e6"]) == 5_000_000)
    }

    @Test func aBatchRunsTheScenesMarkedYes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        try SceneRatings(scenes: [
            "scene-0001": .init(choice: .yes), "scene-0002": .init(choice: .no),
            "scene-0003": .init(choice: .yes, rating: 7),
        ]).write(batch: folder.batch)
        #expect(
            SceneFolder.chosen(inBatch: folder.batch).map { $0.url.lastPathComponent } == [
                "scene-0001", "scene-0003",
            ])
        #expect(!SceneFolder(folder.batch).isExplored)
    }

    @Test func aBatchAlsoRunsTheScenesPickedByTheScore() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let pick = SceneRatings.Pick(score: 0.8, date: Date(timeIntervalSince1970: 0))
        try SceneRatings(scenes: [
            "scene-0001": .init(picked: pick), "scene-0002": .init(choice: .no, picked: pick),
            "scene-0003": .init(choice: .yes, picked: pick), "scene-0004": .init(rating: 5),
        ]).write(batch: folder.batch)
        #expect(
            SceneFolder.chosen(inBatch: folder.batch).map { $0.url.lastPathComponent } == [
                "scene-0001", "scene-0003",
            ])
    }

    @Test func promotingALookKeepsTheFirstOneAside() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        try LookFile.raw.encoded().write(to: folder.look)
        var first = LookFile.standard
        first.name = "first"
        try folder.promote(first)
        var second = first
        second.name = "second"
        try folder.promote(second)
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.look)) == second)
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.rawLook)) == .raw)
    }
}
