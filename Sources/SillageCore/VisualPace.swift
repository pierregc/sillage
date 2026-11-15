import Foundation

/// A pace read off the pictures (#309): the take drawn small with the export's camera, the
/// change of the log luminance between frames a megayear apart, and the speed that keeps the
/// change per second of video near a constant, as constant pace skimming does for film.
public struct VisualPace: Sendable {
    public struct Settings: Sendable, Equatable {
        /// The fastest the pace goes, in captured frames per video frame.
        public var top = 8.0
        /// The share of the frames, the busiest ones, that play at 1x: the change per video frame
        /// held constant is the one the frame at this rank has at 1x.
        public var busiest = 0.25
        /// The change is averaged over this many Myr around a frame, which keeps the grain of a
        /// small drawing out of the speed.
        public var smoothing = 15.0
        /// Which measure of the change the speed follows.
        public var metric = Metric.lit

        public init(top: Double = 8, busiest: Double = 0.25, metric: Metric = .lit) {
            self.top = top
            self.busiest = busiest
            self.metric = metric
        }
    }

    /// Luminances below this, relative to white, are the sky: the logarithm of a pixel that dark
    /// would only show the noise of the drawing.
    static let floor = 0.01

    /// How much two RGBA frames of one size differ, measured three ways on the log luminance.
    public struct Change: Sendable, Equatable {
        /// Mean absolute change over every pixel.
        public var all = 0.0
        /// The same over the pixels lit in either frame: the sky does not dilute it.
        public var lit = 0.0
        /// The share of pixels whose log luminance moves by more than `moved`.
        public var moving = 0.0

        public init(all: Double = 0, lit: Double = 0, moving: Double = 0) {
            self.all = all
            self.lit = lit
            self.moving = moving
        }

        public func value(_ metric: Metric) -> Double {
            switch metric {
            case .all: all
            case .lit: lit
            case .moving: moving
            }
        }
    }

    public enum Metric: String, Sendable, CaseIterable {
        case all, lit, moving
    }

    /// A pixel is lit above this luminance, relative to white, and moves by more than this change
    /// of its log luminance.
    static let lit = 0.02
    static let moved = 0.05

    public static func change(_ a: [UInt8], _ b: [UInt8]) -> Change {
        let pixels = min(a.count, b.count) / 4
        guard pixels > 0 else { return Change() }
        var (all, lit, litCount, moving) = (0.0, 0.0, 0.0, 0.0)
        for pixel in 0..<pixels {
            let (x, y) = (luminance(a, pixel), luminance(b, pixel))
            let difference = abs(log(x + floor) - log(y + floor))
            all += difference
            if max(x, y) > Self.lit {
                lit += difference
                litCount += 1
            }
            if difference > moved { moving += 1 }
        }
        return Change(
            all: all / Double(pixels), lit: litCount > 0 ? lit / litCount : 0,
            moving: moving / Double(pixels))
    }

    static func luminance(_ rgba: [UInt8], _ pixel: Int) -> Double {
        let at = pixel * 4
        let r = linear(rgba[at])
        let g = linear(rgba[at + 1])
        let b = linear(rgba[at + 2])
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func linear(_ byte: UInt8) -> Double { pow(Double(byte) / 255, 2.2) }

    public let settings: Settings

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// `changes[i]` is the change between the drawings at `times[i]` and `times[i + 1]`. One speed
    /// for each of the moments `megayears`, the captured frames of a take.
    public func speeds(changes: [Double], times: [Double], megayears: [Double]) -> [Double] {
        guard times.count == changes.count + 1, changes.count > 0, megayears.count > 1 else {
            return megayears.map { _ in 1 }
        }
        // Change per Myr, at the middle of each interval.
        let middles = changes.indices.map { (times[$0] + times[$0 + 1]) / 2 }
        let rates = changes.indices.map { changes[$0] / max(times[$0 + 1] - times[$0], 1e-9) }
        let smooth = middles.indices.map { index -> Double in
            var sum = 0.0
            var count = 0.0
            var other = index
            while other >= 0, middles[index] - middles[other] <= settings.smoothing / 2 {
                sum += rates[other]
                count += 1
                other -= 1
            }
            other = index + 1
            while other < middles.count, middles[other] - middles[index] <= settings.smoothing / 2 {
                sum += rates[other]
                count += 1
                other += 1
            }
            return sum / count
        }
        let perFrame = megayears.indices.map { frame -> Double in
            let step =
                frame + 1 < megayears.count
                ? megayears[frame + 1] - megayears[frame] : megayears[frame] - megayears[frame - 1]
            return Self.value(smooth, at: middles, for: megayears[frame]) * step
        }
        let ranked = perFrame.sorted()
        let rank = min(max(Int((1 - settings.busiest) * Double(ranked.count)), 0), ranked.count - 1)
        let target = max(ranked[rank], 1e-9)
        return perFrame.map { min(max(target / max($0, 1e-12), 1), settings.top) }
    }

    /// Linear interpolation of `values` at the increasing `times`, held at either end.
    static func value(_ values: [Double], at times: [Double], for moment: Double) -> Double {
        if moment <= times[0] { return values[0] }
        if moment >= times[times.count - 1] { return values[values.count - 1] }
        var (low, high) = (0, times.count - 1)
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= moment { low = middle } else { high = middle }
        }
        let along = (moment - times[low]) / max(times[high] - times[low], 1e-12)
        return values[low] + (values[high] - values[low]) * along
    }
}
