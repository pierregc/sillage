import Foundation
import Testing

@testable import SillageRender

/// What the runner says at the Mac, and when.
@Suite("Notices")
struct NoticesTests {
    private func temporaryLibrary() throws -> QueueStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return QueueStore(library: url)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Notice] = []
        func add(_ notice: Notice) { lock.withLock { stored.append(notice) } }
        var notices: [Notice] { lock.withLock { stored } }
    }

    private func runner(_ store: QueueStore, _ box: Box, script: @escaping (QueueJob) -> String)
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
        #expect(Notices.stage("hires") == "Haute résolution")
        #expect(Notices.stage("export") == "Vidéos")
        #expect(Notices.night("2026-10-25") == "Nuit du 25 oct.")
        #expect(Notices.night(nil) == "Nuit")
        #expect(Notices.queueEmpty(finished: 1).body == "1 travail terminé")
        #expect(Notices.queueEmpty(finished: 3).body == "3 travaux terminés")
        var event = RunEvent(RunEvent.Kind.phaseDone)
        event.night = "2026-10-25"
        event.phase = "hires"
        event.count = 4
        #expect(
            Notices.phaseDone(event) == Notice("Nuit du 25 oct.", "Haute résolution : fini · 4 scènes"))
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
                == "2 scènes explorées · 1 en haute résolution · 1 vidéo · 1 erreur")
        #expect(Notices.summary([]).hasSuffix("aucune erreur"))
    }

    @Test func theStatusLineSaysWhatRuns() {
        let started = Date()
        var activity = ActivityFile(state: .running, updated: started)
        #expect(Notices.statusLine(ActivityFile(state: .idle, updated: started)) == "Rien en cours")
        activity.job = ActivityFile.Job(
            kind: "hires", batch: "2026-10-25", scene: "scene-0023", startedAt: started,
            detail: "image 412/900")
        #expect(Notices.statusLine(activity) == "Haute résolution · scene-0023 · image 412/900")
        activity.state = .paused
        #expect(Notices.statusLine(activity).hasSuffix("en pause"))
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
        Notifier.post(Notice("Un", "deux"), store: store)
        try QueueSettings(notifications: false).write(store)
        Notifier.post(Notice("Trois", "quatre"), store: store)
        #expect(try String(contentsOf: log, encoding: .utf8) == "Un\tdeux\n")
    }

    @Test func aFailureAndAnEmptyQueueAreToldOnceEach() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let batch = store.library.appendingPathComponent("2026-10-26")
        let scene = batch.appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: scene, withIntermediateDirectories: true)
        try store.change {
            $0.add(.export, path: scene.path, at: Date())
            $0.add(.hires, path: scene.path, at: Date())
        }
        let box = Box()
        #expect(runner(store, box) { job in job.id == 1 ? "echo no take; exit 2" : "true" }.run() == 0)
        #expect(
            box.notices == [
                Notice("Échec · Vidéos", "scene-0001 : exit status 2: no take"),
                Notice("File d'attente vide", "1 travail terminé"),
            ])
    }

    @Test func aNightsJobsDoNotAnnounceAnEmptyQueue() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let batch = store.library.appendingPathComponent("2026-10-26")
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try store.change { $0.add(.explore, path: batch.path, by: .night, night: "2026-10-26", at: Date()) }
        let box = Box()
        _ = runner(store, box) { _ in "true" }.run()
        #expect(box.notices.isEmpty)
    }

    @Test func phasesAndTheEndOfANightAreToldWhileItRuns() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let batch = store.library.appendingPathComponent("2026-10-26")
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let events = RunStatusFiles.events(batch: batch)
        // Written before the runner started: an earlier runner has told it.
        var old = RunEvent(RunEvent.Kind.phaseDone, at: Date().addingTimeInterval(-3600))
        old.phase = "explore"
        try RunStatusFiles.append(old, to: events)
        try store.change { $0.add(.night, path: batch.path, by: .night, night: "2026-10-26", at: Date()) }
        func emit(_ kind: String, phase: String? = nil, count: Int? = nil, status: String? = nil)
            -> String
        {
            var event = RunEvent(kind)
            event.night = "2026-10-26"
            event.phase = phase
            event.count = count
            event.status = status
            let data = try! RunStatus.encoder(pretty: false).encode(event)
            return "echo '\(String(decoding: data, as: UTF8.self))' >> events.jsonl"
        }
        let box = Box()
        let script = [
            emit(RunEvent.Kind.exploreScene, status: "ok"),
            emit(RunEvent.Kind.phaseDone, phase: "explore", count: 12), "sleep 0.3",
            emit(RunEvent.Kind.phaseDone, phase: "hires", count: 4),
            emit(RunEvent.Kind.nightDone),
        ].joined(separator: "; ")
        #expect(runner(store, box) { _ in script }.run() == 0)
        #expect(
            box.notices == [
                Notice("Nuit du 26 oct.", "Aperçus : fini · 12 scènes"),
                Notice("Nuit du 26 oct.", "Haute résolution : fini · 4 scènes"),
                Notice(
                    "Nuit du 26 oct. terminée",
                    "1 scène explorée · 0 en haute résolution · 0 vidéo · aucune erreur"),
            ])
    }
}
