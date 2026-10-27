import Foundation

/// One piece of heavy work: an exploration batch, a high resolution run, an export or a night.
public struct QueueJob: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case explore, hires, export, night }
    public enum State: String, Codable, Sendable { case waiting, running, done, failed, cancelled }
    public enum Origin: String, Codable, Sendable { case hand, night }

    public var id: Int
    public var kind: Kind
    public var state: State
    /// Who asked for it.
    public var by: Origin
    /// The night that asked, when `by` is night.
    public var night: String?
    /// The scene folder of a hires or an export, the batch folder of an exploration or a night.
    public var path: String
    /// Given to the stage after its folder, as on its command line.
    public var options: [String]
    public var added: Date
    public var started: Date?
    public var ended: Date?
    /// The process doing it, and when that process started: a pid alone is reused.
    public var pid: Int32?
    public var pidStarted: Date?
    /// The exit status, when the process ran to an end.
    public var status: Int32?
    /// Why it failed or was cancelled.
    public var message: String?
    public var log: String?
    /// Asked to stop while it runs; the runner stops it and leaves it cancelled.
    public var stopping: Bool?
    /// A night asked to stop once the step it is on is done.
    public var stopAfterStep: Bool?
    /// How many times a night was asked to leave out the scene it works on: it leaves out one
    /// each time the count goes up.
    public var skips: Int?

    public init(
        id: Int, kind: Kind, path: String, options: [String] = [], by: Origin = .hand,
        night: String? = nil, added: Date
    ) {
        self.id = id
        self.kind = kind
        state = .waiting
        self.by = by
        self.night = night
        self.path = path
        self.options = options
        self.added = added
    }

    public var isFinished: Bool { state == .done || state == .failed || state == .cancelled }

    /// Whether it works on one scene rather than a whole batch.
    public var isScene: Bool { kind == .hires || kind == .export }

    public var batchURL: URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return isScene ? url.deletingLastPathComponent() : url
    }

    /// As `activity.json` and the events name them.
    public var batch: String { batchURL.lastPathComponent }
    public var scene: String? { isScene ? URL(fileURLWithPath: path).lastPathComponent : nil }

    /// As the queue lists it: `hires 2026-10-25/scene-0023 --particles 2000000`.
    public var summary: String {
        ([kind.rawValue, scene.map { "\(batch)/\($0)" } ?? batch] + options).joined(separator: " ")
    }
}

