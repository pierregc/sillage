import Foundation

/// What the new night sheet asks for: a delivery time or a number of hours, and at most four
/// settings, each Auto until the user says otherwise. Everything else of a night stays Auto
/// and is not shown. It is kept as the next sheet's starting point.
public struct NightSheet: Codable, Sendable, Equatable {
    public enum Timing: String, Codable, Sendable { case deliver, hours }

    public var timing = Timing.deliver
    /// The clock time of the delivery, in minutes after midnight.
    public var deliverMinutes = 7 * 60
    public var hours = 8.0
    /// Scenes taken to high resolution, 2 to 4; nil is Auto.
    public var hiresScenes: Int?
    /// `telescope` or `free`; nil is Auto.
    public var world: String?
    public var fourK = true
    public var vertical = true
    /// Stops after the previews: nothing is taken to high resolution.
    public var exploreOnly = false

    public static let hoursRange = 1.0...24.0
    public static let hiresChoices = NightRecipe.pickRange
    public static let worlds = ["telescope", "free"]

    public init() {}

    /// The recipe the night runs from. What is not set stays Auto.
    public func recipe() -> NightRecipe {
        var recipe = NightRecipe()
        switch timing {
        case .deliver:
            recipe.deliver = .value(
                String(format: "%02d:%02d", deliverMinutes / 60 % 24, deliverMinutes % 60))
        case .hours:
            recipe.hours = .value(min(max(hours, Self.hoursRange.lowerBound), Self.hoursRange.upperBound))
        }
        if exploreOnly {
            recipe.pick = .none
        } else if let count = hiresScenes {
            recipe.pick = .count(min(max(count, Self.hiresChoices.lowerBound), Self.hiresChoices.upperBound))
        }
        if let world, Self.worlds.contains(world) { recipe.style.world = .value(world) }
        if !(fourK && vertical) {
            recipe.export = .value((fourK ? ["4k"] : []) + (vertical ? ["vertical"] : []))
        }
        return recipe
    }

    /// Whether a setting of the disclosure is off Auto, for the label that closes it.
    public var customised: Bool {
        hiresScenes != nil || world != nil || !(fourK && vertical) || exploreOnly
    }

    // MARK: Kept between sheets

    public static func url(library: URL) -> URL {
        library.appendingPathComponent(".sillage", isDirectory: true)
            .appendingPathComponent("night-sheet.json")
    }

    /// The last settings, or the defaults when none were kept or the file is not ours.
    public static func last(library: URL) -> NightSheet {
        guard let data = try? Data(contentsOf: url(library: library)),
            let kept = try? JSONDecoder().decode(NightSheet.self, from: data)
        else { return NightSheet() }
        return kept
    }

