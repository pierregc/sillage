import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// The camera and the take's moment at one instant of a flight flown in the app (#298).
public struct FlightSample: Sendable, Equatable {
    /// Seconds of real time since the recording began.
    public var seconds: Double
    public var eye: SIMD3<Double>
    public var aim: SIMD3<Double>
    /// Vertical field of view in radians.
    public var fov: Double
    /// Radians about the line of sight, as a flight key's.
    public var roll: Double
    /// The take's moment then.
    public var myr: Double
    /// Kiloparsecs from the eye to the nearest matter (`Nearness`), when it is known: what the
    /// path's tolerance is a share of.
    public var nearness: Double?

    public init(
        seconds: Double, eye: SIMD3<Double>, aim: SIMD3<Double>, fov: Double, roll: Double, myr: Double,
        nearness: Double? = nil
    ) {
        self.seconds = seconds
        self.eye = eye
        self.aim = aim
        self.fov = fov
        self.roll = roll
        self.myr = myr
        self.nearness = nearness
    }
}

/// A flight flown in the app, recorded as samples and turned into a flight file (#298): the
/// samples laid on a grid of 30 a second, eye, aim, roll and field of view smoothed over about
/// half a second (held keys start and stop hard), then thinned to the keys that give the same
/// flight back within a tolerance, the moment of the take thinned with them. The keys are checked
/// against the flight they make, `Flight`'s own spline, not against a stand-in: where the path or
/// the time bends the keys come closer, where it runs straight they stay a second apart.
public struct FlightRecorder: Sendable {
    public struct Settings: Sendable, Equatable {
        /// The grid's rate, samples a second of real time.
        public var rate = 30.0
        /// The width of the window the camera is smoothed over, seconds.
        public var smoothing = 0.5
        /// The longest between two keys, seconds.
        public var interval = 1.0
        /// The shortest, seconds, however much the path bends.
        public var closest = 0.1
        /// The eye's tolerance, as a share of the distance to the nearest matter...
        public var eyeShare = 0.005
        /// ...and never finer than this, kiloparsecs: a fifth of the near plane.
        public var eyeFloor = 0.0002
        /// The line of sight's, radians.
        public var direction = 0.002
        public var roll = 0.02
        /// The field of view's, in the logarithm of the tangent of its half angle.
        public var fov = 0.01
        /// The moment's, in captured frames.
        public var time = 0.25
        /// Samples in a row at one moment that make a freeze.
        public var freeze = 3

        public init() {}
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case tooShort(seconds: Double)
        case notRecorded(String)

        public var description: String {
            switch self {
            case .tooShort(let seconds):
                String(format: "a recording of %.1f s is too short to make a flight of", seconds)
            case .notRecorded(let detail): "the recording cannot be made a flight: \(detail)"
            }
        }
    }

    public private(set) var samples: [FlightSample] = []

    public init() {}

    public mutating func append(_ sample: FlightSample) {
        if let last = samples.last, sample.seconds <= last.seconds { return }
        samples.append(sample)
    }

    public var seconds: Double { (samples.last?.seconds ?? 0) - (samples.first?.seconds ?? 0) }
    public var isEmpty: Bool { samples.isEmpty }

    /// The flight the recording makes on a take whose captured frames are at `megayears`, drawn
    /// at `capturedRate`.
    public func flight(
        megayears: [Double], capturedRate: Int, settings: Settings = Settings()
    ) throws -> FlightFile {
        let grid = try smoothed(settings, megayears: megayears)
        guard grid.count >= 3 else { throw Failure.tooShort(seconds: seconds) }
        let wanted = grid.map { sample in
            (try? TimeTrack.position(of: sample.myr, in: megayears)) ?? 0
        }
        let take = FlightTake(
            megayears: megayears, capturedRate: capturedRate, galaxies: 0, centres: { _ in [] },
            disks: { _ in [] })
        let closest = max(Int((settings.closest * settings.rate).rounded()), 1)
        let stride = max(Int((settings.interval * settings.rate).rounded()), closest)

        // The keys the freezes need, the grid's first and last, and one every `interval`.
        var kept = Set([0, grid.count - 1])
        for run in Self.freezes(grid, atLeast: settings.freeze) {
            kept.insert(run.lowerBound)
            kept.insert(run.upperBound)
        }
        for index in Swift.stride(from: stride, to: grid.count - 1, by: stride) { kept.insert(index) }
        var indices = Self.spaced(kept.sorted(), grid.count, closest)

        for _ in 0..<24 {
            let file = Self.file(grid, indices)
            let made = try Flight(file, take: take)
            var added = false
            for (a, b) in zip(indices, indices.dropFirst()) where b - a >= 2 * closest {
                var worst: (index: Int, error: Double)?
                for k in (a + closest)...(b - closest) {
                    let error = Self.error(made, grid[k], wanted[k], settings)
                    if error > 1, error > (worst?.error ?? 0) { worst = (k, error) }
                }
                if let worst {
                    kept.insert(worst.index)
                    added = true
                }
            }
            guard added else { break }
            indices = Self.spaced(kept.sorted(), grid.count, closest)
        }
        return Self.file(grid, indices)
    }

