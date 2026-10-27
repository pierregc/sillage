import Foundation
import simd

/// Whether a scene's story is still going, judged on the curves an explore run writes frame by
/// frame: the galaxy centres, how far the stars have spread, the share of them in tails and how
/// far each disk has been disrupted. The thresholds were measured on the 35 scenes of the
/// 2026-10-25 night, see `docs/notes/whole-stories.md`.
public struct Story: Sendable {
    /// One captured frame of the curves.
    public struct Sample: Sendable, Equatable {
        public var timeMyr: Double
        public var centres: [SIMD3<Double>]
        public var extent: Double
        public var tails: Double
        public var disruption: [Double]

        public init(
            timeMyr: Double, centres: [SIMD3<Double>], extent: Double, tails: Double,
            disruption: [Double]
        ) {
            self.timeMyr = timeMyr
            self.centres = centres
            self.extent = extent
            self.tails = tails
            self.disruption = disruption
        }
    }

    public struct Settings: Sendable, Equatable {
        /// How long, in Myr, a scene has to stay quiet before its story counts as over.
        public var window = 150.0
        /// The stretch, in Myr, a pair's relative velocity is fitted over.
        public var velocityFit = 20.0
        /// A pass closer than this many times the two disks' combined reach is a collision.
        public var reach = 1.5
        /// A bound pair whose separation curves by less than this share of the pull its
        /// potential predicts no longer moves as two bodies: what is left apart is debris.
        public var pull = 0.3
        /// And whose separation stays within this share of itself over the window.
        public var band = 0.3
        public var bandFloorKpc = 3.0
        /// The largest change over the window that still counts as quiet: tails as a share of
        /// the stars, extent relative to itself, disruption on its 0 to 1 scale.
        public var tails = 0.02
        public var extent = 0.15
        public var disruption = 0.05
        /// The approach shown before the first collision, in Myr.
        public var lead = 150.0
        /// How long after the last pair left its reach a story with nothing more to come may run,
        /// in Myr: tails take up to 250 Myr to form, and the window closes the clip. Past it, what
        /// still changes is a disk heating on its own or the centre of mass of debris drifting.
        public var aftermath = 400.0
        /// A collision due after this moment, in Myr of simulated time, is not this story's.
        public var horizon = Story.capMyr

        public init() {}
    }

    /// What keeps a story going.
    public enum Activity: Sendable, Equatable, CustomStringConvertible {
        case warmingUp
        case approaching(Int, Int, pericentreKpc: Double)
        case returning(Int, Int, pericentreKpc: Double)
        case tails(Double)
        case extent(Double)
        case disruption(Int, Double)

        public var description: String {
            switch self {
            case .warmingUp: "too early to tell"
            case .approaching(let i, let j, let pericentre):
                String(format: "galaxies %d and %d approaching, to %.1f kpc", i, j, pericentre)
            case .returning(let i, let j, let pericentre):
                String(format: "galaxies %d and %d bound, coming back to %.1f kpc", i, j, pericentre)
            case .tails(let change): String(format: "tails changing by %.1f %%", change * 100)
            case .extent(let change): String(format: "extent changing by %.0f %%", change * 100)
            case .disruption(let galaxy, let change):
                String(format: "disk %d still being disrupted (+%.2f)", galaxy, change)
            }
        }
    }

    /// Where the story sits in the captured frames, kept in `clip.json`.
    public struct Span: Codable, Sendable, Equatable {
        public var startFrame: Int
        public var endFrame: Int
        public var startMyr: Double
        public var endMyr: Double
        /// False when the run reached its cap with the story still going.
        public var complete: Bool

        public init(startFrame: Int, endFrame: Int, startMyr: Double, endMyr: Double, complete: Bool) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.startMyr = startMyr
            self.endMyr = endMyr
            self.complete = complete
        }

