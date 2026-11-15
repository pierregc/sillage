import Foundation
import SillageCore

/// A monotone map from the video's time to the take's (#305): its slope is the speed, in
/// captured frames per video frame at the captured rate, 1 being one captured frame per frame
/// as every export played before. Written as speed keys at moments of the take, as a speed for
/// every captured frame, or as #295's keys of video seconds and megayears; integrated once, so
/// any frame of any video asks it where in the take it is. It never runs backwards.
///
/// The video's time is counted in played frames: seconds of video times the captured rate, so
/// that without a track a played position is the captured position itself and the cameras,
/// which move in the video's time, keep the clock they always had.
public struct TimeTrack: Sendable, Equatable {
    /// From the moment `myr` of the take on, play at `speed`.
    public struct SpeedKey: Codable, Sendable, Equatable {
        public var myr: Double
        public var speed: Double

        public init(myr: Double, speed: Double) {
            self.myr = myr
            self.speed = speed
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                myr: try c.decode(Double.self, forKey: .myr),
                speed: try c.decode(Double.self, forKey: .speed))
        }
    }

    /// At `at` seconds into the video, the take is at `myr`: a flight's time (#295).
    public struct TimeKey: Codable, Sendable, Equatable {
        public var at: Double
        public var myr: Double

        public init(at: Double, myr: Double) {
            self.at = at
            self.myr = myr
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                at: try c.decode(Double.self, forKey: .at),
                myr: try c.decode(Double.self, forKey: .myr))
        }
    }

    /// One frame of a video: where it is in the video's time and in the take.
    public struct Frame: Sendable, Equatable {
        /// Seconds into the whole take's video times the captured rate.
        public var played: Double
        /// Fractional between captured frames.
        public var captured: Double

        public init(played: Double, captured: Double) {
            self.played = played
            self.captured = captured
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case speed(Double)
        case ramp(Double)
        case outsideTake(myr: Double, first: Double, last: Double)
        case order(String)
        case frames(given: Int, take: Int)
        case tooFewKeys

        public var description: String {
            switch self {
            case .speed(let speed):
                "speed \(speed) is outside \(TimeTrack.speeds.lowerBound) to \(TimeTrack.speeds.upperBound)"
            case .ramp(let ramp): "ramp \(ramp) s: it takes zero or more seconds"
            case .outsideTake(let myr, let first, let last):
                String(
                    format: "%g Myr is outside the take, which runs from %.3f to %.3f Myr", myr,
                    first, last)
            case .order(let detail): detail
            case .frames(let given, let take):
                "\(given) speeds for a take of \(take) captured frames"
            case .tooFewKeys: "a track of times needs two keys at least"
            }
        }
    }

    /// The speeds a track may take: slower draws between captured frames, faster skips them.
    public static let speeds: ClosedRange<Double> = 0.25...16
    /// Seconds of video over which a speed may double or halve, at most.
    public static let defaultRamp = 3.0

    public let capturedFrames: Int
    public let capturedRate: Int
    /// The whole take's video, in played frames.
    public let length: Double
    private let shape: Shape

    private enum Shape: Sendable, Equatable {
        /// Every export before #305.
        case identity
        /// A speed at each captured frame, geometric between, and the played position each
        /// captured frame is reached at.
        case speeds(speed: [Double], played: [Double])
        /// Captured positions at played ones, on a monotone cubic.
        case cubic(played: [Double], captured: [Double], slope: [Double])
    }

    private init(capturedFrames: Int, capturedRate: Int, shape: Shape, length: Double) {
        self.capturedFrames = capturedFrames
        self.capturedRate = max(capturedRate, 1)
        self.shape = shape
        self.length = length
    }

    /// The whole take at one speed.
    public init(capturedFrames: Int, capturedRate: Int, speed: Double = 1) throws {
        guard Self.speeds.contains(speed) else { throw Failure.speed(speed) }
        if speed == 1 {
            let frames = max(capturedFrames, 1)
            self.init(
                capturedFrames: frames, capturedRate: capturedRate, shape: .identity,
                length: Double(frames - 1))
        } else {
            try self.init(
                speeds: Array(repeating: speed, count: max(capturedFrames, 1)),
                capturedRate: capturedRate, ramp: 0)
        }
    }

    /// One speed for each captured frame, held to the ramp.
    public init(speeds: [Double], capturedRate: Int, ramp: Double = defaultRamp) throws {
        guard !speeds.isEmpty else { throw Failure.frames(given: 0, take: 0) }
        if let wrong = speeds.first(where: { !Self.speeds.contains($0) }) {
            throw Failure.speed(wrong)
        }
        guard ramp >= 0, ramp.isFinite else { throw Failure.ramp(ramp) }
        let rate = max(capturedRate, 1)
        let held = ramp > 0 ? Self.ramped(speeds, ramp: ramp, rate: Double(rate)) : speeds
        var played = [0.0]
        played.reserveCapacity(held.count)
        for index in held.indices.dropFirst() {
            played.append(played[index - 1] + Self.duration(held[index - 1], held[index]))
        }
        self.init(
            capturedFrames: held.count, capturedRate: rate, shape: .speeds(speed: held, played: played),
            length: played[played.count - 1])
    }

    /// Speed keys at moments of the take, each held until the next and the first from the
    /// take's start, ramped so that a slower stretch is already at its speed when it begins
    /// and a faster one picks up after it starts. `megayears` is the moment of each captured
    /// frame (`megayears(of:)`).
    public init(
        keys: [SpeedKey], megayears: [Double], capturedRate: Int, ramp: Double = defaultRamp
    ) throws {
        guard let first = keys.first else { throw Failure.tooFewKeys }
        var positions: [Double] = []
        for key in keys {
            guard Self.speeds.contains(key.speed) else { throw Failure.speed(key.speed) }
            let position = try Self.position(of: key.myr, in: megayears)
            if let last = positions.last, position <= last {
                throw Failure.order("speed keys go forward in time: \(key.myr) Myr comes too late")
            }
            positions.append(position)
        }
        // A frame takes the slowest key on either side of it, so the stretch between two
        // captured frames where a key starts or ends is played at the slower of the two.
        let targets = megayears.indices.map { frame in
            keys.indices.filter { key in
                (key == 0 || positions[key] < Double(frame) + 1)
                    && (key + 1 == keys.count || positions[key + 1] > Double(frame) - 1)
            }.map { keys[$0].speed }.min() ?? first.speed
        }
        try self.init(speeds: targets, capturedRate: capturedRate, ramp: ramp)
    }

    /// #295's keys: the take's moment at seconds of the video, on a monotone cubic (Fritsch and
    /// Carlson) that slows into two keys of the same moment, holds between them and picks up
    /// after. The video lasts to the last key, and holds the first key's moment before it.
    public init(times: [TimeKey], megayears: [Double], capturedRate: Int) throws {
        guard times.count >= 2 else { throw Failure.tooFewKeys }
        let rate = Double(max(capturedRate, 1))
        var played: [Double] = []
        var captured: [Double] = []
        for key in times {
            guard key.at >= 0, key.at.isFinite else {
                throw Failure.order("a key at \(key.at) s is before the video starts")
            }
            let position = try Self.position(of: key.myr, in: megayears)
            if let last = played.last, key.at * rate <= last {
                throw Failure.order("time keys go forward in the video: \(key.at) s comes too late")
            }
            if let last = captured.last, position < last {
                throw Failure.order("time never runs backwards: \(key.myr) Myr at \(key.at) s")
            }
            played.append(key.at * rate)
            captured.append(position)
        }
        self.init(
            capturedFrames: megayears.count, capturedRate: capturedRate,
            shape: .cubic(
                played: played, captured: captured, slope: Self.monotoneSlopes(x: played, y: captured)),
            length: played[played.count - 1])
    }

    /// Exactly what every export played before: one captured frame per played one.
    public var isIdentity: Bool {
        switch shape {
        case .identity: true
        case .speeds(let speed, _): speed.allSatisfy { $0 == 1 }
        case .cubic: false
        }
    }

    public var seconds: Double { length / Double(capturedRate) }

    /// Where in the take the video is at a played position, held at either end.
    public func captured(atPlayed position: Double) -> Double {
        switch shape {
        case .identity:
            return position
        case .speeds(let speed, let played):
            let u = min(max(position, 0), length)
            let index = Self.interval(of: u, in: played)
            guard index + 1 < played.count else { return Double(played.count - 1) }
            let (a, b) = (speed[index], speed[index + 1])
            let into = u - played[index]
            var along: Double
            if a == b {
                along = into * a
            } else {
                let x = log(b / a)
                along = -log(max(1 - into * a * x, 1e-300)) / x
            }
            along = min(max(along, 0), 1)
            return Double(index) + along
        case .cubic(let played, let captured, let slope):
            if position <= played[0] { return captured[0] }
            if position >= length { return captured[captured.count - 1] }
            let index = Self.interval(of: position, in: played)
            let h = played[index + 1] - played[index]
            let t = (position - played[index]) / h
            let t2 = t * t
            let t3 = t2 * t
            let value =
                (2 * t3 - 3 * t2 + 1) * captured[index] + (t3 - 2 * t2 + t) * h * slope[index]
                + (-2 * t3 + 3 * t2) * captured[index + 1] + (t3 - t2) * h * slope[index + 1]
            return min(max(value, captured[index]), captured[index + 1])
        }
    }

    /// The played position the video first reaches a captured one at.
    public func played(atCaptured position: Double) -> Double {
        switch shape {
        case .identity:
            return position
        case .speeds(let speed, let played):
            let p = min(max(position, 0), Double(played.count - 1))
            let index = min(Int(p), played.count - 1)
            guard index + 1 < played.count else { return length }
            let (a, b) = (speed[index], speed[index + 1])
            let along = p - Double(index)
            if a == b { return played[index] + along / a }
            let x = log(b / a)
            return played[index] + (1 - exp(-x * along)) / (a * x)
        case .cubic(let played, let captured, _):
            if position <= captured[0] { return played[0] }
            if position >= captured[captured.count - 1] {
                return played[captured.firstIndex { $0 >= position } ?? played.count - 1]
            }
            var (low, high) = (played[0], length)
            for _ in 0..<64 {
                let middle = (low + high) / 2
                if self.captured(atPlayed: middle) < position { low = middle } else { high = middle }
            }
            return high
        }
    }

    /// Captured frames per played frame at a played position: zero in a freeze.
    public func speed(atPlayed position: Double) -> Double {
        switch shape {
        case .identity:
            return 1
        case .speeds(let speed, _):
            let p = captured(atPlayed: position)
            let index = min(Int(p), speed.count - 1)
            guard index + 1 < speed.count else { return speed[index] }
            return speed[index] * pow(speed[index + 1] / speed[index], p - Double(index))
        case .cubic(let played, _, _):
            guard position > played[0], position < length else { return 0 }
            let step = 1e-4
            return (captured(atPlayed: position + step) - captured(atPlayed: position - step))
                / (2 * step)
        }
    }

    /// Every frame a video at `framesPerSecond` shows from `start` for `duration` seconds of
    /// video, cut at the end of the take. Without a track, the frames every export drew.
    public func frames(framesPerSecond: Int, start: Double = 0, duration: Double? = nil) -> [Frame] {
        let rate = Double(capturedRate)
        let last = length
        let first = min(max(start, 0) * rate, last)
        let step = rate / Double(max(framesPerSecond, 1))
        let span = min(duration.map { max($0, 0) * rate } ?? last, last - first)
        let count = duration.map { max(Int(($0 * Double(framesPerSecond)).rounded()), 1) }
        let fitting = Int((span / step + 1e-9).rounded(.down)) + 1
        return (0..<min(count ?? fitting, fitting)).map {
            let played = first + Double($0) * step
            return Frame(played: played, captured: captured(atPlayed: played))
        }
    }

    /// The captured position of every frame of the whole take's video at `framesPerSecond`.
    public func table(framesPerSecond: Int) -> [Double] {
        frames(framesPerSecond: framesPerSecond).map(\.captured)
    }

    // MARK: Building

    /// The moment of each captured frame of a take, in megayears.
    public static func megayears(of recording: Recording) -> [Double] {
        (0..<max(recording.capturedFrames, 1)).map {
            Double(recording.blend(atCaptured: $0)?.time ?? 0) * Physics.megayearsPerTimeUnit
        }
    }

    /// Where a moment falls among the captured frames; outside the take, refused with its span.
    static func position(of myr: Double, in megayears: [Double]) throws -> Double {
        guard let first = megayears.first, let last = megayears.last, myr.isFinite else {
            throw Failure.outsideTake(myr: myr, first: 0, last: 0)
        }
        // A key typed to the take's own rounding still lands on its end.
        let slack = 1e-3
        guard myr >= first - slack, myr <= last + slack else {
            throw Failure.outsideTake(myr: myr, first: first, last: last)
        }
        if myr <= first { return 0 }
        if myr >= last { return Double(megayears.count - 1) }
        let index = interval(of: myr, in: megayears)
        let span = megayears[index + 1] - megayears[index]
        return Double(index) + (span > 0 ? (myr - megayears[index]) / span : 0)
    }

    /// The last index whose value is at most `value`, in an increasing list.
    private static func interval(of value: Double, in sorted: [Double]) -> Int {
        var (low, high) = (0, sorted.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if sorted[middle] <= value { low = middle } else { high = middle - 1 }
        }
        return min(low, max(sorted.count - 2, 0))
    }

    /// Played frames spent between two captured frames whose speeds are `a` and `b`, the speed
    /// geometric between them.
    static func duration(_ a: Double, _ b: Double) -> Double {
        if a == b { return 1 / a }
        return (1 / a - 1 / b) / log(b / a)
    }

    /// The largest speeds under `targets` that change by no more than a doubling over `ramp`
    /// seconds of video: a slowdown is over before the slow stretch starts, and a speed up
    /// starts once it ends.
    static func ramped(_ targets: [Double], ramp: Double, rate: Double) -> [Double] {
        var speeds = targets
        for index in speeds.indices.dropFirst() {
            speeds[index] = min(speeds[index], speeds[index - 1] * rise(from: speeds[index - 1], ramp, rate))
        }
        for index in speeds.indices.dropLast().reversed() {
            speeds[index] = min(speeds[index], speeds[index + 1] * rise(from: speeds[index + 1], ramp, rate))
        }
        return speeds
    }

    /// The most a speed `a` may grow by over one captured frame: a factor e^x such that, the
    /// speed geometric across the frame, its logarithm moves by no more than ln 2 over `ramp`
    /// seconds of video anywhere in it. It moves fastest at the faster end, x b rate a second.
    static func rise(from a: Double, _ ramp: Double, _ rate: Double) -> Double {
        let k = log(2) / (ramp * rate * a)
        var (low, high) = (0.0, k)
        for _ in 0..<60 {
            let x = (low + high) / 2
            if x * exp(x) <= k { low = x } else { high = x }
        }
        return exp(low)
    }

    /// Fritsch and Carlson's tangents: zero where the data is flat or turns, and cut back
    /// wherever the cubic would overshoot, so a monotone list gives a monotone curve.
    static func monotoneSlopes(x: [Double], y: [Double]) -> [Double] {
        let n = x.count
        var secants: [Double] = []
        for index in 0..<(n - 1) {
            let rise: Double = y[index + 1] - y[index]
            let run: Double = x[index + 1] - x[index]
            secants.append(rise / run)
        }
        var slopes = [Double](repeating: 0, count: n)
        slopes[0] = secants[0]
        slopes[n - 1] = secants[n - 2]
        for index in 1..<max(n - 1, 1) {
            let before: Double = secants[index - 1]
            let after: Double = secants[index]
            slopes[index] = before * after <= 0 ? 0 : (before + after) / 2
        }
        for index in secants.indices {
            let secant = secants[index]
            if secant == 0 {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }
            let alpha = slopes[index] / secant
            let beta = slopes[index + 1] / secant
            let size = alpha * alpha + beta * beta
            if size > 9 {
                let tau = 3 / size.squareRoot()
                slopes[index] = tau * alpha * secant
                slopes[index + 1] = tau * beta * secant
            }
        }
        return slopes
    }
}

