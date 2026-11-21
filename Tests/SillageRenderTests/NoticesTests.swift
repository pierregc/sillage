import Foundation
import Testing

@testable import SillageRender

/// What the runner says at the Mac, and when.
@Suite("Notices")
struct NoticesTests {
    func temporaryLibrary() throws -> QueueStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return QueueStore(library: url)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Notice] = []
        func add(_ notice: Notice) { lock.withLock { stored.append(notice) } }
        var notices: [Notice] { lock.withLock { stored } }
    }

    func runner(_ store: QueueStore, _ box: Box, script: @escaping (QueueJob) -> String)
        -> QueueRunner
    {
        QueueRunner(
            store: store,
            command: { job in
                ["/bin/sh", "-c", "cd \"\(job.path)\" && \(script(job))", "job", "\(job.id)"]
            },
            poll: 0.02, grace: 2, busy: { [] }, notify: box.add, say: { _ in })
    }

    @Test func wordsFollowTheGlossary() {
        #expect(Notices.stage("pick") == "Selection")
        #expect(Notices.stage("hires") == "High resolution")
        #expect(Notices.stage("export") == "Videos")
        #expect(Notices.night("2026-10-25") == "Night of 25 Oct")
        #expect(Notices.night(nil) == "Night")
        #expect(Notices.queueEmpty(finished: 1).body == "1 job finished")
        #expect(Notices.queueEmpty(finished: 3).body == "3 jobs finished")
        var event = RunEvent(RunEvent.Kind.phaseDone)
        event.night = "2026-10-25"
        event.phase = "hires"
        event.count = 4
        #expect(
            Notices.phaseDone(event) == Notice("Night of 25 Oct", "High resolution: done · 4 scenes"))
    }

    @Test func aNightEndsWithWhatItDid() {
        var ok = RunEvent(RunEvent.Kind.exploreScene)
        ok.status = "ok"
        var rejected = ok
        rejected.status = "rejected"
        let events = [
            ok, ok, rejected, RunEvent(RunEvent.Kind.hiresDone), RunEvent(RunEvent.Kind.exportDone),
            RunEvent(RunEvent.Kind.error),
        ]
        #expect(
            Notices.summary(events)
                == "2 scenes explored · 1 in high resolution · 1 video · 1 error")
        #expect(Notices.summary([]).hasSuffix("no errors"))
    }

    @Test func theStatusLineSaysWhatRuns() {
        let started = Date()
        var activity = ActivityFile(state: .running, updated: started)
        #expect(Notices.statusLine(ActivityFile(state: .idle, updated: started)) == "Nothing running")
        activity.job = ActivityFile.Job(
            kind: "hires", batch: "2026-10-25", scene: "scene-0023", startedAt: started,
            detail: "frame 412/900")
        #expect(Notices.statusLine(activity) == "High resolution · scene-0023 · frame 412/900")
        activity.state = .paused
        #expect(Notices.statusLine(activity).hasSuffix(" · paused"))
    }

    @Test func quotesInANoticeAreNotCode() {
        let script = Notifier.script(Notice("a\"b", "c\\\" & do shell script \"x\""))
        #expect(
            script
                == "display notification \"c\\\\\\\" & do shell script \\\"x\\\"\" with title \"a\\\"b\"")
    }

    @Test func settingsDefaultToOnAndAreReadFromDisk() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        #expect(QueueSettings.read(store).notifications)
        try QueueSettings(notifications: false).write(store)
        #expect(!QueueSettings.read(store).notifications)
    }

    @Test func switchedOffNothingIsPosted() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let log = store.library.appendingPathComponent("notices.log")
        setenv(Notifier.logVariable, log.path, 1)
        defer { unsetenv(Notifier.logVariable) }
        Notifier.post(Notice("One", "two"), store: store)
        try QueueSettings(notifications: false).write(store)
        Notifier.post(Notice("Three", "four"), store: store)
        #expect(try String(contentsOf: log, encoding: .utf8) == "One\ttwo\n")
    }
}
