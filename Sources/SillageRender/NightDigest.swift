import Foundation

/// `sillage-render status` in five lines at most: what runs, how far it has got, when it will be
/// ready, what failed and the last video written. The first line comes from `QueueStatus`, the
/// formatter the app's status line and queue view use; the rest is built from the night's own
/// files. `json` is the same thing as one object.
public struct NightDigest: Sendable, Equatable, Codable {
    public struct Failure: Sendable, Equatable, Codable {
        public var stage: String?
        public var scene: String?
        public var message: String?
        public var log: String?
    }

    public struct Video: Sendable, Equatable, Codable {
        public var path: String
        public var megabytes: Double?
        public var at: Date
    }

    public struct Night: Sendable, Equatable, Codable {
        public var id: String
        public var state: NightFile.State
        /// The phase it is in, while it runs.
        public var phase: String?
        public var startedAt: Date
        public var deliverBy: Date?
        public var estimatedEnd: Date?
        public var endedAt: Date?
        public var explored: Int
        public var rejected: Int
        public var exploreFailed: Int
        public var picked: Int
        public var hiresDone: Int
        public var hiresPlanned: Int
        public var videos: Int
        public var skipped: Int
        public var failures: [Failure]
        public var lastVideo: Video?
    }

    /// Something computes: a night, or a stage started by hand.
    public var busy: Bool
    public var paused: Bool
    public var stuck: Bool
    /// Jobs waiting in the queue.
    public var waiting: Int
    /// The night the lines are about: the one running, the one asked for or the last one.
    public var night: Night?
    public var lines: [String]

    public func json() throws -> Data { try RunStatus.encoder().encode(self) }
}

// MARK: - Reading

extension NightDigest {
    /// Reads the library now. `night` is a night's folder to report instead of the running or
    /// last one; nil is returned when it holds none.
    public static func read(
        library: URL, night folder: URL? = nil, now: Date = Date(), timeZone: TimeZone = .current,
        processes: [QueueStatus.ProcessInfo]? = nil,
        isAlive: @escaping @Sendable (QueueJob) -> Bool = {
            ProcessProbe.isAlive(pid: $0.pid, started: $0.pidStarted)
        }
    ) -> NightDigest? {
        let status = QueueStatus.read(
            library: library, now: now, timeZone: timeZone, processes: processes, isAlive: isAlive)
        let activity = ActivityFile.read(from: RunStatusFiles.activity(library: library))
        let running = status.isBusy ? QueueStatus.nightFolder(of: activity, library: library) : nil
        let chosen: (batch: URL, file: NightFile)?
        if let folder {
            guard let file = NightFile.read(from: RunStatusFiles.night(batch: folder)) else {
                return nil
            }
            chosen = (folder, file)
        } else {
            chosen = running ?? (status.isBusy ? nil : lastNight(in: library))
        }
        let live = chosen.map { $0.file.id == running?.file.id } ?? false
        return NightDigest(
            status: status, activity: activity, night: chosen, live: live, explicit: folder != nil,
            now: now, timeZone: timeZone)
    }

    /// The night that started last, among the library's folders.
    static func lastNight(in library: URL) -> (batch: URL, file: NightFile)? {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { batch in
            NightFile.read(from: RunStatusFiles.night(batch: batch)).map { (batch, $0) }
        }.max { $0.file.startedAt < $1.file.startedAt }
    }
}

// MARK: - Building

extension NightDigest {
    init(
        status: QueueStatus, activity: ActivityFile?, night chosen: (batch: URL, file: NightFile)?,
        live: Bool, explicit: Bool, now: Date, timeZone: TimeZone
    ) {
        let words = Words(now: now, timeZone: timeZone)
        busy = status.isBusy
        paused = status.isPaused
        stuck = status.isStuck
        waiting = status.waitingCount
        guard let (batch, file) = chosen else {
            night = nil
            var lines = [status.summary]
            if !status.isBusy { lines.append("Aucune nuit encore dans cette bibliothèque") }
            if status.waitingCount > 0 { lines.append(QueueStatus.waitingText(status.waitingCount)) }
            if let last = status.finished.first { lines.append("Dernier travail : " + last.text) }
            self.lines = lines
            return
        }

        let events =
            (try? String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8))
            .map(RunEvent.decodeLines) ?? []
        let found = NightEvents(events)
        let failures = found.errors.map {
            Failure(stage: $0.stage, scene: $0.scene, message: $0.message, log: $0.log)
        }
        let video = found.videos.last.flatMap { event in
            event.path.map {
                Video(
                    path: NightEvents.relative($0, to: batch), megabytes: event.megabytes, at: event.t)
            }
        }
        func phase(_ name: String) -> NightFile.Phase? { file.phases.first { $0.name == name } }
        night = Night(
            id: file.id, state: file.state, phase: live ? activity?.night?.phase : nil,
            startedAt: file.startedAt, deliverBy: file.deliverBy,
            estimatedEnd: file.estimatedEnd ?? (live ? activity?.night?.eta : nil),
            endedAt: file.endedAt, explored: found.explored("ok"),
            rejected: found.explored("rejected"), exploreFailed: found.explored("failed"),
            picked: found.picks.count, hiresDone: found.hires.count,
            hiresPlanned: phase("hires")?.planned ?? 0, videos: found.videos.count,
            skipped: found.skipped.count, failures: failures, lastVideo: video)

