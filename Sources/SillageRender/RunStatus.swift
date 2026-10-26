import Foundation

/// What is running, in three small files any reader can parse: `library/activity.json` is the
/// state now, `<batch>/night.json` the plan of a night and `<batch>/events.jsonl` what happened,
/// one line each. Every long stage writes them through `StageReporter`.
public enum RunStatus {
    public static let version = 1

    /// ISO 8601 with the local offset and milliseconds, as `2026-10-26T20:02:56.250+02:00`.
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(text)"))
            }
            return date
        }
        return decoder
    }

    /// The moment a run will end if it goes on at the pace it has had: `progress` of the work
    /// took `elapsed`. Nil until some of it is done.
    public static func eta(elapsed: TimeInterval, progress: Double, now: Date) -> Date? {
        guard progress > 0, progress.isFinite, elapsed >= 0 else { return nil }
        let share = min(progress, 1)
        return now.addingTimeInterval(elapsed * (1 - share) / share)
    }
}

/// `library/activity.json`: one job at a time, whichever wrote last when several run at once.
public struct ActivityFile: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case idle, running, paused }

    public struct Job: Codable, Sendable, Equatable {
        /// The stage: explore, hires, look or export.
        public var kind: String
        public var batch: String?
        public var scene: String?
        public var startedAt: Date
        /// From 0 to 1.
        public var progress: Double
        /// Such as "frame 412/900".
        public var detail: String?
        public var eta: Date?

        public init(
            kind: String, batch: String? = nil, scene: String? = nil, startedAt: Date,
            progress: Double = 0, detail: String? = nil, eta: Date? = nil
        ) {
            self.kind = kind
            self.batch = batch
            self.scene = scene
            self.startedAt = startedAt
            self.progress = progress
            self.detail = detail
            self.eta = eta
        }

        /// The same job, whatever it has done since.
        func isSame(as other: Job) -> Bool {
            kind == other.kind && batch == other.batch && scene == other.scene
        }
    }

    public struct Night: Codable, Sendable, Equatable {
        public var id: String
        public var phase: String
        public var eta: Date?

        public init(id: String, phase: String, eta: Date? = nil) {
            self.id = id
            self.phase = phase
            self.eta = eta
        }
    }

    public var version = RunStatus.version
    public var state: State
    public var job: Job?
    public var night: Night?
    /// Jobs queued behind the current one.
    public var waiting = 0
    public var updated: Date

    public init(
        state: State, job: Job? = nil, night: Night? = nil, waiting: Int = 0, updated: Date
    ) {
        self.state = state
        self.job = job
        self.night = night
        self.waiting = waiting
        self.updated = updated
    }

    public func encoded() throws -> Data { try RunStatus.encoder().encode(self) }

    public static func read(from url: URL) -> ActivityFile? {
        (try? Data(contentsOf: url)).flatMap { try? RunStatus.decoder().decode(Self.self, from: $0) }
    }
}

/// `<batch>/night.json`: what a night set out to do and how far it has got.
public struct NightFile: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, paused, done, failed, stopped }

    public struct Phase: Codable, Sendable, Equatable {
        public var name: String
        public var planned: Int
        public var done = 0
        public var failed = 0

        public init(name: String, planned: Int, done: Int = 0, failed: Int = 0) {
            self.name = name
            self.planned = planned
            self.done = done
            self.failed = failed
        }
    }

    public var version = RunStatus.version
    public var id: String
    /// The settings the night was started with.
    public var recipe: [String: String]
    /// In order, each with its count: the plan and where it stands.
    public var phases: [Phase]
    public var state: State
    public var startedAt: Date
    public var estimatedEnd: Date?
    public var endedAt: Date?

    public init(
        id: String, recipe: [String: String] = [:], phases: [Phase], state: State = .running,
        startedAt: Date, estimatedEnd: Date? = nil, endedAt: Date? = nil
    ) {
        self.id = id
        self.recipe = recipe
        self.phases = phases
        self.state = state
        self.startedAt = startedAt
        self.estimatedEnd = estimatedEnd
        self.endedAt = endedAt
    }

    public func encoded() throws -> Data { try RunStatus.encoder().encode(self) }

    public static func read(from url: URL) -> NightFile? {
        (try? Data(contentsOf: url)).flatMap { try? RunStatus.decoder().decode(Self.self, from: $0) }
    }
}

