import Foundation

/// The events of a night sorted by what they say, shared by the report and the status digest.
struct NightEvents {
    let explored: [RunEvent]
    let picks: [RunEvent]
    let hires: [RunEvent]
    let videos: [RunEvent]
    let skipped: [RunEvent]
    let errors: [RunEvent]

    init(_ events: [RunEvent]) {
        func of(_ kind: String) -> [RunEvent] { events.filter { $0.kind == kind } }
        explored = of(RunEvent.Kind.exploreScene)
        picks = of(RunEvent.Kind.pick).filter { $0.chosen != false }
        hires = of(RunEvent.Kind.hiresDone)
        videos = of(RunEvent.Kind.exportDone)
        skipped = of(RunEvent.Kind.skip)
        errors = of(RunEvent.Kind.error)
    }

    func explored(_ status: String) -> Int { explored.filter { $0.status == status }.count }

    /// "scene-0023 (0,91)", or "scene-0023 (à la main)" for a scene picked by hand.
    static func pick(_ event: RunEvent) -> String {
        let score = event.score.map { Words.decimal($0, digits: 2) } ?? "à la main"
        return "\(event.scene ?? "") (\(score))"
    }

    /// A path inside the night's folder, written from it.
    static func relative(_ path: String, to batch: URL?) -> String {
        guard let batch, let range = path.range(of: "/\(batch.lastPathComponent)/", options: .backwards)
        else {
            return path
        }
        return String(path[range.upperBound...])
    }
}

/// `<night>/report.md`, rewritten at each phase end and at the end: how long the night took,
/// what it explored, picked, computed and delivered, and what went wrong. Built from
/// `night.json` and `events.jsonl` alone.
public enum NightReport {
    public static func markdown(
        _ night: NightFile, events: [RunEvent], batch: URL? = nil, now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let words = Words(now: now, timeZone: timeZone)
        func moment(_ date: Date) -> String { words.day(date) + " " + words.clock(date) }
        let state: String =
            switch night.state {
            case .running: "en cours"
            case .paused: "en pause"
            case .done: "terminée"
            case .failed: "en échec"
            case .stopped: "arrêtée"
            }
        let end = night.endedAt ?? now
        let found = NightEvents(events)
        let phases = Dictionary(uniqueKeysWithValues: night.phases.map { ($0.name, $0) })
        let planned = phases["hires"].map { " sur \($0.planned) prévues" } ?? ""
        let weight = found.videos.reduce(0) { $0 + ($1.megabytes ?? 0) }
        var lines = [
            "# Nuit du \(words.nightDate(night: night.id, file: night) ?? night.id)", "",
            "- État : \(state), de \(moment(night.startedAt)) à \(moment(end)) (\(Words.duration(end.timeIntervalSince(night.startedAt))))",
            "- Livraison : \(delivery(night, end: night.endedAt ?? night.estimatedEnd ?? now, words: words))",
            "- Aperçus : \(found.explored("ok")) explorés, \(found.explored("rejected")) rejetés, \(found.explored("failed")) en échec",
            "- Choisies : "
                + (found.picks.isEmpty
                    ? "aucune" : found.picks.map(NightEvents.pick).joined(separator: ", ")),
            "- Haute résolution : \(found.hires.count) faite\(found.hires.count > 1 ? "s" : "")\(planned)",
            "- Vidéos : \(found.videos.count)"
                + (found.videos.isEmpty ? "" : " (\(Words.size(megabytes: weight)))"),
            "- Laissées de côté : \(found.skipped.count) · erreurs : \(found.errors.count)",
        ]
        if !found.hires.isEmpty {
            lines += ["", "## Haute résolution", ""]
            lines += found.hires.map {
                "- \($0.scene ?? "") : \(Words.thousands($0.particles ?? 0)) particules en \(Int(($0.minutes ?? 0).rounded())) min"
            }
        }
        if !found.videos.isEmpty {
            lines += ["", "## Vidéos", ""]
            lines += found.videos.map {
                "- \(NightEvents.relative($0.path ?? "", to: batch)) (\(Words.size(megabytes: $0.megabytes ?? 0)))"
            }
        }
        if !found.skipped.isEmpty || !found.errors.isEmpty {
            lines += ["", "## Laissées de côté et échecs", ""]
            lines += found.skipped.map {
                "- \($0.scene ?? ""), \(QueueStatus.phaseLabel($0.stage ?? "")) : \($0.message ?? "")"
            }
            lines += found.errors.map {
                "- \($0.scene ?? night.id), \(QueueStatus.phaseLabel($0.stage ?? "")) : \($0.message ?? "")"
                    + ($0.log.map { " (journal : \(NightEvents.relative($0, to: batch)))" } ?? "")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Against the delivery time: "avant 7 h 00, terminée 19 min avant", or "pas d'heure fixée".
    static func delivery(_ night: NightFile, end: Date, words: Words) -> String {
        guard let deadline = night.deliverBy else { return "pas d'heure fixée" }
        let gap = deadline.timeIntervalSince(end)
        let by = "avant \(words.clock(deadline))"
        let finished = night.endedAt != nil
        if abs(gap) < 60 { return finished ? "\(by), à l'heure" : by }
        let early = gap > 0
        let when = Words.duration(abs(gap))
        if finished {
            let ended = night.state == .done ? "terminée" : "arrêtée"
            return early ? "\(by), \(ended) \(when) avant" : "\(by), \(ended) avec \(when) de retard"
        }
        return early ? "\(by), \(when) de marge" : "\(by), \(when) de retard"
    }
}
