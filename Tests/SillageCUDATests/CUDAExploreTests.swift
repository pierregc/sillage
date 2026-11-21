import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

/// A scene's preview on CUDA (#430): `sillage-cuda explore` on scene-0031 of the fixtures at
/// 3,000 particles leaves the folder a Mac's explore leaves, and `sillage-cuda hires` takes it
/// from there. Serialized: the solver's settings are global, and the videos go through ffmpeg.
@Suite("CUDA explore", .serialized, .solverSettings)
struct CUDAExploreTests {
    static let options = [
        "--particles", "3000", "--width", "256", "--height", "144", "--frames", "12", "--fps", "6",
        "--steps", "48", "--settle", "6",
    ]

    static func folder(scene: Bool) throws -> SceneFolder {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent("explore-\(UUID().uuidString)")
                .appendingPathComponent("2026-10-30-b").appendingPathComponent("scene-0031"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        if scene {
            try FileManager.default.copyItem(
                at: CUDAFullPassTests.fixtures.appendingPathComponent("scene/scene.json"), to: folder.scene)
        }
        return folder
    }

    static func explore(_ folder: SceneFolder, _ options: [String]) throws -> TakePassRun.Outcome {
        try CUDAExplore.run(
            folder, options: options, context: try CUDAContext(), threads: 4,
            checkRecord: CUDAFullPassTests.checked)
    }

    @Test func anExploredSceneLeavesTheMacsFilesAndGoesOnToItsHires() throws {
        let folder = try Self.folder(scene: true)
        defer { CUDATakePassTests.remove(folder) }
        #expect(try Self.explore(folder, Self.options + ["--story-cap", "30"]) == .done)

        for url in [folder.clip, folder.scene, folder.look, folder.preview, folder.curves, folder.thumbnail] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        let clip = try folder.storedClip()
        #expect(clip.particles == 3_000 && clip.width == 256 && clip.fps == 6 && clip.settle == 6)
        let frames = try FFmpegVideo.frameCount(folder.preview)
        #expect(frames >= 12)
        #expect(clip.story != nil && clip.frames == frames)
        let rows = try String(contentsOf: folder.curves, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == frames + 1)
        _ = try LookFile.decoded(from: Data(contentsOf: folder.look))

        try CUDATakePassTests.hires(
            folder, ["--particles", "3000", "--checkpoint-every", "0"], context: CUDAContext())
        let take = try RecordingFile.read(from: folder.take)
        #expect(take.recording.particleCount == 3_000 && take.recording.capturedFrames == clip.storyFrames)
        #expect(folder.storedHires()?.engine == CUDAEngineCheck.engine)
    }

    @Test func anEmptyFolderStartsAFreeDrawAtTheBatchsDefaults() throws {
        let folder = try Self.folder(scene: false)
        defer { CUDATakePassTests.remove(folder) }
        let outcome = try Self.explore(
            folder, Self.options + ["--seed", "7", "--index", "31", "--story-cap", "0"])
        #expect(FileManager.default.fileExists(atPath: folder.clip.path))
        if outcome == .done {
            #expect(FileManager.default.fileExists(atPath: folder.scene.path))
            #expect(FileManager.default.fileExists(atPath: folder.preview.path))
        } else {
            #expect(outcome == .rejected)
        }
    }
}
