import Foundation
import Testing

@testable import SillageRender

@Suite("Queue status")
struct QueueStatusTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/queue-status")
    static let paris = TimeZone(identifier: "Europe/Paris")!

    static func cases() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter {
            !$0.hasPrefix(".")
        }.sorted()
    }

    /// What `sillage-render status --fixture N` does with a case, in-process.
    static func lines(_ name: String) throws -> [String] {
        let folder = fixtures.appendingPathComponent(name)
        let text = { (file: String) in
            try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let processes = (0..<(Int(try text("processes.txt")) ?? 0)).map {
            QueueStatus.ProcessInfo(pid: Int32(1_000 + $0), arguments: ["sillage-render", "render"])
        }
        return QueueStatus.read(
            library: folder.appendingPathComponent("library"),
            now: RunStatus.date(try text("now.txt"))!, timeZone: paris, processes: processes,
            isAlive: { _ in true }
        ).lines
    }

    @Test func everyFixtureSaysWhatItsFileSays() throws {
        let names = try Self.cases()
        #expect(names.count >= 7)
        for name in names {
            let expected = try String(
                contentsOf: Self.fixtures.appendingPathComponent(name).appendingPathComponent(
                    "expected.txt"), encoding: .utf8
            ).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            #expect(try Self.lines(name) == expected, "\(name)")
        }
    }

    @Test func aFreeMacIsSaidFreeOnlyWhenNothingRuns() throws {
        #expect(try Self.lines("idle").first == "Nothing running · the Mac is free")
        // A file left running by a crash, with no process to write it, is no work.
        #expect(try Self.lines("stale").first == "Nothing running · the Mac is free")
        #expect(try Self.lines("orphan").first == "Computing (no detail)")
    }

    @Test func aNightIsSaidWithItsPhaseAndItsEnd() throws {
        let lines = try Self.lines("night-hires")
        #expect(
            lines.first == "Night of 26 Oct · high resolution 2/4 · ready around 06:20 · 3 waiting")
    }

    @Test func waitingJobsFollowEachOther() throws {
        let lines = try Self.lines("night-hires")
        // The export is estimated, so the next hires starts when it ends; that one has no
        // estimate, so what comes after has no time.
        let waiting = lines.drop { $0 != "Waiting" }.dropFirst().prefix(3)
        #expect(waiting.count == 3)
        #expect(waiting.first?.contains("starts around 02:20 · ends around 02:2") == true)
        #expect(waiting.dropFirst().first?.contains("starts around 02:2") == true)
        #expect(waiting.last?.contains("starts") == false)
    }

    @Test func theLastTenFinishedAreListed() {
        var queue = JobQueue()
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        for index in 0..<14 {
            let job = queue.add(
                .hires, path: "/library/2026-10-26/scene-\(index)", at: start)
            try? queue.start(job.id, pid: 1, pidStarted: nil, log: nil, at: start)
            queue.end(
                job.id, status: 0, at: start.addingTimeInterval(Double(index) * 60 + 60))
        }
        let status = QueueStatus(.init(activity: nil, queue: queue, now: start, timeZone: Self.paris))
        #expect(status.finished.count == 10)
        #expect(status.finished.first?.job == 14)
        #expect(status.headline == "Nothing running · the Mac is free")
    }

    @Test func theRunnerWaitingForAJobIsNotWork() {
        let runner = QueueStatus.ProcessInfo(
            pid: 10, arguments: ["sillage-render", "queue", "run"])
        let status = QueueStatus.ProcessInfo(pid: 11, arguments: ["sillage-render", "status"])
        let stage = QueueStatus.ProcessInfo(pid: 12, arguments: ["sillage-render", "hires", "x"])
        let render = QueueStatus.ProcessInfo(pid: 13, arguments: ["sillage-render", "--frames"])
        #expect(QueueStatus.computing([runner, status]).isEmpty)
        #expect(QueueStatus.computing([runner, stage, render]) == [stage, render])
    }

    @Test func aHandStartedStageShowsWithoutTheQueue() throws {
        let lines = try Self.lines("by-hand")
        #expect(lines.first == "Video · scene-0023 · ready around 15:12 · 1 waiting")
    }

    @Test func aRunWithNothingWrittenForAQuarterHourIsStuck() throws {
        let lines = try Self.lines("stuck")
        #expect(lines.first?.contains("seems stuck, nothing written for 25 min") == true)
    }

    @Test func aPausedQueueGivesNoTime() throws {
        let lines = try Self.lines("paused")
        #expect(lines.first == "Paused · High resolution · scene-0023 · 1 waiting")
    }

    @Test func datesAreWrittenTheSameWhateverTheMachine() {
        let words = Words(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: Self.paris)
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(words.at(now.addingTimeInterval(60)).count == 5)
        #expect(words.at(now.addingTimeInterval(86_400)).hasPrefix("tomorrow "))
        #expect(words.about(now.addingTimeInterval(86_400)).hasPrefix("tomorrow around "))
        #expect(words.at(now.addingTimeInterval(3 * 86_400)).contains("Oct") == true)
        #expect(Words.duration(45) == "45 s")
        #expect(Words.duration(12 * 60) == "12 min")
        #expect(Words.duration(8_100) == "2 h 15 min")
        #expect(Words.size(megabytes: 672.8) == "672.8 MB" && Words.thousands(8_000_000) == "8,000,000")
    }

    @Test func stageDetailsAreShownAsWritten() {
        #expect(QueueStatus.detail("frame 412/900") == "frame 412/900")
        #expect(QueueStatus.detail("") == nil)
        #expect(QueueStatus.detail(nil) == nil)
    }
}
