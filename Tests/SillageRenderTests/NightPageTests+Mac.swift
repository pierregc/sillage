import Foundation
import Testing

@testable import SillageRender

extension NightPageTests {
    @Test func aNightBeingSteeredSaysSo() throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let night = root.appendingPathComponent("2026-10-28", isDirectory: true)
        try FileManager.default.createDirectory(at: night, withIntermediateDirectories: true)
        let started = RunStatus.date("2026-10-28T00:00:00.000+01:00")!
        let file = NightFile(
            id: "2026-10-28", phases: [.init(name: "explore", planned: 10, done: 3)],
            startedAt: started)
        try RunStatusFiles.write(file.encoded(), to: RunStatusFiles.night(batch: night))
        let store = QueueStore(library: root)
        let job = try store.submit(
            .night, path: night.path, runner: nil, at: started
        ).job
        try store.change {
            try $0.start(
                job.id, pid: getpid(), pidStarted: ProcessProbe.started(getpid()), log: nil, at: started)
            try $0.stopAfterStep(job.id, at: started)
            $0.pause(at: started)
        }
        let activity = ActivityFile(
            state: .paused,
            job: .init(kind: "explore", batch: "2026-10-28", startedAt: started),
            night: .init(id: "2026-10-28", phase: "explore"), updated: started)
        try RunStatusFiles.write(activity.encoded(), to: RunStatusFiles.activity(library: root))
        let page = try #require(
            NightsSnapshot.read(
                library: root, selected: "2026-10-28", now: started.addingTimeInterval(60),
                timeZone: Self.paris,
                processes: [.init(pid: 1, arguments: ["sillage-render", "render"])]
            ).page)
        #expect(page.live && page.status == "Paused" && page.controls.isPaused)
        #expect(page.controls.stopAfterAsked && page.controls.job == job.id)
        // Exploring has no scene to leave out.
        #expect(!page.controls.canSkip)
        #expect(page.phases[0].state == .current && page.phases[0].counts == "3/10")
    }
}
