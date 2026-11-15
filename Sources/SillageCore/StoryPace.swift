import Foundation

#if canImport(simd)
    import simd
#endif

/// How fast a take can be played, read off the curves a run writes (#309): where a pair is
/// engaged or stars are forming in a burst the video keeps its pace, and elsewhere it speeds up
/// as the tails, the extent and the disruption stop changing, by `Story`'s own thresholds.
/// Unlike `Story`, which follows a run frame by frame, the pace may look ahead: the whole take
/// is known before the video is drawn.
public struct StoryPace: Sendable {
    public struct Settings: Sendable, Equatable {
        /// An activity of this many thresholds, the largest change of tails, extent or
        /// disruption over the window in `Story`'s thresholds, plays at 1x, and a quarter of it
        /// at four times that speed.
        public var pace = 4.0
        /// The fastest the pace goes, in captured frames per video frame.
        public var top = 8.0
        /// The span, in Myr, around a frame the change is measured over: `Story`'s window.
        public var window = Story.Settings().window
        /// Star formation this many times its level before the story plays at 1x, measured over
        /// `burstWindow` Myr around the frame.
        public var burst = 2.0
        public var burstWindow = 50.0
        /// Centres that stay this close, in kpc, to the end of the take have merged: a pair whose
        /// debris is still settling is no longer engaged, whatever `Story` would still wait for.
        public var merged = 10.0

        public init(pace: Double = 4, top: Double = 8) {
            self.pace = pace
            self.top = top
        }
    }

    /// What the curves say, whatever the pace asked of them.
    public struct Trace: Sendable, Equatable {
        /// The curves' samples.
        public var timeMyr: [Double]
        /// The largest of the three changes in thresholds, 1 being the edge of quiet.
        public var activity: [Double]
        /// Each change on its own, in thresholds.
        public var tails: [Double]
        public var extent: [Double]
        public var disruption: [Double]
        /// A pair is engaged, or stars form in a burst: the frame plays at 1x.
        public var held: [Bool]
        /// The first pass of any pair inside its reach, and the last moment a pair was engaged.
        public var firstPassMyr: Double?
        public var engagedUntilMyr: Double?
    }

    public let story: Story
    public let settings: Settings

    public init(story: Story, settings: Settings = Settings()) {
        self.story = story
        self.settings = settings
    }

    /// The speed of a frame whose activity is `activity` thresholds.
    public func speed(activity: Double, held: Bool, settings: Settings? = nil) -> Double {
        let settings = settings ?? self.settings
        if held { return 1 }
        return min(max(settings.pace / max(activity, 1e-6), 1), settings.top)
    }

    public func trace(_ samples: [Story.Sample]) -> Trace {
        let times = samples.map(\.timeMyr)
        let count = samples.count
        var trace = Trace(
            timeMyr: times, activity: [], tails: [], extent: [], disruption: [],
            held: [Bool](repeating: false, count: count))
        guard count > 1 else {
            trace.activity = [Double](repeating: 0, count: count)
            trace.tails = trace.activity
            trace.extent = trace.activity
            trace.disruption = trace.activity
            return trace
        }
        let approach = story.firstApproach(samples)
        trace.firstPassMyr = approach?.timeMyr
        // The last moment a pair was inside its reach and moving as two bodies, as `Tracker`
        // follows it; everything before is the approach and the passes, which play as they are.
        var engaged: Double?
        for index in samples.indices where story.reading(samples, at: index).engaged {
            engaged = times[index]
        }
        if let storyEnd = engaged, let merge = mergeMoment(samples) { engaged = min(storyEnd, merge) }
        trace.engagedUntilMyr = engaged

        let thresholds = story.settings
        let tails = samples.map(\.tails)
        let extents = samples.map(\.extent)
        let galaxies = samples.map(\.disruption.count).max() ?? 0
        let disruption = (0..<galaxies).map { galaxy in
            samples.map { galaxy < $0.disruption.count ? $0.disruption[galaxy] : 0 }
        }
        let limits = Self.pairLimits(story, galaxies: samples.first?.centres.count ?? 0)

        for index in samples.indices {
            let span = window(around: times[index], in: times, width: settings.window)
            let tail = Self.range(tails, span) / thresholds.tails
            // Galaxies parting stretch the extent for as long as they move, whatever the stars
            // do: `Story` counts it only while the pair is within its reach, and so does this.
            let together = limits.allSatisfy {
                simd_distance(samples[index].centres[$0.i], samples[index].centres[$0.j]) < $0.limit
            }
            let high = extents[span].max() ?? 0
            let extent = together && high > 0 ? Self.range(extents, span) / high / thresholds.extent : 0
            let disrupted =
                disruption.map { Self.range($0, span) }.max().map { $0 / thresholds.disruption } ?? 0
            trace.tails.append(tail)
            trace.extent.append(extent)
            trace.disruption.append(disrupted)
            trace.activity.append(max(tail, extent, disrupted))
        }

        // Star formation before the story is the quiet level a burst is judged against.
        let start =
            approach.flatMap { approach in times.firstIndex { $0 >= approach.timeMyr - thresholds.lead } }
            ?? 0
        let rates = samples.indices.map { index in
            samples[index].formed
                / max(times[index == 0 ? 1 : index] - times[index == 0 ? 0 : index - 1], 1e-9)
        }
        let quiet = Self.median(Array(rates[0..<min(max(start, 20), count)]))
        for index in samples.indices {
            let span = window(around: times[index], in: times, width: settings.burstWindow, shifted: false)
            let mean = rates[span].reduce(0, +) / Double(max(span.count, 1))
            let bursting = mean / (quiet > 0 ? quiet : 1) > settings.burst
            trace.held[index] = bursting || (engaged.map { times[index] <= $0 } ?? false)
        }
        return trace
    }

