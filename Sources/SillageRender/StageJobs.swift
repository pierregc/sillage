import Foundation

/// A card of the export sheet: a video preset, or an animated preview.
public enum ExportChoice: String, CaseIterable, Sendable, Identifiable {
    case hd = "1080p"
    case uhd = "4k"
    case vertical
    case square
    case whatsapp
    case webp
    case gif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hd: "1080p"
        case .uhd: "4K"
        case .vertical: "Vertical"
        case .square: "Carré"
        case .whatsapp: "WhatsApp"
        case .webp: "Aperçu animé WebP"
        case .gif: "GIF"
        }
    }

    public var detail: String {
        switch self {
        case .hd: "1920 × 1080"
        case .uhd: "3840 × 2160"
        case .vertical: "Shorts, Reels · 1080 × 1920"
        case .square: "1080 × 1080"
        case .whatsapp: "Moins de 15 Mo, avec sa légende"
        case .webp, .gif: "960 px, 8 s en boucle"
        }
    }

    public var preset: VideoPreset? { VideoPreset.named(rawValue) }
    public var format: AnimatedImage.Format? { AnimatedImage.Format(rawValue: rawValue) }

    /// WhatsApp keeps H.264 and the animations are no video: Avancé's codec leaves them alone.
    public var takesCodec: Bool { preset.map { $0.codec == nil } ?? false }
}

/// A look a scene can be exported with besides its own: one of `looks/`, or the raw one.
public struct StageLook: Sendable, Equatable, Hashable {
    public static let rawName = "raw"

    public var name: String
    public var file: URL

    public init(name: String, file: URL) {
        self.name = name
        self.file = file
    }
}

/// Avancé: what every ticked card shares. Absent, the stage's own default.
public struct ExportSettings: Sendable, Equatable {
    public var codec: VideoCodec = .hevc
    public var start: Double?
    public var duration: Double?
    public var framesPerSecond: Int?
    public var look: StageLook?

    public init() {}

    /// Nothing but the codec set: such an export takes its file back once the take is redone.
    var isPlain: Bool { start == nil && duration == nil && framesPerSecond == nil && look == nil }
}

/// One job the page or a collection is about to queue, with what it costs.
public struct PlannedJob: Sendable, Equatable, Identifiable {
    public var kind: QueueJob.Kind
    public var folder: SceneFolder
    public var options: [String]
    /// The card or the size: "4K", "5 M".
    public var title: String
    public var seconds: Double?
    /// Where an export lands, and whether it writes over a file already there.
    public var output: URL?
    public var replaces = false
    /// The same is already waiting or running, and is not added twice.
    public var queued = false

    public var id: String { ([folder.url.path, kind.rawValue] + options).joined(separator: " ") }
    public var path: String { folder.url.path }
}

/// What a scene's `exports/` holds, read once for every card of a sheet.
public struct ExportFolderState: Sendable, Equatable {
    /// File name to modification date.
    public var files: [String: Date]
    /// When the scene's look last changed.
    public var lookChanged: Date?

    public init(files: [String: Date] = [:], lookChanged: Date? = nil) {
        self.files = files
        self.lookChanged = lookChanged
    }

