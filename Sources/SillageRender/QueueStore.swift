import Foundation

/// A library's queue on disk, `library/.queue/`: `queue.json`, the jobs' logs, the runner's log
/// and its lock. Everyone who changes the queue, the app, the command line or the runner, does
/// it under one lock, so none loses another's change; readers just read, the file being
/// replaced whole.
public struct QueueStore: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(URL)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .unreadable(let url): "\(url.path) does not decode; move it aside to start afresh"
            case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    public let library: URL

    public init(library: URL) { self.library = library.standardizedFileURL }

    public var folder: URL { library.appendingPathComponent(".queue", isDirectory: true) }
    public var file: URL { folder.appendingPathComponent("queue.json") }
    public var runnerLog: URL { folder.appendingPathComponent("runner.log") }
    var lockFile: URL { folder.appendingPathComponent("lock") }
    var runnerFile: URL { folder.appendingPathComponent("runner.json") }

    public func log(for id: Int) -> URL {
        folder.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("job-\(id).log")
    }

    /// The queue as it is now, empty when there is none yet or it cannot be read.
    public func read() -> JobQueue {
        (try? Data(contentsOf: file)).flatMap { try? JobQueue.decoded(from: $0) } ?? JobQueue()
    }

    /// Reads, changes and rewrites the queue, holding the lock throughout. A file that does not
    /// decode stops here rather than being replaced by an empty queue.
    @discardableResult
    public func change<T>(_ body: (inout JobQueue) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure.system("open \(lockFile.path)", errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.system("flock", errno) }
        }
        var queue = JobQueue()
        if let data = try? Data(contentsOf: file) {
            guard let decoded = try? JobQueue.decoded(from: data) else {
                throw Failure.unreadable(file)
            }
            queue = decoded
        }
        let before = queue
        let result = try body(&queue)
        if queue != before { try RunStatusFiles.write(queue.encoded(), to: file) }
        return result
    }

    /// The runner at work on this queue, if one is.
    public func runner() -> RunnerLock.Record? {
        guard let data = try? Data(contentsOf: runnerFile),
            let record = try? RunStatus.decoder().decode(RunnerLock.Record.self, from: data),
            ProcessProbe.isAlive(pid: record.pid, started: record.started)
        else { return nil }
        return record
    }

    /// Adds a job, and starts a runner when none is at work and the queue is not paused. The
    /// check is made under the queue's lock, where a runner also decides to stop, so a job is
    /// never left with no runner to take it. Returns the job and the pid of a runner started.
    public func submit(
        _ kind: QueueJob.Kind, path: String, options: [String] = [], by: QueueJob.Origin = .hand,
        night: String? = nil, runner executable: URL?, at date: Date = Date()
    ) throws -> (job: QueueJob, runner: Int32?) {
        let (job, wanted) = try change { queue in
            let job = queue.add(kind, path: path, options: options, by: by, night: night, at: date)
            return (job, !queue.paused && runner() == nil)
        }
        publish(read())
        guard wanted, let executable else { return (job, nil) }
        return (job, try launchRunner(executable))
    }

    /// A waiting job is cancelled at once; a running one is stopped by the runner, started
    /// here if none is at work to do it.
    @discardableResult
    public func cancel(_ id: Int, runner executable: URL?, at date: Date = Date()) throws
        -> QueueJob.State
    {
        let (state, wanted) = try change { queue in
            let state = try queue.cancel(id, at: date)
            return (state, state == .running && runner() == nil)
        }
        publish(read())
        if wanted, let executable { try launchRunner(executable) }
        return state
    }

    /// Lets the queue go on, starting a runner if there is work and none is at it.
    @discardableResult
    public func resume(runner executable: URL?, at date: Date = Date()) throws -> Int32? {
        let wanted = try change { queue in
            queue.resume(at: date)
            return (queue.running != nil || !queue.waiting.isEmpty) && runner() == nil
        }
        guard wanted, let executable else { return nil }
        return try launchRunner(executable)
    }

    /// Starts `queue run` in a session of its own, so it outlives whoever started it.
    @discardableResult
    public func launchRunner(_ executable: URL) throws -> Int32 {
        try Spawn.detached(
            executable.path, ["queue", "run", "--library", library.path], log: runnerLog)
    }

    /// Brings `activity.json` in line with the queue: the job it runs, whether it is suspended,
    /// how many wait. A stage running a queue job rewrites its own progress over this; `ended`
    /// clears the job a stage that died could not.
    public func publish(_ queue: JobQueue, ended: QueueJob? = nil, at date: Date = Date()) {
        let url = RunStatusFiles.activity(library: library)
        var activity = ActivityFile.read(from: url) ?? ActivityFile(state: .idle, updated: date)
        func shows(_ job: QueueJob) -> Bool {
            guard let shown = activity.job else { return false }
            return shown.kind == job.kind.rawValue && shown.batch == job.batch
                && (job.scene == nil || shown.scene == job.scene)
        }
        activity.waiting = queue.waiting.count
        if let running = queue.running {
            if !shows(running) {
                activity.job = ActivityFile.Job(
                    kind: running.kind.rawValue, batch: running.batch, scene: running.scene,
                    startedAt: running.started ?? date, detail: "starting")
            }
            activity.state = queue.paused ? .paused : .running
        } else if let ended, shows(ended) {
            activity.state = .idle
            activity.job = nil
        }
        activity.updated = date
        if let data = try? activity.encoded() { try? RunStatusFiles.write(data, to: url) }
    }
}

/// The lock that makes a runner the only one: held with `flock` for the runner's life, and
/// released by the system if the runner dies, so it never goes stale. Its file says which
/// process holds it, for anyone who needs to know whether a runner is at work.
public final class RunnerLock: @unchecked Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public var pid: Int32
        public var started: Date?
    }

    private var descriptor: Int32
    private let url: URL

    /// Nil when another runner holds it.
    public static func acquire(_ store: QueueStore) throws -> RunnerLock? {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let url = store.runnerFile
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw QueueStore.Failure.system("open \(url.path)", errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let me = getpid()
        let record = Record(pid: me, started: ProcessProbe.started(me))
        let data = try RunStatus.encoder(pretty: false).encode(record)
        ftruncate(descriptor, 0)
        _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return RunnerLock(descriptor: descriptor, url: url)
    }

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    /// Clears the record and lets go. Called under the queue's lock when the runner finds
    /// nothing left to do, so a job added a moment later starts a new runner.
    public func release() {
        guard descriptor >= 0 else { return }
        ftruncate(descriptor, 0)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
