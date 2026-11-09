import Foundation
import Testing

@testable import SillageRender

@Suite("Night page")
struct NightPageTests {
    static let fixtures = NightStatusTests.fixtures
    static let paris = NightStatusTests.paris

    static func read(_ name: String, selected: String? = "2026-10-26", alive: Bool = true)
        -> NightsSnapshot
    {
        let library = fixtures.appendingPathComponent(name).appendingPathComponent("library")
        let processes =
            (NightStatusTests.text(name, "processes.txt") ?? "0") == "0"
            ? []
            : [QueueStatus.ProcessInfo(pid: 1_000, arguments: ["sillage-render", "render"])]
        return NightsSnapshot.read(
            library: library, selected: selected,
            now: RunStatus.date(NightStatusTests.text(name, "now.txt")!)!, timeZone: paris,
            processes: processes, isAlive: { _ in alive })
    }

    @Test func theSidebarListsNightsNewestFirst() {
        let done = Self.read("done", selected: nil).items
        #expect(done.map(\.id) == ["2026-10-27", "2026-10-26"])
        #expect(done[1].title == "26 Oct · 50 scenes · 4 videos")
        #expect(
            Self.read("hires", selected: nil).items.map(\.title) == [
                "26 Oct · 50 scenes · 1 video · running"
            ])
        #expect(Self.read("failed", selected: nil).items[0].title.hasSuffix(" · failed"))
    }

    @Test func aRunningNightSaysWhereItIs() throws {
        let page = try #require(Self.read("hires").page)
        #expect(page.title == "Night of 26 Oct" && page.live && page.status == "Running")
        #expect(
            page.current?.line == "scene-0023, high resolution, frame 412/900, ready around 02:20")
        #expect(page.current?.progress == 0.458)
        #expect(page.delivery == "Delivery: ready around 06:20, by 07:00, 40 min to spare")
        #expect(page.report == nil)
        #expect(
            page.phases.map(\.title) == ["Previews", "Selection", "High resolution", "Style", "Videos"])
        let counts = page.phases.map(\.counts)
        #expect(counts == ["50/50", "4/4", "1/4", "1/4", "1/4"])
        #expect(page.phases.map(\.state) == [.done, .done, .current, .waiting, .waiting])
        #expect(page.phases[0].detail == "2 rejected · 1 failed")
        #expect(page.phases[0].time == "finished 00:05")
        // Part of the running hires counts towards its bar.
        #expect(page.phases[2].fraction > 0.25 + 0.1 && page.phases[2].fraction < 0.5)
        #expect(page.controls.job == 7 && page.controls.canSteer && page.controls.canSkip)
    }

    @Test func sceneCardsFollowTheStagesOfEachScene() throws {
        let page = try #require(Self.read("hires").page)
        // The picks come first, in the order they were picked.
        #expect(
            page.scenes.prefix(4).map(\.name) == [
                "scene-0019", "scene-0007", "scene-0023", "scene-0031",
            ])
        let first = page.scenes[0]
        #expect(first.stage == "Done")
        #expect(first.detail.contains("score 0.91") && first.detail.contains("high resolution 30 min"))
        #expect(page.scenes[2].current && page.scenes[2].stage == "High resolution")
        // Then the others, the latest first; rejected and failed ones have no card.
        #expect(page.scenes[4].name == "scene-0047")
        #expect(!page.scenes.contains { $0.name == "scene-0048" || $0.name == "scene-0050" })
    }

    @Test func aFinishedNightOpensOnItsReport() throws {
        let page = try #require(Self.read("done").page)
        #expect(!page.live && page.controls.job == nil && page.current == nil)
        #expect(page.status == "Finished 06:41, before 07:00")
        let report = try #require(page.report)
        #expect(report.hasPrefix("# Night of 26 Oct\n"))
        #expect(page.phases.allSatisfy { $0.state == .done })
        #expect(page.delivery?.hasPrefix("Delivery: by 07:00") == true)
    }

    @Test func errorsLinkTheirLog() throws {
        let page = try #require(Self.read("failed").page)
        #expect(page.status.hasPrefix("Failed"))
        #expect(page.problems.count == 2)
        #expect(page.problems[0].text == "scene-0007, high resolution: failed with status 1")
        #expect(page.problems[0].log == ".logs/scene-0007.hires.log")
        #expect(page.problems[0].logURL?.lastPathComponent == "scene-0007.hires.log")
        #expect(
            page.problems[0].logURL?.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent == "2026-10-26")
        #expect(page.scenes.first { $0.name == "scene-0031" }?.stage == "Left out")
        #expect(page.phases[2].state == .done || page.phases[2].state == .left)
    }

    @Test func aSceneTheResumedNightDidIsNotLeftOut() throws {
        let page = try #require(Self.read("resumed", selected: "2026-10-30-b").page)
        let picks = Array(page.scenes.prefix(2))
        #expect(picks.map(\.name) == ["scene-0044", "scene-0030"])
        #expect(picks.allSatisfy { $0.stage == "Done" && !$0.detail.contains("would end") })
        #expect(!page.scenes.contains { $0.stage == "Left out" })
    }

    @Test func workRunAfterTheEndStaysOffTheNightsPage() throws {
        let page = try #require(Self.read("after-end", selected: "2026-10-30-b").page)
        #expect(
            page.phases.map(\.time) == [
                "finished 30 Oct 23:25", "finished 30 Oct 23:25", "finished 07:47", "finished 07:47",
                "finished 07:51",
            ])
        // Its hires and its video by hand are on the scene's page.
        for name in ["scene-0031", "scene-0019"] {
            #expect(page.scenes.first { $0.name == name }?.stage == "Preview", "\(name)")
        }
    }

    @Test func aNightWhoseRunnerIsGoneIsInterruptedNotRunning() throws {
        // The file says running, nothing computes.
        let library = Self.fixtures.appendingPathComponent("hires/library")
        let page = try #require(
            NightsSnapshot.read(
                library: library, selected: "2026-10-26",
                now: RunStatus.date("2026-10-27T09:30:00.000+01:00")!, timeZone: Self.paris,
                processes: [], isAlive: { _ in false }
            ).page)
        #expect(!page.live && page.status.hasPrefix("Interrupted"))
        #expect(page.controls.job == nil && page.current == nil)
        #expect(page.phases[2].state == .left)
        #expect(page.report?.hasPrefix("# Night of 26 Oct\n") == true)
    }

    @Test func aNightWaitingInTheQueueHasAPage() throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueStore(library: root)
        let job = try store.submit(
            .night, path: root.appendingPathComponent("2026-10-28").path, runner: nil,
            at: RunStatus.date("2026-10-27T21:00:00.000+01:00")!
        ).job
        let snapshot = NightsSnapshot.read(
            library: root, selected: "2026-10-28",
            now: RunStatus.date("2026-10-27T21:05:00.000+01:00")!, timeZone: Self.paris,
            processes: [])
        #expect(snapshot.items.map(\.title) == ["28 Oct · waiting"])
        let page = try #require(snapshot.page)
        #expect(page.status == "Waiting in the queue" && page.controls.queuedJob == job.id)
        #expect(page.scenes.isEmpty && page.phases.count == 5)
        #expect(NightsSnapshot.read(library: root, selected: "2026-10-30", processes: []).page == nil)
    }

    @Test func aLibraryWithoutNightsHasNone() throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = NightsSnapshot.read(library: root, selected: nil, processes: [])
        #expect(snapshot.items.isEmpty && snapshot.page == nil)
    }

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

    static func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-nightpage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
