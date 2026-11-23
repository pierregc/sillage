import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// The commands that read a take or a scene's files and draw nothing, run the same by either
/// engine (#467): `flight`, the story `pace` and `look --promote | --palette`.
@Suite("Drawless commands")
struct DrawlessCommandsTests {
    /// The engines' fixture as a scene folder: its scene, clip and take.
    static func folder() throws -> SceneFolder {
        let fixtures = try RepositoryRoot.resolve().appendingPathComponent("Tests/Fixtures/engines")
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent("drawless-\(UUID().uuidString)")
                .appendingPathComponent("scene-0001"))
        let manager = FileManager.default
        try manager.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try manager.copyItem(at: fixtures.appendingPathComponent("scene/scene.json"), to: folder.scene)
        try manager.copyItem(at: fixtures.appendingPathComponent("scene/clip.json"), to: folder.clip)
        try manager.copyItem(at: fixtures.appendingPathComponent("frames/take.sillage"), to: folder.take)
        return folder
    }

    @Test func flightPrintsEachGalaxyAndTheLooksCameraAtEachMoment() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }
        let take = try RecordingFile.read(from: folder.take)
        let megayears = TimeTrack.megayears(of: take.recording)
        let lines = try FlightReport.lines(
            [folder.url.path, "--at", "\(megayears[0])", "--arms", "2,4"], catalogue: [])
        let galaxies = take.scene.galaxies.count
        #expect(lines.filter { $0.hasPrefix("galaxy ") }.count == galaxies)
        #expect(lines.filter { $0.hasPrefix("  densest at ") }.count == galaxies * 2)
        #expect(lines.last?.hasPrefix("look       {\"eye\": [") == true)
    }

    @Test func flightWithoutMomentsIsRefused() throws {
        #expect(throws: FlightReport.Failure.self) { try FlightReport.lines(["somewhere"], catalogue: []) }
    }

    @Test func theVisualPaceIsRefusedWithWhereToRunIt() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }
        #expect(throws: PaceStory.Failure.self) {
            try PaceStory.lines([folder.url.path, "--speed", "visual"], command: "sillage-cuda")
        }
    }

    @Test func aPalettePutInTheLookIsTheSceneSeedsBest() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }
        let lines = try LookChoice.lines([folder.url.path, "--palette", "auto"], command: "sillage-cuda")
        #expect(lines.count == 1 && lines[0].contains("is now in"))
        let look = try LookFile.decoded(from: Data(contentsOf: folder.look))
        #expect(look.paletteRecipe != nil)
        #expect(look.palette.count == (try LookChoice.sceneSeed(folder)).galaxies)
    }

    @Test func drawingALookIsLeftToTheMac() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }
        for option in ["--grid", "--style"] {
            #expect(throws: LookChoice.Failure.self) {
                try LookChoice.lines([folder.url.path, option, "auto"], command: "sillage-cuda")
            }
        }
    }
}
