import Foundation

/// `sillage-render queue run`: takes the queue's jobs one at a time, each in a process of its
/// own, and exits once nothing is left to start. One runner per queue, held by `RunnerLock`. It
/// keeps the Mac awake while it works, suspends the running job while the queue is paused and
/// stops it when it is cancelled.
public final class QueueRunner: @unchecked Sendable {
    /// The command line a job runs, its executable first.
    public typealias Command = (QueueJob) -> [String]

    public let store: QueueStore
    private let command: Command
    private let poll: TimeInterval
    private let say: (String) -> Void
    /// After SIGTERM, how long a job has to end before SIGKILL.
    private let grace: TimeInterval
    /// What else holds the GPU, by pid.
    private let busy: () -> [Int32]
    private let notify: (Notice) -> Void
    private var activity: NSObjectProtocol?
    private let startedAt = Date()
    /// How far each batch's events.jsonl has been read, for the phases and ends of nights.
    private var eventOffsets: [URL: UInt64] = [:]
    /// Jobs asked for by hand that ended well in this run.
    private var handJobsDone = 0

    public init(
        store: QueueStore, command: @escaping Command, poll: TimeInterval = 0.5,
        grace: TimeInterval = 10, busy: @escaping () -> [Int32] = QueueRunner.otherRenderers,
        notify: ((Notice) -> Void)? = nil, say: @escaping (String) -> Void = { print($0) }
    ) {
        self.store = store
        self.notify = notify ?? { Notifier.post($0, store: store) }
        self.command = command
        self.poll = poll
        self.grace = grace
        self.busy = busy
        self.say = say
    }

    /// A `sillage-render` started by hand, or by another queue, renders on the same GPU. Runners
    /// and the queue's other commands do not count: two runners waiting on each other would
    /// wait forever.
    public static func otherRenderers() -> [Int32] {
        ProcessProbe.others(named: "sillage-render")
            .filter { $0.arguments.dropFirst().first != "queue" }
            .map(\.pid)
    }

    /// The command lines of the stages, run by `executable`, the `sillage-render` running this.
    public static func stages(executable: String) -> Command {
        { job in
            switch job.kind {
            case .hires, .export: [executable, job.kind.rawValue, job.path] + job.options
            case .night: [executable, "night"] + job.options + ["--out", job.path]
            case .explore:
                ["/bin/bash", exploreScript.path, "--no-build", "--out", job.path] + job.options
            }
        }
    }