        var lines: [String] = []
        let errors = Self.errorsText(failures.count)
        let name = "Nuit du " + (words.nightDate(night: file.id, file: file) ?? file.id)
        if live {
            lines.append(status.summary + " · " + errors)
        } else {
            if !explicit { lines.append(status.summary) }
            lines.append([name, Self.outcome(file, words), errors].joined(separator: " · "))
        }
        lines.append(Self.counts(file, found: found))
        if live { lines.append(Self.readiness(file, paused: status.isPaused, activity, words)) }
        if let first = failures.first {
            let who = [first.scene, first.stage.map(QueueStatus.phaseLabel)].compactMap { $0 }
            var text = "Erreurs : " + who.joined(separator: " ")
            if let message = first.message { text += " : " + message }
            if let log = first.log { text += " (journal " + NightEvents.relative(log, to: batch) + ")" }
            if failures.count > 1 { text += " · et \(failures.count - 1) de plus" }
            lines.append(text)
        }
        if let video {
            let weight = video.megabytes.map { " · " + Words.size(megabytes: $0) } ?? ""
            lines.append("Dernière vidéo : \(video.path)\(weight) · \(words.at(video.at))")
        } else {
            lines.append("Aucune vidéo pour l'instant")
        }
        self.lines = lines
    }

    static func errorsText(_ count: Int) -> String {
        count == 0 ? "0 erreur" : count == 1 ? "1 erreur" : "\(count) erreurs"
    }

    /// "terminée 6 h 41, avant 7 h 00", for a night that is not running.
    static func outcome(_ night: NightFile, _ words: Words) -> String {
        let end = night.endedAt.map { words.at($0) }
        let state: String =
            switch night.state {
            case .done: "terminée"
            case .failed: "en échec"
            case .stopped: "arrêtée"
            case .paused: "en pause"
            case .running: "interrompue"
            }
        guard let end, night.state != .running, night.state != .paused else { return state }
        let late = night.deliverBy.map { $0 < (night.endedAt ?? $0) } ?? false
        let deadline = night.deliverBy.map { (late ? ", après " : ", avant ") + words.at($0) } ?? ""
        return state + " " + end + (night.state == .done ? deadline : "")
    }

    /// "Aperçus 50/50 (2 rejetés) · choix 4/4 · haute résolution 1/4 · 2 vidéos".
    static func counts(_ night: NightFile, found: NightEvents) -> String {
        var parts: [String] = []
        for name in ["explore", "pick", "hires"] {
            guard let phase = night.phases.first(where: { $0.name == name }), phase.planned > 0
            else { continue }
            var text = "\(QueueStatus.phaseLabel(name)) \(phase.done)/\(phase.planned)"
            var aside: [String] = []
            if name == "explore", found.explored("rejected") > 0 {
                aside.append(
                    "\(found.explored("rejected")) rejeté\(found.explored("rejected") > 1 ? "s" : "")")
            }
            if phase.failed > 0 { aside.append("\(phase.failed) en échec") }
            if let skipped = phase.skipped, skipped > 0 {
                aside.append("\(skipped) laissée\(skipped > 1 ? "s" : "") de côté")
            }
            if !aside.isEmpty { text += " (" + aside.joined(separator: ", ") + ")" }
            parts.append(text)
        }
        let videos = found.videos.count
        parts.append("\(videos) vidéo\(videos > 1 ? "s" : "")")
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// "Livraison : prête vers 6 h 20, avant 7 h 00 (40 min de marge)".
    static func readiness(
        _ night: NightFile, paused: Bool, _ activity: ActivityFile?, _ words: Words
    ) -> String {
        if paused { return "Livraison : en pause, pas d'heure estimée" }
        guard let end = night.estimatedEnd ?? activity?.night?.eta else {
            return "Livraison : pas d'heure estimée"
        }
        return "Livraison : prête \(words.about(end)), "
            + NightReport.delivery(night, end: end, words: words)
    }
}