/// One line of `<batch>/events.jsonl`. The fields a kind has are set, the others left out.
public struct RunEvent: Codable, Sendable, Equatable {
    public enum Kind {
        public static let nightStart = "night.start"
        public static let exploreScene = "explore.scene"
        public static let pick = "pick"
        public static let hiresStart = "hires.start"
        public static let hiresDone = "hires.done"
        public static let exportDone = "export.done"
        public static let error = "error"
        public static let phaseDone = "phase.done"
        public static let nightDone = "night.done"
    }

    public var t: Date
    public var kind: String
    public var scene: String?
    /// explore.scene: ok, rejected or failed.
    public var status: String?
    public var score: Double?
    public var seconds: Double?
    /// hires.start and hires.done.
    public var particles: Int?
    public var steps: Int?
    public var minutes: Double?
    public var takeGB: Double?
    /// export.done.
    public var preset: String?
    public var style: String?
    public var codec: String?
    public var frames: Int?
    public var megabytes: Double?
    public var path: String?
    /// error.
    public var stage: String?
    public var message: String?
    public var log: String?
    /// pick.
    public var chosen: Bool?
    public var rating: Int?
    /// night.start, phase.done and night.done.
    public var night: String?
    public var phase: String?
    public var count: Int?

    public init(_ kind: String, scene: String? = nil, at t: Date = Date()) {
        self.t = t
        self.kind = kind
        self.scene = scene
    }

    /// Takes `--name value` pairs from a command line, as `sillage-render event` is given them.
    /// A name no event has is an error rather than a field quietly dropped.
    public init(_ kind: String, options: [String], at t: Date = Date()) throws {
        self.init(kind, at: t)
        var index = 0
        while index < options.count {
            let name = options[index]
            guard name.hasPrefix("--"), index + 1 < options.count else {
                throw FieldError.malformed(name)
            }
            let value = options[index + 1]
            index += 2
            func number() throws -> Double {
                guard let parsed = Double(value) else { throw FieldError.notANumber(name, value) }
                return parsed
            }
            switch String(name.dropFirst(2)) {
            case "scene": scene = value
            case "status": status = value
            case "score": score = try number()
            case "seconds": seconds = try number()
            case "particles": particles = Int(try number())
            case "steps": steps = Int(try number())
            case "minutes": minutes = try number()
            case "take-gb": takeGB = try number()
            case "preset": preset = value
            case "style": style = value
            case "codec": codec = value
            case "frames": frames = Int(try number())
            case "megabytes": megabytes = try number()
            case "path": path = value
            case "stage": stage = value
            case "message": message = value
            case "log": log = value
            case "chosen": chosen = ["true", "yes", "1"].contains(value)
            case "rating": rating = Int(try number())
            case "night": night = value
            case "phase": phase = value
            case "count": count = Int(try number())
            default: throw FieldError.unknown(name)
            }
        }
    }

    public enum FieldError: Error, CustomStringConvertible {
        case malformed(String)
        case unknown(String)
        case notANumber(String, String)

        public var description: String {
            switch self {
            case .malformed(let name): "\(name): expected --name value"
            case .unknown(let name): "\(name) is not a field of an event"
            case .notANumber(let name, let value): "\(name) \(value) is not a number"
            }
        }
    }