    /// The moment every pair that came within its reach stays within `merged` kpc to the end of
    /// the take, nil if one of them does not: `Story` waits for the nuclei to settle as two
    /// bodies, which a viewer takes for a remnant long before.
    func mergeMoment(_ samples: [Story.Sample]) -> Double? {
        guard let last = samples.last else { return nil }
        var moment: Double?
        for pair in Self.pairLimits(story, galaxies: last.centres.count) {
            let distances = samples.map { simd_distance($0.centres[pair.i], $0.centres[pair.j]) }
            guard distances.contains(where: { $0 < pair.limit }) else { continue }
            guard let apart = distances.lastIndex(where: { $0 >= settings.merged }) else {
                moment = max(moment ?? 0, samples[0].timeMyr)
                continue
            }
            guard apart + 1 < samples.count else { return nil }
            moment = max(moment ?? 0, samples[apart + 1].timeMyr)
        }
        return moment
    }

    /// One speed for each of the moments `megayears`, the captured frames of a take: each curve
    /// sample's speed, geometric between samples and held at either end.
    public func speeds(_ trace: Trace, atMyr megayears: [Double], settings: Settings? = nil) -> [Double] {
        let each = trace.activity.indices.map {
            speed(activity: trace.activity[$0], held: trace.held[$0], settings: settings)
        }
        return Self.interpolated(each, at: trace.timeMyr, for: megayears)
    }

    /// Log-linear interpolation of `values`, given at the increasing `times`, at `moments`.
    static func interpolated(_ values: [Double], at times: [Double], for moments: [Double]) -> [Double] {
        guard let first = values.first, let last = values.last else { return moments.map { _ in 1 } }
        var low = 0
        return moments.map { moment in
            if moment <= times[0] { return first }
            if moment >= times[times.count - 1] { return last }
            while low + 1 < times.count - 1, times[low + 1] <= moment { low += 1 }
            while low > 0, times[low] > moment { low -= 1 }
            let along = (moment - times[low]) / max(times[low + 1] - times[low], 1e-12)
            return values[low] * pow(values[low + 1] / values[low], along)
        }
    }

    struct PairLimit {
        var i: Int
        var j: Int
        var limit: Double
    }

    static func pairLimits(_ story: Story, galaxies: Int) -> [PairLimit] {
        let count = min(galaxies, story.profiles.count)
        return (0..<count).flatMap { i in
            ((i + 1)..<count).map { PairLimit(i: i, j: $0, limit: story.limit(i, $0)) }
        }
    }

    /// The indices of the samples within `width` Myr of `time`, centred on it; at either end of
    /// the take the window slides inwards rather than shrinking, so the last frames are judged
    /// on a full window instead of on a sliver that looks quiet.
    func window(around time: Double, in times: [Double], width: Double, shifted: Bool = true)
        -> Range<Int>
    {
        var low = time - width / 2
        var high = time + width / 2
        if shifted, let first = times.first, let last = times.last {
            if low < first {
                high = min(last, high + first - low)
                low = first
            }
            if high > last {
                low = max(first, low - (high - last))
                high = last
            }
        }
        var start = 0
        var end = times.count
        var (a, b) = (0, times.count)
        while a < b {
            let middle = (a + b) / 2
            if times[middle] < low { a = middle + 1 } else { b = middle }
        }
        start = a
        (a, b) = (start, times.count)
        while a < b {
            let middle = (a + b) / 2
            if times[middle] <= high { a = middle + 1 } else { b = middle }
        }
        end = a
        return start..<max(end, start + 1)
    }

    static func range(_ values: [Double], _ span: Range<Int>) -> Double {
        guard let low = values[span].min(), let high = values[span].max() else { return 0 }
        return high - low
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