        public var frames: Int { endFrame - startFrame + 1 }
    }

    /// The first collision: the first pass of any pair closer than its reach.
    public struct Approach: Sendable, Equatable {
        public var index: Int
        public var timeMyr: Double
        public var distanceKpc: Double
        public var pair: [Int]
    }

    /// How long a run is allowed to go on for a story that does not end, in Myr of simulated
    /// time.
    public static let capMyr = 2_000.0
    /// How much longer than its planned span an explore run goes on average, as a share of that
    /// span: 0.20 measured on the 2026-10-25 night, 0.25 with pericentres placed after the
    /// approach. What to plan a batch with before its stories are known; `explore-batch.sh`
    /// keeps the same figure.
    public static let extraShare = 0.25

    public let settings: Settings
    let profiles: [EncounterCentres.Profile]
    let reaches: [Double]

    init(profiles: [EncounterCentres.Profile], reaches: [Double], settings: Settings = Settings()) {
        self.profiles = profiles
        self.reaches = reaches
        self.settings = settings
    }

    /// The pull of each galaxy is the one the generator places encounters with.
    public init(scene: SceneConfig, settings: Settings = Settings()) {
        self.init(
            profiles: EncounterCentres(scene: scene).profiles,
            reaches: scene.galaxies.map { Double(SceneCheck.reach($0)) }, settings: settings)
    }

    private static let unit = Physics.megayearsPerTimeUnit

    func potential(_ i: Int, _ j: Int, _ r: Double) -> Double {
        profiles[i].potential(r) + profiles[j].potential(r)
    }

    func limit(_ i: Int, _ j: Int) -> Double {
        settings.reach * (reaches[i] + reaches[j])
    }

    /// What a frame says, judged on the samples up to it and none after.
    public struct Reading: Sendable, Equatable {
        /// Collisions still to come, or too early to tell.
        public var pairs: [Activity] = []
        /// Tails, extent or disruption still changing over the window.
        public var window: [Activity] = []
        /// Some pair is inside its reach and still moving as two bodies.
        public var engaged = false
    }

    public func reading(_ samples: [Sample], at index: Int) -> Reading {
        let now = samples[index]
        var reading = Reading()
        guard let first = samples.first, now.timeMyr - first.timeMyr >= settings.window else {
            reading.pairs = [.warmingUp]
            return reading
        }
        let window = samples[Self.start(of: now.timeMyr - settings.window, in: samples, upTo: index)...index]
        let fit = samples[
            Self.start(of: now.timeMyr - settings.velocityFit, in: samples, upTo: index)...index]
        var together = true
        let count = min(now.centres.count, profiles.count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let offset = now.centres[j] - now.centres[i]
                let r = max(simd_length(offset), 1e-6)
                let limit = limit(i, j)
                if r >= limit { together = false }
                guard fit.count >= 3 else { continue }
                let velocity = Self.slope(fit.map { ($0.timeMyr, $0.centres[j] - $0.centres[i]) }) * Self.unit
                let radial = simd_dot(offset, velocity) / r
                let momentum = simd_length(simd_cross(offset, velocity))
                let energy = simd_length_squared(velocity) / 2 + potential(i, j, r)
                let settled = energy < 0 && settled(i, j, window, at: r)
                if r < limit && !settled { reading.engaged = true }
                // Parted for good, or merged.
                if energy >= 0 && radial >= 0 || settled { continue }
                let orbit = Orbit(story: self, i, j, energy: energy, momentum: momentum, from: r)
                // Passes wide, or after the horizon.
                guard orbit.pericentre < limit,
                    let wait = orbit.timeToPericentre(receding: radial >= 0),
                    now.timeMyr + wait < settings.horizon
                else { continue }
                reading.pairs.append(
                    energy >= 0
                        ? .approaching(i, j, pericentreKpc: orbit.pericentre)
                        : .returning(i, j, pericentreKpc: orbit.pericentre))
            }
        }
        let tails = window.map(\.tails)
        if let low = tails.min(), let high = tails.max(), high - low >= settings.tails {
            reading.window.append(.tails(high - low))
        }
        // Galaxies parting stretch the extent for as long as they move, whatever the stars do.
        let extents = window.map(\.extent)
        if together, let low = extents.min(), let high = extents.max(), high > 0,
            (high - low) / high >= settings.extent
        {
            reading.window.append(.extent((high - low) / high))
        }
        for galaxy in 0..<now.disruption.count {
            let values = window.compactMap { galaxy < $0.disruption.count ? $0.disruption[galaxy] : nil }
            if let low = values.min(), let high = values.max(), high - low >= settings.disruption {
                reading.window.append(.disruption(galaxy, high - low))
            }
        }
        return reading
    }

    /// What still goes on: a collision to come keeps the story going; otherwise whatever still
    /// changes over the window does, until `aftermath` past the last moment a pair was engaged.
    /// Empty once the story is over.
    public func activity(_ reading: Reading, atMyr time: Double, engagedMyr: Double) -> [Activity] {
        if !reading.pairs.isEmpty { return reading.pairs + reading.window }
        return time - engagedMyr >= settings.aftermath ? [] : reading.window
    }

    /// A pair's relative orbit in its own potential, energy and angular momentum held.
    struct Orbit {
        let story: Story
        let i: Int
        let j: Int
        let energy: Double
        let momentum: Double
        let r: Double
        let pericentre: Double

        init(story: Story, _ i: Int, _ j: Int, energy: Double, momentum: Double, from r: Double) {
            self.story = story
            self.i = i
            self.j = j
            self.energy = energy
            self.momentum = momentum
            self.r = r
            pericentre = story.innerTurningPoint(i, j, energy: energy, momentum: momentum, from: r)
        }

        func radialSpeed(_ x: Double) -> Double {
            max(2 * (energy - story.potential(i, j, x)) - momentum * momentum / (x * x), 0).squareRoot()
        }

        /// Where a bound orbit turns at its outer end, nil for an unbound one.
        var apocentre: Double? {
            guard energy < 0 else { return nil }
            var low = r
            var high = r
            while radialSpeed(high) > 0 || high == r {
                low = high
                high *= 2
                if high > 1e6 { return nil }
            }
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if radialSpeed(middle) > 0 { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }

        /// Time between two radii of the orbit in Myr, by substitutions that keep the integrand
        /// finite at a turning point.
        func time(from a: Double, to b: Double, steps: Int = 200) -> Double {
            guard b > a else { return 0 }
            let middle = (a + b) / 2
            var total = 0.0
            // Near a: x = a + u², near b: x = b - w².
            for (from, sign) in [(a, 1.0), (b, -1.0)] {
                let span = abs(middle - from).squareRoot()
                for k in 0..<steps {
                    let u = (Double(k) + 0.5) / Double(steps) * span
                    let x = from + sign * u * u
                    let speed = radialSpeed(x)
                    guard speed > 0 else { continue }
                    total += 2 * u * (span / Double(steps)) / speed
                }
            }
            return total * Story.unit
        }

        /// How long until the next pericentre, nil if the pair never comes back.
        func timeToPericentre(receding: Bool) -> Double? {
            guard receding else { return time(from: pericentre, to: r) }
            guard let apocentre else { return nil }
            return time(from: r, to: apocentre) + time(from: pericentre, to: apocentre)
        }
    }

    /// A bound pair inside its reach whose centres no longer pull on each other as two bodies:
    /// after a merger, what is left of a disrupted disk has its centre of mass wherever its
    /// debris is, and it drifts instead of falling back.
    func settled(_ i: Int, _ j: Int, _ window: ArraySlice<Sample>, at r: Double) -> Bool {
        guard let end = window.last?.timeMyr else { return false }
        let separations = window.map { simd_distance($0.centres[i], $0.centres[j]) }
        guard let low = separations.min(), let high = separations.max(),
            high - low <= max(settings.band * high, settings.bandFloorKpc)
        else { return false }
        let times = window.map { ($0.timeMyr - end) / Self.unit }
        let curvature = Self.curvature(times, separations)
        let step = 1e-3 * max(r, 1)
        let pull = (potential(i, j, r + step) - potential(i, j, r - step)) / (2 * step)
        return abs(curvature) < settings.pull * pull
    }

    /// Where a pair's relative orbit turns at its inner end, with its energy and angular momentum
    /// held: the next pericentre if nothing else intervened.
    func innerTurningPoint(_ i: Int, _ j: Int, energy: Double, momentum: Double, from r: Double)
        -> Double
    {
        func excess(_ x: Double) -> Double {
            momentum * momentum / (2 * x * x) + potential(i, j, x) - energy
        }
        var low = 1e-3
        var high = r
        guard excess(low) > 0 else { return 0 }
        guard excess(high) <= 0 else { return r }
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if excess(middle) > 0 { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// The first pass of any pair below its reach. A dip counts once the pair has separated
    /// again by five per cent, so a wobble is not a passage; one at the very first sample is
    /// the clip's edge.
    public func firstApproach(_ samples: [Sample]) -> Approach? {
        guard let first = samples.first else { return nil }
        var best: Approach?
        let count = min(first.centres.count, profiles.count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                var lowest: Int? = 0
                var previous = Double.infinity
                for (index, sample) in samples.enumerated() {
                    let d = simd_distance(sample.centres[i], sample.centres[j])
                    defer { previous = d }
                    guard let low = lowest else {
                        if d < previous { lowest = index }
                        continue
                    }
                    let lowDistance = simd_distance(samples[low].centres[i], samples[low].centres[j])
                    if d < lowDistance {
                        lowest = index
                    } else if d > lowDistance * 1.05 + 0.2 {
                        if low > 0, lowDistance < limit(i, j),
                            best.map({ samples[low].timeMyr < $0.timeMyr }) ?? true
                        {
                            best = Approach(
                                index: low, timeMyr: samples[low].timeMyr, distanceKpc: lowDistance,
                                pair: [i, j])
                        }
                        lowest = nil
                    }
                }
            }
        }
        return best
    }

    /// The story over a whole run: from `lead` before the first collision, or from the start,
    /// to the first frame of the quiet that lasted to the end. A run with no collision at all
    /// keeps the clip it planned.
    public func span(_ samples: [Sample], quietFrom: Int?, plannedFrames: Int) -> Span? {
        guard let last = samples.indices.last else { return nil }
        let complete = quietFrom != nil
        var start = 0
        var end = last
        if let approach = firstApproach(samples) {
            start = samples.firstIndex { $0.timeMyr >= approach.timeMyr - settings.lead } ?? 0
            if let quietFrom { end = max(quietFrom, approach.index) }
        } else if complete {
            end = min(max(plannedFrames, 1), samples.count) - 1
        }
        return Span(
            startFrame: start, endFrame: end, startMyr: samples[start].timeMyr,
            endMyr: samples[end].timeMyr, complete: complete)
    }

    /// The story followed as frames come in, for a run that decides when to stop.
    public struct Tracker: Sendable {
        public let story: Story
        public private(set) var samples: [Sample] = []
        public private(set) var activity: [Activity] = [.warmingUp]
        /// The first frame of the current quiet stretch.
        public private(set) var quietFrom: Int?
        /// The last moment a pair was inside its reach and moving as two bodies.
        public private(set) var engagedMyr: Double?

        public init(story: Story) { self.story = story }

        public var isOver: Bool { activity.isEmpty }

        public mutating func append(_ sample: Sample) {
            samples.append(sample)
            let reading = story.reading(samples, at: samples.count - 1)
            if reading.engaged || engagedMyr == nil { engagedMyr = sample.timeMyr }
            activity = story.activity(
                reading, atMyr: sample.timeMyr, engagedMyr: engagedMyr ?? sample.timeMyr)
            if !activity.isEmpty {
                quietFrom = nil
            } else if quietFrom == nil {
                quietFrom = samples.count - 1
            }
        }

        public func span(plannedFrames: Int) -> Span? {
            story.span(samples, quietFrom: quietFrom, plannedFrames: plannedFrames)
        }
    }

    /// Reads `curves.csv` by column name: time, extent, tails, each disk's disruption and each
    /// galaxy's centre.
    public static func samples(csv: String) -> [Sample] {
        let lines = csv.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map(String.init) else { return [] }
        let column = { (name: String) in header.firstIndex(of: name) }
        guard let time = column("time_myr"), let extent = column("extent_kpc"),
            let tails = column("tidal_fraction")
        else { return [] }
        var galaxies = 0
        while column("x_\(galaxies)") != nil { galaxies += 1 }
        let centres = (0..<galaxies).compactMap { index -> (Int, Int, Int)? in
            guard let x = column("x_\(index)"), let y = column("y_\(index)"), let z = column("z_\(index)")
            else { return nil }
            return (x, y, z)
        }
        let disruption = (0..<galaxies).compactMap { column("disruption_\($0)") }
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == header.count, let t = Double(fields[time]),
                let e = Double(fields[extent]), let f = Double(fields[tails])
            else { return nil }
            let positions = centres.compactMap { x, y, z -> SIMD3<Double>? in
                guard let a = Double(fields[x]), let b = Double(fields[y]), let c = Double(fields[z])
                else { return nil }
                return SIMD3(a, b, c)
            }
            guard positions.count == centres.count else { return nil }
            return Sample(
                timeMyr: t, centres: positions, extent: e, tails: f,
                disruption: disruption.map { Double(fields[$0]) ?? 0 })
        }
    }

    static func start(of time: Double, in samples: [Sample], upTo index: Int) -> Int {
        var low = 0
        var high = index
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].timeMyr < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Least squares slope of a vector against time, per Myr.
    static func slope(_ points: [(Double, SIMD3<Double>)]) -> SIMD3<Double> {
        let n = Double(points.count)
        let meanTime = points.reduce(0) { $0 + $1.0 } / n
        let meanValue = points.reduce(SIMD3<Double>.zero) { $0 + $1.1 } / n
        var across = SIMD3<Double>.zero
        var spread = 0.0
        for (t, value) in points {
            across += (t - meanTime) * (value - meanValue)
            spread += (t - meanTime) * (t - meanTime)
        }
        return spread > 0 ? across / spread : .zero
    }

    /// Twice the leading coefficient of the least squares parabola: the second derivative.
    static func curvature(_ times: [Double], _ values: [Double]) -> Double {
        let n = Double(times.count)
        guard times.count >= 3 else { return 0 }
        let mean = times.reduce(0, +) / n
        var s = [Double](repeating: 0, count: 5)
        var v = [Double](repeating: 0, count: 3)
        for (t, y) in zip(times, values) {
            let x = t - mean
            var power = 1.0
            for k in 0..<5 {
                s[k] += power
                if k < 3 { v[k] += power * y }
                power *= x
            }
        }
        // Normal equations for c0 + c1 x + c2 x^2, solved by Cramer's rule.
        let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
        func determinant(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let whole = determinant(m)
        guard abs(whole) > 1e-300 else { return 0 }
        var replaced = m
        for row in 0..<3 { replaced[row][2] = v[row] }
        return 2 * determinant(replaced) / whole
    }
}

extension SceneConfig {
    /// Where a generated scene's pericentres go: the clip less the approach its story opens on,
    /// so the first collision never lands on the clip's first frames.
    public func encounterWindow(settleSteps: Int, steps: Int, leadMyr: Double = Story.Settings().lead)
        -> ClosedRange<Float>
    {
        let clip = clipWindow(settleSteps: settleSteps, steps: steps)
        return min(clip.lowerBound + Float(leadMyr), clip.upperBound)...clip.upperBound
    }
}
