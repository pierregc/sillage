import AVFoundation
import AppKit
import Foundation
import SillageRender
import SwiftUI

/// Builds a library on disk and drives the window's model through it: scenes arriving,
/// keys, clicks, filters, a ratings file changed by another tool, a render still being
/// written, the single player, and a batch of four hundred. Headless, like `--replay`, and
/// it renders the grid to `out/ui-library.png` for looking at.
@MainActor
enum LibraryCheck {
    private static var lines: [String] = []
    private static var failures = 0
    private static var stills = 0

    static func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-librarycheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try exercise(root)
        } catch {
            check("the walk runs to the end", false, "\(error)")
        }
        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-library.log"), atomically: true, encoding: .utf8)
        print(report)
        try? FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !passed { failures += 1 }
    }

    /// Turns the run loop, which is where the model's tasks resume, until the condition holds.
    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private static func exercise(_ root: URL) throws {
        let batch = root.appendingPathComponent("2026-10-24", isDirectory: true)
        let flat = root.appendingPathComponent("2026-09-21", isDirectory: true)
        for index in 1...3 {
            try writeScene(
                SceneFolder(batch.appendingPathComponent(String(format: "scene-%04d", index))),
                tint: index, archetype: index == 1 ? "antennae" : nil)
        }
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try writeVideo(to: flat.appendingPathComponent("scene-0001.mov"), tint: 4)
        try Data("id,seed,tempo,galaxies\nscene-0001,77,ballet,4\n".utf8)
            .write(to: flat.appendingPathComponent("index.csv"))

        let model = LibraryModel(root: root)
        model.watch()
        defer { model.stop() }
        check(
            "both kinds of batch are read", wait(10) { model.scenes.count == 4 },
            "\(model.scenes.count) scenes")
        check("every video is playable", wait(10) { model.playable.count == 4 }, "\(model.playable.count)")
        let ids = model.visible.map(\.id)
        check(
            "the latest batch comes first",
            ids == [
                "2026-10-24/scene-0001", "2026-10-24/scene-0002", "2026-10-24/scene-0003",
                "2026-09-21/scene-0001",
            ],
            ids.joined(separator: " "))

        stills = 0
        let scenes = model.scenes
        Task {
            for scene in scenes where await ThumbnailCache.shared.load(scene) != nil { stills += 1 }
        }
        check(
            "a still per scene, taken from the video when there is no thumbnail",
            wait(10) { stills == 4 }, "\(stills)")

        // Keys, each one saved as it is pressed.
        let first = SceneFolder(batch.appendingPathComponent("scene-0001"))
        model.handle(.right)
        check("the first arrow selects the first scene", model.selection == "2026-10-24/scene-0001")
        model.handle(.yes)
        let now = Date()
        model.handle(.digit(1), at: now)
        model.handle(.digit(0), at: now.addingTimeInterval(0.2))
        var saved = SceneRatings.read(batch: first.batch).scenes["scene-0001"]
        check(
            "Y then 1 0: yes and 10 in ratings.json", saved?.choice == .yes && saved?.rating == 10,
            "\(String(describing: saved))")
        model.handle(.digit(7), at: now.addingTimeInterval(2))
        model.handle(.digit(0), at: now.addingTimeInterval(4))
        saved = SceneRatings.read(batch: first.batch).scenes["scene-0001"]
        check("a 0 that does not follow a 1 is 0", saved?.rating == 0, "\(String(describing: saved?.rating))")
        model.handle(.right)
        model.handle(.no)
        check(
            "N on the next scene",
            SceneRatings.read(batch: batch).scenes["scene-0002"]?.choice == .no)
        model.columns = 2
        model.handle(.down)
        check("one row down, two columns on", model.selection == "2026-09-21/scene-0001")
        model.handle(.digit(4))
        check(
            "a flat batch has its own ratings.json",
            SceneRatings.read(batch: flat).scenes["scene-0001"]?.rating == 4)
        model.handle(.clear)
        check("clear removes the scene from the file", SceneRatings.read(batch: flat).scenes.isEmpty)

        // Clicks: one saves, the same one again takes it back.
        let third = "2026-10-24/scene-0003"
        model.choose(.yes, for: third)
        let clicked = SceneRatings.read(batch: batch).scenes["scene-0003"]?.choice
        model.choose(.yes, for: third)
        model.rate(6, for: third)
        let rated = SceneRatings.read(batch: batch).scenes["scene-0003"]
        check(
            "a click saves, a second one takes it back",
            clicked == .yes && rated?.choice == nil && rated?.rating == 6)

        // The collections follow the clicks at once, without waiting for a scan.
        let counts = model.counts
        check(
            "the counts follow the choices",
            counts[.toSort] == 2 && counts[.chosen] == 1 && counts[.all] == 4
                && counts[.toStyle] == nil,
            "\(counts)")
        model.query.collection = .chosen
        check("Kept shows only the yes", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query.collection = .toSort
        check(
            "To sort shows neither the yes nor the no",
            model.visible.map(\.id) == ["2026-10-24/scene-0003", "2026-09-21/scene-0001"],
            model.visible.map(\.id).joined(separator: " "))
        model.query.search = "0003"
        check("the search is on the name", model.visible.map(\.id) == ["2026-10-24/scene-0003"])
        model.query = LibraryQuery()
        check(
            "All keeps the discarded ones",
            model.visible.count == 4 && model.visible.contains { $0.stage == .discarded })

        // Filters.
        model.query.choice = .yes
        check("yes filter", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query = LibraryQuery()
        model.query.archetype = "antennae"
        check("archetype filter", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query = LibraryQuery()
        model.query.archetype = LibraryQuery.free
        check("scenes without an archetype are free", model.visible.count == 3)
        model.query = LibraryQuery()
        model.query.batch = "2026-09-21"
        check("batch filter", model.visible.map(\.id) == ["2026-09-21/scene-0001"])
        model.query = LibraryQuery()
        model.query.order = .rating
        check(
            "sort by rating", model.visible.first?.id == "2026-10-24/scene-0003",
            model.visible.map(\.id).joined(separator: " "))
        model.query = LibraryQuery()
        model.query.choice = .undecided
        model.selection = third
        model.handle(.yes)
        check(
            "a scene leaving the filter hands the selection to the next",
            model.selection == "2026-09-21/scene-0001" && !model.visible.contains { $0.id == third },
            model.selection ?? "none")
        model.query = LibraryQuery()

        // Another tool writes the file.
        try SceneRatings.update(batch: batch, scene: "scene-0002") { $0.rating = 3 }
        check(
            "a ratings.json changed elsewhere is read again",
            wait(6) { model.entries["2026-10-24/scene-0002"]?.rating == 3 })

        // A render still writing its preview, then finishing it.
        let arriving = SceneFolder(batch.appendingPathComponent("scene-0004"))
        try FileManager.default.createDirectory(at: arriving.url, withIntermediateDirectories: true)
        try PNGWriter.write(pixels(tint: 5), width: width, height: height, to: arriving.thumbnail)
        try Data("not a video yet".utf8).write(to: arriving.preview)
        check("an arriving scene shows without restarting anything", wait(6) { model.scenes.count == 5 })
        check("while it is being written it does not play", !model.playable.contains("2026-10-24/scene-0004"))
        try writeVideo(to: arriving.preview, tint: 5)
        check("finished, it plays", wait(8) { model.playable.contains("2026-10-24/scene-0004") })

        // One player, following the pointer, then the opened scene.
        model.selection = "2026-10-24/scene-0001"
        check("the selection plays", model.playing == "2026-10-24/scene-0001")
        model.hover("2026-10-24/scene-0002", inside: true)
        check("hovering plays", wait(2) { model.playing == "2026-10-24/scene-0002" })
        model.open("2026-10-24/scene-0003")
        check("the open scene comes before hovering", model.playing == "2026-10-24/scene-0003")
        check(
            "the player really plays",
            wait(5) { model.player.currentItem?.status == .readyToPlay },
            "\(model.player.currentItem?.status.rawValue ?? -1)")
        check("escape closes", model.handle(.close) && model.opened == nil)
        model.hover("2026-10-24/scene-0002", inside: false)
        check(
            "a single player", model.player.items().count <= 3,
            "\(model.player.items().count) items queued")

        var clock = Date()
        try renderShot(model)

        // The card says what the scene is and where it stands.
        var sample = model.scenes[0]
        check("no video, no count", LibraryCard.videoCount(sample) == nil)
        sample.exports = [URL(fileURLWithPath: "/a.mp4"), URL(fileURLWithPath: "/b.mp4")]
        check("the video count", LibraryCard.videoCount(sample) == 2)
        check(
            "every step has a pill",
            Set(SceneStage.allCases.map(\.pillTitle)).count == SceneStage.allCases.count)

        // A library of about a hundred scenes with every kind of file, read in one scan.
        let stages = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-stagescan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stages) }
        var picks: [String: SceneRatings.Entry] = [:]
        for index in 0..<100 {
            let name = String(format: "scene-%04d", index)
            let folder = SceneFolder(stages.appendingPathComponent("2026-10-26/\(name)"))
            try FileManager.default.createDirectory(
                at: folder.exports, withIntermediateDirectories: true)
            try Data().write(to: folder.thumbnail)
            try Data(#"{"draw":{"generator":"mice"}}"#.utf8).write(to: folder.scene)
            try Data(#"{"score":0.5}"#.utf8).write(to: folder.interest)
            if index % 2 == 0 { picks[name] = .init(choice: index % 6 == 0 ? .no : .yes) }
            if index % 4 == 0 {
                try Data().write(to: folder.take)
                try Data(#"{"particles":5000000,"seconds":900}"#.utf8).write(to: folder.hires)
            }
            if index % 8 == 0 { try Data().write(to: folder.rawLook) }
            if index % 16 == 0 { try Data().write(to: folder.export(preset: "1080p")) }
        }
        try SceneRatings(scenes: picks).write(batch: stages.appendingPathComponent("2026-10-26"))
        _ = SceneLibrary.scan(stages)
        clock = Date()
        let hundred = SceneLibrary.scan(stages)
        let hundredScan = Date().timeIntervalSince(clock)
        check(
            "100 scenes at every step read in under 50 ms",
            hundred.count == 100 && hundredScan < 0.05 && Set(hundred.map(\.stage)).count >= 5,
            "\(ms(hundredScan)), \(Set(hundred.map(\.stage)).count) steps")

        // A batch of four hundred, the size a night produces.
        let crowd = root.appendingPathComponent("2026-10-25", isDirectory: true)
        for index in 1...400 {
            let folder = SceneFolder(crowd.appendingPathComponent(String(format: "scene-%04d", index)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: first.thumbnail, to: folder.thumbnail)
            try FileManager.default.copyItem(at: first.preview, to: folder.preview)
        }
        clock = Date()
        let scanned = SceneLibrary.scan(root)
        let scan = Date().timeIntervalSince(clock)
        check("405 scenes read in under half a second", scanned.count == 405 && scan < 0.5, ms(scan))
        clock = Date()
        let arrived = wait(30) { model.scenes.count == 405 }
        check("the whole batch reaches the window", arrived, ms(Date().timeIntervalSince(clock)))
        clock = Date()
        let probed = wait(120) { model.playable.count == 405 }
        check(
            "every video probed once", probed,
            "\(model.playable.count) in \(ms(Date().timeIntervalSince(clock)))")
        clock = Date()
        for _ in 0..<10 { _ = model.query.apply(model.scenes, entries: model.entries) }
        let filter = Date().timeIntervalSince(clock) / 10
        check("sorting and filtering 405 scenes fits in a frame", filter < 0.008, ms(filter))
        clock = Date()
        model.selection = "2026-10-25/scene-0200"
        model.handle(.digit(8))
        let click = Date().timeIntervalSince(clock)
        check("a choice in a batch of 400 is immediate", click < 0.016, ms(click))
        let rescans = model.scenes.count
        clock = Date()
        _ = wait(2.5) { false }
        check(
            "a scan that finds nothing new changes nothing", model.scenes.count == rescans,
            "last scan \(ms(model.lastScan))")

        try exerciseTriage()
        try exerciseScenePage()
    }

    /// Three scenes of one night at different steps, walked through the scene page: versions,
    /// steps, neighbours, a choice that takes the scene out of its collection, the commands to
    /// copy and the way back to the raw style.
    private static func exerciseScenePage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-scenepage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let night = root.appendingPathComponent("2026-10-26", isDirectory: true)
        let folders = (1...3).map {
            SceneFolder(night.appendingPathComponent(String(format: "scene-%04d", $0)))
        }
        for (offset, folder) in folders.enumerated() {
            try writeScene(folder, tint: offset + 6, archetype: offset == 0 ? "antennae" : nil)
            try Data(#"{"score":\#(0.9 - Double(offset) / 10)}"#.utf8).write(to: folder.interest)
        }
        try Data(
            "id,batch_seed,index,galaxies\nscene-0001,20261026,1,2\nscene-0002,20261026,2,3\n".utf8
        ).write(to: night.appendingPathComponent("index.csv"))
        var clip = SceneFolder.Clip()
        clip.story = .init(startFrame: 40, endFrame: 700, startMyr: 82, endMyr: 461, complete: true)
        try clip.encoded().write(to: folders[0].clip)

        // The first has gone all the way: take, hires record and clip, a style, two exports.
        let done = folders[0]
        try Data().write(to: done.take)
        try writeVideo(to: done.hiresVideo, tint: 9)
        try Data(
            """
            {"particles":8000000,"massive":2000000,"previewParticles":200000,"width":1920,"height":1080,
            "frames":660,"fps":30,"settle":300,"steps":1980,"timeStepScale":1,"timeStep":0.05,
            "timeStepMyr":0.2,"previewTimeStepMyr":0.2,"softening":0.08,"clipStartMyr":82,"clipEndMyr":461,
            "seconds":5100}
            """.utf8
        ).write(to: done.hires)
        try LookFile(name: "raw", palette: [GalaxyColours([1, 0.62, 0.25]), GalaxyColours([0.3, 0.7, 1])])
            .encoded().write(to: done.look)
        try done.promote(
            LookFile(
                name: "dream", palette: [GalaxyColours([0.9, 0.3, 0.6]), GalaxyColours([0.2, 0.9, 0.8])]))
        try FileManager.default.createDirectory(at: done.exports, withIntermediateDirectories: true)
        try writeVideo(to: done.export(preset: "1080p"), tint: 12)
        try writeVideo(to: done.export(preset: "whatsapp", codec: nil), tint: 3)
        try Data("caption".utf8).write(to: done.exports.appendingPathComponent("whatsapp.txt"))
        let frame = [UInt8](repeating: 200, count: 16 * 16 * 4)
        try AnimatedImage.write(
            [frame, frame], width: 16, height: 16, framesPerSecond: 10, format: .gif,
            to: done.preview("1080p-dream", extension: "gif"))
        try SceneRatings(scenes: [
            "scene-0001": .init(choice: .yes, rating: 8), "scene-0003": .init(choice: .yes),
        ]).write(batch: night)

        let model = LibraryModel(root: root)
        model.pasteboard = NSPasteboard(name: .init("dev.pierregc.sillage.librarycheck"))
        model.watch()
        defer { model.stop() }
        // Nothing queued here runs: no runner is started.
        let queue = QueueModel(library: root, watch: false)
        queue.runnerURL = nil
        renderQueue = queue
        defer { renderQueue = nil }
        check("three scenes for the page", wait(10) { model.scenes.count == 3 && model.playable.count == 3 })
        let id = { (index: Int) in "2026-10-26/" + String(format: "scene-%04d", index) }

        stills = 0
        let pageScenes = model.scenes
        Task { for scene in pageScenes where await ThumbnailCache.shared.load(scene) != nil { stills += 1 } }
        _ = wait(10) { stills == 3 }
        model.open(id(1))
        check("a click opens the scene's page", model.opened == id(1) && model.selection == id(1))
        check("what the page reads arrives", wait(5) { model.facts?.id == id(1) })
        let scene = try found(model.scene(id(1)))
        check(
            "versions: preview, high resolution, then each video",
            scene.versions.map(\.title) == ["Preview", "High resolution", "Video 1080p", "Video whatsapp"],
            scene.versions.map(\.title).joined(separator: ", "))
        check(
            "the page plays the exported video first",
            model.playingURL?.lastPathComponent == "1080p.mp4" && model.playing == id(1))
        model.version = done.hiresVideo
        check("choosing a version plays it instead", model.playingURL == done.hiresVideo)
        check(
            "a single decoder",
            model.player.items().count <= 3
                && wait(5) {
                    model.player.currentItem?.status == .readyToPlay
                })
        let states = SceneStep.states(scene, entry: model.entries[id(1)])
        check("all is done, nothing is next", SceneStep.allCases.allSatisfy { states[$0] == .done })
        let facts = model.facts
        check(
            "the page reads the story, the computation and the style",
            facts?.story?.endMyr == 461 && facts?.hires?.particles == 8_000_000
                && facts?.styleName == "dream" && facts?.palette.count == 2 && facts?.rawStyle == false
                && facts?.otherLooks.map(\.name) == ["raw"],
            facts?.styleName ?? "no style")
        let drawn = facts?.hires.map { Format.particles($0.particles, massive: $0.massive) }
        check(
            "the high resolution gives its massive particles",
            drawn == "8\u{A0}M particles (2\u{A0}M massive)" && scene.hires?.massive == 2_000_000,
            drawn ?? "no computation")
        check("seed and index in the batch", scene.seed == "20261026" && scene.index == 1)
        let files = model.facts?.exports ?? []
        check(
            "each file of exports/ has its row, the caption stays with its video",
            Set(files.map(\.url.lastPathComponent)) == ["1080p.mp4", "whatsapp.mp4", "1080p-dream.gif"]
                && files.first { $0.url.lastPathComponent == "whatsapp.mp4" }?.caption?.lastPathComponent
                    == "whatsapp.txt",
            files.map(\.url.lastPathComponent).joined(separator: ", "))
        let exported = files.first { $0.url.lastPathComponent == "1080p.mp4" }
        check(
            "preset, codec, size, duration and weight read",
            exported?.preset == "1080p" && exported?.codec == "H.264" && exported?.size != nil
                && (exported?.seconds ?? 0) > 0 && (exported?.bytes ?? 0) > 0,
            exported.map { ExportRow.details($0) } ?? "no row")
        let still = files.first { $0.url.lastPathComponent == "1080p-dream.gif" }
        check(
            "a GIF is an image with its style, not a video",
            still?.isImage == true && still?.codec == "GIF" && still?.style == "dream"
                && still?.size == "16×16" && !scene.videos.contains { $0.pathExtension == "gif" })
        check(
            "file names give preset and style",
            ExportedFile.names(of: "4k-aurora") == ("4k", "aurora")
                && ExportedFile.names(of: "1080p-h264") == ("1080p", nil)
                && ExportedFile.names(of: "1080p-gold-leaf-hevc") == ("1080p", "gold-leaf")
                && ExportedFile.names(of: "1080p-2") == ("1080p", nil)
                && ExportedFile.names(of: "montage").preset == nil)
        model.copyCaption(try found(files.first { $0.caption != nil }?.caption))
        check(
            "copying the caption puts its text on the pasteboard",
            model.pasteboard.string(forType: .string) == "caption" && model.copiedNote == "Caption copied")
        model.version = still?.url
        check(
            "showing a GIF does not start the player",
            model.playing == nil || model.playingURL != still?.url)
        model.version = nil
        // A new export lands and the next scan lists it.
        try writeVideo(to: done.export(preset: "square"), tint: 5)
        check(
            "an arriving export joins the list",
            wait(8) { model.facts?.exports.count == 4 })
        render(ScenePage(model: model, scene: scene, snapshot: true), to: "out/ui-scene-page.png")

        try exerciseStageJobs(model, queue: queue, done: done, chosen: folders[2], id: id)

        model.restoreRawLook(scene)
        check(
            "back to the raw style keeps the other in looks/",
            done.hasRawLook && FileManager.default.fileExists(atPath: done.lookFile(named: "dream").path)
                && wait(5) { model.facts?.rawStyle == true })

        // Neighbours in the collection, and a choice that takes the scene out of it.
        model.handle(.right)
        check(
            "→ moves to the neighbour and back to its default version",
            model.opened == id(2) && model.version == nil
                && model.playingURL == folders[1].preview)
        model.close()
        model.query.collection = .toSort
        model.open(id(2))
        model.handle(.yes)
        check(
            "yes on the page: the scene leaves To sort but the page stays",
            model.opened == id(2) && !model.visible.contains { $0.id == id(2) }
                && model.entries[id(2)]?.choice == .yes)
        let chosen = try found(model.scene(id(2)))
        let next = SceneStep.states(chosen, entry: model.entries[id(2)])
        check("next is the high resolution", next[.highResolution] == .next && next[.style] == .later)
        model.query.collection = .chosen
        model.open(id(3))
        _ = wait(5) { model.facts?.id == id(3) }
        render(
            ScenePage(model: model, scene: try found(model.scene(id(3))), snapshot: true),
            to: "out/ui-scene-page-next.png")
        model.handle(.left)
        check("← moves to the neighbour in Kept", model.opened == id(2), model.opened ?? "closed")
        model.handle(.digit(6))
        check("a digit rates the page's scene", model.entries[id(2)]?.rating == 6)
        check(
            "escape goes back to the grid on the same scene",
            model.handle(.close) && model.opened == nil && model.selection == id(2))
        model.handle(.open)
        check("space opens the page again", model.opened == id(2))
        model.stop()
        check("leaving the library closes the page", model.opened == nil && model.playing == nil)
    }

    private struct Missing: Error {}

    private static func found<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    /// The queue the page's buttons add to, in the snapshots.
    private static var renderQueue: QueueModel?

    private static func render(_ page: ScenePage, to path: String) {
        write(page.frame(width: 1180, height: 940), to: path)
    }

    /// Compute and Export through the queue, as the form and the sheet plan them, without a
    /// runner: the jobs are checked in `queue.json`, shown on the page and cancelled.
    private static func exerciseStageJobs(
        _ model: LibraryModel, queue: QueueModel, done: SceneFolder, chosen: SceneFolder,
        id: (Int) -> String
    ) throws {
        let quotes = StageQuotes.read([done, chosen], library: queue.store.library)
        check(
            "every high resolution size has its duration",
            StageJobs.hiresSizes.filter { $0 <= quotes.maximum }.allSatisfy { quotes.hires[$0] != nil },
            quotes.sizes.map {
                "\(StageJobs.particles($0, massive: StageJobs.massive(drawing: $0))) "
                    + Format.duration(quotes.hires[$0] ?? 0)
            }
            .joined(separator: ", "))

        // Compute draws as a night does: Auto is its 8 M from 2 M massive while the evening leaves
        // room, and every size past 2 M has light tracers.
        let alone = StageQuotes.read([chosen], library: queue.store.library)
        // The Mac idle at a fixed evening, whatever else runs on it, so the picture says when.
        let evening = NightSheetCheck.evening
        let idle = QueueModel(library: queue.store.library, watch: false) {
            QueueStatus.read(library: $0, now: evening, processes: [])
        }
        idle.runnerURL = nil
        let form = HiresForm(queue: idle, folders: [chosen], quotes: alone, clock: { evening })
        let menu = form.choices
        check(
            "Auto draws 8 M with 2 M massive, as a night does",
            menu.first?.hasPrefix("Auto · 8\u{A0}M (2\u{A0}M massive), about ") == true
                && form.planned.map(\.options) == [["--particles", "8000000", "--massive", "2000000"]],
            menu.first ?? "no menu")
        let sizes = [
            (1_000_000, "1\u{A0}M, about "), (2_000_000, "2\u{A0}M, about "),
            (5_000_000, "5\u{A0}M (2\u{A0}M massive), about "),
            (8_000_000, "8\u{A0}M (2\u{A0}M massive), about "),
            (10_000_000, "10\u{A0}M (2\u{A0}M massive), about "),
        ].filter { $0.0 <= alone.maximum }
        check(
            "every size gives its massive count and its duration",
            menu.count == sizes.count + 1 && zip(menu.dropFirst(), sizes).allSatisfy { $0.hasPrefix($1.1) },
            menu.joined(separator: " | "))
        let real = StageJobs.hiresSeconds(chosen, particles: 8_000_000, cost: alone.cost) ?? 0
        check(
            "8 M with 2 M massive costs less than a real 8 M",
            (alone.hires[8_000_000] ?? .infinity) < real * 0.6,
            "\(Format.duration(alone.hires[8_000_000] ?? 0)) against \(Format.duration(real))")
        write(
            VStack(alignment: .leading, spacing: 12) {
                form
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(menu.enumerated()), id: \.offset) { index, label in
                        Text((index == 0 ? "✓ " : "    ") + label).font(.callout.monospacedDigit())
                    }
                }
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
            .environment(\.offscreen, true),
            to: "out/ui-hires-form.png")

        let hires = try found(form.planned.first)
        let forecast = StageForecast(jobs: [hires], status: queue.status, now: Date())
        check(
            "Compute says when it will be ready",
            forecast.summary.contains("ready ") || forecast.summary.contains("ahead of this one"),
            forecast.summary)
        render(
            ScenePage(model: model, scene: try found(model.scene(id(3))), snapshot: true),
            to: "out/ui-scene-page-hires.png")
        check("Compute adds a high resolution", queue.submit([hires]) == 1)
        let queued = queue.queue.unfinished(at: chosen)
        check(
            "the job targets the scene, the size and its massive count",
            queued.count == 1 && queued.first?.kind == .hires
                && queued.first?.options == ["--particles", "8000000", "--massive", "2000000"]
                && SceneFolder(path: queued.first?.path ?? "").url.path == chosen.url.path,
            queued.first?.summary ?? "nothing")
        let waiting = queued.first.map { StageJobs.title(of: $0) }
        check("waiting, it says so", waiting == "8\u{A0}M (2\u{A0}M massive)", waiting ?? "nothing")
        check(
            "the same request is not added twice",
            queue.submit([
                StageJobs.hires(
                    chosen, particles: 5_000_000, massive: StageJobs.massive(drawing: 5_000_000),
                    cost: quotes.cost, queue: queue.queue)
            ])
                == 0)
        model.activeHires = queue.activeHires
        check(
            "the scene moves to High resolution while it computes",
            model.scene(id(3))?.stage == .highResolution && model.counts[.highResolution] == 1,
            "\(model.scene(id(3))?.stage.rawValue ?? "missing"), \(model.counts)")

        let state = quotes.exports[done.url.path] ?? .init()
        let plan = { (choice: ExportChoice, settings: ExportSettings) in
            StageJobs.export(
                choice, settings, folder: done, state: state, cost: quotes.cost, queue: queue.queue)
        }
        let again = plan(.hd, ExportSettings())
        check(
            "the same export of the same take replaces its file",
            again.replaces && again.output == done.export(preset: "1080p"),
            again.output?.lastPathComponent ?? "nothing")
        var styled = ExportSettings()
        styled.look = model.facts?.otherLooks.first
        let otherLook = plan(.hd, styled)
        check(
            "another style goes to a file of its own",
            !otherLook.replaces && otherLook.output?.lastPathComponent == "1080p-raw.mp4"
                && otherLook.options.contains(done.rawLook.path),
            otherLook.options.joined(separator: " "))
        var prores = ExportSettings()
        prores.codec = .prores
        check(
            "ProRes writes a .mov beside it",
            plan(.uhd, prores).output?.lastPathComponent == "4k-prores.mov"
                && plan(.whatsapp, prores).output?.lastPathComponent == "whatsapp.mp4")
        let sheet = ExportSheet(
            queue: queue, folders: [done], looks: model.facts?.otherLooks ?? [], close: {},
            ticked: [.uhd, .webp], quotes: quotes)
        check(
            "each ticked card is a job, with its duration",
            sheet.planned.map(\.title) == ["4K", "Animated WebP preview"]
                && sheet.planned.allSatisfy { $0.seconds != nil })
        write(sheet.environment(\.offscreen, true), to: "out/ui-export-sheet.png")
        check("Export adds a job per card", queue.submit(sheet.planned) == 2)
        let exports = queue.queue.unfinished(at: done).filter { $0.kind == .export }
        check(
            "the exports wait with their file",
            exports.map { StageJobs.title(of: $0) } == [
                "4K · 4k.mp4", "Animated WebP preview · preview.webp",
            ],
            exports.map { StageJobs.title(of: $0) }.joined(separator: ", "))
        queue.refresh()
        check(
            "each waiting job has its row in the queue",
            exports.allSatisfy { queue.row($0.id) != nil })
        render(
            ScenePage(model: model, scene: try found(model.scene(id(1))), snapshot: true),
            to: "out/ui-scene-page-jobs.png")
        let first = try found(exports.first)
        queue.attempt { try queue.cancel(first.id) }
        check(
            "Cancel removes the job from the queue",
            queue.failure == nil && queue.queue.job(first.id)?.state == .cancelled
                && queue.queue.unfinished(at: done).count == 1)
    }

    /// Four scored scenes in one night, sorted through the triage view the way a night is: yes,
    /// no, ratings, back and forth, a scene arriving, the end.
    private static func exerciseTriage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-triagecheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let night = root.appendingPathComponent("2026-10-26", isDirectory: true)
        func addScene(_ index: Int) throws {
            let folder = SceneFolder(night.appendingPathComponent(String(format: "scene-%04d", index)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try Data().write(to: folder.thumbnail)
            try Data("{}".utf8).write(to: folder.scene)
            try Data(#"{"score":\#(1 - Double(index) / 10)}"#.utf8).write(to: folder.interest)
        }
        for index in 1...4 { try addScene(index) }
        let other = root.appendingPathComponent("2026-10-25/scene-0001", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: SceneFolder(other).scene)

        let model = LibraryModel(root: root)
        model.watch()
        defer { model.stop() }
        model.query.collection = .toSort
        check("five scenes to sort", wait(10) { model.visible.count == 5 }, "\(model.visible.count)")
        let id = { (index: Int) in "2026-10-26/" + String(format: "scene-%04d", index) }
        func saved(_ index: Int) -> SceneRatings.Entry? {
            SceneRatings.read(batch: night).scenes[String(format: "scene-%04d", index)]
        }

        model.startTriage(batch: "2026-10-26")
        check(
            "sorting opens the night's first scene, in sort order",
            model.triage?.current == id(1) && model.triage?.order.count == 4,
            model.triage?.current ?? "closed")
        check("0 / 4 sorted", model.triageProgress?.decided == 0 && model.triageProgress?.total == 4)
        model.handle(.digit(7))
        check(
            "a digit rates without changing scene",
            model.triage?.current == id(1) && saved(1)?.rating == 7)
        model.handle(.yes)
        check(
            "yes is written at once and moves to the next",
            saved(1)?.choice == .yes && model.triage?.current == id(2))
        check("1 / 4 sorted", model.triageProgress?.decided == 1)
        let now = Date()
        model.handle(.digit(1), at: now)
        model.handle(.digit(0), at: now.addingTimeInterval(0.3))
        check("1 then 0 is 10", saved(2)?.rating == 10 && model.triage?.current == id(2))
        model.handle(.no)
        check(
            "no discards and moves to the next",
            saved(2)?.choice == .no && model.triage?.current == id(3))
        check(
            "the decided scene has left To sort but stays in the session",
            !model.visible.contains { $0.id == id(1) } && model.triage?.order.contains(id(1)) == true)
        model.handle(.left)
        check("← goes back to the decided scene", model.triage?.current == id(2))
        model.handle(.right)
        model.handle(.right)
        model.handle(.right)
        check("→ stops at the last one", model.triage?.current == id(4))
        model.handle(.left)
        model.handle(.left)
        model.handle(.left)
        model.handle(.clear)
        check(
            "clear empties the scene and hands it back to sort",
            saved(1) == nil && model.triageProgress?.decided == 1 && model.triage?.current == id(1))
        model.handle(.right)
        model.handle(.right)
        model.handle(.yes)
        check(
            "yes on the 3rd goes to the next to sort, the 4th",
            saved(3)?.choice == .yes && model.triage?.current == id(4))

        renderTriage(model, to: "out/ui-triage.png")
        try addScene(5)
        check(
            "a scene arriving during the session joins it",
            wait(6) { model.triageProgress?.total == 5 }, "\(model.triageProgress?.total ?? 0)")
        model.handle(.yes)
        check("the next to sort wraps round to the start", model.triage?.current == id(5))
        model.handle(.no)
        check(
            "the first one is left, the one that was cleared",
            model.triage?.current == id(1) && model.triage?.finished == false)
        model.handle(.yes)
        check(
            "all is sorted: 5 / 5 and the session says so",
            model.triage?.finished == true && model.triageProgress?.decided == 5
                && model.triageProgress?.total == 5)
        check("nothing is decided when all is sorted", !model.handle(.yes) && saved(1)?.choice == .yes)
        renderTriage(model, to: "out/ui-triage-finished.png")
        model.handle(.left)
        check("← leaves the end", model.triage?.finished == false)
        check("escape leaves the session", model.handle(.close) && model.triage == nil)
        check(
            "to sort keeps only the other night's scene",
            model.visible.map(\.id) == ["2026-10-25/scene-0001"])
        model.startTriage()
        check("a session on the whole of To sort", model.triageProgress?.total == 1)
        model.stop()
        check("leaving the library closes the session", model.triage == nil)
    }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }

    private static let width = 160
    private static let height = 90

    private static func pixels(tint: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 255 / width + tint * 50) % 256)
                pixels[offset + 1] = UInt8(y * 255 / height)
                pixels[offset + 2] = UInt8((tint * 70) % 256)
            }
        }
        return pixels
    }

    private static func writeVideo(to url: URL, tint: Int) throws {
        let writer = try VideoWriter(width: width, height: height, framesPerSecond: 30, to: url)
        for frame in 0..<20 {
            let rgba = pixels(tint: tint + frame)
            try writer.append { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let bgra = base.bindMemory(to: UInt8.self, capacity: stride * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let from = (y * width + x) * 4
                        let to = y * stride + x * 4
                        (bgra[to], bgra[to + 1], bgra[to + 2]) = (rgba[from + 2], rgba[from + 1], rgba[from])
                        bgra[to + 3] = 255
                    }
                }
            }
        }
        try writer.finish()
    }

    private static func writeScene(_ folder: SceneFolder, tint: Int, archetype: String?) throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try PNGWriter.write(pixels(tint: tint), width: width, height: height, to: folder.thumbnail)
        try writeVideo(to: folder.preview, tint: tint)
        let scene = archetype.map { #"{"draw": {"generator": "\#($0)"}}"# } ?? "{}"
        try Data(scene.utf8).write(to: folder.scene)
    }

    private static func renderTriage(_ model: LibraryModel, to path: String) {
        guard let triage = model.triage else { return }
        write(TriageView(model: model, triage: triage) {}.frame(width: 1180, height: 640), to: path)
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(
            content: view.panelSurface().environment(\.colorScheme, .dark).environment(\.queue, renderQueue))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            check("\(path) renders", false)
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        check("\(path) renders", true)
    }

    private static func renderShot(_ model: LibraryModel) throws {
        model.columns = 2
        let cards = model.visible.prefix(4).map { scene in
            LibraryCard(
                model: model, scene: scene, entry: model.entries[scene.id],
                selected: model.selection == scene.id, playing: false,
                ready: model.playable.contains(scene.id))
        }
        let view = VStack(spacing: 0) {
            LibraryHeader(model: model, collection: model.query.collection)
            Divider()
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { ForEach(0..<2, id: \.self) { cards[$0] } }
                GridRow { ForEach(2..<min(4, cards.count), id: \.self) { cards[$0] } }
            }
            .frame(width: LibraryCard.width * 2 + 12)
            .padding(12)
        }
        .frame(width: 1180)
        .panelSurface()
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            check("the grid renders", false)
            return
        }
        let url = URL(fileURLWithPath: "out/ui-library.png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        check("the grid renders", true, url.path)
    }
}
