import Foundation
import SillageRender

/// `--queuecheck`: drives the queue the way the app does, against the runner bundled in it, on
/// a library of its own. No GPU: the export fails at once for want of a take, and the
/// exploration asks for no scene.
@MainActor
enum QueueCheck {
    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-queuecheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try exercise(root)
        } catch {
            check("le parcours va au bout", false, "\(error)")
        }
        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-queue.log"), atomically: true, encoding: .utf8)
        print(report)
        if failures == 0 { try? FileManager.default.removeItem(at: root) }
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "OUI" : "NON")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !passed { failures += 1 }
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private static func exercise(_ root: URL) throws {
        check(
            "le runner est dans l'app", QueueModel.runnerExecutable != nil,
            QueueModel.runnerExecutable?.path ?? "")
        let scene = SceneFolder(
            root.appendingPathComponent("2026-10-26").appendingPathComponent("scene-0001"))
        try FileManager.default.createDirectory(at: scene.url, withIntermediateDirectories: true)
        let model = QueueModel(library: root)
        let noticeLog = root.appendingPathComponent("notices.log")
        setenv(Notifier.logVariable, noticeLog.path, 1)
        defer { unsetenv(Notifier.logVariable) }

        let (export, runner) = try model.submit(
            .export, path: scene.url.path, options: ["--preset", "1080p"])
        check("le travail est dans la file", model.queue.job(export.id)?.state != nil)
        check("un runner démarre", runner != nil, runner.map { "pid \($0)" } ?? "")
        if let runner {
            check(
                "il a sa propre session", getsid(runner) == runner && getsid(runner) != getsid(0),
                "session \(getsid(runner)), app \(getsid(0))")
        }
        check(
            "l'app le voit au travail",
            wait(10) {
                model.refresh()
                return model.runner != nil || model.queue.job(export.id)?.isFinished == true
            })
        check(
            "le travail se termine",
            wait(30) {
                model.refresh()
                return model.queue.job(export.id)?.isFinished == true && model.runner == nil
            })
        let failed = model.queue.job(export.id)
        check(
            "sans prise, l'export échoue avec la raison",
            failed?.state == .failed && failed?.message?.contains("no take.sillage") == true,
            failed?.message ?? "")
        let events =
            (try? String(contentsOf: RunStatusFiles.events(batch: scene.batch), encoding: .utf8))
            .map(RunEvent.decodeLines) ?? []
        check(
            "l'échec est dans events.jsonl",
            events.contains { $0.kind == RunEvent.Kind.error && $0.log == failed?.log })
        let notices =
            (try? String(contentsOf: noticeLog, encoding: .utf8))?.split(separator: "\n") ?? []
        check(
            "l'échec est annoncé : étape, scène, raison",
            notices.contains { $0.hasPrefix("Échec · Rendu\tscene-0001") },
            notices.first.map(String.init) ?? "")
        check(
            "une file qui n'a rien réussi ne se dit pas vide",
            !notices.contains { $0.hasPrefix("File d'attente vide") })
        let activity = ActivityFile.read(from: RunStatusFiles.activity(library: root))
        check("activity.json dit le Mac libre", activity?.state == .idle && activity?.job == nil)

        try QueueSettings(notifications: false).write(model.store)
        let before = notices.count
        try model.pause()
        let batch = root.appendingPathComponent("2026-10-27").path
        let (explore, held) = try model.submit(.explore, path: batch, options: ["--scenes", "0"])
        let (extra, _) = try model.submit(.export, path: scene.url.path, options: ["--preset", "4k"])
        check("en pause, rien ne démarre", held == nil && model.runner == nil)
        try model.moveFirst(extra.id)
        check("« en premier » passe devant", model.queue.waiting.map(\.id) == [extra.id, explore.id])
        try model.cancel(extra.id)
        check("annuler retire un travail en attente", model.queue.job(extra.id)?.state == .cancelled)
        try model.resume()
        check(
            "la reprise lance l'exploration",
            wait(30) {
                model.refresh()
                return model.queue.job(explore.id)?.isFinished == true && model.runner == nil
            })
        check(
            "elle va au bout", model.queue.job(explore.id)?.state == .done,
            model.queue.job(explore.id)?.message ?? "")
        let after =
            (try? String(contentsOf: noticeLog, encoding: .utf8))?.split(separator: "\n") ?? []
        check("réglage coupé, le runner se tait", after.count == before, "\(after.count) lignes")
        check(
            "le lot est créé",
            FileManager.default.fileExists(atPath: batch + "/batch.conf"))
    }
}
