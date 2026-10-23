import Foundation
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
        #expect(SceneFolder.Stage.allCases.filter { $0.pendingIssue != nil }.count == 3)
    }

    /// A first run generates the scene; a second reads back what the first wrote, so it can
    /// be redone at will, and the options given still override it.
    @Test func exploreStartsAFreshSceneThenReplaysTheOneItWrote() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.batch) }

        let first = folder.exploreArguments(["--seed", "42"], clip: .init())
        #expect(value("--preset", in: first) == "contemplation")
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
}
