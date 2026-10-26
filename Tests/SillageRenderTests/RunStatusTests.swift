import Foundation
import Testing

@testable import SillageRender

@Suite("Run status")
struct RunStatusTests {
    private func temporaryLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func folder(in library: URL, scene: String = "scene-0001") -> SceneFolder {
        SceneFolder(
            library.appendingPathComponent("2026-10-26").appendingPathComponent(scene))
    }

    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let noon = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func activityAndNightRoundTrip() throws {
        let job = ActivityFile.Job(
            kind: "hires", batch: "2026-10-26", scene: "scene-0007", startedAt: noon,
            progress: 0.458, detail: "frame 412/900", eta: noon.addingTimeInterval(3_600))
        let activity = ActivityFile(
            state: .running, job: job,
            night: .init(id: "2026-10-26", phase: "hires", eta: noon.addingTimeInterval(7_200)),
            waiting: 3, updated: noon.addingTimeInterval(10))
        let back = try RunStatus.decoder().decode(ActivityFile.self, from: activity.encoded())
        #expect(back == activity)
        #expect(back.version == RunStatus.version)

        let night = NightFile(
            id: "2026-10-26", recipe: ["scenes": "50", "hours": "8"],
            phases: [
                .init(name: "explore", planned: 50, done: 41, failed: 1),
                .init(name: "hires", planned: 5),
            ], state: .paused, startedAt: noon, estimatedEnd: noon.addingTimeInterval(28_800))
        #expect(try RunStatus.decoder().decode(NightFile.self, from: night.encoded()) == night)

        var event = RunEvent(RunEvent.Kind.exportDone, scene: "scene-0007", at: noon)
        event.preset = "1080p"
        event.style = "classic"
        event.codec = "hevc"
        event.frames = 900
        event.megabytes = 84.5
        event.seconds = 212.4
        event.path = "exports/1080p.mp4"
        let line = try RunStatus.encoder(pretty: false).encode(event)
        #expect(!line.contains(0x0A))
        #expect(try RunStatus.decoder().decode(RunEvent.self, from: line) == event)
    }

    @Test func datesCarryTheirOffset() throws {
        let paris = TimeZone(secondsFromGMT: 7_200)!
        let text = RunStatus.string(noon, timeZone: paris)
        #expect(text.hasSuffix("+02:00"))
        #expect(RunStatus.date(text) == noon)
        // Without the milliseconds, as another writer might.
        #expect(RunStatus.date("2026-10-26T20:02:56+02:00") != nil)
        #expect(RunStatus.date("yesterday") == nil)
    }

    @Test func etaFollowsFromProgress() {
        let now = noon
        #expect(RunStatus.eta(elapsed: 100, progress: 0.25, now: now) == now.addingTimeInterval(300))
        #expect(RunStatus.eta(elapsed: 100, progress: 1, now: now) == now)
        #expect(RunStatus.eta(elapsed: 100, progress: 0, now: now) == nil)
    }

    /// A settle at the pace of the steps, then frames at a flat cost: once a tenth of the
    /// frames are done, the end the pace of the frames gives is within 15 % of the real one.
    @Test func etaOfAFlatCostRunIsClose() {
        let settle = 120.0
        let perFrame = 3.0
        let frames = 900
        let end = settle + perFrame * Double(frames)
        let done = frames / 10
        let now = noon.addingTimeInterval(settle + perFrame * Double(done))
        let eta = RunStatus.eta(
            elapsed: perFrame * Double(done), progress: Double(done) / Double(frames), now: now)
        let real = noon.addingTimeInterval(end)
        let error = abs(eta!.timeIntervalSince(real)) / (end - (settle + perFrame * Double(done)))
        #expect(error < 0.15)
    }

    @Test func activityIsRewrittenNoMoreThanEveryTenSeconds() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let clock = Clock(noon)
        let reporter = StageReporter(
            stage: "explore", folder: folder(in: library), clock: { clock.now })
        let url = RunStatusFiles.activity(library: library)

        reporter.start(detail: "starting")
        #expect(ActivityFile.read(from: url)?.state == .running)

        var written: [String] = []
        for second in 1...35 {
            clock.now = noon.addingTimeInterval(Double(second))
            reporter.update(progress: Double(second) / 40, detail: "frame \(second)/40")
            let detail = ActivityFile.read(from: url)?.job?.detail ?? ""
            if written.last != detail { written.append(detail) }
        }
        // The start, then the first update past ten seconds, then every ten after it.
        #expect(written == ["starting", "frame 10/40", "frame 20/40", "frame 30/40"])