    /// The events of a file's text, in order. A line that does not decode is skipped: a reader
    /// should not lose a night to one bad line.
    public static func decodeLines(_ text: String) -> [RunEvent] {
        let decoder = RunStatus.decoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(RunEvent.self, from: Data($0.utf8))
        }
    }
}

/// Where the status files are, and how they are written.
public enum RunStatusFiles {
    public static func activity(library: URL) -> URL {
        library.appendingPathComponent("activity.json")
    }

    public static func night(batch: URL) -> URL { batch.appendingPathComponent("night.json") }

    public static func events(batch: URL) -> URL { batch.appendingPathComponent("events.jsonl") }

    /// A temporary file in the same folder, renamed over the old one: a reader sees the old
    /// file or the new, never half of one.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// One line in one `write` on a file opened for appending, so lines from scenes finishing
    /// together, or from several processes, follow each other and never mix.
    public static func append(_ event: RunEvent, to url: URL) throws {
        var line = try RunStatus.encoder(pretty: false).encode(event)
        line.append(0x0A)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension SceneFolder {
    /// The folder holding the batches, where `activity.json` lives.
    public var library: URL { batch.deletingLastPathComponent() }

    /// The scene's name without the dot a batch hides it under while it explores.
    public var sceneName: String {
        let name = url.lastPathComponent
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }
}

/// What a stage tells the world while it runs: `activity.json` rewritten with its progress no
/// more than every ten seconds, so a file left alone for a quarter of an hour while it says
/// running is a stuck run, and the events it ends with.
public final class StageReporter: @unchecked Sendable {
    public static let interval: TimeInterval = 10

    public let stage: String
    private let activityURL: URL
    private let eventsURL: URL
    private var job: ActivityFile.Job
    private let clock: () -> Date
    private var lastWrite: Date?
    private let lock = NSLock()

    public init(
        stage: String, folder: SceneFolder, clock: @escaping () -> Date = { Date() }
    ) {
        self.stage = stage
        activityURL = RunStatusFiles.activity(library: folder.library)
        eventsURL = RunStatusFiles.events(batch: folder.batch)
        self.clock = clock
        job = ActivityFile.Job(
            kind: stage, batch: folder.batch.lastPathComponent, scene: folder.sceneName,
            startedAt: clock())
    }

    /// The job is running, at the start of its work.
    public func start(detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        job.detail = detail
        write()
    }

    /// `eta` is the caller's own when it knows better than the pace so far, as `hires` does by
    /// counting a settle step apart from a frame; otherwise it follows from the progress.
    public func update(progress: Double, detail: String? = nil, eta: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if let lastWrite, now.timeIntervalSince(lastWrite) < Self.interval { return }
        job.progress = min(max(progress, 0), 1)
        job.detail = detail
        job.eta =
            eta
            ?? RunStatus.eta(
                elapsed: now.timeIntervalSince(job.startedAt), progress: job.progress, now: now)
        write()
    }

    /// Leaves the file idle, unless another job has written its own over this one meanwhile:
    /// scenes explored side by side share it.
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let current = ActivityFile.read(from: activityURL), let other = current.job,
            other.isSame(as: job)
        else { return }
        var idle = current
        idle.state = .idle
        idle.job = nil
        idle.updated = clock()
        if let data = try? idle.encoded() { try? RunStatusFiles.write(data, to: activityURL) }
    }

    public func record(_ event: RunEvent) {
        var event = event
        if event.scene == nil { event.scene = job.scene }
        try? RunStatusFiles.append(event, to: eventsURL)
    }

    /// The night, its queue and the state of a pause belong to whoever runs them; a stage
    /// rewrites only its own job.
    private func write() {
        let now = clock()
        let current = ActivityFile.read(from: activityURL)
        let file = ActivityFile(
            state: .running, job: job, night: current?.night, waiting: current?.waiting ?? 0,
            updated: now)
        if let data = try? file.encoded() { try? RunStatusFiles.write(data, to: activityURL) }
        lastWrite = now
    }
}
