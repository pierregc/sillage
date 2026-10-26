import Foundation

/// `sillage-render queue <command>`: the queue from the command line.
public enum QueueCommand {
    public static let usage = """
        usage: sillage-render queue run
               sillage-render queue add hires <scene or batch> [--particles N] [hires options]
               sillage-render queue add export <scene> --preset NAME [export options]
               sillage-render queue add explore [explore-batch.sh options]
               sillage-render queue list [--json]
               sillage-render queue cancel <id> | first <id> | pause | resume
        Each takes --library DIR, by default $SILLAGE_LIBRARY or the repository's library/;
        add hires and add export use the scene's own library.
        """

    public enum Failure: Error, CustomStringConvertible {
        case usage
        case invalid(String)

        public var description: String {
            switch self {
            case .usage: QueueCommand.usage
            case .invalid(let why): why
            }
        }
    }

    /// The library a command works on when not told.
    public static func defaultLibrary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["SILLAGE_LIBRARY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return QueueRunner.exploreScript.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("library", isDirectory: true)
    }

    /// `arguments` follow `queue`; `executable` is the `sillage-render` a runner is started from.
    public static func main(
        _ arguments: [String], executable: URL, say: @escaping (String) -> Void = { print($0) }
    ) -> Int32 {
        var arguments = arguments
        var library = defaultLibrary()
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            library = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            arguments.removeSubrange(index...index + 1)
        }
        guard let command = arguments.first else {
            say(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        let store = QueueStore(library: library)
        do {
            switch command {
            case "run":
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return QueueRunner(
                    store: store, command: QueueRunner.stages(executable: executable.path),
                    say: { say("\(stamp.string(from: Date())) \($0)") }
                )
                .run()
            case "add":
                try add(rest, library: library, executable: executable, say: say)
            case "list":
                list(store, json: rest.contains("--json"), say: say)
            case "cancel":
                let id = try number(rest)
                let state = try store.cancel(id, runner: executable)
                say("queue      job \(id) \(state == .running ? "is stopping" : "cancelled")")
            case "first":
                let id = try number(rest)
                try store.change { try $0.moveFirst(id, at: Date()) }
                say("queue      job \(id) starts next")
            case "pause":
                let running = try store.change { queue in
                    queue.pause(at: Date())
                    return queue.running
                }
                say("queue      paused" + (running.map { ", job \($0.id) suspended" } ?? ""))
            case "resume":
                let runner = try store.resume(runner: executable)
                say("queue      resumed")
                if let runner { started(runner, store, say) }
            default:
                throw Failure.usage
            }
            return 0
        } catch {
            say("\(error)")
            return 2
        }
    }

    private static func number(_ rest: [String]) throws -> Int {
        guard let text = rest.first, let id = Int(text) else { throw Failure.usage }
        return id
    }

    private static func started(_ pid: Int32, _ store: QueueStore, _ say: (String) -> Void) {
        say("runner     started, pid \(pid), log \(store.runnerLog.path)")
    }

    private static func add(
        _ rest: [String], library: URL, executable: URL, say: @escaping (String) -> Void
    ) throws {
        guard let name = rest.first, let kind = QueueJob.Kind(rawValue: name) else {
            throw Failure.usage
        }
        var jobs: [(path: String, options: [String], library: URL)] = []
        switch kind {
        case .hires:
            guard rest.count > 1 else { throw Failure.usage }
            jobs = try hiresJobs(path: rest[1], options: Array(rest.dropFirst(2)))
        case .export:
            guard rest.count > 1 else { throw Failure.usage }
            jobs = [try exportJob(path: rest[1], options: Array(rest.dropFirst(2)))]
        case .explore:
            var options = Array(rest.dropFirst())
            var out = library.appendingPathComponent(day(Date()), isDirectory: true).path
            if let index = options.firstIndex(of: "--out"), index + 1 < options.count {
                out = URL(fileURLWithPath: options[index + 1]).standardizedFileURL.path
                options.removeSubrange(index...index + 1)
            }
            jobs = [(out, options, library)]
        case .night:
            throw Failure.invalid("queue: the night command comes with #104")
        }
        for job in jobs {
            let store = QueueStore(library: job.library)
            let (added, runner) = try store.submit(
                kind, path: job.path, options: job.options, runner: executable)
            let queue = store.read()
            let ahead = queue.waiting.count - 1 + (queue.running == nil ? 0 : 1)
            say("queue      job \(added.id) added: \(added.summary), \(ahead) before it")
            if let runner { started(runner, store, say) }
        }
    }

    /// One job for a scene; for a batch, one for each scene chosen and not already done at
    /// that size, as `hires <batch>` does.
    private static func hiresJobs(path: String, options: [String]) throws -> [(
        path: String, options: [String], library: URL
    )] {
        let folder = SceneFolder(path: path)
        let maximum = SceneFolder.maximumParticles()
        if folder.isExplored {
            do {
                _ = try folder.hiresArguments(options, maximumParticles: maximum)
            } catch {
                throw Failure.invalid("hires: \(error)")
            }
            return [(folder.url.path, options, folder.library)]
        }
        let batch = folder.url
        let (asked, _) = SceneFolder.Clip().updated(with: options)
        let particles = options.contains("--particles") ? asked.particles : maximum
        let scenes = SceneFolder.chosen(inBatch: batch).filter { scene in
            guard let done = scene.storedHires() else { return true }
            return done.particles != particles
                || (options.contains("--frames") && done.frames != asked.frames)
        }
        guard !scenes.isEmpty else {
            throw Failure.invalid(
                "hires: \(path) is neither an explored scene nor a batch with scenes to run")
        }
        for scene in scenes {
            do {
                _ = try scene.hiresArguments(options, maximumParticles: maximum)
            } catch {
                throw Failure.invalid("hires: \(scene.sceneID): \(error)")
            }
        }
        return scenes.map { ($0.url.path, options, batch.deletingLastPathComponent()) }
    }

    /// Needs a take, or a hires of the scene waiting or running before it.
    private static func exportJob(path: String, options: [String]) throws -> (
        path: String, options: [String], library: URL
    ) {
        let folder = SceneFolder(path: path)
        func value(_ name: String) -> String? {
            options.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < options.count ? options[$0 + 1] : nil
            }
        }
        guard value("preset") != nil || value("format") != nil else {
            throw Failure.invalid("export: say which with --preset or --format")
        }
        if let preset = value("preset"), VideoPreset.named(preset) == nil {
            throw Failure.invalid("export: \(SceneFolder.ExportError.noSuchPreset(preset))")
        }
        if let format = value("format"), AnimatedImage.Format(rawValue: format.lowercased()) == nil {
            throw Failure.invalid("export: --format \(format) is neither webp nor gif")
        }
        let queue = QueueStore(library: folder.library).read()
        let hiresComing = queue.jobs.contains {
            $0.kind == .hires && !$0.isFinished && SceneFolder(path: $0.path) == folder
        }
        guard FileManager.default.fileExists(atPath: folder.take.path) || hiresComing else {
            throw Failure.invalid("export: \(SceneFolder.LookError.noTake(folder.url))")
        }
        return (folder.url.path, options, folder.library)
    }

    private static func list(_ store: QueueStore, json: Bool, say: (String) -> Void) {
        let queue = store.read()
        if json {
            say((try? queue.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            return
        }
        let runner = store.runner().map { "runner pid \($0.pid)" } ?? "no runner"
        say("queue      \(store.folder.path) · \(runner)\(queue.paused ? " · paused" : "")")
        let shown = queue.jobs.filter { !$0.isFinished } + queue.finished.prefix(10)
        if shown.isEmpty { say("           nothing queued") }
        for job in shown {
            var line =
                String(format: "%5d  ", job.id)
                + job.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
                + "  " + job.summary
            if job.by == .night { line += " · night \(job.night ?? "")" }
            if let started = job.started {
                line += " · \(time(started))" + (job.ended.map { " to \(time($0))" } ?? "")
            }
            if let message = job.message, job.state != .done { line += " · \(message)" }
            say(line)
        }
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