/// A time track as it is kept on disk (`exports/<name>.time.json`): exactly one of a constant
/// `speed`, speed `keys`, a speed for every captured frame or a flight's `times`, and the ramp
/// for the speeds. Strict as `LookFile` is: a field this build does not know is an error.
public struct TimeTrackFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let fileExtension = "time.json"

    public var version: Int
    /// Seconds of video over which a speed may double or halve; absent, `TimeTrack.defaultRamp`.
    public var ramp: Double?
    public var speed: Double?
    public var keys: [TimeTrack.SpeedKey]?
    public var speeds: [Double]?
    public var times: [TimeTrack.TimeKey]?

    public init(
        ramp: Double? = nil, speed: Double? = nil, keys: [TimeTrack.SpeedKey]? = nil,
        speeds: [Double]? = nil, times: [TimeTrack.TimeKey]? = nil
    ) {
        version = Self.currentVersion
        self.ramp = ramp
        self.speed = speed
        self.keys = keys
        self.speeds = speeds
        self.times = times
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ramp: try c.decodeIfPresent(Double.self, forKey: .ramp),
            speed: try c.decodeIfPresent(Double.self, forKey: .speed),
            keys: try c.decodeIfPresent([TimeTrack.SpeedKey].self, forKey: .keys),
            speeds: try c.decodeIfPresent([Double].self, forKey: .speeds),
            times: try c.decodeIfPresent([TimeTrack.TimeKey].self, forKey: .times))
        version = try c.decode(Int.self, forKey: .version)
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case unsupportedVersion(Int)
        case shape(String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "time track version \(version), this build reads \(TimeTrackFile.currentVersion)"
            case .shape(let detail): "time track: \(detail)"
            }
        }
    }

    /// What `--speed` gives: a number, the whole take at that speed, or a `.time.json`'s path.
    public static func given(_ text: String) throws -> TimeTrackFile {
        if let speed = Double(text) { return TimeTrackFile(speed: speed) }
        return try decoded(from: Data(contentsOf: URL(fileURLWithPath: text)))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> TimeTrackFile {
        let file = try JSONDecoder().decode(TimeTrackFile.self, from: data)
        guard file.version == currentVersion else {
            throw ReadError.unsupportedVersion(file.version)
        }
        let given = [file.speed != nil, file.keys != nil, file.speeds != nil, file.times != nil]
        guard given.filter({ $0 }).count == 1 else {
            throw ReadError.shape("one of speed, keys, speeds or times, and only one")
        }
        if file.ramp != nil, file.speeds == nil, file.keys == nil {
            throw ReadError.shape("ramp goes with keys or speeds")
        }
        return file
    }

    /// The track this file gives a take whose captured frames stand at `megayears`.
    public func track(megayears: [Double], capturedRate: Int) throws -> TimeTrack {
        let ramp = self.ramp ?? TimeTrack.defaultRamp
        if let speed {
            return try TimeTrack(
                capturedFrames: megayears.count, capturedRate: capturedRate, speed: speed)
        }
        if let keys {
            return try TimeTrack(
                keys: keys, megayears: megayears, capturedRate: capturedRate, ramp: ramp)
        }
        if let speeds {
            guard speeds.count == megayears.count else {
                throw TimeTrack.Failure.frames(given: speeds.count, take: megayears.count)
            }
            return try TimeTrack(speeds: speeds, capturedRate: capturedRate, ramp: ramp)
        }
        return try TimeTrack(times: times ?? [], megayears: megayears, capturedRate: capturedRate)
    }
}
