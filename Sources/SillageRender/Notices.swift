import Foundation

/// What the runner tells the person at the Mac: a title and a line, with the words of the app
/// (High resolution, Videos, Queue).
public struct Notice: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(_ title: String, _ body: String) {
        self.title = title
        self.body = body
    }
}

public enum Notices {
    /// A stage as the app names it.
    public static func stage(_ name: String) -> String {
        switch name {
        case "explore", "exploration": "Previews"
        case "hires": "High resolution"
        case "look", "style": "Style"
        case "export": "Videos"
        case "night": "Night"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// `Night of 25 Oct` from a night named by its date, `Night` when it has no name.
    public static func night(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Night" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(name.prefix(10))) else { return "Night of \(name)" }
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_US_POSIX")
        writer.dateFormat = "d MMM"
        return "Night of \(writer.string(from: date))"
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// A phase of a night is over.
    public static func phaseDone(_ event: RunEvent) -> Notice {
        var body = "\(stage(event.phase ?? "")): done"
        if let n = event.count { body += " · \(count(n, "scene", "scenes"))" }
        return Notice(night(event.night), body)
    }

    /// The night is over: what it did, from the events of its batch.
    public static func nightDone(_ event: RunEvent, events: [RunEvent]) -> Notice {
        Notice("\(night(event.night)) finished", summary(events))
    }

    public static func summary(_ events: [RunEvent]) -> String {
        let explored = events.filter { $0.kind == RunEvent.Kind.exploreScene && $0.status == "ok" }
        let hires = events.filter { $0.kind == RunEvent.Kind.hiresDone }
        let videos = events.filter { $0.kind == RunEvent.Kind.exportDone }
        let errors = events.filter { $0.kind == RunEvent.Kind.error }
        return [
            count(explored.count, "scene explored", "scenes explored"),
            "\(hires.count) in high resolution",
            count(videos.count, "video", "videos"),
            errors.isEmpty ? "no errors" : count(errors.count, "error", "errors"),
        ].joined(separator: " · ")
    }

    /// A job failed: the stage, the scene and why.
    public static func failed(_ job: QueueJob) -> Notice {
        let what = job.scene ?? job.batch
        return Notice("Failed · \(stage(job.kind.rawValue))", "\(what): \(job.message ?? "stopped")")
    }

    /// The queue is empty after jobs asked for by hand.
    public static func queueEmpty(finished: Int) -> Notice {
        Notice("Queue empty", "\(count(finished, "job finished", "jobs finished"))")
    }

    /// The status line of the menu bar item: what runs, on which scene, how far.
    public static func statusLine(_ activity: ActivityFile) -> String {
        guard activity.state != .idle, let job = activity.job else { return "Nothing running" }
        let parts = [
            stage(job.kind), job.scene ?? job.batch, job.detail,
            activity.state == .paused ? "paused" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// `library/.queue/settings.json`, written by the app and read by the runner each time it has
/// something to say, so a change made during a night counts at once.
public struct QueueSettings: Codable, Sendable, Equatable {
    public var notifications = true

    public init(notifications: Bool = true) { self.notifications = notifications }

    public static func file(in store: QueueStore) -> URL {
        store.folder.appendingPathComponent("settings.json")
    }

    public static func read(_ store: QueueStore) -> QueueSettings {
        (try? Data(contentsOf: file(in: store))).flatMap {
            try? JSONDecoder().decode(QueueSettings.self, from: $0)
        } ?? QueueSettings()
    }

    public func write(_ store: QueueStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RunStatusFiles.write(try encoder.encode(self), to: Self.file(in: store))
    }
}

/// Posts a notice on the Mac. The runner is a command line process without a bundle, which
/// `UNUserNotificationCenter` refuses, so the notice goes through `osascript`.
public enum Notifier {
    /// When set, notices are appended to this file instead of shown: for checks and tests.
    public static let logVariable = "SILLAGE_NOTICE_LOG"

    /// Shows `notice` unless the library's settings have notifications off.
    public static func post(_ notice: Notice, store: QueueStore) {
        guard QueueSettings.read(store).notifications else { return }
        if let log = ProcessInfo.processInfo.environment[logVariable] {
            let line = "\(notice.title)\t\(notice.body)\n"
            if let handle = FileHandle(forWritingAtPath: log) ?? create(log) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script(notice)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func create(_ path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    /// The AppleScript, with the text quoted so that nothing in it is code.
    static func script(_ notice: Notice) -> String {
        func quoted(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            return "\"\(escaped)\""
        }
        return "display notification \(quoted(notice.body)) with title \(quoted(notice.title))"
    }
}
