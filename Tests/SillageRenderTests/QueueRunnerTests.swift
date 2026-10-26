import Foundation
import Testing

@testable import SillageRender

/// The store and the runner against real processes: small shell scripts stand in for the
/// stages.
@Suite("Queue runner")
struct QueueRunnerTests {
    private func temporaryLibrary() throws -> QueueStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return QueueStore(library: url)
    }

    /// Each job runs `script`, given its id as $1, in the job's own folder.
    private func runner(_ store: QueueStore, _ script: @escaping (QueueJob) -> String) -> QueueRunner {
        QueueRunner(
            store: store,
            command: { job in ["/bin/sh", "-c", "cd \"\(job.path)\" && \(script(job))", "job", "\(job.id)"] },
            poll: 0.02, grace: 2, busy: { [] }, say: { _ in })
    }

    private func scene(_ store: QueueStore, _ name: String = "scene-0001") throws -> SceneFolder {
        let folder = SceneFolder(
            store.library.appendingPathComponent("2026-10-26").appendingPathComponent(name))
        try FileManager.default.createDirectory(at: folder.exports, withIntermediateDirectories: true)
        return folder
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    private func inBackground(_ runner: QueueRunner) -> () -> Int32? {
        let result = Result()
        Thread.detachNewThread { result.set(runner.run()) }
        return { result.value }
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32?
        func set(_ value: Int32) { lock.withLock { stored = value } }
        var value: Int32? { lock.withLock { stored } }
    }

    @Test func changesFromManyWritersAreNeverLost() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = try? store.change { $0.add(.export, path: "/l/b/scene-\(index)", at: Date()) }
        }
        let queue = store.read()
        #expect(queue.jobs.count == 40 && Set(queue.jobs.map(\.id)) == Set(1...40))
    }

    @Test func aGarbledQueueIsLeftAlone() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.file)
        #expect(throws: QueueStore.Failure.self) { try store.change { $0.pause(at: Date()) } }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "{ not json")
        #expect(store.read().jobs.isEmpty)
    }

    @Test func oneRunnerHoldsTheQueue() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let lock = try #require(try RunnerLock.acquire(store))
        #expect(try RunnerLock.acquire(store) == nil)
        #expect(store.runner()?.pid == getpid())
        try store.change { $0.add(.explore, path: store.library.path, at: Date()) }
        #expect(runner(store) { _ in "true" }.run() == 0)
        #expect(store.read().jobs.first?.state == .waiting)
        lock.release()
        #expect(store.runner() == nil)
        #expect(try RunnerLock.acquire(store) != nil)
    }

    @Test func aProcessIsKnownByItsPidAndItsStart() throws {
        let me = getpid()
        let started = try #require(ProcessProbe.started(me))
        #expect(ProcessProbe.isAlive(pid: me, started: started))
        #expect(!ProcessProbe.isAlive(pid: me, started: started.addingTimeInterval(-60)))
        #expect(!ProcessProbe.isAlive(pid: nil, started: nil))
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Spawn.child("/usr/bin/true", [], log: log)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(ProcessProbe.started(pid) == nil)
    }

    /// The app quitting, or its terminal closing, must not reach the runner.
    @Test func aDetachedProcessHasASessionOfItsOwn() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("detached-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Spawn.detached("/bin/sleep", ["2"], log: log)
        defer { kill(pid, SIGKILL) }
        #expect(getsid(pid) == pid && getsid(pid) != getsid(0))
        #expect(getpgid(pid) == pid)
    }

    @Test func jobsRunOneAfterAnotherAndTheRunnerStopsWhenNoneIsLeft() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let trace = store.library.appendingPathComponent("trace.txt").path
        for name in ["2026-10-24", "2026-10-25", "2026-10-26"] {
            let batch = store.library.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            try store.change { $0.add(.explore, path: batch.path, at: Date()) }
        }
        let code = runner(store) { job in
            let tail = job.id == 2 ? "mkdir .scene-0004 && echo 'probe failed' && exit 3" : "true"
            return "echo start $1 >> \(trace); sleep 0.1; echo end $1 >> \(trace); \(tail)"
        }.run()
        #expect(code == 0)
        let lines = try String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3"])

        let queue = store.read()
        #expect(queue.jobs.map(\.state) == [.done, .failed, .done])
        #expect(queue.job(2)?.status == 3 && queue.job(2)?.message == "exit status 3: probe failed")
        #expect(queue.jobs.allSatisfy { $0.log.map { FileManager.default.fileExists(atPath: $0) } == true })
        let failed = store.library.appendingPathComponent("2026-10-25")
        #expect(!FileManager.default.fileExists(atPath: failed.appendingPathComponent(".scene-0004").path))
        let events = RunEvent.decodeLines(
            try String(contentsOf: RunStatusFiles.events(batch: failed), encoding: .utf8))
        #expect(events.map(\.kind) == [RunEvent.Kind.error] && events.first?.stage == "explore")
        #expect(events.first?.log == queue.job(2)?.log)

        #expect(store.runner() == nil)
        let activity = try #require(ActivityFile.read(from: RunStatusFiles.activity(library: store.library)))
        #expect(activity.state == .idle && activity.job == nil && activity.waiting == 0)
    }

    @Test func cancellingAJobStopsItAndRemovesItsPartialOutput() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let folder = try scene(store)
        try Data("old take".utf8).write(to: folder.take)
        try store.change { $0.add(.hires, path: folder.url.path, at: Date()) }
        let result = inBackground(runner(store) { _ in "echo half > .take.sillage; sleep 30" })
        #expect(wait(5) { FileManager.default.fileExists(atPath: SceneFolder.partial(folder.take).path) })
        #expect(store.read().running?.id == 1)
        let started = Date()
        try store.change { _ = try $0.cancel(1, at: Date()) }
        #expect(wait(5) { result() != nil })
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(store.read().job(1)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: SceneFolder.partial(folder.take).path))
        #expect(try String(contentsOf: folder.take, encoding: .utf8) == "old take")
    }

    @Test func pausingSuspendsTheJobAndResumingLetsItFinish() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let folder = try scene(store)
        let ticks = folder.url.appendingPathComponent("ticks").path
        try store.change { $0.add(.export, path: folder.url.path, options: ["--preset", "4k"], at: Date()) }
        let result = inBackground(
            runner(store) { _ in
                "i=0; while [ $i -lt 25 ]; do echo $i >> ticks; i=$((i+1)); sleep 0.04; done"
            })
        func count() -> Int {
            ((try? String(contentsOfFile: ticks, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        #expect(wait(5) { count() >= 3 })
        try store.change { $0.pause(at: Date()) }
        let activityURL = RunStatusFiles.activity(library: store.library)
        #expect(wait(5) { ActivityFile.read(from: activityURL)?.state == .paused })
        let frozen = count()
        Thread.sleep(forTimeInterval: 0.4)
        #expect(count() <= frozen + 1)
        #expect(store.read().running?.id == 1 && result() == nil)
        #expect(ActivityFile.read(from: activityURL)?.job?.kind == "export")
        try store.change { $0.resume(at: Date()) }
        #expect(wait(10) { result() != nil })
        #expect(count() == 25 && store.read().job(1)?.state == .done)
    }

    /// A runner that died left a job marked running: if its process is gone the job fails
    /// and its partial output goes; if the process lives on, the new runner waits for it
    /// before starting anything else.
    @Test func aNewRunnerRecoversWhatTheLastOneLeft() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let dead = try scene(store, "scene-0001")
        let orphaned = try scene(store, "scene-0002")
        let next = try scene(store, "scene-0003")
        try Data("half".utf8).write(to: SceneFolder.partial(dead.hiresVideo))
        try Data("half".utf8).write(to: dead.exports.appendingPathComponent(".4k.mp4"))
        try Data("whole".utf8).write(to: dead.exports.appendingPathComponent("1080p.mp4"))

        let log = store.library.appendingPathComponent("spawn.log")
        let gone = try Spawn.child("/usr/bin/true", [], log: log)
        let goneStarted = ProcessProbe.started(gone)
        var status: Int32 = 0
        waitpid(gone, &status, 0)
        let alive = try Spawn.detached("/bin/sleep", ["0.6"], log: log)
        let aliveStarted = ProcessProbe.started(alive)
        try store.change { queue in
            for folder in [dead, orphaned, next] { queue.add(.hires, path: folder.url.path, at: Date()) }
            try queue.start(1, pid: gone, pidStarted: goneStarted, log: nil, at: Date())
            try queue.start(2, pid: alive, pidStarted: aliveStarted, log: nil, at: Date())
        }

        let started = Date()
        #expect(runner(store) { _ in "true" }.run() == 0)
        let queue = store.read()
        #expect(queue.job(1)?.state == .failed)
        #expect(queue.job(1)?.message == "interrupted: its process ended with no runner")
        #expect(!FileManager.default.fileExists(atPath: SceneFolder.partial(dead.hiresVideo).path))
        #expect(!FileManager.default.fileExists(atPath: dead.exports.appendingPathComponent(".4k.mp4").path))
        #expect(FileManager.default.fileExists(atPath: dead.exports.appendingPathComponent("1080p.mp4").path))
        #expect(queue.job(2)?.state == .failed && queue.job(2)?.message == "ended while no runner watched it")
        #expect(queue.job(3)?.state == .done)
        #expect(Date().timeIntervalSince(started) >= 0.4)
        let events = RunEvent.decodeLines(
            try String(contentsOf: RunStatusFiles.events(batch: dead.batch), encoding: .utf8))
        #expect(events.compactMap(\.scene) == ["scene-0001", "scene-0002"])
    }

    @Test func aRunnerWaitsWhileAnotherRenderHoldsTheGPU() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        try store.change { $0.add(.explore, path: store.library.path, at: Date()) }
        let checks = Result()
        let started = Date()
        let runner = QueueRunner(
            store: store, command: { _ in ["/usr/bin/true"] }, poll: 0.02,
            busy: {
                checks.set((checks.value ?? 0) + 1)
                return (checks.value ?? 0) <= 3 ? [4242] : []
            }, say: { _ in })
        #expect(runner.run() == 0)
        #expect(checks.value == 4 && Date().timeIntervalSince(started) >= 0.5)
        #expect(store.read().job(1)?.state == .done)
    }

    /// The runner itself and the queue's commands are `sillage-render` too, and must not count.
    @Test func theOtherRenderersAreFoundByNameAndArguments() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("others-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Spawn.child("/bin/sleep", ["5", "queue"], log: log)
        defer { kill(pid, SIGKILL) }
        let found = ProcessProbe.others(named: "sleep").first { $0.pid == pid }
        #expect(found?.arguments == ["/bin/sleep", "5", "queue"])
        #expect(ProcessProbe.arguments(of: getpid()) == CommandLine.arguments)
        #expect(!ProcessProbe.others(named: "sleep").contains { $0.pid == getpid() })
    }

    @Test func submittingStartsARunnerOnlyWhenNoneIsAtWork() throws {
        let store = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: store.library) }
        let lock = try #require(try RunnerLock.acquire(store))
        let held = try store.submit(
            .explore, path: store.library.path, runner: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(held.runner == nil && held.job.id == 1)
        lock.release()
        try store.change { $0.pause(at: Date()) }
        let paused = try store.submit(
            .explore, path: store.library.path, runner: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(paused.runner == nil)
        try store.change { $0.resume(at: Date()) }
        let free = try store.submit(
            .explore, path: store.library.path, runner: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(free.runner != nil)
        #expect(
            ActivityFile.read(from: RunStatusFiles.activity(library: store.library))?.waiting == 3)
    }
}
