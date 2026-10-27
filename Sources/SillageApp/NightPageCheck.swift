import AppKit
import Foundation
import SillageRender
import SwiftUI

/// `--nightpagecheck`: the page of a night without a window, on copies of the status fixtures.
/// It reads a night that runs, follows a change of its files within two seconds, steers it
/// through the queue, opens a night that ended while the app was closed on its report, reads a
/// night that waits its turn, and hands the scenes to the triage view. Then the pages in
/// `out/ui-night-page*.png`. No GPU.
@MainActor
enum NightPageCheck {
    private static var lines: [String] = []
    private static var failures = 0

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/night-status", isDirectory: true)
    nonisolated static let paris = TimeZone(identifier: "Europe/Paris") ?? .current

    static func run() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-nightpage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try exercise(root) } catch { check("la vérification va au bout", false, "\(error)") }
        if failures == 0 { try? FileManager.default.removeItem(at: root) }
        let report = lines.joined(separator: "\n") + "\n\n\(failures) échec(s)"
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-nightpage.log"), atomically: true, encoding: .utf8)
        print(report)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !passed { failures += 1 }
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// A library of a fixture's files: the night is what the fixture's files say.
    private static func copy(_ fixture: String, to root: URL) throws -> URL {
        let target = root.appendingPathComponent(fixture, isDirectory: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent(fixture).appendingPathComponent("library"), to: target)
        return target
    }

    /// Reads as the fixture's own clock and processes say, so a night "runs" without a runner.
    private static func reader(_ fixture: String) -> @Sendable (URL, String?) -> NightsSnapshot {
        let now = RunStatus.date(text(fixture, "now.txt")) ?? Date()
        let running = text(fixture, "processes.txt") != "0"
        return { library, selected in
            NightsSnapshot.read(
                library: library, selected: selected, now: now, timeZone: paris,
                processes: running
                    ? [QueueStatus.ProcessInfo(pid: 1_000, arguments: ["sillage-render", "render"])] : [],
                isAlive: { _ in running })
        }
    }

    private static func text(_ fixture: String, _ file: String) -> String {
        (try? String(
            contentsOf: fixtures.appendingPathComponent(fixture).appendingPathComponent(file),
            encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func exercise(_ root: URL) throws {
        check(
            "les fixtures de statut sont là",
            FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("hires").path),
            fixtures.path)

        // A night that runs.
        let running = try copy("hires", to: root)
        let nights = NightsModel(library: running, watch: true, read: reader("hires"))
        let queue = QueueModel(library: running, watch: false)
        check(
            "la barre latérale liste la nuit",
            nights.items.map(\.title) == ["26 oct. · 50 scènes · 1 vidéo · en cours"],
            nights.items.map(\.title).joined(separator: " | "))
        nights.select("2026-10-26")
        guard let page = nights.page else {
            check("la page se lit", false)
            return
        }
        check("la page se lit", page.id == "2026-10-26" && page.live)
        check(
            "cinq phases, avec leurs comptes",
            page.phases.map(\.title) == ["Aperçus", "Sélection", "Haute résolution", "Style", "Vidéos"]
                && page.phases.map(\.counts) == ["50/50", "4/4", "1/4", "1/4", "1/4"])
        check(
            "la ligne du travail en cours",
            page.current?.line == "scene-0023, haute résolution, image 412/900, prêt vers 2 h 20",
            page.current?.line ?? "")
        check("les scènes sont des cartes", page.scenes.count == 47, "\(page.scenes.count) cartes")

        // Its files change: the page follows within two seconds.
        let batch = running.appendingPathComponent("2026-10-26", isDirectory: true)
        let event = RunEvent("explore.scene", scene: "scene-0099", at: Date())
        var arrival = event
        arrival.status = "ok"
        arrival.score = 0.5
        try RunStatusFiles.append(arrival, to: RunStatusFiles.events(batch: batch))
        let appended = Date()
        let seen = wait(4) { nights.page?.scenes.contains { $0.name == "scene-0099" } == true }
        let delay = Date().timeIntervalSince(appended)
        check(
            "une scène qui arrive se montre en moins de 2 s", seen && delay < 2,
            String(format: "%.1f s", delay))
        guard var activity = ActivityFile.read(from: RunStatusFiles.activity(library: running)) else {
            check("activity.json se lit", false)
            return
        }
        activity.job?.detail = "frame 500/900"
        activity.job?.progress = 0.55
        try RunStatusFiles.write(activity.encoded(), to: RunStatusFiles.activity(library: running))
        let written = Date()
        let moved = wait(4) { nights.page?.current?.line.contains("image 500/900") == true }
        let lag = Date().timeIntervalSince(written)
        check("l'avancement se met à jour en moins de 2 s", moved && lag < 2, String(format: "%.1f s", lag))

        // Steering goes through the queue.
        try queue.stopAfterStep(7)
        nights.refresh()
        check(
            "Arrêter après cette étape le demande à la nuit",
            queue.store.read().job(7)?.stopAfterStep == true
                && nights.page?.controls.stopAfterAsked == true)
        try queue.skip(7)
        check("Passer cette scène le compte une fois", queue.store.read().job(7)?.skips == 1)
        nights.skipWasAsked(for: nights.page?.current?.scene)
        check("et ne peut pas être redemandé pour la même scène", nights.skipAsked == "scene-0023")
        check("Passer est permis pendant une haute résolution", nights.page?.controls.canSkip == true)
        try queue.pause()
        nights.refresh()
        check("Pause suspend la file", queue.store.read().paused && nights.page?.controls.isPaused == true)

        // A night that ended while the app was closed: the files say all of it.
        let closed = try copy("done", to: root)
        let ended = NightsModel(library: closed, watch: false, read: reader("done"))
        check("deux nuits, la plus récente d'abord", ended.items.map(\.id) == ["2026-10-27", "2026-10-26"])
        ended.select("2026-10-26")
        let report = ended.page?.report ?? ""
        check(
            "une nuit finie s'ouvre sur le résumé du matin",
            ended.page?.live == false && ReportLine.parse(report).count > 5 && ended.page?.current == nil,
            "\(ReportLine.parse(report).count) lignes")
        check("sans boutons de pilotage", ended.page?.controls.job == nil)

        // A night that failed shows its errors with their logs.
        let failed = try copy("failed", to: root)
        let broken = NightsModel(library: failed, watch: false, read: reader("failed"))
        broken.select("2026-10-26")
        check(
            "les erreurs ont leur journal",
            broken.page?.problems.count == 2 && broken.page?.problems.allSatisfy { $0.logURL != nil } == true)

        // A night that waits its turn can be cancelled.
        let waiting = root.appendingPathComponent("waiting", isDirectory: true)
        try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
        let line = QueueModel(library: waiting, watch: false)
        let job = try line.submit(.night, path: waiting.appendingPathComponent("2026-10-28").path).job
        let later = NightsModel(library: waiting, watch: false)
        later.select("2026-10-28")
        check(
            "une nuit en attente a sa page",
            later.page?.queued == true && later.page?.controls.queuedJob == job.id
                && later.items.first?.summary == "en attente")
        try line.cancel(job.id)
        later.refresh()
        check(
            "Annuler la nuit la retire de la file", line.store.read().waiting.isEmpty && later.items.isEmpty)
        // Pause and resume on a queue with nothing to run start no runner.
        try line.pause()
        check("la file se met en pause", line.store.read().paused)
        try line.resume()
        check("et reprend", !line.store.read().paused)

        try triage(running)
        try pictures(
            running: (nights, queue), ended: (ended, QueueModel(library: closed, watch: false)),
            failed: (broken, QueueModel(library: failed, watch: false)), root: running)
    }

    /// Trier: the scenes of the night are the ones the triage view takes.
    private static func triage(_ library: URL) throws {
        let batch = library.appendingPathComponent("2026-10-26", isDirectory: true)
        for (index, name) in ["scene-0019", "scene-0007", "scene-0023", "scene-0031"].enumerated() {
            try scene(batch.appendingPathComponent(name, isDirectory: true), tint: index)
        }
        let model = LibraryModel(root: library)
        Task { await model.refresh() }
        check("la bibliothèque lit les scènes de la nuit", wait(10) { model.scenes.count == 4 })
        let toSort = model.scenes.filter { $0.batch == "2026-10-26" && $0.stage == .toSort }
        check("elles sont à trier", toSort.count == 4, "\(toSort.count)")
        model.startTriage(batch: "2026-10-26")
        check(
            "Trier ouvre la séance sur cette nuit",
            model.triage?.batch == "2026-10-26" && model.triageProgress?.total == 4)
        model.endTriage()
        model.open("2026-10-26/scene-0019")
        check("une carte ouvre la page de la scène", model.opened == "2026-10-26/scene-0019")
        model.stop()
    }

    private static func scene(_ folder: URL, tint: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (width, height) = (160, 90)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 255 / width + tint * 50) % 256)
                pixels[offset + 1] = UInt8(y * 255 / height)
                pixels[offset + 2] = UInt8((tint * 70) % 256)
            }
        }
        let scene = SceneFolder(folder)
        try PNGWriter.write(pixels, width: width, height: height, to: scene.thumbnail)
        try Data("{}".utf8).write(to: scene.scene)
    }

    // MARK: Pictures

    private static func pictures(
        running: (NightsModel, QueueModel), ended: (NightsModel, QueueModel),
        failed: (NightsModel, QueueModel), root: URL
    ) throws {
        let library = LibraryModel(root: root)
        Task { await library.refresh() }
        _ = wait(10) { library.scenes.count == 4 }
        // A picture is taken at once, so the stills are loaded first.
        var loaded = 0
        Task {
            for scene in library.scenes { _ = await ThumbnailCache.shared.load(scene) }
            loaded = library.scenes.count
        }
        _ = wait(10) { loaded == 4 }
        let shots: [(String, (NightsModel, QueueModel))] = [
            ("", running), ("-done", ended), ("-failed", failed),
        ]
        for (suffix, (nights, queue)) in shots {
            nights.select("2026-10-26")
            SillageApp.write(
                AnyView(
                    NightPageView(
                        id: "2026-10-26", nights: nights, queue: queue, library: library,
                        openScene: { _ in }, sort: { _ in }, snapshot: true
                    )
                    .frame(width: 1180)),
                to: "out/ui-night-page\(suffix).png")
        }
    }
}