/// `library/.queue/queue.json`: every job in the order it ran or will run, one at a time.
/// Changed only through `QueueStore.change`, which holds a lock while it reads and rewrites it.
public struct JobQueue: Codable, Sendable, Equatable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noSuchJob(Int)
        case notWaiting(Int, QueueJob.State)
        case finished(Int, QueueJob.State)
        case notARunningNight(Int)

        public var description: String {
            switch self {
            case .notARunningNight(let id): "job \(id) is not a night that runs"
            case .noSuchJob(let id): "no job \(id) in the queue"
            case .notWaiting(let id, let state): "job \(id) is \(state.rawValue), not waiting"
            case .finished(let id, let state): "job \(id) is \(state.rawValue) already"
            }
        }
    }

    /// Finished jobs kept for the queue's history; older ones are dropped.
    public static let keptFinished = 50

    public var version = RunStatus.version
    /// Nothing starts, and the job running is suspended, until `resume`.
    public var paused = false
    public var nextID = 1
    public var jobs: [QueueJob] = []
    public var updated: Date?

    public init() {}

    public var running: QueueJob? { jobs.first { $0.state == .running } }
    public var waiting: [QueueJob] { jobs.filter { $0.state == .waiting } }
    public var finished: [QueueJob] {
        jobs.filter(\.isFinished).sorted { ($0.ended ?? $0.added) > ($1.ended ?? $1.added) }
    }

    public func job(_ id: Int) -> QueueJob? { jobs.first { $0.id == id } }

    /// The next job to start: none while one runs or the queue is paused.
    public var next: QueueJob? {
        guard !paused, running == nil else { return nil }
        return jobs.first { $0.state == .waiting }
    }

    @discardableResult
    public mutating func add(
        _ kind: QueueJob.Kind, path: String, options: [String] = [], by: QueueJob.Origin = .hand,
        night: String? = nil, at date: Date
    ) -> QueueJob {
        let job = QueueJob(
            id: nextID, kind: kind, path: path, options: options, by: by, night: night, added: date)
        nextID += 1
        jobs.append(job)
        updated = date
        return job
    }

    public mutating func start(
        _ id: Int, pid: Int32, pidStarted: Date?, log: String?, at date: Date
    ) throws {
        let index = try self.index(id)
        guard jobs[index].state == .waiting else { throw Failure.notWaiting(id, jobs[index].state) }
        jobs[index].state = .running
        jobs[index].started = date
        jobs[index].pid = pid
        jobs[index].pidStarted = pidStarted
        jobs[index].log = log
        updated = date
    }

    /// A running job's process has ended: done on a zero status, cancelled if it was asked to
    /// stop, failed otherwise. A job that never started fails with the reason it did not.
    public mutating func end(_ id: Int, status: Int32?, message: String? = nil, at date: Date) {
        guard let index = try? self.index(id), !jobs[index].isFinished else { return }
        var job = jobs[index]
        job.status = status
        job.ended = date
        if job.stopping == true {
            job.state = .cancelled
            job.message = "cancelled while it ran"
        } else if job.stopAfterStep == true, status != 0 {
            job.state = .cancelled
            job.message = "stopped after a step"
        } else if status == 0 {
            job.state = .done
        } else {
            job.state = .failed
            job.message = message ?? status.map { "exit status \($0)" } ?? "ended with no status"
        }
        job.stopping = nil
        jobs[index] = job
        prune()
        updated = date
    }

    /// A waiting job is cancelled at once; a running one is marked to be stopped by the runner.
    /// Returns the state the job is left in.
    @discardableResult
    public mutating func cancel(_ id: Int, at date: Date) throws -> QueueJob.State {
        let index = try self.index(id)
        switch jobs[index].state {
        case .waiting:
            jobs[index].state = .cancelled
            jobs[index].ended = date
            jobs[index].message = "cancelled before it started"
            prune()
        case .running:
            jobs[index].stopping = true
        case let state:
            throw Failure.finished(id, state)
        }
        updated = date
        return jobs[index].state
    }

    /// A running night ends once its current step is done.
    public mutating func stopAfterStep(_ id: Int, at date: Date) throws {
        let index = try runningNight(id)
        jobs[index].stopAfterStep = true
        updated = date
    }

    /// A running night leaves out the scene it works on and goes on with the next.
    public mutating func skip(_ id: Int, at date: Date) throws {
        let index = try runningNight(id)
        jobs[index].skips = (jobs[index].skips ?? 0) + 1
        updated = date
    }

    private func runningNight(_ id: Int) throws -> Int {
        let index = try self.index(id)
        guard jobs[index].kind == .night, jobs[index].state == .running else {
            throw Failure.notARunningNight(id)
        }
        return index
    }

    /// Puts a waiting job before every other waiting one: it starts once the running job ends.
    public mutating func moveFirst(_ id: Int, at date: Date) throws {
        let index = try self.index(id)
        guard jobs[index].state == .waiting else { throw Failure.notWaiting(id, jobs[index].state) }
        let job = jobs.remove(at: index)
        jobs.insert(job, at: jobs.firstIndex { $0.state == .waiting } ?? jobs.endIndex)
        updated = date
    }

    public mutating func pause(at date: Date) {
        paused = true
        updated = date
    }

    public mutating func resume(at date: Date) {
        paused = false
        updated = date
    }

    /// What a runner finds when it starts: a job still marked running whose process is gone
    /// was interrupted, by a crash, a kill or a restart, and fails (or is cancelled, if it was
    /// asked to stop). Returns those jobs, whose partial output is to be removed. A job whose
    /// process lives on is left running, for the runner to watch until it ends.
    public mutating func recover(at date: Date, isAlive: (QueueJob) -> Bool) -> [QueueJob] {
        var lost: [QueueJob] = []
        for index in jobs.indices where jobs[index].state == .running && !isAlive(jobs[index]) {
            let stopping = jobs[index].stopping == true
            jobs[index].state = stopping ? .cancelled : .failed
            jobs[index].ended = date
            jobs[index].message =
                stopping ? "cancelled while it ran" : "interrupted: its process ended with no runner"
            jobs[index].stopping = nil
            lost.append(jobs[index])
        }
        if !lost.isEmpty {
            prune()
            updated = date
        }
        return lost
    }

    private func index(_ id: Int) throws -> Int {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw Failure.noSuchJob(id) }
        return index
    }

    private mutating func prune() {
        let old = finished.dropFirst(Self.keptFinished).map(\.id)
        guard !old.isEmpty else { return }
        let dropped = Set(old)
        jobs.removeAll { dropped.contains($0.id) }
    }

    public func encoded() throws -> Data { try RunStatus.encoder().encode(self) }

    public static func decoded(from data: Data) throws -> JobQueue {
        try RunStatus.decoder().decode(JobQueue.self, from: data)
    }
}
