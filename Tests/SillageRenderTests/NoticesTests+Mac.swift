import Foundation
import Testing

@testable import SillageRender

extension NoticesTests {
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
                Notice("Failed · Videos", "scene-0001: exit status 2: no take"),
                Notice("Queue empty", "1 job finished"),
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
                Notice("Night of 26 Oct", "Previews: done · 12 scenes"),
                Notice("Night of 26 Oct", "High resolution: done · 4 scenes"),
                Notice(
                    "Night of 26 Oct finished",
                    "1 scene explored · 0 in high resolution · 0 videos · no errors"),
            ])
    }
}
