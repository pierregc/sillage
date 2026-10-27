import Foundation

/// A night in the sidebar: "25 oct. · 35 scènes · 4 vidéos".
public struct NightListItem: Sendable, Equatable, Identifiable {
    /// The night's folder name.
    public var id: String
    /// "25 oct.".
    public var day: String
    /// "35 scènes · 4 vidéos", with how it stands when it is not over.
    public var summary: String
    public var startedAt: Date
    /// Nil for a night that waits in the queue and has written nothing yet.
    public var state: NightFile.State?
    public var live: Bool
    public var queued: Bool

    public var title: String { day + " · " + summary }
}

/// What the page of one night shows, read from its files (`night.json`, `events.jsonl`,
/// `report.md`), `activity.json` and the queue. Nothing here needs the app to have been open
/// while the night ran.
public struct NightPage: Sendable, Equatable {
    public struct PhaseBar: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case waiting, current, done, left }

        /// `explore`, `pick`, `hires`, `style` or `export`.
        public var id: String
        public var title: String
        public var state: State
        /// "12/50".
        public var counts: String
        /// "2 rejetés · 1 en échec".
        public var detail: String
        /// "fini 1 h 05", "fin vers 3 h 10" or "début vers 3 h 10".
        public var time: String
        public var fraction: Double
    }

    public struct SceneCard: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var score: Double?
        /// Where it stands: Aperçu, Choisie, Haute résolution, Style, Vidéos 1/2, Terminée or
        /// Laissée de côté.
        public var stage: String
        /// "score 0,91 · haute résolution 40 min".
        public var detail: String
        public var picked: Bool
        /// The scene the job running now works on.
        public var current: Bool
        public var videos: Int
        public var arrived: Date
    }

    public struct Problem: Sendable, Equatable, Identifiable {
        public var id: Int
        /// "scene-0023, haute résolution : ended by signal 9".
        public var text: String
        /// The log from the night's folder.
        public var log: String?
        public var logURL: URL?
    }

    /// The running job, as one line and how far it has got.
    public struct Current: Sendable, Equatable {
        public var line: String
        public var scene: String?
        public var kind: String?
        public var progress: Double?
    }

    /// What the buttons may do.
    public struct Controls: Sendable, Equatable {
        /// The queue's number for the night running.
        public var job: Int?
        /// The queue's number for the night waiting its turn.
        public var queuedJob: Int?
        public var isPaused = false
        public var stopAfterAsked = false
        public var stoppingNow = false
        public var canSkip = false

        public var canSteer: Bool { job != nil }
    }

    public var id: String
    public var folder: URL
    /// "Nuit du 25 oct.".
    public var title: String
    public var state: NightFile.State?
    public var live: Bool
    public var queued: Bool
    public var stuck: Bool
    /// "En cours", "Terminée 6 h 41, avant 7 h 00".
    public var status: String
    public var current: Current?
    /// "Livraison : prête vers 6 h 20, avant 7 h 00, 40 min de marge".
    public var delivery: String?
    public var phases: [PhaseBar]
    public var scenes: [SceneCard]
    public var problems: [Problem]
    /// The morning summary, once the night is over: `report.md`.
    public var report: String?
    public var controls: Controls

    public static let phaseNames = ["explore", "pick", "hires", "style", "export"]

    public static func phaseTitle(_ name: String) -> String {
        switch name {
        case "explore": "Aperçus"
        case "pick": "Sélection"
        case "hires": "Haute résolution"
        case "style", "look": "Style"
        case "export": "Vidéos"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// The sidebar's nights and the page of the one chosen, from one reading of the library.
public struct NightsSnapshot: Sendable, Equatable {
    public var items: [NightListItem]
    public var page: NightPage?

    public init(items: [NightListItem] = [], page: NightPage? = nil) {
        self.items = items
        self.page = page
    }

    /// Reads the library now. `selected` is the night whose page is wanted.
    public static func read(
        library: URL, selected: String? = nil, now: Date = Date(), timeZone: TimeZone = .current,
        processes: [QueueStatus.ProcessInfo]? = nil,
        isAlive: @escaping @Sendable (QueueJob) -> Bool = {
            ProcessProbe.isAlive(pid: $0.pid, started: $0.pidStarted)
        }
    ) -> NightsSnapshot {
        let status = QueueStatus.read(
            library: library, now: now, timeZone: timeZone, processes: processes, isAlive: isAlive)
        let queue = QueueStore(library: library).read()
        let activity = ActivityFile.read(from: RunStatusFiles.activity(library: library))
        let words = Words(now: now, timeZone: timeZone)

        let liveJob = queue.running.flatMap { $0.kind == .night && isAlive($0) ? $0 : nil }
        let liveID =
            (status.isBusy ? QueueStatus.nightFolder(of: activity, library: library)?.file.id : nil)
            ?? liveJob?.batch
        let waiting = queue.waiting.filter { $0.kind == .night }

        var folders: [String: (url: URL, file: NightFile)] = [:]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in contents {
            if let file = NightFile.read(from: RunStatusFiles.night(batch: url)) {
                folders[url.lastPathComponent] = (url, file)
            }
        }

        var items: [NightListItem] = folders.map { name, found in
            let waits = waiting.contains { $0.batch == name }
            return NightListItem(
                id: name, day: words.nightDate(night: name, file: found.file) ?? name,
                summary: Self.summary(found.file, live: name == liveID),
                startedAt: found.file.startedAt, state: found.file.state, live: name == liveID,
                queued: waits)
        }
        for job in waiting where folders[job.batch] == nil {
            guard !items.contains(where: { $0.id == job.batch }) else { continue }
            let day = words.nightDate(night: job.batch, file: nil) ?? job.batch
            items.append(
                NightListItem(
                    id: job.batch, day: day, summary: "en attente", startedAt: job.added, state: nil,
                    live: false, queued: true))
        }
        items.sort {
            $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id > $1.id
        }

        var page: NightPage?
        if let selected {
            let job = liveJob.flatMap { $0.batch == selected ? $0 : nil }
            let queued = waiting.first { $0.batch == selected }
            page = NightPage.make(
                id: selected, library: library, found: folders[selected], live: selected == liveID,
                job: job, queued: queued, activity: activity, status: status, queue: queue,
                words: words)
        }
        return NightsSnapshot(items: items, page: page)
    }

    /// "35 scènes · 4 vidéos", with how it stands when it is not over.
    static func summary(_ night: NightFile, live: Bool) -> String {
        func phase(_ name: String) -> NightFile.Phase? { night.phases.first { $0.name == name } }
        let scenes = phase("explore")?.done ?? 0
        let videos = phase("export")?.done ?? 0
        var parts = ["\(scenes) scène\(scenes > 1 ? "s" : "")", "\(videos) vidéo\(videos > 1 ? "s" : "")"]
        switch night.state {
        case _ where live: parts.append(night.state == .paused ? "en pause" : "en cours")
        case .failed: parts.append("en échec")
        case .stopped: parts.append("arrêtée")
        case .running, .paused: parts.append("interrompue")
        case .done: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Building a page

extension NightPage {
    static func make(
        id: String, library: URL, found: (url: URL, file: NightFile)?, live: Bool, job: QueueJob?,
        queued: QueueJob?, activity: ActivityFile?, status: QueueStatus, queue: JobQueue,
        words: Words
    ) -> NightPage? {
        guard let found else {
            // Queued and not started: nothing written yet.
            guard let queued else { return nil }
            let folder = library.appendingPathComponent(id, isDirectory: true)
            var controls = Controls()
            controls.queuedJob = queued.id
            return NightPage(
                id: id, folder: folder,
                title: "Nuit du " + (words.nightDate(night: id, file: nil) ?? id), state: nil,
                live: false, queued: true, stuck: false, status: "En attente dans la file d'attente",
                current: nil, delivery: nil, phases: Self.phaseNames.map(Self.emptyBar), scenes: [],
                problems: [], report: nil, controls: controls)
        }
        let (folder, file) = found
        let events =
            (try? String(contentsOf: RunStatusFiles.events(batch: folder), encoding: .utf8))
            .map(RunEvent.decodeLines) ?? []
        let night = NightEvents(events)
        let shown = live ? activity?.job.flatMap { $0.batch == id ? $0 : nil } : nil
        let paused = live && status.isPaused

        let title = "Nuit du " + (words.nightDate(night: id, file: file) ?? id)
        let state = NightPage.state(file, live: live, paused: paused)
        var line = ""
        if live {
            line = paused ? "En pause" : "En cours"
            if status.isStuck {
                line += " · semble bloquée"
            }
        } else {
            let outcome = NightDigest.outcome(file, words)
            line = outcome.prefix(1).uppercased() + outcome.dropFirst()
        }

        var controls = Controls()
        controls.queuedJob = queued?.id
        controls.isPaused = queue.paused
        if let job, live {
            controls.job = job.id
            controls.stopAfterAsked = job.stopAfterStep == true
            controls.stoppingNow = job.stopping == true
            controls.canSkip = shown.map { $0.kind != "explore" && $0.scene != nil } ?? false
        }

        let delivery: String? =
            live
            ? NightDigest.readiness(file, paused: paused, activity, words)
            : file.deliverBy == nil
                ? nil
                : "Livraison : "
                    + NightReport.delivery(
                        file, end: file.endedAt ?? file.estimatedEnd ?? words.now, words: words)

        let report: String? =
            live
            ? nil
            : (try? String(
                contentsOf: folder.appendingPathComponent("report.md"), encoding: .utf8))
                ?? NightReport.markdown(
                    file, events: events, batch: folder, now: words.now,
                    timeZone: words.calendar.timeZone)

        return NightPage(
            id: id, folder: folder, title: title, state: state, live: live,
            queued: queued != nil, stuck: live && status.isStuck, status: line,
            current: live ? current(file, shown, activity, paused: paused, words) : nil,
            delivery: delivery,
            phases: phases(file, events: events, found: night, live: live, job: shown, activity, words),
            scenes: cards(events, file: file, current: live ? shown : nil),
            problems: problems(night, folder: folder),
            report: report, controls: controls)
    }

    static func state(_ file: NightFile, live: Bool, paused: Bool) -> NightFile.State? {
        if live { return paused ? .paused : .running }
        return file.state
    }

    static func emptyBar(_ name: String) -> PhaseBar {
        PhaseBar(
            id: name, title: phaseTitle(name), state: .waiting, counts: "", detail: "", time: "",
            fraction: 0)
    }

    // MARK: Current job

    /// "scene-0023, haute résolution, image 412/900, prêt vers 1 h 12".
    static func current(
        _ file: NightFile, _ job: ActivityFile.Job?, _ activity: ActivityFile?, paused: Bool,
        _ words: Words
    ) -> Current {
        guard let job else {
            let phase = activity?.night?.phase ?? "explore"
            let line = paused ? "En pause" : QueueStatus.phase(phase, file: file)
            return Current(line: line.prefix(1).uppercased() + line.dropFirst(), progress: nil)
        }
        var parts = [job.scene.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }]
        parts.append(QueueStatus.phaseLabel(job.kind))
        parts.append(QueueStatus.detail(job.detail))
        if !paused, let eta = job.eta { parts.append("prêt " + words.about(eta)) }
        var line = parts.compactMap { $0 }.joined(separator: ", ")
        if paused { line = "En pause · " + line }
        return Current(line: line, scene: job.scene, kind: job.kind, progress: job.progress)
    }

    // MARK: Phase bar

    static func phases(
        _ file: NightFile, events: [RunEvent], found: NightEvents, live: Bool,
        job: ActivityFile.Job?, _ activity: ActivityFile?, _ words: Words
    ) -> [PhaseBar] {
        let phaseDone = Dictionary(
            events.filter { $0.kind == RunEvent.Kind.phaseDone }.compactMap { event in
                event.phase.map { ($0, event.t) }
            }, uniquingKeysWith: { _, later in later })
        let lastEvent: [String: Date] = [
            "hires": found.hires.last?.t ?? .distantPast,
            "export": found.videos.last?.t ?? .distantPast,
            "style": events.last { $0.kind == RunEvent.Kind.style }?.t ?? .distantPast,
        ]
        let running = live ? activity?.night?.phase : nil
        return Self.phaseNames.map { name in
            guard let phase = file.phases.first(where: { $0.name == name }) else {
                var bar = emptyBar(name)
                if !live, file.state != .done, bar.state == .waiting { bar.state = .left }
                return bar
            }
            let finished =
                phaseDone[name] != nil
                || (phase.planned > 0 && phase.done + phase.failed + (phase.skipped ?? 0) >= phase.planned)
            let state: PhaseBar.State =
                finished ? .done : (running == name ? .current : (live ? .waiting : .left))
            var fraction = phase.planned > 0 ? Double(phase.done) / Double(phase.planned) : 0
            if state == .current, name != "explore", let job, phase.planned > 0,
                Self.phase(of: job.kind) == name
            {
                fraction += job.progress / Double(phase.planned)
            }
            var aside: [String] = []
            if name == "explore", found.explored("rejected") > 0 {
                let rejected = found.explored("rejected")
                aside.append("\(rejected) rejeté\(rejected > 1 ? "s" : "")")
            }
            if phase.failed > 0 { aside.append("\(phase.failed) en échec") }
            if let skipped = phase.skipped, skipped > 0 {
                aside.append("\(skipped) laissée\(skipped > 1 ? "s" : "") de côté")
            }
            let time: String
            switch state {
            case .done:
                let at = phaseDone[name] ?? lastEvent[name].flatMap { $0 > .distantPast ? $0 : nil }
                time = at.map { "fini " + words.at($0) } ?? ""
            case .current: time = phase.estimatedEnd.map { "fin " + words.about($0) } ?? ""
            case .waiting: time = phase.estimatedStart.map { "début " + words.about($0) } ?? ""
            case .left: time = ""
            }
            return PhaseBar(
                id: name, title: phaseTitle(name), state: state,
                counts: phase.planned > 0 ? "\(phase.done)/\(phase.planned)" : "",
                detail: aside.joined(separator: " · "), time: time, fraction: min(fraction, 1))
        }
    }

    /// The phase of the night a stage belongs to.
    static func phase(of kind: String) -> String {
        kind == "look" ? "style" : kind
    }

    // MARK: Scenes

    /// A card a scene, the picked ones first in the order they were picked, then the others as
    /// they arrived, the latest first. Scenes rejected or failed in the exploration have none.
    static func cards(_ events: [RunEvent], file: NightFile, current: ActivityFile.Job?) -> [SceneCard] {
        let exports = max(
            file.recipe["exports"].map { $0.split(separator: ",").count } ?? 1, 1)
        struct Seen {
            var arrived = Date.distantPast
            var score: Double?
            var picked = false
            var pickOrder = 0
            var hiresStarted = false
            var minutes: Double?
            var styled = false
            var videos = 0
            var leftOut: String?
        }
        var seen: [String: Seen] = [:]
        var order = 0
        for event in events {
            guard let name = event.scene.map({ $0.hasPrefix(".") ? String($0.dropFirst()) : $0 })
            else { continue }
            switch event.kind {
            case RunEvent.Kind.exploreScene:
                guard event.status == "ok" else { continue }
                seen[name, default: Seen()].arrived = event.t
                seen[name, default: Seen()].score = event.score
            case RunEvent.Kind.pick where event.chosen != false:
                guard seen[name] != nil else { continue }
                order += 1
                seen[name]?.picked = true
                seen[name]?.pickOrder = order
                if let score = event.score { seen[name]?.score = score }
            case RunEvent.Kind.hiresStart: seen[name]?.hiresStarted = true
            case RunEvent.Kind.hiresDone:
                seen[name]?.hiresStarted = true
                seen[name]?.minutes = event.minutes ?? 0
            case RunEvent.Kind.style: seen[name]?.styled = true
            case RunEvent.Kind.exportDone: seen[name]?.videos += 1
            case RunEvent.Kind.skip: seen[name]?.leftOut = event.message ?? ""
            default: break
            }
        }
        let cards = seen.map { name, scene -> SceneCard in
            var stage = "Aperçu"
            if scene.picked { stage = "Choisie" }
            if scene.hiresStarted { stage = "Haute résolution" }
            if scene.minutes != nil { stage = "Style" }
            if scene.styled || scene.videos > 0 { stage = "Vidéos \(scene.videos)/\(exports)" }
            if scene.videos >= exports { stage = "Terminée" }
            if name == current?.scene {
                switch current?.kind {
                case "hires": stage = "Haute résolution"
                case "look": stage = "Style"
                case "export": stage = "Vidéos \(scene.videos)/\(exports)"
                default: break
                }
            }
            if scene.leftOut != nil { stage = "Laissée de côté" }
            var detail: [String] = []
            if let score = scene.score { detail.append("score " + Words.decimal(score, digits: 2)) }
            if let minutes = scene.minutes, minutes > 0 {
                detail.append("haute résolution " + Words.duration(minutes * 60))
            }
            if let why = scene.leftOut, !why.isEmpty { detail.append(why) }
            return SceneCard(
                name: name, score: scene.score, stage: stage, detail: detail.joined(separator: " · "),
                picked: scene.picked, current: name == current?.scene, videos: scene.videos,
                arrived: scene.arrived)
        }
        let order2 = seen.mapValues(\.pickOrder)
        return cards.sorted { a, b in
            if a.picked != b.picked { return a.picked }
            if a.picked { return order2[a.name, default: 0] < order2[b.name, default: 0] }
            return a.arrived != b.arrived ? a.arrived > b.arrived : a.name > b.name
        }
    }

    // MARK: Problems

    static func problems(_ found: NightEvents, folder: URL) -> [Problem] {
        found.errors.enumerated().map { index, event in
            let who = [event.scene, event.stage.map(QueueStatus.phaseLabel)].compactMap { $0 }
                .joined(separator: ", ")
            let text = [who, event.message].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " : ")
            let relative = event.log.map { NightEvents.relative($0, to: folder) }
            // The path the night wrote, or from its folder when the library has moved.
            let url = event.log.flatMap { path -> URL? in
                if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
                return relative.map { folder.appendingPathComponent($0) }
            }
            return Problem(
                id: index, text: text.isEmpty ? "erreur" : text,
                log: relative, logURL: url)
        }
    }
}