    public func keep(library: URL) throws {
        let url = Self.url(library: library)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Launching

    /// A recipe file of its own for each night: a queued night reads it when its turn comes.
    public static func writeRecipe(_ recipe: NightRecipe, library: URL, at date: Date = Date()) throws
        -> URL
    {
        let folder = library.appendingPathComponent(".sillage", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("night-\(formatter.string(from: date)).json")
        try recipe.encoded().write(to: url, options: .atomic)
        return url
    }

    /// Adds the night to the library's queue, a runner started if none is at work, and keeps
    /// the settings for the next sheet.
    @discardableResult
    public func launch(
        library: URL, runner executable: URL?, at date: Date = Date()
    ) throws -> (job: QueueJob, runner: Int32?) {
        let recipe = try NightCommand.checked(recipe())
        let file = try Self.writeRecipe(recipe, library: library, at: date)
        let batch = library.appendingPathComponent(NightCommand.day(date), isDirectory: true)
        let added = try QueueStore(library: library).submit(
            .night, path: batch.path, options: [file.path], night: batch.lastPathComponent,
            runner: executable, at: date)
        try? keep(library: library)
        return added
    }
}

/// The plan under the time control, in the words of the sheet: one line a step with what it
/// computes, how long it takes and when it ends, then the delivery, and the warnings.
public struct NightSheetPlan: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var phase: NightPlan.Phase
        public var title: String
        public var detail: String
        public var duration: String
        public var until: String

        /// "Aperçus · environ 50 scènes · 3 h 40 · jusqu'à 1 h 10".
        public var text: String {
            [title, detail, duration, until].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    public struct Warning: Sendable, Equatable {
        /// `disk`, `late`, `explore` or `over`.
        public var kind: String
        public var text: String
    }

    public var lines: [Line]
    /// "Prêt à 7 h 00", or "Prêt demain à 7 h 00".
    public var delivery: String
    /// "Fin prévue à 6 h 20 · 40 min de marge".
    public var margin: String
    public var warnings: [Warning]

    public init(
        plan: NightPlan, now: Date, timeZone: TimeZone = .current, requestedHires: Int? = nil
    ) {
        let words = Words(now: now, timeZone: timeZone)
        var lines: [Line] = []
        for summary in plan.summaries where summary.phase != .pick {
            let done = summary.seconds == 0
            let (title, detail) = Self.describe(summary, plan: plan)
            lines.append(
                Line(
                    phase: summary.phase, title: title, detail: detail,
                    duration: done ? "déjà fait" : Words.duration(summary.seconds),
                    until: done ? "" : "jusqu'à " + words.clock(summary.end)))
        }
        self.lines = lines
        let days =
            words.calendar.dateComponents(
                [.day], from: words.calendar.startOfDay(for: now),
                to: words.calendar.startOfDay(for: plan.deliverBy)
            ).day ?? 0
        let clock = words.clock(plan.deliverBy)
        delivery =
            days == 0
            ? "Prêt à \(clock)"
            : days == 1 ? "Prêt demain à \(clock)" : "Prêt le \(words.day(plan.deliverBy)) à \(clock)"
        let spare = plan.deliverBy.timeIntervalSince(plan.end)
        margin =
            spare >= 0
            ? "Fin prévue à \(words.clock(plan.end)) · \(Words.duration(spare)) de marge"
            : "Fin prévue à \(words.clock(plan.end)) · \(Words.duration(-spare)) de retard"
        warnings = Self.warnings(plan, words: words, requestedHires: requestedHires)
    }

    private static func describe(_ summary: NightPlan.Summary, plan: NightPlan) -> (String, String) {
        func scenes(_ count: Int) -> String { count == 1 ? "1 scène" : "\(count) scènes" }
        switch summary.phase {
        case .explore:
            return ("Aperçus", "environ " + scenes(summary.count))
        case .pick:
            return ("Choix", scenes(summary.count))
        case .hires:
            return (
                "Haute résolution", scenes(summary.count) + " à " + millions(plan.hiresParticles)
            )
        case .style:
            return ("Style", scenes(summary.count))
        case .export:
            return ("Vidéos", summary.count == 1 ? "1 vidéo" : "\(summary.count) vidéos")
        }
    }

    /// "2 M de particules".
    static func millions(_ particles: Int) -> String {
        let value = Double(particles) / 1e6
        let text =
            value >= 10 || value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        return "\(text) M de particules"
    }

    private static func warnings(_ plan: NightPlan, words: Words, requestedHires: Int?) -> [Warning] {
        var warnings: [Warning] = []
        if let free = plan.freeBytes, plan.diskBytes > free {
            warnings.append(
                Warning(
                    kind: "disk",
                    text: "Il faut environ \(gigabytes(plan.diskBytes)), il en reste "
                        + "\(gigabytes(free)) sur le disque."))
        }
        if plan.warnings.contains(where: { $0.kind == "explore" }) {
            warnings.append(
                Warning(
                    kind: "explore",
                    text: "Les aperçus sont réduits à environ \(plan.scenes) scènes pour laisser "
                        + "le temps à la haute résolution."))
        }
        if let asked = requestedHires, plan.picks < asked {
            warnings.append(
                Warning(
                    kind: "picks",
                    text: "Seules \(plan.picks) des \(asked) scènes demandées en haute résolution "
                        + "tiennent avant \(words.clock(plan.deliverBy))."))
        }
        let left = Set(plan.steps.filter { $0.phase == .hires && !$0.fits && !$0.done }.compactMap(\.scene))
        if !left.isEmpty {
            warnings.append(
                Warning(
                    kind: "late",
                    text: (left.count == 1
                        ? "Une scène en haute résolution ne tient pas"
                        : "\(left.count) scènes en haute résolution ne tiennent pas")
                        + " avant \(words.clock(plan.deliverBy)) : "
                        + (left.count == 1 ? "elle sera laissée de côté." : "elles seront laissées de côté.")
                ))
        }
        if plan.end > plan.deliverBy {
            warnings.append(
                Warning(
                    kind: "over",
                    text: "La nuit finirait à \(words.clock(plan.end)), après l'heure de livraison."))
        }
        return warnings
    }

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f Go", bytes / 1e9).replacingOccurrences(of: ".", with: ",")
    }
}

/// Plans the night a sheet describes, again and again as it changes. The draws of the batch
/// are sized once, the slow part, and the folder is read once per set of exports, so a new
/// plan takes a few milliseconds and the sheet can follow every change.
public final class NightSheetPlanner: @unchecked Sendable {
    public let library: URL
    public let batch: URL
    private let maximumParticles: Int
    private let model: CostModel
    private let freeBytes: Double?
    private let timeZone: TimeZone
    private let standIn: (@Sendable (Int) -> [NightScene])?
    private let lock = NSLock()
    private var probe: ExploreProbe?
    private var progress: [[String]: NightProgress] = [:]
    private var drawn: [Int: [NightScene]] = [:]

