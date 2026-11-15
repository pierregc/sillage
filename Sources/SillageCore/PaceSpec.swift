import Foundation

/// What `export --speed` and `pace` are asked for besides a speed or a track file (#309):
/// `story`, `story:<pace>`, `story:<pace>:<top>` or `visual`, `visual:<top>`,
/// `visual:<top>:<busiest>`.
public enum PaceSpec: Sendable, Equatable {
    case story(StoryPace.Settings)
    case visual(VisualPace.Settings)

    public init?(_ text: String) {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var metric = VisualPace.Metric.lit
        // `visual-all`, `visual-moving`: the measure the speed follows.
        if parts[0].hasPrefix("visual-"),
            let named = VisualPace.Metric(rawValue: String(parts[0].dropFirst(7)))
        {
            metric = named
            parts[0] = "visual"
        }
        let numbers = parts.dropFirst().map { Double($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! > 0 }), numbers.count <= 2 else { return nil }
        let values = numbers.compactMap { $0 }
        switch parts[0] {
        case "story":
            var settings = StoryPace.Settings()
            if values.count > 0 { settings.pace = values[0] }
            if values.count > 1 { settings.top = values[1] }
            guard settings.top >= 1 else { return nil }
            self = .story(settings)
        case "visual":
            var settings = VisualPace.Settings(metric: metric)
            if values.count > 0 { settings.top = values[0] }
            if values.count > 1 { settings.busiest = values[1] }
            guard settings.top >= 1, settings.busiest <= 1 else { return nil }
            self = .visual(settings)
        default:
            return nil
        }
    }

    /// `speeds` held to at most `speed` from `from` to `to` Myr: a stretch the pace would play
    /// faster is slowed, one it plays slower is left. The ramp of the track does the rest.
    public static func slowed(
        _ speeds: [Double], megayears: [Double], from: Double, to: Double, speed: Double
    ) -> [Double] {
        zip(speeds, megayears).map { $0.1 >= from && $0.1 <= to ? min($0.0, speed) : $0.0 }
    }
}
