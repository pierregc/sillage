import Foundation
import Testing

@testable import SillageRender

@Suite("Night status and report")
struct NightStatusTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/night-status")
    static let paris = TimeZone(identifier: "Europe/Paris")!

    static func cases() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter {
            !$0.hasPrefix(".")
        }.sorted()
    }

    static func text(_ name: String, _ file: String) -> String? {
        (try? String(
            contentsOf: fixtures.appendingPathComponent(name).appendingPathComponent(file),
            encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `sillage-render status` prints for a case, in-process, with the case's own arguments.
    static func run(_ name: String, extra: [String] = []) -> (status: Int32, lines: [String]) {
        let library = fixtures.appendingPathComponent(name).appendingPathComponent("library")
        let own = (text(name, "args.txt") ?? "").replacingOccurrences(of: "{library}", with: library.path)
            .split(separator: " ").map(String.init)
        var printed: [String] = []
        let status = StatusCommand.main(
            [
                "--library", library.path, "--now", text(name, "now.txt") ?? "", "--timezone",
                paris.identifier,
                "--fixture", text(name, "processes.txt") ?? "0",
            ] + own + extra
        ) { printed.append($0) }
        return (status, printed)
    }

    @Test func everyFixtureSaysWhatItsFilesSay() throws {
        let names = try Self.cases()
        #expect(names == ["after-end", "done", "exploring", "failed", "hires", "idle", "resumed"])
        for name in names {
            let expected = try #require(Self.text(name, "expected.txt")).split(separator: "\n").map(
                String.init)
            let run = Self.run(name)
            #expect(run.status == 0 && run.lines == expected, "\(name)")
            #expect(run.lines.count <= 5, "\(name)")
        }
    }

    @Test func aRunningNightIsSaidAsTheExampleOfTheTicketIs() {
        let lines = Self.run("hires").lines
        #expect(
            lines.first
                == "Nuit du 26 oct. · haute résolution 2/4 · scene-0023 image 412/900 · prêt vers 6 h 20 · 0 erreur"
        )
        // The first line is the app's own, with the errors added.
        let status = QueueStatus.read(
            library: Self.fixtures.appendingPathComponent("hires/library"),
            now: RunStatus.date(Self.text("hires", "now.txt")!)!, timeZone: Self.paris,
            processes: [.init(pid: 1, arguments: ["sillage-render", "render"])], isAlive: { _ in true })
        #expect(lines.first == status.summary + " · 0 erreur")
        #expect(status.headline == "Nuit du 26 oct. · haute résolution 2/4 · prêt vers 6 h 20")
    }

    @Test func anIdleMacNamesTheLastNightAndHowItEnded() {
        let lines = Self.run("idle").lines
        #expect(lines.first == "Rien en cours · le Mac est libre")
        #expect(lines[1] == "Nuit du 26 oct. · terminée 6 h 41, avant 7 h 00 · 0 erreur")
        #expect(Self.run("failed").lines[1].contains("en échec"))
    }

    @Test func aNightIsReportedByItsFolder() {
        let lines = Self.run("done").lines
        // The failed night is the latest, and not the one asked for.
        #expect(lines.first?.hasPrefix("Nuit du 26 oct. · terminée") == true)
        #expect(!lines.contains("Rien en cours · le Mac est libre"))
        let library = Self.fixtures.appendingPathComponent("done/library")
        #expect(
            StatusCommand.main([
                "--library", library.path, "--night", library.appendingPathComponent("nowhere").path,
            ]) {
                _ in
            } == 1)
    }

    @Test func aLibraryWithoutNightsSaysSo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var printed: [String] = []
        #expect(StatusCommand.main(["--library", root.path, "--fixture", "0"]) { printed.append($0) } == 0)
        #expect(
            printed == ["Rien en cours · le Mac est libre", "Aucune nuit encore dans cette bibliothèque"])
    }

    @Test func jsonSaysTheSameAsTheLines() throws {
        for name in try Self.cases() {
            let lines = Self.run(name).lines
            let printed = Self.run(name, extra: ["--json"]).lines.joined(separator: "\n")
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
            #expect(object["lines"] as? [String] == lines, "\(name)")
            #expect(object["busy"] as? Bool == (name == "exploring" || name == "hires"), "\(name)")
            #expect((object["night"] as? [String: Any])?["id"] != nil, "\(name)")
        }
        let hires = try #require(
            JSONSerialization.jsonObject(with: Data(Self.run("hires", extra: ["--json"]).lines.joined().utf8))
                as? [String: Any])
        let night = try #require(hires["night"] as? [String: Any])
        #expect(night["state"] as? String == "running" && night["phase"] as? String == "hires")
        #expect(night["hiresDone"] as? Int == 1 && night["hiresPlanned"] as? Int == 4)
        #expect((night["lastVideo"] as? [String: Any])?["path"] as? String == "scene-0019/exports/4k.mp4")
        let failed = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.run("failed", extra: ["--json"]).lines.joined().utf8))
                as? [String: Any])
        let failures = try #require((failed["night"] as? [String: Any])?["failures"] as? [[String: Any]])
        #expect(
            failures.count == 2
                && failures[0]["log"] as? String == "/library/2026-10-26/.logs/scene-0007.hires.log")
    }

    /// 2026-10-30-b: both hires left out for time at 23:25, then done by the night resumed at
    /// 23:49 in the same folder.
    @Test func aResumedNightDoesNotLeaveOutWhatItDidAfterAll() throws {
        let batch = Self.fixtures.appendingPathComponent("resumed/library/2026-10-30-b")
        let events = RunEvent.decodeLines(
            try String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8))
        #expect(events.filter { $0.kind == RunEvent.Kind.skip }.map(\.scene) == ["scene-0044", "scene-0030"])
        #expect(NightEvents(events, end: nil).skipped.isEmpty)
        let report = try String(contentsOf: batch.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("- Laissées de côté : 0 · erreurs : 0") && !report.contains("would end"))
        func skipped(_ name: String) throws -> Int? {
            let printed = Self.run(name, extra: ["--json"]).lines.joined()
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
            return (object["night"] as? [String: Any])?["skipped"] as? Int
        }
        #expect(try skipped("resumed") == 0)
        // A skip nothing undid still counts.
        #expect(try skipped("failed") == 1)
    }

    @Test func aSkipHoldsInItsRunUntilTheSameStageIsDone() {
        typealias Kind = RunEvent.Kind
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ kind: String, _ scene: String? = nil, stage: String? = nil) -> RunEvent {
            clock += 60
            var event = RunEvent(kind, scene: scene, at: clock)
            event.stage = stage
            return event
        }
        func standing(_ events: [RunEvent]) -> [String?] { NightEvents.standingSkips(events).map(\.scene) }
        let start = event(Kind.nightStart)
        let skip = event(Kind.skip, "scene-0001", stage: "hires")
        #expect(standing([start, skip]) == ["scene-0001"])
        // Done by hand since.
        #expect(standing([start, skip, event(Kind.hiresDone, "scene-0001")]).isEmpty)
        // Another scene's hires, the scene's style, or a hires done before do not undo it.
        #expect(standing([start, skip, event(Kind.hiresDone, "scene-0002")]) == ["scene-0001"])
        #expect(standing([start, skip, event(Kind.style, "scene-0001")]) == ["scene-0001"])
        #expect(standing([start, event(Kind.hiresDone, "scene-0001"), skip]) == ["scene-0001"])
        #expect(
            standing([start, event(Kind.skip, "scene-0001", stage: "style"), event(Kind.style, "scene-0001")])
                .isEmpty)
        #expect(
            standing([
                start, event(Kind.skip, "scene-0001", stage: "export"), event(Kind.exportDone, "scene-0001"),
            ]).isEmpty)
        // A resumed night tries the scene again, even when it stops before getting to it.
        #expect(standing([start, skip, event(Kind.nightDone), event(Kind.nightStart)]).isEmpty)
        #expect(standing([skip]) == ["scene-0001"])
    }

    @Test func aHiresWithTracersSaysHowManyCarryTheMass() throws {
        let start = RunStatus.date("2026-11-04T21:00:00+01:00")!
        let night = NightFile(id: "2026-11-04", phases: [], state: .done, startedAt: start)
        var hires = RunEvent(
            RunEvent.Kind.hiresDone, scene: "scene-0031", at: start.addingTimeInterval(3_600))
        hires.particles = 8_000_000
        hires.massive = 2_000_000
        hires.minutes = 38
        let report = NightReport.markdown(
            night, events: [RunEvent(RunEvent.Kind.nightStart, at: start), hires],
            now: start.addingTimeInterval(7_200), timeZone: Self.paris)
        #expect(report.contains("- scene-0031 : 8 000 000 particules (2 000 000 massives) en 38 min"))
        #expect(try RunEvent(RunEvent.Kind.hiresStart, options: ["--massive", "2e6"]).massive == 2_000_000)
    }

    /// 2026-10-30-b again: a hires of scene-0031 at 08:20 and its whatsapp export at 08:46, run
    /// by hand after the night ended at 07:51.
    @Test func workRunInTheFolderAfterTheEndIsNotTheNights() throws {
        let batch = Self.fixtures.appendingPathComponent("after-end/library/2026-10-30-b")
        let events = RunEvent.decodeLines(
            try String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8))
        #expect(events.filter { $0.kind == RunEvent.Kind.hiresDone }.count == 3)
        let night = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        let report = NightReport.markdown(
            night, events: events, batch: batch,
            now: RunStatus.date(Self.text("after-end", "now.txt")!)!, timeZone: Self.paris)
        #expect(report.contains("- Haute résolution : 2 faites sur 2 prévues"))
        #expect(report.contains("- Vidéos : 4 (672,8 Mo)") && !report.contains("whatsapp"))
        let printed = Self.run("after-end", extra: ["--json"]).lines.joined()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        let digest = try #require(object["night"] as? [String: Any])
        #expect(digest["hiresDone"] as? Int == 2 && digest["videos"] as? Int == 4)
        #expect(
            (digest["lastVideo"] as? [String: Any])?["path"] as? String
                == "scene-0030/exports/vertical.mp4")
    }

    @Test func onlyWhatTheNightsRunsWroteCounts() {
        typealias Kind = RunEvent.Kind
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ kind: String, _ scene: String? = nil, stage: String? = nil) -> RunEvent {
            clock += 60
            var event = RunEvent(kind, scene: scene, at: clock)
            event.stage = stage
            return event
        }
        func own(_ events: [RunEvent], end: Date? = nil) -> [RunEvent] {
            NightEvents.own(events, end: end)
        }
        let start = event(Kind.nightStart)
        let skip = event(Kind.skip, "scene-0003", stage: "hires")
        let hires = event(Kind.hiresDone, "scene-0001")
        let done = event(Kind.nightDone)
        let byHand = event(Kind.hiresDone, "scene-0003")
        let failed = event(Kind.error, "scene-0002", stage: "hires")
        let why = event(Kind.error, stage: "night")
        let again = event(Kind.nightStart)
        let video = event(Kind.exportDone, "scene-0001")
        // Run by hand, then failed in the queue, once the night is over. The queue's word on the
        // night itself is the night's.
        #expect(own([start, hires, done, byHand, failed, why]) == [start, hires, done, why])
        // Between two runs.
        #expect(own([start, done, byHand, again, video]) == [start, done, again, video])
        // A run killed before its night.done ends at the night's end.
        #expect(own([start, hires, byHand, why], end: hires.t) == [start, hires, why])
        // Lines before any night.start, as a night that wrote none.
        #expect(own([hires, byHand]) == [hires, byHand])
        // What the night left out stays left out when it is done by hand after the end.
        #expect(NightEvents([start, skip, done, byHand], end: nil).skipped == [skip])
        #expect(NightEvents([start, skip, byHand, done], end: nil).skipped.isEmpty)
    }

    @Test func theNightStatusPageNamesWhatTheCodeWrites() throws {
        let page = try String(
            contentsOf: Self.fixtures.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("docs/night-status.md"),
            encoding: .utf8)
        let kinds = [
            RunEvent.Kind.nightStart, RunEvent.Kind.exploreScene, RunEvent.Kind.pick,
            RunEvent.Kind.hiresStart, RunEvent.Kind.hiresDone, RunEvent.Kind.exportDone,
            RunEvent.Kind.style, RunEvent.Kind.skip, RunEvent.Kind.error, RunEvent.Kind.phaseDone,
            RunEvent.Kind.nightDone,
        ]
        for kind in kinds { #expect(page.contains("`\(kind)`"), "\(kind)") }
        #expect(page.contains("\(Int(QueueStatus.stuckAfter / 60)) minutes or more"))
        #expect(page.contains("sillage-render status"))
        for name in ["idle", "exploring", "mid hires", "failed", "done", "resumed", "after the end"] {
            #expect(page.contains("| \(name) |"), "\(name)")
        }
        #expect(page.contains(try #require(Self.text("hires", "expected.txt")).split(separator: "\n")[0]))
    }

    @Test func fullKeepsTheQueueViewsLines() {
        let library = Self.fixtures.appendingPathComponent("hires/library")
        var printed: [String] = []
        _ = StatusCommand.main(
            [
                "--full", "--library", library.path, "--now", Self.text("hires", "now.txt")!, "--timezone",
                "Europe/Paris", "--fixture", "1",
            ]
        ) { printed.append($0) }
        #expect(printed.first == "Nuit du 26 oct. · haute résolution 2/4 · prêt vers 6 h 20")
    }

    @Test func theReportOfEveryNightMatchesItsGoldenFile() throws {
        var checked = 0
        for name in try Self.cases() {
            let library = Self.fixtures.appendingPathComponent(name).appendingPathComponent("library")
            let batches = try FileManager.default.contentsOfDirectory(
                at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for batch in batches {
                guard let night = NightFile.read(from: RunStatusFiles.night(batch: batch)) else {
                    continue
                }
                let golden = batch.appendingPathComponent("report.md")
                let events =
                    (try? String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8))
                    .map(RunEvent.decodeLines) ?? []
                let report = NightReport.markdown(
                    night, events: events, batch: batch,
                    now: RunStatus.date(Self.text(name, "now.txt")!)!, timeZone: Self.paris)
                if let expected = try? String(contentsOf: golden, encoding: .utf8) {
                    #expect(report == expected, "\(name)/\(batch.lastPathComponent)")
                    #expect(report.split(separator: "\n").prefix { !$0.hasPrefix("##") }.count <= 11)
                    checked += 1
                }
            }
        }
        #expect(checked >= 4)
    }
}