    // MARK: The grid

    /// The samples on a grid of `rate` a second, in the order of the recording and smoothed.
    func smoothed(_ settings: Settings, megayears: [Double]) throws -> [FlightSample] {
        guard let first = samples.first, samples.count >= 2 else {
            throw Failure.tooShort(seconds: seconds)
        }
        guard let low = megayears.first, let high = megayears.last else {
            throw Failure.notRecorded("the take has no moments")
        }
        for sample in samples {
            let values = [sample.eye.x, sample.eye.y, sample.eye.z, sample.aim.x, sample.aim.y, sample.aim.z]
            guard values.allSatisfy(\.isFinite), sample.fov.isFinite, sample.roll.isFinite,
                sample.myr.isFinite
            else { throw Failure.notRecorded("a sample is not a number") }
        }
        let rate = settings.rate
        let count = Int((seconds * rate).rounded(.down)) + 1
        guard count >= 3 else { throw Failure.tooShort(seconds: seconds) }
        var grid: [FlightSample] = []
        grid.reserveCapacity(count)
        var at = 0
        var running = -Double.infinity
        let tangent = { (fov: Double) in log(tan(fov / 2)) }
        for k in 0..<count {
            let t = first.seconds + Double(k) / rate
            while at + 2 < samples.count, samples[at + 1].seconds < t { at += 1 }
            let (a, b) = (samples[at], samples[at + 1])
            let u = min(max((t - a.seconds) / (b.seconds - a.seconds), 0), 1)
            var sample = FlightSample(
                seconds: Double(k) / rate, eye: a.eye + (b.eye - a.eye) * u, aim: a.aim + (b.aim - a.aim) * u,
                fov: 2 * atan(exp(tangent(a.fov) + (tangent(b.fov) - tangent(a.fov)) * u)),
                roll: a.roll + (b.roll - a.roll) * u, myr: a.myr + (b.myr - a.myr) * u)
            if let na = a.nearness, let nb = b.nearness { sample.nearness = na + (nb - na) * u }
            // Time never runs backwards, whatever the noise in the samples says.
            sample.myr = min(max(max(sample.myr, running), low), high)
            running = sample.myr
            grid.append(sample)
        }
        return Self.smooth(grid, width: settings.smoothing, rate: rate)
    }

    /// Eye, aim, roll and field of view under a raised cosine `width` seconds wide, held at
    /// the ends; the moment and the nearness as they were.
    static func smooth(_ grid: [FlightSample], width: Double, rate: Double) -> [FlightSample] {
        let radius = Int((width * rate / 2).rounded())
        guard radius > 0 else { return grid }
        let weights = (-radius...radius).map { 0.5 * (1 + cos(Double.pi * Double($0) / Double(radius + 1))) }
        let total = weights.reduce(0, +)
        let tangent = { (fov: Double) in log(tan(fov / 2)) }
        var smoothed = grid
        for k in grid.indices {
            var (eye, aim) = (SIMD3<Double>.zero, SIMD3<Double>.zero)
            var (roll, fov) = (0.0, 0.0)
            for (offset, weight) in zip(-radius...radius, weights) {
                let sample = grid[min(max(k + offset, 0), grid.count - 1)]
                eye += sample.eye * weight
                aim += sample.aim * weight
                roll += sample.roll * weight
                fov += tangent(sample.fov) * weight
            }
            smoothed[k].eye = eye / total
            smoothed[k].aim = aim / total
            smoothed[k].roll = roll / total
            smoothed[k].fov = 2 * atan(exp(fov / total))
        }
        return smoothed
    }

    /// The runs of the grid where the moment stands still for at least `length` samples.
    static func freezes(_ grid: [FlightSample], atLeast length: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start = 0
        for k in 1...grid.count {
            if k < grid.count, abs(grid[k].myr - grid[start].myr) < 1e-9 { continue }
            if k - start >= length { runs.append(start...(k - 1)) }
            start = k
        }
        return runs
    }