    /// `draws` stands in for the batch's own (a check gives it fixed ones).
    public init(
        library: URL, now: Date = Date(), model: CostModel? = nil,
        maximumParticles: Int = SceneFolder.maximumParticles(), freeBytes: Double? = nil,
        timeZone: TimeZone = .current, draws: (@Sendable (Int) -> [NightScene])? = nil
    ) {
        self.library = library
        batch = library.appendingPathComponent(NightCommand.day(now), isDirectory: true)
        self.maximumParticles = maximumParticles
        self.model = model ?? CostModel.current(library: library)
        self.freeBytes = freeBytes
        self.timeZone = timeZone
        standIn = draws
    }

    private static let shared = Shared()

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var planner: (planner: NightSheetPlanner, made: Date)?
    }

    /// The planner of this library for today, kept for half an hour so that the app can size
    /// the draws while it is idle and the sheet finds them ready.
    public static func shared(library: URL, now: Date = Date()) -> NightSheetPlanner {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        let batch = library.appendingPathComponent(NightCommand.day(now), isDirectory: true)
        if let kept = shared.planner, kept.planner.batch == batch,
            now.timeIntervalSince(kept.made) < 1_800
        {
            return kept.planner
        }
        let planner = NightSheetPlanner(library: library, now: now)
        shared.planner = (planner, now)
        return planner
    }

    /// Sizes the draws a plan starts from, the first time a few seconds.
    public func warm(now: Date = Date()) {
        _ = plan(NightSheet(), now: now)
    }

    public func plan(_ sheet: NightSheet, now: Date = Date()) -> NightSheetPlan {
        NightSheetPlan(
            plan: nightPlan(sheet, now: now), now: now, timeZone: timeZone,
            requestedHires: sheet.exploreOnly ? nil : sheet.hiresScenes)
    }

    public func nightPlan(_ sheet: NightSheet, now: Date = Date()) -> NightPlan {
        let recipe = sheet.recipe()
        let folder = NightFolder(batch: batch, recipe: recipe, maximumParticles: maximumParticles)
        lock.lock()
        let sizer = probe ?? folder.probe(now: now)
        probe = sizer
        let key = recipe.exports
        let known = progress[key]
        lock.unlock()
        let kept = known ?? folder.progress()
        lock.lock()
        progress[key] = kept
        lock.unlock()
        let particles = folder.hiresParticles
        let planner = NightPlanner(
            recipe: recipe, model: model, maximumParticles: maximumParticles, progress: kept,
            freeBytes: freeBytes ?? NightFolder.freeBytes(batch)
        ) { [self] perGalaxy in
            lock.lock()
            let known = drawn[perGalaxy]
            lock.unlock()
            if let known { return known }
            let scenes =
                standIn?(perGalaxy)
                ?? sizer.draws(perGalaxy: perGalaxy, count: NightPlanner.sample).map {
                    sizer.scene($0, hiresParticles: particles, frames: nil)
                }
            lock.lock()
            drawn[perGalaxy] = scenes
            lock.unlock()
            return scenes
        }
        return planner.plan(now: now, deliverBy: (try? recipe.deliverBy(now: now)) ?? now)
    }
}
