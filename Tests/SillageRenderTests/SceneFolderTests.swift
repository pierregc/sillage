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

    @Test func onlyTheStagesStillToComeAreRefused() {
        #expect(SceneFolder.Stage.explore.pendingIssue == nil)
        #expect(SceneFolder.Stage.allCases.filter { $0.pendingIssue != nil }.count == 1)
        #expect(SceneFolder.Stage.hires.pendingIssue == nil)
        #expect(SceneFolder.Stage.look.pendingIssue == nil)
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
        #expect(value("--video", in: arguments) == folder.hiresVideo.path)
        #expect(value("--curves", in: arguments) == folder.hiresCurves.path)
        #expect(value("--take", in: arguments) == folder.take.path)
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

    @Test func hiresRunsAtTheMaximumUnlessToldAndNeverAboveIt() throws {
        let folder = try explored()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(try folder.hiresArguments([], maximumParticles: 1_500_000).record.particles == 1_500_000)
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

    @Test func promotingALookKeepsTheFirstOneAside() throws {
        let folder = try temporaryFolder()
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