    static var exploreScript: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/explore-batch.sh")
    }

    private enum Step {
        case watch(QueueJob, child: Bool)
        case notStarted(Int)
        case stop
    }

    /// 0 once the queue is empty, or at once when another runner holds the queue.
    public func run() -> Int32 {
        let lock: RunnerLock
        do {
            guard let held = try RunnerLock.acquire(store) else {
                say("runner     another runner is at work on \(store.folder.path)")
                return 0
            }
            lock = held
        } catch {
            say("runner     \(error)")
            return 1
        }
        say("runner     pid \(getpid()), \(store.folder.path)")
        hold(true)
        defer { hold(false) }

        do {
            let lost = try store.change { queue in
                queue.recover(at: Date()) {
                    ProcessProbe.isAlive(pid: $0.pid, started: $0.pidStarted)
                }
            }
            for job in lost { wrapUp(job) }

            var waited: [Int32] = []
            while true {
                let others = store.read().next == nil ? [] : busy()
                if !others.isEmpty {
                    if others != waited {
                        let pids = others.map(String.init).joined(separator: ", ")
                        say("runner     waiting for the GPU, held by sillage-render \(pids)")
                    }
                    waited = others
                    Thread.sleep(forTimeInterval: poll * 10)
                    continue
                }
                waited = []
                let step: Step = try store.change { queue in
                    if let running = queue.running { return .watch(running, child: false) }
                    guard let job = queue.next else {
                        // Under the queue's lock: a job added after this starts a new runner.
                        lock.release()
                        return .stop
                    }
                    let log = store.log(for: job.id)
                    let line = command(job)
                    do {
                        let pid = try Spawn.child(line[0], Array(line.dropFirst()), log: log)
                        try queue.start(
                            job.id, pid: pid, pidStarted: ProcessProbe.started(pid), log: log.path,
                            at: Date())
                        return .watch(queue.job(job.id) ?? job, child: true)
                    } catch {
                        queue.end(job.id, status: nil, message: "did not start: \(error)", at: Date())
                        return .notStarted(job.id)
                    }
                }
                switch step {
                case .stop:
                    let queue = store.read()
                    store.publish(queue)
                    if !queue.paused, handJobsDone > 0 {
                        notify(Notices.queueEmpty(finished: handJobsDone))
                    }
                    say("runner     \(queue.paused ? "the queue is paused" : "the queue is empty")")
                    return 0
                case .notStarted(let id):
                    if let failed = store.read().job(id) { wrapUp(failed) }
                case .watch(let job, let child):
                    store.publish(store.read())
                    say("job \(job.id)      \(job.summary) started, pid \(job.pid ?? 0)")
                    let ended = watch(job, child: child)
                    try store.change {
                        $0.end(job.id, status: ended.status, message: ended.message, at: Date())
                    }
                    if let finished = store.read().job(job.id) { wrapUp(finished) }
                }
            }
        } catch {
            say("runner     \(error)")
            return 1
        }
    }

    /// Follows a job until its process ends, suspending, resuming and stopping it as the queue
    /// asks. A job left by a runner that died is not this one's child: it is watched by pid.
    private func watch(_ job: QueueJob, child: Bool) -> (status: Int32?, message: String?) {
        guard let pid = job.pid, pid > 0 else { return (nil, "no process") }
        var suspended = false
        var stopAsked: Date?
        while true {
            if child {
                var raw: Int32 = 0
                if waitpid(pid, &raw, WNOHANG) == pid {
                    if suspended { hold(true) }
                    let signal = raw & 0x7f
                    let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
                    let why = signal == 0 ? "exit status \(status)" : "ended by signal \(signal)"
                    return (status, [why, lastLine(of: job)].compactMap { $0 }.joined(separator: ": "))
                }
            } else if !ProcessProbe.isAlive(pid: pid, started: job.pidStarted) {
                if suspended { hold(true) }
                return (nil, "ended while no runner watched it")
            }
            drainEvents(of: job.batchURL)
            let queue = store.read()
            if stopAsked == nil, queue.job(job.id)?.stopping == true {
                say("job \(job.id)      stopping")
                killpg(pid, SIGTERM)
                killpg(pid, SIGCONT)
                stopAsked = Date()
            } else if let stopAsked, Date().timeIntervalSince(stopAsked) > grace {
                killpg(pid, SIGKILL)
            } else if stopAsked == nil, queue.paused != suspended {
                suspended = queue.paused
                killpg(pid, suspended ? SIGSTOP : SIGCONT)
                say("job \(job.id)      \(suspended ? "suspended" : "resumed")")
                // A paused queue keeps the Mac awake no longer.
                hold(!suspended)
                store.publish(queue)
            }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    /// After a job has ended: the partial output of an unfinished job removed, its failure put
    /// in the batch's events, `activity.json` caught up.
    private func wrapUp(_ job: QueueJob) {
        drainEvents(of: job.batchURL)
        if job.state == .failed { notify(Notices.failed(job)) }
        if job.state == .done, job.by == .hand { handJobsDone += 1 }
        if job.state != .done {
            let removed =
                job.isScene
                ? SceneFolder(path: job.path).removePartialOutputs()
                : SceneFolder.removePartialOutputs(inBatch: job.batchURL)
            if let out = job.options.firstIndex(of: "--out").map({ $0 + 1 }), out < job.options.count {
                try? FileManager.default.removeItem(
                    at: SceneFolder.partial(URL(fileURLWithPath: job.options[out])))
            }
            for url in removed { say("job \(job.id)      removed \(url.path)") }
        }
        if job.state == .failed {
            var event = RunEvent(RunEvent.Kind.error, scene: job.scene)
            event.stage = job.kind.rawValue
            event.message = job.message
            event.log = job.log
            try? RunStatusFiles.append(event, to: RunStatusFiles.events(batch: job.batchURL))
        }
        store.publish(store.read(), ended: job)
        say("job \(job.id)      \(job.state.rawValue)\(job.message.map { ": \($0)" } ?? "")")
    }

    /// Tells of the phases and the end of a night, as its stages write them in the batch's
    /// events, when they are new: events older than this runner were told by an earlier one.
    private func drainEvents(of batch: URL) {
        let url = RunStatusFiles.events(batch: batch)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let offset = eventOffsets[url] ?? 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
            let end = data.lastIndex(of: 0x0A)
        else { return }
        eventOffsets[url] = offset + UInt64(end + 1)
        let events = RunEvent.decodeLines(String(decoding: data[...end], as: UTF8.self))
        let all = offset == 0 ? events : nil
        for event in events where event.t >= startedAt.addingTimeInterval(-1) {
            switch event.kind {
            case RunEvent.Kind.phaseDone: notify(Notices.phaseDone(event))
            case RunEvent.Kind.nightDone:
                let history =
                    all
                    ?? RunEvent.decodeLines(
                        (try? String(contentsOf: url, encoding: .utf8)) ?? "")
                notify(Notices.nightDone(event, events: history))
            default: break
            }
        }
    }

    /// The last line the job wrote, which is usually why it failed.
    private func lastLine(of job: QueueJob) -> String? {
        guard let log = job.log, let text = try? String(contentsOfFile: log, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n").last.map { String($0.prefix(300)) }
    }

    /// The assertion that keeps the Mac from idle sleep and the runner from App Nap, whatever
    /// the display does.
    private func hold(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "sillage runs its queue")
        } else if !on, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