        let file = try #require(ActivityFile.read(from: url))
        let job = try #require(file.job)
        #expect(job.kind == "explore" && job.batch == "2026-10-26" && job.scene == "scene-0001")
        #expect(job.progress == 0.75)
        // 30 s for three quarters of it: ten more.
        #expect(job.eta == noon.addingTimeInterval(40))
        #expect(file.updated == noon.addingTimeInterval(30))
    }

    @Test func finishingLeavesTheFileIdleButKeepsAnotherJobsOwn() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let clock = Clock(noon)
        let url = RunStatusFiles.activity(library: library)
        let first = StageReporter(
            stage: "explore", folder: folder(in: library, scene: ".scene-0001"),
            clock: { clock.now })
        let second = StageReporter(
            stage: "explore", folder: folder(in: library, scene: ".scene-0002"),
            clock: { clock.now })

        // The night's own fields survive a stage rewriting the file.
        let night = ActivityFile.Night(id: "2026-10-26", phase: "explore")
        try RunStatusFiles.write(
            ActivityFile(state: .running, night: night, waiting: 4, updated: noon).encoded(),
            to: url)
        first.start(detail: "a")
        #expect(ActivityFile.read(from: url)?.job?.scene == "scene-0001")
        second.start(detail: "b")
        #expect(ActivityFile.read(from: url)?.job?.scene == "scene-0002")

        first.finish()
        #expect(ActivityFile.read(from: url)?.job?.scene == "scene-0002")
        second.finish()
        let idle = try #require(ActivityFile.read(from: url))
        #expect(idle.state == .idle && idle.job == nil)
        #expect(idle.night == night && idle.waiting == 4)
    }

    /// Scenes explored side by side finish in any order, and their lines come out whole.
    @Test func interleavedEventsDecode() throws {
        let fixture = """
            {"kind":"night.start","night":"2026-10-26","t":"2026-10-26T20:00:00.000+02:00"}
            {"kind":"explore.scene","scene":"scene-0001","score":0.61,"seconds":212,"status":"ok","t":"2026-10-26T20:03:32.000+02:00"}
            {"kind":"explore.scene","scene":"scene-0003","seconds":9,"status":"rejected","t":"2026-10-26T20:03:41.000+02:00"}
            {"kind":"explore.scene","scene":"scene-0002","score":0.34,"seconds":230,"status":"ok","t":"2026-10-26T20:03:50.000+02:00"}
            {"kind":"explore.scene","scene":"scene-0004","seconds":5,"status":"failed","t":"2026-10-26T20:03:55.000+02:00"}
            {"kind":"error","log":".logs/scene-0004.log","message":"failed:1","scene":"scene-0004","stage":"explore","t":"2026-10-26T20:03:55.000+02:00"}
            {"kind":"hires.start","particles":2000000,"scene":"scene-0001","steps":900,"t":"2026-10-26T23:00:00.000+02:00"}
            {"kind":"hires.done","minutes":61.5,"particles":2000000,"scene":"scene-0001","steps":900,"t":"2026-10-27T00:01:30.000+02:00","takeGB":2.7}

            """
        let events = RunEvent.decodeLines(fixture)
        #expect(events.count == 8)
        #expect(
            events.filter { $0.kind == RunEvent.Kind.exploreScene }.compactMap(\.scene)
                == ["scene-0001", "scene-0003", "scene-0002", "scene-0004"])
        #expect(events[1].status == "ok" && events[1].score == 0.61 && events[1].seconds == 212)
        #expect(events[2].status == "rejected" && events[2].score == nil)
        #expect(events[5].stage == "explore" && events[5].log == ".logs/scene-0004.log")
        #expect(events[7].takeGB == 2.7 && events[7].minutes == 61.5)
        #expect(events[0].t < events[7].t)
        // A line cut short is skipped, not fatal.
        #expect(RunEvent.decodeLines(fixture + "{\"kind\":\"pick\",\"sc").count == 8)
    }

    @Test func linesAppendedTogetherNeverMix() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let url = RunStatusFiles.events(batch: library)
        let count = 400
        DispatchQueue.concurrentPerform(iterations: count) { index in
            var event = RunEvent(RunEvent.Kind.exploreScene, scene: String(format: "scene-%04d", index))
            event.status = "ok"
            event.seconds = Double(index)
            // A long message stretches the line, to make a torn write likely if there were one.
            event.message = String(repeating: "x", count: 600)
            try? RunStatusFiles.append(event, to: url)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == count)
        let events = RunEvent.decodeLines(text)
        #expect(events.count == count)
        #expect(Set(events.compactMap(\.scene)).count == count)
    }

    @Test func aJSONFileIsReplacedWholeWithoutLeftovers() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let url = RunStatusFiles.activity(library: library)
        for second in 0..<5 {
            try RunStatusFiles.write(
                ActivityFile(
                    state: .idle, updated: noon.addingTimeInterval(Double(second))
                ).encoded(), to: url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == ["activity.json"])
        #expect(ActivityFile.read(from: url)?.updated == noon.addingTimeInterval(4))
    }

    @Test func eventsComeFromACommandLine() throws {
        let event = try RunEvent(
            "explore.scene",
            options: ["--scene", "scene-0007", "--status", "ok", "--score", "0.5", "--seconds", "212"],
            at: noon)
        #expect(event.scene == "scene-0007" && event.status == "ok")
        #expect(event.score == 0.5 && event.seconds == 212 && event.kind == "explore.scene")
        let hires = try RunEvent(
            "hires.done", options: ["--particles", "2e6", "--take-gb", "2.5"], at: noon)
        #expect(hires.particles == 2_000_000 && hires.takeGB == 2.5)

        #expect(throws: RunEvent.FieldError.self) { try RunEvent("pick", options: ["--colour", "red"]) }
        #expect(throws: RunEvent.FieldError.self) { try RunEvent("pick", options: ["--score", "high"]) }
        #expect(throws: RunEvent.FieldError.self) { try RunEvent("pick", options: ["--score"]) }
    }

    @Test func aStageFindsItsFilesFromItsFolder() {
        let scene = SceneFolder(path: "/library/2026-10-26/.scene-0004")
        #expect(scene.sceneName == "scene-0004")
        #expect(scene.library.path == "/library")
        #expect(RunStatusFiles.activity(library: scene.library).path == "/library/activity.json")
        #expect(RunStatusFiles.events(batch: scene.batch).path == "/library/2026-10-26/events.jsonl")
        #expect(RunStatusFiles.night(batch: scene.batch).lastPathComponent == "night.json")
    }
}
