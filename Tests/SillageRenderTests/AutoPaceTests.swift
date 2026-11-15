import Foundation
import SillageCore
import Testing

@testable import SillageRender

/// Automatic pace in nights, the queue's estimates and the export panel's jobs (#311).
@Suite("Automatic pace")
struct AutoPaceTests {
    private func recipe(_ json: String) throws -> NightRecipe {
        try NightRecipe.decoded(from: Data(json.utf8))
    }

    @Test func aNightsSpeedIsOneANumberOrAuto() throws {
        #expect(NightRecipe().speed == .constant(1) && NightRecipe().speed.argument == nil)
        #expect(try recipe(#"{"version": 1}"#).speed == .constant(1))
        let auto = try recipe(#"{"speed": "auto"}"#)
        #expect(auto.speed == .auto && auto.speed.argument == "auto")
        let twice = try recipe(#"{"speed": 2}"#)
        #expect(twice.speed == .constant(2) && twice.speed.argument == "2")
        #expect(try recipe(#"{"speed": 0.5}"#).speed.argument == "0.5")
        #expect(try recipe(#"{"speed": 1}"#).speed.argument == nil)
        #expect(try NightRecipe.decoded(from: auto.encoded()) == auto)
        #expect(try NightRecipe.decoded(from: twice.encoded()) == twice)
        for bad in [#"{"speed": 0.1}"#, #"{"speed": 17}"#, #"{"speed": "fast"}"#, #"{"speed": true}"#] {
            #expect(throws: (any Error).self) { try recipe(bad) }
        }
    }

    @Test func aNightsPlanCountsTheVideosFramesFromItsSpeed() {
        var scene = NightScene(name: nil, score: nil, exploreUnits: 0, hiresUnits: 1e6, frames: 900)
        scene.name = "scene-0001"
        let model = CostModel.fallback(at: Date(timeIntervalSince1970: 1_800_000_000))
        func planner(_ speed: NightRecipe.Speed) -> NightPlanner {
            var recipe = NightRecipe()
            recipe.speed = speed
            return NightPlanner(recipe: recipe, model: model, maximumParticles: 10_000_000, freeBytes: 500e9)
            { _ in [scene] }
        }
        #expect(planner(.constant(1)).videoFrames(scene) == 900)
        #expect(planner(.constant(2)).videoFrames(scene) == 450)
        #expect(planner(.auto).videoFrames(scene) == Int((900 * PaceSpec.expectedShare).rounded()))
        let (plain, auto) = (planner(.constant(1)), planner(.auto))
        #expect(auto.finishSeconds(scene, pick: 0) < plain.finishSeconds(scene, pick: 0))
    }

    // MARK: A scene whose curves say how long the video is

    /// A merger explored at 400 000 particles, its curves: the galaxies close in over the first
    /// third, merge, and nothing changes after the half.
    private func scene() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopace-\(UUID().uuidString)").appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SceneFolder(url)
        var config = SceneConfig.merger(particleCount: 400_000)
        config.solver = .barnesHut
        try SceneFile(config).encoded().write(to: folder.scene)
        var clip = SceneFolder.Clip()
        clip.particles = 400_000
        clip.frames = 600
        clip.fps = 30
        try clip.encoded().write(to: folder.clip)
        var csv =
            "time_myr,extent_kpc,tidal_fraction,formed,x_0,y_0,z_0,x_1,y_1,z_1,disruption_0,disruption_1\n"
        for frame in 0..<600 {
            let along = Double(frame) / 599
            let apart = max(60 * (1 - along / 0.35), 0)
            let tails = min(along / 0.5, 1) * 0.3
            let extent = 40 + 30 * min(along / 0.5, 1)
            csv += String(
                format: "%.3f,%.3f,%.4f,100,%.3f,0,0,%.3f,0,0,%.3f,%.3f\n", 100 + 0.8 * Double(frame), extent,
                tails, -apart / 2, apart / 2, min(along / 0.5, 1) * 0.3, min(along / 0.5, 1) * 0.3)
        }
        try csv.write(to: folder.curves, atomically: true, encoding: .utf8)
        return folder
    }

    @Test func anAutoVideoIsShorterThanItsTakeAndAConstantOneIsExact() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        #expect(VideoLength.share(of: nil, folder: folder) == 1)
        #expect(VideoLength.share(of: "1", folder: folder) == 1)
        #expect(VideoLength.share(of: "2", folder: folder) == 0.5)
        #expect(VideoLength.share(of: "0.25", folder: folder) == 4)
        let auto = VideoLength.share(of: "auto", folder: folder)
        #expect(auto < 0.97 && auto > 0.3, "\(auto)")
        // The pace's own names are the same thing.
        #expect(VideoLength.share(of: "story:4:8", folder: folder) == auto)
        // A bolder one is shorter still.
        #expect(VideoLength.share(of: "story:8:8", folder: folder) <= auto)
        // A scene with no curves says what the pace keeps on average.
        let bare = try scene()
        defer { try? FileManager.default.removeItem(at: bare.batch) }
        try FileManager.default.removeItem(at: bare.curves)
        #expect(VideoLength.share(of: "auto", folder: bare) == PaceSpec.expectedShare)
    }