    public static func read(_ folder: SceneFolder) -> ExportFolderState {
        let manager = FileManager.default
        func date(_ path: String) -> Date? {
            (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        let names = (try? manager.contentsOfDirectory(atPath: folder.exports.path)) ?? []
        var files: [String: Date] = [:]
        for name in names where !name.hasPrefix(".") {
            files[name] = date(folder.exports.appendingPathComponent(name).path)
        }
        return ExportFolderState(files: files, lookChanged: date(folder.look.path))
    }
}

/// The jobs the scene page and the collections put in the queue, from a size or a ticked card.
/// Redoing a stage never touches another: an export in another format, with another style or
/// another range writes a file of its own; the same export after a new take replaces its file.
public enum StageJobs {
    /// The sizes the menu offers besides Auto.
    public static let hiresSizes = [1_000_000, 2_000_000, 5_000_000, 10_000_000]
    /// Auto looks between the smallest size and the machine's maximum by this much.
    public static let autoStep = 500_000

    public static func hires(
        _ folder: SceneFolder, particles: Int, cost: CostModel, queue: JobQueue
    ) -> PlannedJob {
        PlannedJob(
            kind: .hires, folder: folder, options: ["--particles", String(particles)],
            title: Self.particles(particles),
            seconds: hiresSeconds(folder, particles: particles, cost: cost),
            queued: queue.unfinished(at: folder).contains { $0.kind == .hires })
    }

    /// Measured on this Mac (#19) for a 700 Myr story, for a scene whose own files cannot say:
    /// one explored before its clip was written.
    static let measuredHires: [(particles: Double, seconds: Double)] = [
        (1e6, 1_800), (2e6, 5_100), (5e6, 14_400), (10e6, 28_800),
    ]

    /// From the cost model and the scene's story, else from the measured sizes; nil for a folder
    /// that is not there.
    public static func hiresSeconds(_ folder: SceneFolder, particles: Int, cost: CostModel) -> Double? {
        if let seconds = try? cost.hiresSeconds(folder, particles: particles) { return seconds }
        guard FileManager.default.fileExists(atPath: folder.url.path) else { return nil }
        let wanted = Double(particles)
        let points = measuredHires
        guard wanted > points[0].particles else { return points[0].seconds * wanted / points[0].particles }
        let upper = points.firstIndex { $0.particles >= wanted } ?? points.count - 1
        let (a, b) = (points[upper - 1], points[upper])
        return a.seconds + (b.seconds - a.seconds) * (wanted - a.particles) / (b.particles - a.particles)
    }

    /// The most particles whose runs end before the next morning, as a night delivers, once the
    /// queue ahead is done: the machine's maximum when all of it fits, the least offered when
    /// nothing does. `seconds` is the cost of every scene asked at one size.
    public static func autoParticles(
        seconds: (Int) -> Double?, start: Date, now: Date, calendar: Calendar = .current,
        maximum: Int = SceneFolder.maximumParticles()
    ) -> Int {
        let morning = (try? NightRecipe().deliverBy(now: now, calendar: calendar)) ?? now
        var sizes = Array(stride(from: hiresSizes[0], through: maximum, by: autoStep))
        if sizes.last != maximum { sizes.append(maximum) }
        var best = sizes[0]
        for size in sizes {
            guard let cost = seconds(size), start.addingTimeInterval(cost) <= morning else { continue }
            best = size
        }
        return best
    }

    public static func export(
        _ choice: ExportChoice, _ settings: ExportSettings, folder: SceneFolder,
        state: ExportFolderState, cost: CostModel, queue: JobQueue
    ) -> PlannedJob {
        var options: [String]
        var stem: [String]
        var codecPart: [String] = []
        let ext: String
        if let format = choice.format {
            options = ["--format", format.rawValue]
            stem = ["preview"]
            ext = format.rawValue
        } else {
            let preset = choice.preset ?? VideoPreset.all[0]
            let codec = choice.takesCodec ? settings.codec : preset.defaultCodec
            options = ["--preset", preset.name]
            if codec != preset.defaultCodec {
                options += ["--codec", codec.rawValue]
                codecPart = [codec.rawValue]
            }
            stem = [preset.name]
            ext = codec.fileExtension
        }
        if let look = settings.look {
            options += ["--look", look.file.path]
            stem.append(look.name)
        }
        if let start = settings.start { options += ["--start", number(start)] }
        if let duration = settings.duration { options += ["--duration", number(duration)] }
        if let fps = settings.framesPerSecond { options += ["--fps", String(fps)] }

        let mine = queue.unfinished(at: folder).filter { $0.kind == .export }
        var job = PlannedJob(kind: .export, folder: folder, options: options, title: choice.title)
        job.seconds = JobEstimate.seconds(
            QueueJob(id: 0, kind: .export, path: folder.url.path, options: options, added: Date()),
            cost: cost)
        if let same = mine.first(where: { Self.request($0.options) == options }) {
            job.queued = true
            job.output = Self.out(same.options).map { URL(fileURLWithPath: $0) }
            return job
        }

        func named(_ number: Int?) -> URL {
            let name = (stem + (number.map { [String($0)] } ?? []) + codecPart).joined(separator: "-")
            return folder.exports.appendingPathComponent("\(name).\(ext)")
        }
        let pending = Set(
            mine.compactMap { Self.out($0.options).map { URL(fileURLWithPath: $0).lastPathComponent } })
        var output = named(nil)
        let first = output.lastPathComponent
        if let made = state.files[first], !pending.contains(first), settings.isPlain,
            state.lookChanged.map({ made >= $0 }) ?? true
        {
            job.replaces = true
        } else {
            var number = 2
            while state.files[output.lastPathComponent] != nil || pending.contains(output.lastPathComponent) {
                output = named(number)
                number += 1
            }
        }
        job.output = output
        job.options += ["--out", output.path]
        return job
    }

    /// What a queued job of a scene makes: "5 M", "4K · 4k-2.mp4".
    public static func title(of job: QueueJob) -> String {
        func option(_ name: String) -> String? {
            job.options.firstIndex(of: name).flatMap {
                $0 + 1 < job.options.count ? job.options[$0 + 1] : nil
            }
        }
        switch job.kind {
        case .hires:
            return option("--particles").flatMap(Double.init).map { particles(Int($0)) }
                ?? "Le plus que la machine tient"
        case .export:
            let card = ExportChoice(rawValue: option("--format") ?? option("--preset") ?? "1080p")
            var parts = [card?.title ?? option("--preset") ?? "Vidéo"]
            if let out = option("--out") { parts.append(URL(fileURLWithPath: out).lastPathComponent) }
            return parts.joined(separator: " · ")
        case .explore, .night:
            return job.batch
        }
    }

    /// "5 M", "3,5 M", "800 k".
    public static func particles(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions)) M"
                : String(format: "%.1f M", millions).replacingOccurrences(of: ".", with: ",")
        }
        return count >= 1_000 ? "\(count / 1_000) k" : "\(count)"
    }

    /// A queued export's options without its `--out`, to tell the same request asked twice.
    static func request(_ options: [String]) -> [String] {
        guard let at = options.firstIndex(of: "--out") else { return options }
        var rest = options
        rest.removeSubrange(at..<min(at + 2, rest.count))
        return rest
    }

    static func out(_ options: [String]) -> String? {
        options.firstIndex(of: "--out").flatMap { $0 + 1 < options.count ? options[$0 + 1] : nil }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

extension JobQueue {
    /// The jobs waiting or running on a scene.
    public func unfinished(at folder: SceneFolder) -> [QueueJob] {
        let path = folder.url.path
        return jobs.filter {
            !$0.isFinished && $0.isScene && SceneFolder(path: $0.path).url.path == path
        }
    }
}

/// When jobs about to be queued would be ready, behind what the queue already holds:
/// "2 calculs avant celui-ci · prêt vers 23 h 40".
public struct StageForecast: Sendable, Equatable {
    public var ahead: Int
    public var paused: Bool
    /// The jobs to add, in order: already queued ones are left out.
    public var jobs: [PlannedJob]
    /// When each would be ready; nil from the first one with no estimate, or when the queue
    /// ahead has none.
    public var ready: [Date?]
    public var now: Date
    public var timeZone: TimeZone

    public init(
        jobs: [PlannedJob], ahead: Int, paused: Bool, freeAt: Date?, now: Date,
        timeZone: TimeZone = .current
    ) {
        self.jobs = jobs.filter { !$0.queued }
        self.ahead = ahead
        self.paused = paused
        self.now = now
        self.timeZone = timeZone
        var cursor = paused ? nil : freeAt.map { max($0, now) }
        ready = self.jobs.map { job in
            cursor = cursor.flatMap { start in job.seconds.map { start.addingTimeInterval($0) } }
            return cursor
        }
    }

    public init(jobs: [PlannedJob], status: QueueStatus, now: Date, timeZone: TimeZone = .current) {
        self.init(
            jobs: jobs, ahead: status.ahead, paused: status.isPaused,
            freeAt: status.freeAt, now: now, timeZone: timeZone)
    }

    private var words: Words { Words(now: now, timeZone: timeZone) }

    /// "environ 12 min", "moins d'une minute".
    static func about(_ seconds: Double) -> String {
        seconds < 60 ? "moins d'une minute" : "environ " + Words.duration(seconds)
    }

    /// "environ 12 min · prêt vers 23 h 40".
    public func line(_ index: Int) -> String {
        guard jobs.indices.contains(index) else { return "" }
        var parts = [jobs[index].seconds.map(Self.about) ?? "durée inconnue"]
        if let ready = ready[index] { parts.append("prêt " + words.about(ready)) }
        return parts.joined(separator: " · ")
    }

    /// "1 calcul avant celui-ci · prêt vers 23 h 40", "Commence tout de suite · tout prêt vers 1 h 10".
    public var summary: String {
        guard !jobs.isEmpty else { return "Déjà dans la file d'attente" }
        let these = jobs.count == 1 ? "celui-ci" : "ceux-ci"
        var parts: [String] = []
        if paused { parts.append("File en pause") }
        if ahead == 0 {
            if !paused { parts.append("Commence tout de suite") }
        } else {
            parts.append((ahead == 1 ? "1 calcul" : "\(ahead) calculs") + " avant \(these)")
        }
        if jobs.count > 1, jobs.allSatisfy({ $0.seconds != nil }) {
            parts.append(Self.about(jobs.compactMap(\.seconds).reduce(0, +)) + " en tout")
        }
        if let last = ready.last ?? nil {
            parts.append((jobs.count == 1 ? "prêt " : "tout prêt ") + words.about(last))
        } else if !paused {
            parts.append("heure de fin inconnue")
        }
        return parts.joined(separator: " · ")
    }
}
