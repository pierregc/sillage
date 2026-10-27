import Foundation

/// `<night>/report.md`, rewritten at each phase end and at the end: a first version, built
/// from `night.json` and `events.jsonl` alone, until the morning report of #105.
public enum NightReport {
    public static func markdown(
        _ night: NightFile, events: [RunEvent], timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM HH:mm"
        func minutes(_ seconds: Double) -> String {
            let total = Int((seconds / 60).rounded())
            return total >= 60 ? String(format: "%d h %02d", total / 60, total % 60) : "\(total) min"
        }
        let state: String =
            switch night.state {
            case .running: "en cours"
            case .paused: "en pause"
            case .done: "terminée"
            case .failed: "en échec"
            case .stopped: "arrêtée"
            }
        let end = night.endedAt ?? Date()
        let explored = events.filter { $0.kind == RunEvent.Kind.exploreScene }
        let picks = events.filter { $0.kind == RunEvent.Kind.pick }
        let hires = events.filter { $0.kind == RunEvent.Kind.hiresDone }
        let videos = events.filter { $0.kind == RunEvent.Kind.exportDone }
        let skipped = events.filter { $0.kind == RunEvent.Kind.skip }
        let errors = events.filter { $0.kind == RunEvent.Kind.error }
        var lines = [
            "# Nuit \(night.id)", "",
            "- État : \(state), du \(formatter.string(from: night.startedAt)) au \(formatter.string(from: end)) (\(minutes(end.timeIntervalSince(night.startedAt))))",
            "- Aperçus : \(explored.filter { $0.status == "ok" }.count) explorés, \(explored.filter { $0.status == "rejected" }.count) rejetés, \(explored.filter { $0.status == "failed" }.count) en échec",
            "- Choisies : "
                + (picks.isEmpty
                    ? "aucune"
                    : picks.map { String(format: "%@ (%.2f)", $0.scene ?? "", $0.score ?? 0) }.joined(separator: ", ")),
            "- Haute résolution : \(hires.count) faites",
            "- Vidéos : \(videos.count)",
            "- Laissées de côté : \(skipped.count) · erreurs : \(errors.count)",
        ]
        if !hires.isEmpty {
            lines += ["", "## Haute résolution", ""]
            lines += hires.map {
                String(format: "- %@ : %d particules en %.0f min", $0.scene ?? "", $0.particles ?? 0, $0.minutes ?? 0)
            }
        }
        if !videos.isEmpty {
            lines += ["", "## Vidéos", ""]
            lines += videos.map { String(format: "- %@ (%.1f Mo)", $0.path ?? "", $0.megabytes ?? 0) }
        }
        if !skipped.isEmpty || !errors.isEmpty {
            lines += ["", "## Laissées de côté et erreurs", ""]
            lines += skipped.map { "- \($0.scene ?? "") à l'étape \($0.stage ?? "") : \($0.message ?? "")" }
            lines += errors.map {
                "- \($0.scene ?? night.id), \($0.stage ?? "") : \($0.message ?? "")"
                    + ($0.log.map { " (\($0))" } ?? "")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