    @Test func aTrackFileCountsFromItsOwnLength() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func file(_ track: TimeTrackFile, _ name: String) throws -> String {
            let url = folder.batch.appendingPathComponent(name)
            try track.encoded().write(to: url)
            return url.path
        }
        let slow = try file(
            TimeTrackFile(ramp: 0, speeds: Array(repeating: 0.5, count: 600)), "slow.time.json")
        #expect(abs(VideoLength.share(of: slow, folder: folder) - 2) < 1e-6)
        let flight = try file(
            TimeTrackFile(times: [.init(at: 0, myr: 100), .init(at: 10, myr: 579.2)]), "flight.time.json")
        // 10 s of video for a 599 frame take at 30 fps.
        #expect(abs(VideoLength.share(of: flight, folder: folder) - 300.0 / 599) < 1e-6)
        let keys = try file(
            TimeTrackFile(
                ramp: 0, keys: [.init(myr: 100, speed: 1), .init(myr: 340, speed: 2)]), "keys.time.json")
        let kept = VideoLength.share(of: keys, folder: folder)
        #expect(kept < 1 && kept > 0.5, "\(kept)")
        #expect(VideoLength.share(of: "/nowhere.time.json", folder: folder) == 1)
    }

    @Test func theQueueCountsAnExportsFramesFromItsTrack() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let cost = CostModel.fallback(at: Date(timeIntervalSince1970: 1_800_000_000))
        func seconds(_ options: [String]) throws -> Double {
            let job = QueueJob(id: 1, kind: .export, path: folder.url.path, options: options, added: Date())
            return try #require(JobEstimate.seconds(job, cost: cost))
        }
        let plain = try seconds(["--preset", "1080p"])
        let twice = try seconds(["--preset", "1080p", "--speed", "2"])
        let auto = try seconds(["--preset", "1080p", "--speed", "auto"])
        let line = cost.exportLine(preset: try #require(VideoPreset.named("1080p")), codec: .hevc)
        #expect(abs(plain - line.seconds(600)) < 1e-6)
        #expect(abs(twice - line.seconds(300)) < 1e-6)
        #expect(auto < plain && auto > line.seconds(150))
        // The duration asked is in video seconds, whatever the track.
        let cut = try seconds(["--preset", "1080p", "--speed", "auto", "--duration", "10"])
        #expect(abs(cut - line.seconds(300)) < 1e-6)
    }

    // MARK: The export panel's jobs

    private let cost = CostModel.fallback(at: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func aSpeedGoesToTheCommandAndNamesTheFile() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        func plan(_ speed: ExportSpeed) -> PlannedJob {
            var settings = ExportSettings()
            settings.speed = speed
            return StageJobs.export(
                .uhd, settings, folder: folder, state: ExportFolderState(), cost: cost, queue: JobQueue())
        }
        let plain = plan(.plain)
        #expect(!plain.options.contains("--speed") && plain.output?.lastPathComponent == "4k.mp4")
        let auto = plan(.auto)
        #expect(auto.options.starts(with: ["--preset", "4k", "--speed", "auto"]))
        #expect(auto.output?.lastPathComponent == "4k-auto.mp4" && !auto.replaces)
        #expect(plan(.constant(0.5)).output?.lastPathComponent == "4k-x0.5.mp4")
        #expect(plan(.constant(4)).options.contains("4"))
        let track = URL(fileURLWithPath: "/somewhere/pace.time.json")
        let named = plan(.track(track))
        #expect(named.options.contains(track.path) && named.output?.lastPathComponent == "4k-pace.mp4")
        #expect((auto.seconds ?? 0) <= (plain.seconds ?? 0))
        // The same speed asked twice is one job; another speed is another.
        var queue = JobQueue()
        _ = queue.add(.export, path: folder.url.path, options: auto.options, at: Date())
        var settings = ExportSettings()
        settings.speed = .auto
        let again = StageJobs.export(
            .uhd, settings, folder: folder, state: ExportFolderState(), cost: cost, queue: queue)
        #expect(again.queued)
        #expect(!plan(.constant(2)).queued)
    }
}
