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
            check("the walk runs to the end", false, "\(error)")
        }
        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-queue.log"), atomically: true, encoding: .utf8)
        print(report)
        if failures == 0 { try? FileManager.default.removeItem(at: root) }
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private static func exercise(_ root: URL) throws {
        check(
            "the runner is in the app", QueueModel.runnerExecutable != nil,
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
        check("the job is in the queue", model.queue.job(export.id)?.state != nil)
        check("a runner starts", runner != nil, runner.map { "pid \($0)" } ?? "")
        if let runner {
            check(
                "it has its own session", getsid(runner) == runner && getsid(runner) != getsid(0),
                "session \(getsid(runner)), app \(getsid(0))")
        }
        check(
            "the app sees it at work",
            wait(10) {
                model.refresh()
                return model.runner != nil || model.queue.job(export.id)?.isFinished == true
            })
        check(
            "the job ends",
            wait(30) {
                model.refresh()
                return model.queue.job(export.id)?.isFinished == true && model.runner == nil
            })
        let failed = model.queue.job(export.id)
        check(
            "without a take, the export fails with the reason",
            failed?.state == .failed && failed?.message?.contains("no take.sillage") == true,
            failed?.message ?? "")
        let events =
            (try? String(contentsOf: RunStatusFiles.events(batch: scene.batch), encoding: .utf8))
            .map(RunEvent.decodeLines) ?? []
        check(
            "the failure is in events.jsonl",
            events.contains { $0.kind == RunEvent.Kind.error && $0.log == failed?.log })
        let notices =
            (try? String(contentsOf: noticeLog, encoding: .utf8))?.split(separator: "\n") ?? []
        check(
            "the failure is announced: stage, scene, reason",
            notices.contains { $0.hasPrefix("Failed · Videos\tscene-0001") },
            notices.first.map(String.init) ?? "")
        check(
            "a queue that finished nothing is not called empty",
            !notices.contains { $0.hasPrefix("Queue empty") })
        let activity = ActivityFile.read(from: RunStatusFiles.activity(library: root))
        check("activity.json says the Mac is free", activity?.state == .idle && activity?.job == nil)

        try QueueSettings(notifications: false).write(model.store)
        let before = notices.count
        try model.pause()
        let batch = root.appendingPathComponent("2026-10-27").path
        let (explore, held) = try model.submit(.explore, path: batch, options: ["--scenes", "0"])
        let (extra, _) = try model.submit(.export, path: scene.url.path, options: ["--preset", "4k"])
        check("paused, nothing starts", held == nil && model.runner == nil)
        try model.moveFirst(extra.id)
        check("“Move to front” goes first", model.queue.waiting.map(\.id) == [extra.id, explore.id])
        try model.cancel(extra.id)
        check("cancel removes a waiting job", model.queue.job(extra.id)?.state == .cancelled)
        try model.resume()
        check(
            "resuming starts the exploration",
            wait(30) {
                model.refresh()
                return model.queue.job(explore.id)?.isFinished == true && model.runner == nil
            })
        check(
            "it runs to the end", model.queue.job(explore.id)?.state == .done,
            model.queue.job(explore.id)?.message ?? "")
        let after =
            (try? String(contentsOf: noticeLog, encoding: .utf8))?.split(separator: "\n") ?? []
        check("switched off, the runner stays quiet", after.count == before, "\(after.count) lines")
        check(
            "the batch is created",
            FileManager.default.fileExists(atPath: batch + "/batch.conf"))
    }
}
