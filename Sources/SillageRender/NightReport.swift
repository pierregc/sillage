import Foundation

/// The events of a night sorted by what they say, shared by the report, the status digest and
/// the night page. Only what the night's own runs wrote counts.
struct NightEvents {
    /// The night's own events, in order.
    let events: [RunEvent]
    let explored: [RunEvent]
    let picks: [RunEvent]
    let hires: [RunEvent]
    let videos: [RunEvent]
    let skipped: [RunEvent]
    let errors: [RunEvent]

    /// `end` is the night's `endedAt`.
    init(_ all: [RunEvent], end: Date?) {
        let events = Self.own(all, end: end)
        func of(_ kind: String) -> [RunEvent] { events.filter { $0.kind == kind } }
        self.events = events
        explored = of(RunEvent.Kind.exploreScene)
        picks = of(RunEvent.Kind.pick).filter { $0.chosen != false }
        hires = of(RunEvent.Kind.hiresDone)
        videos = of(RunEvent.Kind.exportDone)
        skipped = Self.standingSkips(events)
        errors = of(RunEvent.Kind.error)
    }

    func explored(_ status: String) -> Int { explored.filter { $0.status == status }.count }

    /// What the night's runs wrote. A stage run in the folder after a run's `night.done`, by
    /// hand or from the queue, is the scene's and not the night's, until the night starts
    /// again; so is one after `end`, for a last run killed before it could write its
    /// `night.done`. The queue's error about the night itself comes after its end and is the
    /// night's.
    static func own(_ events: [RunEvent], end: Date?) -> [RunEvent] {
        var over = false
        return events.filter { event in
            switch event.kind {
            case RunEvent.Kind.nightStart: over = false
            case RunEvent.Kind.nightDone: over = true
            default:
                let after = over || end.map { event.t > $0 } == true
                return !after || event.stage == "night"
            }
            return true
        }
    }

    /// The skips that still hold. A night resumed in the same folder tries again what an earlier
    /// run left out, and a stage run by hand while it runs may do it: a skip holds in its own
    /// run, until a later done of the same scene and stage.
    static func standingSkips(_ events: [RunEvent]) -> [RunEvent] {
        let run = events.lastIndex { $0.kind == RunEvent.Kind.nightStart } ?? events.startIndex
        return events.indices.filter { index in
            let skip = events[index]
            guard index >= run, skip.kind == RunEvent.Kind.skip else { return false }
            let done = doneKind(skip.stage)
            return !events[(index + 1)...].contains { $0.kind == done && $0.scene == skip.scene }
        }.map { events[$0] }
    }

    /// The event that says a stage of a scene is done.
    static func doneKind(_ stage: String?) -> String? {
        switch stage {
        case "hires": RunEvent.Kind.hiresDone
        case "style": RunEvent.Kind.style
        case "export": RunEvent.Kind.exportDone
        default: nil
        }
    }

    /// "scene-0023 (0.91)", or "scene-0023 (by hand)" for a scene picked by hand.
    static func pick(_ event: RunEvent) -> String {
        let score = event.score.map { Words.decimal($0, digits: 2) } ?? "by hand"
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
            case .running: "running"
            case .paused: "paused"
            case .done: "finished"
            case .failed: "failed"
            case .stopped: "stopped"
            }
        let end = night.endedAt ?? now
        let found = NightEvents(events, end: night.endedAt)
        let phases = Dictionary(uniqueKeysWithValues: night.phases.map { ($0.name, $0) })
        let planned = phases["hires"].map { " of \($0.planned) planned" } ?? ""
        let weight = found.videos.reduce(0) { $0 + ($1.megabytes ?? 0) }
        var lines = [
            "# Night of \(words.nightDate(night: night.id, file: night) ?? night.id)", "",
            "- State: \(state), from \(moment(night.startedAt)) to \(moment(end)) (\(Words.duration(end.timeIntervalSince(night.startedAt))))",
            "- Delivery: \(delivery(night, end: night.endedAt ?? night.estimatedEnd ?? now, words: words))",
            "- Previews: \(found.explored("ok")) explored, \(found.explored("rejected")) rejected, \(found.explored("failed")) failed",
            "- Kept: "
                + (found.picks.isEmpty
                    ? "none" : found.picks.map(NightEvents.pick).joined(separator: ", ")),
            "- High resolution: \(found.hires.count) done\(planned)",
            "- Videos: \(found.videos.count)"
                + (found.videos.isEmpty ? "" : " (\(Words.size(megabytes: weight)))"),
            "- Left out: \(found.skipped.count) · errors: \(found.errors.count)",
        ]
        if !found.hires.isEmpty {
            lines += ["", "## High resolution", ""]
            lines += found.hires.map {
                let particles = Words.thousands($0.particles ?? 0) + " particles"
                let massive = $0.massive.map { " (\(Words.thousands($0)) massive)" } ?? ""
                let minutes = Int(($0.minutes ?? 0).rounded())
                return "- \($0.scene ?? ""): \(particles)\(massive) in \(minutes) min"
            }
        }
        if !found.videos.isEmpty {
            lines += ["", "## Videos", ""]
            lines += found.videos.map {
                "- \(NightEvents.relative($0.path ?? "", to: batch)) (\(Words.size(megabytes: $0.megabytes ?? 0)))"
            }
        }
        if !found.skipped.isEmpty || !found.errors.isEmpty {
            lines += ["", "## Left out and failed", ""]
            lines += found.skipped.map {
                "- \($0.scene ?? ""), \(QueueStatus.phaseLabel($0.stage ?? "")): \($0.message ?? "")"
            }
            lines += found.errors.map {
                "- \($0.scene ?? night.id), \(QueueStatus.phaseLabel($0.stage ?? "")): \($0.message ?? "")"
                    + ($0.log.map { " (log: \(NightEvents.relative($0, to: batch)))" } ?? "")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Against the delivery time: "by 07:00, finished 19 min early", or "no time set".
    static func delivery(_ night: NightFile, end: Date, words: Words) -> String {
        guard let deadline = night.deliverBy else { return "no time set" }
        let gap = deadline.timeIntervalSince(end)
        let by = "by \(words.clock(deadline))"
        let finished = night.endedAt != nil
        if abs(gap) < 60 { return finished ? "\(by), on time" : by }
        let early = gap > 0
        let when = Words.duration(abs(gap))
        if finished {
            let ended = night.state == .done ? "finished" : "stopped"
            return early ? "\(by), \(ended) \(when) early" : "\(by), \(ended) \(when) late"
        }
        return early ? "\(by), \(when) to spare" : "\(by), \(when) late"
    }
}