    /// `indices` with the ones closer than `closest` samples to the one before dropped, the
    /// grid's last always kept.
    static func spaced(_ indices: [Int], _ count: Int, _ closest: Int) -> [Int] {
        var spaced: [Int] = []
        for index in indices {
            if let last = spaced.last, index - last < closest {
                if index == count - 1 { spaced.removeLast() } else { continue }
            }
            spaced.append(index)
        }
        return spaced
    }

    // MARK: The keys

    static func file(_ grid: [FlightSample], _ indices: [Int]) -> FlightFile {
        FlightFile(
            keys: indices.map { index in
                let sample = grid[index]
                return FlightFile.Key(
                    at: (sample.seconds * 1e6).rounded() / 1e6, myr: sample.myr, eye: .world(sample.eye),
                    aim: .world(sample.aim), fov: sample.fov, roll: sample.roll)
            })
    }

    /// How far a flight made of the keys is from the sample, in tolerances: the worst of the
    /// eye, the line of sight, the roll, the field of view and the moment.
    static func error(_ flight: Flight, _ sample: FlightSample, _ wanted: Double, _ settings: Settings)
        -> Double
    {
        let position = flight.captured(atSeconds: sample.seconds)
        let (eye, aim) = (
            flight.point(\.eye, sample.seconds, position), flight.point(\.aim, sample.seconds, position)
        )
        let scale = sample.nearness.map { max($0, 0) } ?? simd_length(sample.aim - sample.eye)
        let tolerance = max(settings.eyeFloor, settings.eyeShare * scale)
        var worst = simd_length(eye - sample.eye) / tolerance
        if let fit = Flight.normalised(aim - eye), let seen = Flight.normalised(sample.aim - sample.eye) {
            worst = max(worst, acos(min(max(simd_dot(fit, seen), -1), 1)) / settings.direction)
        }
        let (roll, fov) = flight.attitude(atSeconds: sample.seconds)
        let tangent = { (fov: Double) in log(tan(fov / 2)) }
        worst = max(worst, abs(roll - sample.roll) / settings.roll)
        worst = max(worst, abs(tangent(fov) - tangent(sample.fov)) / settings.fov)
        return max(worst, abs(position - wanted) / settings.time)
    }
}

/// A path set by hand in the app (#298): a key where the camera and the playhead stand, K
/// after K, each after the one before by the distance between them flown at the throttle's
/// speed. Written as it is, without smoothing: the keys are the ones the pilot chose.
public struct FlightWaypoints: Sendable, Equatable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case backwards(previous: Double, this: Double)

        public var description: String {
            switch self {
            case .backwards(let previous, let this):
                String(
                    format: "time cannot run backwards: %.1f Myr after %.1f Myr; "
                        + "move the playhead on, or clear the path", this, previous)
            }
        }
    }

    /// The shortest between two keys, seconds.
    public static let shortest = 0.5
    /// A turn the camera makes in a second when only the view changes, radians.
    public static let turnPerSecond = 0.8

    public private(set) var keys: [FlightFile.Key] = []

    public init() {}

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var seconds: Double { keys.last?.at ?? 0 }

    /// A key at the camera `sample` shows, its `at` after the last by the distance flown at
    /// `speed` kiloparsecs a second, the turn of the view at `turnPerSecond` when that is longer,
    /// and never under `shortest`.
    @discardableResult
    public mutating func add(_ sample: FlightSample, speed: Double) throws -> FlightFile.Key {
        var at = 0.0
        if let last = keys.last, case .world(let eye)? = last.eye, case .world(let aim)? = last.aim {
            if let before = last.myr, sample.myr < before - 1e-9 {
                throw Failure.backwards(previous: before, this: sample.myr)
            }
            let flown = simd_length(sample.eye - eye) / max(speed, 1e-9)
            var turned = 0.0
            if let a = Flight.normalised(aim - eye), let b = Flight.normalised(sample.aim - sample.eye) {
                turned = acos(min(max(simd_dot(a, b), -1), 1)) / Self.turnPerSecond
            }
            at = last.at + max(flown, turned, Self.shortest)
            at = (at * 1000).rounded() / 1000
        }
        let key = FlightFile.Key(
            at: at, myr: sample.myr, eye: .world(sample.eye), aim: .world(sample.aim), fov: sample.fov,
            roll: sample.roll)
        keys.append(key)
        return key
    }

    public mutating func removeLast() { if !keys.isEmpty { keys.removeLast() } }
    public mutating func clear() { keys.removeAll() }

    /// The path as a flight file; at least two keys.
    public func file() throws -> FlightFile {
        let file = FlightFile(keys: keys)
        try file.validate()
        return file
    }
}
