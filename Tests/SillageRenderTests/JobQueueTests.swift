import Foundation
import Testing

@testable import SillageRender

@Suite("Job queue")
struct JobQueueTests {
    private let noon = Date(timeIntervalSince1970: 1_792_000_000)

    private func queue(_ count: Int) -> JobQueue {
        var queue = JobQueue()
        for index in 1...count {
            queue.add(
                .hires, path: "/library/2026-10-25/scene-000\(index)", options: ["--particles", "2e6"],
                at: noon)
        }
        return queue
    }

    @Test func jobsRunOneAtATimeInTheOrderAdded() throws {
        var queue = queue(3)
        #expect(queue.jobs.map(\.id) == [1, 2, 3] && queue.nextID == 4)
        #expect(queue.jobs.allSatisfy { $0.state == .waiting && $0.by == .hand })
        #expect(queue.next?.id == 1)
        try queue.start(1, pid: 400, pidStarted: noon, log: "/tmp/job-1.log", at: noon)
        #expect(queue.running?.id == 1 && queue.next == nil)
        #expect(throws: JobQueue.Failure.notWaiting(1, .running)) {
            try queue.start(1, pid: 401, pidStarted: noon, log: nil, at: noon)
        }
        queue.end(1, status: 0, at: noon.addingTimeInterval(60))
        #expect(queue.job(1)?.state == .done && queue.job(1)?.ended == noon.addingTimeInterval(60))
        #expect(queue.next?.id == 2 && queue.waiting.map(\.id) == [2, 3])
    }

    @Test func aPausedQueueStartsNothing() {
        var queue = queue(2)
        queue.pause(at: noon)
        #expect(queue.paused && queue.next == nil)
        queue.resume(at: noon)
        #expect(queue.next?.id == 1)
    }

    @Test func firstPutsAWaitingJobNextBehindTheRunningOne() throws {
        var queue = queue(4)
        try queue.start(1, pid: 400, pidStarted: noon, log: nil, at: noon)
        try queue.moveFirst(4, at: noon)
        #expect(queue.waiting.map(\.id) == [4, 2, 3])
        #expect(queue.running?.id == 1 && queue.next == nil)
        queue.end(1, status: 0, at: noon)
        #expect(queue.next?.id == 4)
        #expect(throws: JobQueue.Failure.notWaiting(1, .done)) { try queue.moveFirst(1, at: noon) }
        #expect(throws: JobQueue.Failure.noSuchJob(9)) { try queue.moveFirst(9, at: noon) }
    }

    @Test func cancelTakesAWaitingJobOutAndStopsARunningOne() throws {
        var queue = queue(3)
        #expect(try queue.cancel(2, at: noon) == .cancelled)
        #expect(queue.job(2)?.message == "cancelled before it started" && queue.next?.id == 1)
        try queue.start(1, pid: 400, pidStarted: noon, log: nil, at: noon)
        #expect(try queue.cancel(1, at: noon) == .running)
        #expect(queue.job(1)?.stopping == true && queue.running?.id == 1)
        queue.end(1, status: 143, message: "ended by signal 15", at: noon)
        #expect(queue.job(1)?.state == .cancelled && queue.job(1)?.stopping == nil)
        #expect(queue.next?.id == 3)
        #expect(throws: JobQueue.Failure.finished(1, .cancelled)) { try queue.cancel(1, at: noon) }
    }

    @Test func aJobEndsDoneFailedOrNeverStarted() throws {
        var queue = queue(3)
        try queue.start(1, pid: 400, pidStarted: noon, log: nil, at: noon)
        queue.end(1, status: 2, message: "exit status 2: hires: no scene.json", at: noon)
        #expect(queue.job(1)?.state == .failed && queue.job(1)?.status == 2)
        #expect(queue.job(1)?.message == "exit status 2: hires: no scene.json")
        try queue.start(2, pid: 401, pidStarted: noon, log: nil, at: noon)
        queue.end(2, status: nil, at: noon)
        #expect(queue.job(2)?.message == "ended with no status")
        queue.end(3, status: nil, message: "did not start: no such file", at: noon)
        #expect(queue.job(3)?.state == .failed && queue.job(3)?.started == nil)
        queue.end(3, status: 0, at: noon)
        #expect(queue.job(3)?.state == .failed)
    }

    /// The runner died: a job whose process is gone fails, or is cancelled if it was being
    /// stopped; one whose process lives on stays running for the next runner to watch.
    @Test func recoveryFailsTheJobsWhoseProcessIsGone() throws {
        var queue = queue(4)
        for id in 1...3 {
            try queue.start(id, pid: Int32(400 + id), pidStarted: noon, log: nil, at: noon)
        }
        _ = try queue.cancel(2, at: noon)
        let later = noon.addingTimeInterval(3_600)
        let lost = queue.recover(at: later) { $0.pid == 403 }
        #expect(lost.map(\.id) == [1, 2])
        #expect(queue.job(1)?.state == .failed && queue.job(1)?.ended == later)
        #expect(queue.job(1)?.message == "interrupted: its process ended with no runner")
        #expect(queue.job(2)?.state == .cancelled)
        #expect(queue.job(3)?.state == .running && queue.job(4)?.state == .waiting)
        #expect(queue.recover(at: later) { _ in true }.isEmpty)
    }

    @Test func onlyTheLatestFinishedJobsAreKept() throws {
        var queue = JobQueue()
        for index in 0..<(JobQueue.keptFinished + 10) {
            let job = queue.add(.export, path: "/library/b/scene-0001", at: noon)
            queue.end(job.id, status: 0, at: noon.addingTimeInterval(Double(index)))
        }
        queue.add(.export, path: "/library/b/scene-0002", at: noon)
        #expect(queue.finished.count == JobQueue.keptFinished)
        #expect(queue.finished.first?.id == JobQueue.keptFinished + 10)
        #expect(queue.finished.last?.id == 11)
        #expect(queue.waiting.count == 1)
    }

    @Test func aJobNamesItsBatchAndScene() {
        var queue = JobQueue()
        let hires = queue.add(
            .hires, path: "/library/2026-10-25/scene-0023", options: ["--particles", "2000000"],
            at: noon)
        #expect(hires.batch == "2026-10-25" && hires.scene == "scene-0023")
        #expect(hires.batchURL.path == "/library/2026-10-25")
        #expect(hires.summary == "hires 2026-10-25/scene-0023 --particles 2000000")
        let explore = queue.add(
            .explore, path: "/library/2026-10-27", by: .night, night: "2026-10-27", at: noon)
        #expect(explore.batch == "2026-10-27" && explore.scene == nil && explore.by == .night)
    }

    @Test func theFileRoundTrips() throws {
        var queue = queue(2)
        try queue.start(1, pid: 400, pidStarted: noon.addingTimeInterval(0.25), log: "/l/job-1.log", at: noon)
        queue.pause(at: noon)
        let text = String(decoding: try queue.encoded(), as: UTF8.self)
        #expect(text.contains("\"state\" : \"running\"") && text.contains("\"paused\" : true"))
        #expect(try JobQueue.decoded(from: queue.encoded()) == queue)
    }
}
