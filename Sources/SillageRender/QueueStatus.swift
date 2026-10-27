import Foundation

/// What the Mac is doing and what is queued, in the words the app, `sillage-render status` and
/// the remote guide share. Built from the status files (#101) and the queue (#102) only, plus a
/// look at the running `sillage-render` processes so that "le Mac est libre" is never wrong.
public struct QueueStatus: Sendable, Equatable {
    public enum Outcome: String, Sendable { case running, waiting, done, failed, cancelled }

    /// One job of the queue view: the running one, a waiting one or a finished one.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        /// The queue's number for it; nil for a stage started from the command line.
        public var job: Int?
        public var outcome: Outcome
        /// "Haute résolution", "Vidéo", ...
        public var title: String
        /// The scene, or the batch, it works on.
        public var subject: String
        /// What it is doing now: "image 412/900".
        public var detail: String?
        public var progress: Double?
        /// Where it stands in time: "prêt vers 6 h 20", "début vers 6 h 20 · fin vers 7 h 05".
        public var timing: String?
        public var options: String?

        /// The row as one line.
        public var text: String {
            ([title, subject] + [detail, timing].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// What the top of the sidebar says, without the number of jobs waiting.
    public var headline: String
    /// The headline with the scene and the image it is on, for `status`:
    /// "Nuit du 25 oct. · haute résolution 2/4 · scene-0023 image 412/900 · prêt vers 6 h 20".
    public var summary: String
    public var isBusy: Bool
    public var isPaused: Bool
    /// Running with nothing written for a quarter of an hour.
    public var isStuck: Bool
    public var waitingCount: Int
    public var running: Row?
    public var waiting: [Row]
    /// The last ten, the latest first.
    public var finished: [Row]

    public static let finishedShown = 10

    /// The status line: the headline and how many jobs wait behind it.
    public var statusLine: String {
        guard waitingCount > 0 else { return headline }
        return headline + " · " + Self.waitingText(waitingCount)
    }

    /// Everything, as `sillage-render status` prints it and as the app's rows read.
    public var lines: [String] {
        var lines = [statusLine]
        if let running {
            lines.append("En cours")
            lines.append("  " + Self.numbered(running))
        }
        if !waiting.isEmpty {
            lines.append("En attente")
            lines += waiting.map { "  " + Self.numbered($0) }
        }
        if !finished.isEmpty {
            lines.append("Terminés")
            lines += finished.map { "  " + Self.numbered($0) }
        }
        return lines
    }

    private static func numbered(_ row: Row) -> String {
        row.job.map { "n° \($0) · " + row.text } ?? row.text
    }

    public static func waitingText(_ count: Int) -> String {
        count == 1 ? "1 en attente" : "\(count) en attente"
    }
}

// MARK: - Inputs

extension QueueStatus {
    /// A `sillage-render` process, as the system lists it.
    public struct ProcessInfo: Sendable, Equatable {
        public var pid: Int32
        public var arguments: [String]

        public init(pid: Int32, arguments: [String]) {
            self.pid = pid
            self.arguments = arguments
        }
    }

    /// Commands of `sillage-render` that do no heavy work: the runner waiting for a job, a status
    /// reading, an event being appended.
    static let quietCommands: Set<String> = ["queue", "status", "event", "costs", "story"]

    /// The processes among `all` that are computing something.
    public static func computing(_ all: [ProcessInfo]) -> [ProcessInfo] {
        all.filter { process in
            guard process.arguments.count > 1 else { return true }
            return !quietCommands.contains(process.arguments[1])
        }
    }

    /// Everything a reading depends on, so that a test or a command can fix any of it.
    public struct Inputs: Sendable {
        public var activity: ActivityFile?
        public var queue: JobQueue
        public var night: NightFile?
        /// The processes named `sillage-render`.
        public var processes: [ProcessInfo]
        public var now: Date
        public var timeZone: TimeZone
        /// How long a job will take, when it can be told, else nil.
        public var estimate: @Sendable (QueueJob) -> TimeInterval?
        public var isAlive: @Sendable (QueueJob) -> Bool

        public init(
            activity: ActivityFile?, queue: JobQueue, night: NightFile? = nil,
            processes: [ProcessInfo] = [], now: Date, timeZone: TimeZone = .current,
            estimate: @escaping @Sendable (QueueJob) -> TimeInterval? = { _ in nil },
            isAlive: @escaping @Sendable (QueueJob) -> Bool = { _ in true }
        ) {
            self.activity = activity
            self.queue = queue
            self.night = night
            self.processes = processes
            self.now = now
            self.timeZone = timeZone
            self.estimate = estimate
            self.isAlive = isAlive
        }
    }

    /// `running` and nothing written for this long is a stuck run (#101).
    public static let stuckAfter: TimeInterval = 15 * 60
    /// An activity file this recent is believed without a process to back it: a stage rewrites
    /// it every ten seconds, and a batch has gaps between its scenes.
    public static let freshFor: TimeInterval = 90
}

// MARK: - Reading the files

extension QueueStatus {
    /// Reads the library's files and its processes, now.
    public static func read(
        library: URL, now: Date = Date(), timeZone: TimeZone = .current,
        processes: [ProcessInfo]? = nil,
        isAlive: @escaping @Sendable (QueueJob) -> Bool = {
            ProcessProbe.isAlive(pid: $0.pid, started: $0.pidStarted)
        }
    ) -> QueueStatus {
        let store = QueueStore(library: library)
        let queue = store.read()
        let activity = ActivityFile.read(from: RunStatusFiles.activity(library: library))
        let cost = CostModel.current(library: library)
        let listed =
            processes
            ?? ProcessProbe.others(named: "sillage-render").map {
                ProcessInfo(pid: $0.pid, arguments: $0.arguments)
            }
        return QueueStatus(
            Inputs(
                activity: activity, queue: queue, night: night(of: activity, library: library),
                processes: listed, now: now, timeZone: timeZone,
                estimate: { JobEstimate.seconds($0, cost: cost) }, isAlive: isAlive))
    }

    static func night(of activity: ActivityFile?, library: URL) -> NightFile? {
        nightFolder(of: activity, library: library)?.file
    }

    /// The folder and the file of the night the activity file names.
    static func nightFolder(
        of activity: ActivityFile?, library: URL
    ) -> (batch: URL, file: NightFile)? {
        guard let night = activity?.night else { return nil }
        let batches = [activity?.job?.batch, night.id].compactMap { $0 }
        for name in batches {
            let batch = library.appendingPathComponent(name, isDirectory: true)
            if let file = NightFile.read(from: RunStatusFiles.night(batch: batch)), file.id == night.id {
                return (batch, file)
            }
        }
        return nil
    }
}

/// How long a queued job will take, from the cost model fitted on the library's runs.
public enum JobEstimate {
    public static func seconds(_ job: QueueJob, cost: CostModel) -> TimeInterval? {
        let folder = SceneFolder(path: job.path)
        switch job.kind {
        case .hires:
            let particles =
                option("--particles", in: job.options).flatMap { Double($0) }.map { Int($0) }
                ?? SceneFolder.maximumParticles()
            return try? cost.hiresSeconds(folder, particles: particles)
        case .export:
            let name = option("--preset", in: job.options) ?? "1080p"
            guard let preset = VideoPreset.all.first(where: { $0.name == name }) else { return nil }
            let codec = option("--codec", in: job.options).flatMap(VideoCodec.init(rawValue:))
            let fps = option("--fps", in: job.options).flatMap { Int($0) } ?? 30
            let frames =
                option("--duration", in: job.options).flatMap { Double($0) }.map {
                    Int($0 * Double(fps))
                } ?? (try? folder.storedClip())?.frames
            return frames.map {
                cost.exportSeconds(preset: preset, codec: codec ?? preset.defaultCodec, frames: $0)
            }
        case .explore, .night:
            return nil
        }
    }

    private static func option(_ name: String, in options: [String]) -> String? {
        guard let index = options.firstIndex(of: name), index + 1 < options.count else { return nil }
        return options[index + 1]
    }
}

// MARK: - Building

extension QueueStatus {
    public init(_ inputs: Inputs) {
        let words = Words(now: inputs.now, timeZone: inputs.timeZone)
        let queue = inputs.queue
        let activity = inputs.activity
        let age = activity.map { inputs.now.timeIntervalSince($0.updated) } ?? .infinity
        let alive = !Self.computing(inputs.processes).isEmpty

        // A job the queue says runs, whose process is gone, runs no more.
        let queued = queue.running.flatMap { inputs.isAlive($0) ? $0 : nil }
        // A stage started by hand writes only the activity file. One that wrote nothing for
        // a minute and a half, with no `sillage-render` left to write, is a file left behind.
        let believed = activity?.state != .idle && activity?.job != nil && (age < Self.freshFor || alive)
        let byHand = queued == nil && believed ? activity?.job : nil

        isPaused = queue.paused || (believed && activity?.state == .paused)
        isStuck = believed && activity?.state != .idle && age >= Self.stuckAfter
        waitingCount = queue.waiting.count

        var row: Row?
        var readyAt: Date?
        if let queued {
            let shown = activity?.job.flatMap { Self.shows($0, queued) ? $0 : nil }
            row = Row(
                id: "job-\(queued.id)", job: queued.id, outcome: .running,
                title: Self.title(queued.kind.rawValue), subject: Self.subject(queued),
                detail: Self.detail(shown?.detail ?? "starting"), progress: shown?.progress,
                timing: nil, options: Self.options(queued))
            readyAt = shown?.eta
        } else if let byHand {
            row = Row(
                id: "stage-\(byHand.kind)", job: nil, outcome: .running,
                title: Self.title(byHand.kind), subject: byHand.scene ?? byHand.batch ?? "",
                detail: Self.detail(byHand.detail), progress: byHand.progress, timing: nil,
                options: nil)
            readyAt = byHand.eta
        }
        // A night is ready when it ends, not when the job in it does.
        let nightReady = activity?.night.map { $0.eta ?? inputs.night?.estimatedEnd }
        // A paused queue ends when someone resumes it: no time to give.
        if isPaused { readyAt = nil }
        row?.timing = Self.readyText(readyAt, words)
        running = row
        isBusy = row != nil || alive

        let (paused, stuck, busy) = (isPaused, isStuck, isBusy)
        func makeHeadline(detailed: Bool) -> String {
            var text = "Calcul en cours (sans détail)"
            if let row {
                text = Self.headline(
                    row: row, activity: activity, night: inputs.night,
                    ready: paused ? nil : nightReady ?? readyAt, words: words, detailed: detailed)
            }
            if !busy {
                text = queue.paused ? "File en pause · le Mac est libre" : "Rien en cours · le Mac est libre"
            } else if paused {
                text = "En pause · " + text
            }
            if busy, stuck { text += " · semble bloqué, rien écrit depuis \(Words.duration(age))" }
            return text
        }
        self.headline = makeHeadline(detailed: false)
        summary = makeHeadline(detailed: true)

        // Where each waiting job would start and end, one after the other.
        var cursor: Date? = queue.paused ? nil : (row == nil && !alive ? inputs.now : readyAt)
        var rows: [Row] = []
        for job in queue.waiting {
            var timing: String?
            if let start = cursor {
                if let seconds = inputs.estimate(job) {
                    let end = start.addingTimeInterval(seconds)
                    timing = "début \(words.about(start)) · fin \(words.about(end))"
                    cursor = end
                } else {
                    timing = "début \(words.about(start))"
                    cursor = nil
                }
            }
            rows.append(
                Row(
                    id: "job-\(job.id)", job: job.id, outcome: .waiting,
                    title: Self.title(job.kind.rawValue), subject: Self.subject(job), detail: nil,
                    progress: nil, timing: timing, options: Self.options(job)))
        }
        waiting = rows

        finished = queue.finished.prefix(Self.finishedShown).map { job in
            Row(
                id: "job-\(job.id)", job: job.id,
                outcome: job.state == .done ? .done : job.state == .failed ? .failed : .cancelled,
                title: Self.title(job.kind.rawValue), subject: Self.subject(job), detail: nil,
                progress: nil, timing: Self.endText(job, words), options: Self.options(job))
        }
    }

    static func shows(_ shown: ActivityFile.Job, _ job: QueueJob) -> Bool {
        // A night's steps write their own job, in the night's batch.
        if job.kind == .night { return shown.batch == job.batch }
        return shown.kind == job.kind.rawValue && shown.batch == job.batch
            && (job.scene == nil || shown.scene == job.scene)
    }

    /// The glossary's words for the stages.
    static func title(_ kind: String) -> String {
        switch kind {
        case "explore": "Aperçus"
        case "hires": "Haute résolution"
        case "export": "Vidéo"
        case "look": "Style"
        case "palettes": "Palette"
        case "night": "Nuit"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    static func subject(_ job: QueueJob) -> String { job.scene ?? job.batch }

    static func options(_ job: QueueJob) -> String? {
        job.options.isEmpty ? nil : job.options.joined(separator: " ")
    }

    /// "frame 412/900" as the stages write it, in the words the app uses.
    static func detail(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text == "starting" { return "démarrage" }
        if text.hasPrefix("frame ") { return "image " + text.dropFirst("frame ".count) }
        return text
    }

    static func readyText(_ date: Date?, _ words: Words) -> String? {
        date.map { "prêt \(words.about($0))" }
    }

    static func endText(_ job: QueueJob, _ words: Words) -> String? {
        let took = job.started.flatMap { start in
            job.ended.map { Words.duration($0.timeIntervalSince(start)) }
        }
        switch job.state {
        case .done:
            let when = job.ended.map { "terminé \(words.at($0))" }
            return [when, took.map { "en \($0)" }].compactMap { $0 }.joined(separator: " ")
        case .failed:
            let when = job.ended.map { "échec \(words.at($0))" } ?? "échec"
            return [when, job.message].compactMap { $0 }.joined(separator: " · ")
        default:
            return job.ended.map { "annulé \(words.at($0))" } ?? "annulé"
        }
    }

    /// "Nuit du 26 oct. · haute résolution 2/4 · prêt vers 6 h 20", or the job alone.
    static func headline(
        row: Row, activity: ActivityFile?, night: NightFile?, ready: Date?, words: Words,
        detailed: Bool = false
    ) -> String {
        var parts: [String] = []
        if let running = activity?.night {
            parts.append("Nuit du " + (words.nightDate(night: running.id, file: night) ?? running.id))
            parts.append(Self.phase(running.phase, file: night))
            if detailed, let job = activity?.job {
                let doing = [job.scene, Self.detail(job.detail)].compactMap { $0 }
                if !doing.isEmpty { parts.append(doing.joined(separator: " ")) }
            }
        } else {
            parts += [row.title, row.subject]
            if detailed, let detail = row.detail { parts.append(detail) }
        }
        if let ready { parts.append("prêt \(words.about(ready))") }
        return parts.joined(separator: " · ")
    }

    /// "haute résolution 2/4" for the phase a night is in.
    static func phase(_ name: String, file: NightFile?) -> String {
        let label = Self.phaseLabel(name)
        guard let phase = file?.phases.first(where: { $0.name == name }), phase.planned > 0 else {
            return label
        }
        return "\(label) \(min(phase.done + 1, phase.planned))/\(phase.planned)"
    }

    static func phaseLabel(_ name: String) -> String {
        switch name {
        case "explore": "aperçus"
        case "pick": "choix"
        case "hires": "haute résolution"
        case "look", "style": "style"
        case "export": "vidéos"
        default: name
        }
    }
}

// MARK: - Words

/// Dates and durations in French, written by hand so that the same text comes out whatever the
/// machine's language.
struct Words {
    let now: Date
    let calendar: Calendar

    init(now: Date, timeZone: TimeZone) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    static let months = [
        "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.",
        "déc.",
    ]

    /// "6 h 20".
    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "26 oct.".
    func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        return "\(parts.day ?? 1) \(Self.months[(parts.month ?? 1) - 1])"
    }

    /// The moment with the day only when it is not today: "6 h 20", "demain 6 h 20",
    /// "28 oct. 6 h 20".
    func at(_ date: Date) -> String {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
            ).day ?? 0
        switch days {
        case 0: return clock(date)
        case 1: return "demain " + clock(date)
        default: return day(date) + " " + clock(date)
        }
    }

    /// "vers 6 h 20": an estimate.
    func about(_ date: Date) -> String { "vers " + at(date) }

    /// "2 h 15", "12 min", "45 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        if total >= 3600 { return String(format: "%d h %02d", total / 3600, total % 3600 / 60) }
        if total >= 60 { return "\(total / 60) min" }
        return "\(total) s"
    }

    /// "0,91", with a comma.
    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// "212,3 Mo", "3,4 Go".
    static func size(megabytes: Double) -> String {
        megabytes >= 1000
            ? decimal(megabytes / 1000, digits: 1) + " Go" : decimal(megabytes, digits: 1) + " Mo"
    }

    /// "2 000 000".
    static func thousands(_ value: Int) -> String {
        var digits = Array(String(abs(value)))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(" ", at: index)
            index -= 3
        }
        return (value < 0 ? "-" : "") + String(digits)
    }

    /// The day a night is named for, from the folder's date or its first moment.
    func nightDate(night id: String, file: NightFile?) -> String? {
        if let start = file?.startedAt { return day(start) }
        let parts = id.split(separator: "-").compactMap { Int($0) }
        if parts.count >= 3, id.count >= 10, (1...12).contains(parts[1]) {
            return "\(parts[2]) \(Self.months[parts[1] - 1])"
        }
        return nil
    }
}
