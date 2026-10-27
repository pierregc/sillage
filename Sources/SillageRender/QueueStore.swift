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

/// What the system says about a process: when it started, which tells a live process from
/// another that was given the same pid since.
public enum ProcessProbe {
    /// Nil when there is no such process, or only its zombie.
    public static func started(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
            info.kp_proc.p_stat != SZOMB
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }

    /// Whether `pid` is still the process that started at `started`; with no start to compare,
    /// a reused pid cannot be told apart, so it is not. The dates go through JSON with
    /// millisecond precision.
    public static func isAlive(pid: Int32?, started expected: Date?) -> Bool {
        guard let pid, let expected, let started = started(pid) else { return false }
        return abs(started.timeIntervalSince(expected)) < 0.01
    }
}

extension ProcessProbe {
    /// This user's processes called `name`, this one left out, each with its arguments.
    public static func others(named name: String) -> [(pid: Int32, arguments: [String])] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = table.count * stride
        guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        return table.prefix(size / stride).compactMap { info in
            let pid = info.kp_proc.p_pid
            let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard pid != me, info.kp_proc.p_stat != SZOMB, command == name else { return nil }
            return (pid, arguments(of: pid))
        }
    }

    /// A process's command line, empty when it cannot be read.
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        // argc, the executable's path, padding, then argc strings, each ended by a zero.
        let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

/// Starting processes with `posix_spawn`: no descriptor of the parent leaks into them (a runner's
/// lock held open by a child would outlive the runner), input from /dev/null, output to a log.
public enum Spawn {
    /// This process's own executable. Not `Bundle.main`, which names the app for a tool
    /// bundled inside one.
    public static var currentExecutable: URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&path, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
    }

    static let standardPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// In a session of its own: nothing that ends the parent's session or process group reaches
    /// it. Reaped on a thread of its own, so a parent that lives on keeps no zombie.
    public static func detached(_ executable: String, _ arguments: [String], log: URL) throws
        -> Int32
    {
        let pid = try spawn(executable, arguments, log: log, flags: POSIX_SPAWN_SETSID)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        return pid
    }

    /// In a process group of its own, so one signal to the group reaches every process it
    /// starts. The caller waits for it.
    public static func child(_ executable: String, _ arguments: [String], log: URL) throws -> Int32 {
        try spawn(executable, arguments, log: log, flags: POSIX_SPAWN_SETPGROUP)
    }

    /// In the caller's own process group, so whatever suspends or stops the group, the queue's
    /// pause and cancel, reaches it too. The caller waits for it.
    public static func member(_ executable: String, _ arguments: [String], log: URL) throws
        -> Int32
    {
        try spawn(executable, arguments, log: log, flags: 0)
    }

    private static func spawn(
        _ executable: String, _ arguments: [String], log: URL, flags: Int32
    ) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Signals blocked or ignored where the parent spawns from would carry over, and a job
        // that ignores SIGTERM cannot be cancelled.
        posix_spawnattr_setflags(
            &attributes,
            Int16(flags | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t(0)
        var every = ~sigset_t(0)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var environment = ProcessInfo.processInfo.environment
        // An app started from the Finder has a bare PATH, and the stages call python3 and
        // Homebrew's tools.
        let path = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        environment["PATH"] = (path + standardPath.filter { !path.contains($0) })
            .joined(separator: ":")
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: Int32 = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard code == 0 else { throw QueueStore.Failure.system("posix_spawn \(executable)", code) }
        return pid
    }
}
