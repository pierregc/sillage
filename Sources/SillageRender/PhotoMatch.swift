import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// The moment and the view where a take overlaps a real picture best, and how well (#320).
///
/// The picture comes as a map of its extended light, made by `scripts/photo-match.py picture`.
/// The take is projected into the same small grid as a histogram of its stars' light, with no
/// renderer, so the whole search runs on the CPU, on Linux and in the tests. Both maps go to
/// log brightness the same way, and the score is their correlation with the bodies capped, so
/// the tails and the bridge count as much as the bright centres. docs/notes/photo-match.md.
public enum PhotoMatch {
    /// A picture reduced to its extended light.
    public struct Picture: Sendable {
        public var width: Int
        public var height: Int
        /// Linear light above the sky, row by row from the top; NaN where a compact source was
        /// masked.
        public var light: [Float]
        /// Decades between the picture's reference light and twice its sky noise.
        public var depth: Float
        /// The nuclei when they were marked, in fractions of the width, x right and y down.
        public var nuclei: [SIMD2<Double>]?
        public var source: String

        public init(
            width: Int, height: Int, light: [Float], depth: Float, nuclei: [SIMD2<Double>]? = nil,
            source: String = ""
        ) {
            self.width = width
            self.height = height
            self.light = light
            self.depth = depth
            self.nuclei = nuclei
            self.source = source
        }

        /// The file `scripts/photo-match.py picture` writes.
        public init(data: Data) throws {
            struct File: Decodable {
                var version: Int
                var source: String?
                var width: Int
                var height: Int
                var depth: Float
                var nuclei: [[Double]]?
                var light: [Float?]
            }
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version == 1, file.width > 0, file.height > 0,
                file.light.count == file.width * file.height
            else {
                throw Failure.picture(
                    "a map of \(file.width) x \(file.height) with \(file.light.count) values")
            }
            self.init(
                width: file.width, height: file.height, light: file.light.map { $0 ?? .nan },
                depth: file.depth,
                nuclei: file.nuclei.map { $0.filter { $0.count == 2 }.map { SIMD2($0[0], $0[1]) } },
                source: file.source ?? "")
        }

        public var seen: [Bool] { light.map { !$0.isNaN } }

        /// The picture flipped left to right, as seen in a mirror.
        public func mirrored() -> Picture {
            var flipped = light
            for row in 0..<height {
                for column in 0..<width {
                    flipped[row * width + column] = light[row * width + width - 1 - column]
                }
            }
            return Picture(
                width: width, height: height, light: flipped, depth: depth,
                nuclei: nuclei?.map { SIMD2(1 - $0.x, $0.y) }, source: source + " (mirrored)")
        }

        /// Blocks of `factor` x `factor` averaged over what they saw; a block mostly masked is
        /// masked.
        public func reduced(by factor: Int) -> Picture {
            guard factor > 1 else { return self }
            let w = max(width / factor, 1)
            let h = max(height / factor, 1)
            var out = [Float](repeating: .nan, count: w * h)
            for row in 0..<h {
                for column in 0..<w {
                    var sum: Float = 0
                    var count = 0
                    for y in (row * factor)..<min((row + 1) * factor, height) {
                        for x in (column * factor)..<min((column + 1) * factor, width) {
                            let value = light[y * width + x]
                            if !value.isNaN {
                                sum += value
                                count += 1
                            }
                        }
                    }
                    if count * 2 > factor * factor { out[row * w + column] = sum / Float(count) }
                }
            }
            return Picture(width: w, height: h, light: out, depth: depth, nuclei: nuclei, source: source)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case picture(String)
        case take(String)

        public var description: String {
            switch self {
            case .picture(let what): "not a picture map: \(what)"
            case .take(let what): "nothing to match in the take: \(what)"
            }
        }
    }

    /// Where the take is seen from and how it lies on the picture.
    public struct View: Codable, Sendable, Equatable {
        /// Degrees above the scene's plane (z up), as the look's camera has it: the viewer at
        /// azimuth 0 and elevation 0 stands on -y, and at elevation 90 looks straight down.
        public var elevation: Double
        /// Degrees about z.
        public var azimuth: Double
        /// Degrees the projected scene turns clockwise on the picture.
        public var roll: Double
        /// Kiloparsecs across the picture's width.
        public var kpcPerWidth: Double
        /// Where the scene's origin lands, in fractions of the picture's width, x right and y
        /// down, as `references/telescope/marks.json` places things.
        public var origin: SIMD2<Double>

        public init(
            elevation: Double, azimuth: Double, roll: Double = 0, kpcPerWidth: Double = 100,
            origin: SIMD2<Double> = SIMD2(0.5, 0.5)
        ) {
            self.elevation = elevation
            self.azimuth = azimuth
            self.roll = roll
            self.kpcPerWidth = kpcPerWidth
            self.origin = origin
        }

        /// The unit vector from the scene towards the viewer.
        public var towardsViewer: SIMD3<Double> {
            let e = elevation * .pi / 180
            let a = azimuth * .pi / 180
            return SIMD3(sin(a) * cos(e), -cos(a) * cos(e), sin(e))
        }

        /// Degrees between this view's direction and another's.
        public func angle(to other: View) -> Double {
            let a = towardsViewer
            let b = other.towardsViewer
            let dot = a.x * b.x + a.y * b.y + a.z * b.z
            return acos(min(max(dot, -1), 1)) * 180 / .pi
        }

        /// The two rows that take a point in kiloparsecs to the screen before the roll, in
        /// kiloparsecs, x right and y down.
        static func screenRows(elevation: Double, azimuth: Double) -> (SIMD3<Float>, SIMD3<Float>) {
            let e = elevation * .pi / 180
            let a = azimuth * .pi / 180
            return (
                SIMD3(Float(cos(a)), Float(sin(a)), 0),
                SIMD3(Float(sin(a) * sin(e)), Float(-cos(a) * sin(e)), Float(-cos(e)))
            )
        }

        /// The roll and the scale, as the 2 x 2 that takes screen kiloparsecs to fractions of
        /// the width: (xx, xy, yx, yy).
        var placement: SIMD4<Double> {
            let r = roll * .pi / 180
            let k = 1 / kpcPerWidth
            return SIMD4(cos(r) * k, -sin(r) * k, sin(r) * k, cos(r) * k)
        }

        /// Where a point of the scene lands on the picture, in fractions of its width.
        public func place(_ point: SIMD3<Float>) -> SIMD2<Double> {
            let (x, y) = Self.screenRows(elevation: elevation, azimuth: azimuth)
            let s = SIMD2(Double(dot(x, point)), Double(dot(y, point)))
            let m = placement
            return origin + SIMD2(m.x * s.x + m.y * s.y, m.z * s.x + m.w * s.y)
        }
    }

    /// The light of one frame: one star in so many, where it stands and what it gives.
    public struct Stars: Sendable {
        public var positions: [SIMD3<Float>]
        public var light: [Float]

        public init(positions: [SIMD3<Float>], light: [Float]) {
            self.positions = positions
            self.light = light
        }
    }

    /// What the search reads of a take.
    public protocol Frames: Sendable {
        var count: Int { get }
        func megayears(_ frame: Int) -> Double
        /// At most about `limit` emitting stars of the frame.
        func stars(_ frame: Int, limit: Int) -> Stars
        func centres(_ frame: Int) -> [SIMD3<Float>]
    }

    /// A take on disk, read a frame at a time.
    public struct TakeFrames: Frames {
        let recording: Recording
        let emitting: [Bool]
        let luminosity: [Float]
        let formation: [Float]
        let emitters: Int

        public init(_ take: RecordingFile.Loaded) throws {
            recording = take.recording
            let particles = take.particles
            let count = take.recording.particleCount
            guard count > 0, !recording.isEmpty else { throw Failure.take("no frame") }
            emitting = (0..<count).map { index in
                index < particles.component.count
                    ? ParticleComponent(rawValue: particles.component[index])?.emits ?? false : true
            }
            luminosity =
                particles.luminosity.count >= count
                ? particles.luminosity : [Float](repeating: 1, count: count)
            formation =
                particles.formation.count >= count
                ? particles.formation : [Float](repeating: ParticleSystem.ancient, count: count)
            emitters = emitting.filter { $0 }.count
            guard emitters > 0 else { throw Failure.take("no star that shines") }
        }

        public var count: Int { recording.count }

        public func megayears(_ frame: Int) -> Double {
            Double(recording.frame(at: frame)?.time ?? 0) * Physics.megayearsPerTimeUnit
        }

        /// Where a stored frame falls among the captured ones.
        public func captured(_ frame: Int) -> Double { recording.capturedPosition(atStored: Double(frame)) }

        public func stars(_ frame: Int, limit: Int) -> Stars {
            let stride = limit >= emitters ? 1 : (emitters + limit - 1) / max(limit, 1)
            let time = recording.frame(at: frame)?.time ?? 0
            let positions = recording.positions(at: frame, every: stride)
            var kept: [SIMD3<Float>] = []
            var light: [Float] = []
            kept.reserveCapacity(positions.count)
            light.reserveCapacity(positions.count)
            for (sample, position) in positions.enumerated() {
                let index = sample * stride
                guard emitting[index], formation[index] <= time else { continue }
                kept.append(position)
                light.append(luminosity[index])
            }
            return Stars(positions: kept, light: light)
        }

        public func centres(_ frame: Int) -> [SIMD3<Float>] { recording.centers(at: frame) }
    }

    /// How the search runs. Without a guess it looks over the whole take and every direction.
    public struct Options: Sendable {
        /// Where to start, in Myr; absent, the whole take.
        public var moment: Double?
        /// How far either side of `moment` to look, in Myr.
        public var within: Double = 150
        /// Where to start looking from; absent, every direction.
        public var view: View?
        /// How far from `view`'s direction to look, in degrees.
        public var span: Double = 45
        /// Levels above this, in decades below the picture's reference light, count as this:
        /// the bodies' weight capped (see the note).
        public var ceiling: Float = -1
        /// Blur of both maps, in pixels of a 256 wide map.
        public var blur: Float = 1.5
        public var coarseWidth = 64
        public var coarseStars = 20_000
        public var stars = 200_000
        /// Frames looked at in the coarse pass, spread over the window.
        public var coarseFrames = 24
        /// Degrees between neighbouring directions in the coarse pass.
        public var directionStep: Double = 12
        /// Candidates the coarse pass hands the fine one.
        public var candidates = 4
        /// Kiloparsecs across the picture's width when the distance gives them; absent, the
        /// scale is searched too, and trades against time (see the note).
        public var kpcPerWidth: Double?
        public var measure: Measure = .isophotes

        public init() {}
    }

    public struct Trial: Sendable, Equatable {
        public var frame: Int
        public var megayears: Double
        public var view: View
        public var score: Double
    }

    public struct Outcome: Sendable {
        public var best: Trial
        /// The score along time (the direction held, the placement fitted again), and along each
        /// angle (all else held), as (Myr or degrees, score).
        public var time: [SIMD2<Double>]
        public var elevation: [SIMD2<Double>]
        public var azimuth: [SIMD2<Double>]
        public var roll: [SIMD2<Double>]
        /// Both maps at the picture's size, as the score sees them before the cap; NaN where the
        /// picture was masked.
        public var pictureLevels: [Float]
        public var takeLevels: [Float]
        public var trials: Int
    }

    // MARK: The maps

    /// How two maps are held against each other (the note compares them).
    public enum Measure: String, Sendable, CaseIterable {
        /// The overlap of their isophotes, intersection over union, averaged over levels from
        /// just above the sky to the ceiling.
        case isophotes
        /// The correlation of their levels capped at the ceiling.
        case correlation
        /// The same with the sky, the faint light and the bodies weighed a third each.
        case balanced
    }

    /// A picture made ready to be scored against.
    struct Target {
        let width: Int
        let height: Int
        let depth: Float
        let ceiling: Float
        let sigma: Float
        let measure: Measure
        let seen: [Int32]
        let levels: [Float]
        let nuclei: [SIMD2<Double>]?
        /// The isophote levels, and the picture's membership of each, pixel by pixel.
        let thresholds: [Float]
        let inside: [[Float]]
        /// For the correlations: each seen pixel's weight, the picture's capped levels less
        /// their mean, and their spread.
        let weights: [Float]
        let centred: [Float]
        let norm: Float

        init(_ picture: Picture, ceiling: Float, sigma: Float, measure: Measure = .isophotes) {
            width = picture.width
            height = picture.height
            depth = picture.depth
            self.ceiling = ceiling
            self.sigma = sigma
            self.measure = measure
            nuclei = picture.nuclei
            let mask = picture.seen
            let blurred = PhotoMatch.blurred(
                picture.light.map { $0.isNaN ? 0 : $0 }, mask: mask, width: width, height: height,
                sigma: sigma)
            let seen = mask.indices.filter { mask[$0] }.map(Int32.init)
            var levels = PhotoMatch.levels(blurred, at: seen, depth: depth)
            for index in mask.indices where !mask[index] { levels[index] = .nan }
            self.levels = levels
            self.seen = seen
            let sky = -depth + PhotoMatch.skyMargin
            let top = max(ceiling, sky + 0.5)
            let low: Float = sky + 0.15
            let gap: Float = (top - low) / Float(PhotoMatch.isophotes - 1)
            thresholds = (0..<PhotoMatch.isophotes).map { low + gap * Float($0) }
            inside = thresholds.map { t in seen.map { PhotoMatch.membership(levels[Int($0)], t) } }
            switch measure {
            case .isophotes, .correlation:
                weights = [Float](repeating: 1 / Float(max(seen.count, 1)), count: seen.count)
            case .balanced:
                let classes = seen.map { index -> Int in
                    let level = levels[Int(index)]
                    return level <= sky ? 0 : level <= ceiling ? 1 : 2
                }
                var counts: [Int] = [0, 0, 0]
                for c in classes { counts[c] += 1 }
                let present: Int = counts.filter { $0 > 0 }.count
                weights = classes.map { (c: Int) -> Float in 1 / Float(max(present * counts[c], 1)) }
            }
            let capped: [Float] = seen.map { (index: Int32) -> Float in min(levels[Int(index)], ceiling) }
            var mean: Float = 0
            for (value, weight) in zip(capped, weights) { mean += value * weight }
            centred = capped.map { (value: Float) -> Float in value - mean }
            var square: Float = 0
            for (value, weight) in zip(centred, weights) { square += value * value * weight }
            norm = square.squareRoot()
        }

        /// How well the take's light goes with the picture's, from 0 to 1.
        func score(_ light: [Float]) -> Double {
            let levels = PhotoMatch.levels(light, at: seen, depth: depth)
            if measure == .isophotes {
                var total: Float = 0
                for (t, threshold) in thresholds.enumerated() {
                    let picture = inside[t]
                    var both: Float = 0
                    var either: Float = 0
                    for (k, index) in seen.enumerated() {
                        let take = PhotoMatch.membership(levels[Int(index)], threshold)
                        both += min(take, picture[k])
                        either += max(take, picture[k])
                    }
                    total += either > 0 ? both / either : 0
                }
                return Double(total) / Double(thresholds.count)
            }
            var mean: Float = 0
            for (k, index) in seen.enumerated() { mean += min(levels[Int(index)], ceiling) * weights[k] }
            var cross: Float = 0
            var own: Float = 0
            for (k, index) in seen.enumerated() {
                let value = min(levels[Int(index)], ceiling) - mean
                cross += value * centred[k] * weights[k]
                own += value * value * weights[k]
            }
            guard own > 0, norm > 0 else { return 0 }
            return max(Double(cross / (own.squareRoot() * norm)), 0)
        }
    }

    static let isophotes = 6
    /// Decades over which a pixel goes from outside an isophote to inside it.
    static let isophoteWidth: Float = 0.25

    @inline(__always) static func membership(_ level: Float, _ threshold: Float) -> Float {
        min(max((level - threshold) / isophoteWidth + 0.5, 0), 1)
    }

    /// Decades above the picture's floor still counted as sky.
    static let skyMargin: Float = 0.3

    /// Log brightness against the light the brightest half percent of the seen pixels reach,
    /// floored `depth` decades down.
    static func levels(_ light: [Float], at seen: [Int32], depth: Float) -> [Float] {
        let reference = percentile(seen.map { light[Int($0)] }, 0.995)
        let floor = pow(10, -depth)
        guard reference > 0 else { return [Float](repeating: -depth, count: light.count) }
        return light.map { log10(max($0 / reference, floor)) }
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        var values = values
        let k = min(max(Int((Double(values.count - 1) * p).rounded()), 0), values.count - 1)
        var low = 0
        var high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low
            var j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { high = j } else if k >= i { low = i } else { break }
        }
        return values[k]
    }

    static func gaussian(_ sigma: Float) -> [Float] {
        let radius = max(Int((3 * sigma).rounded(.up)), 1)
        let spread: Float = 2 * sigma * sigma
        let weights: [Float] = (-radius...radius).map { (offset: Int) -> Float in
            let square = Float(offset * offset)
            return exp(-square / spread)
        }
        let total: Float = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// A separable Gaussian; light beyond the edge is lost. With a mask, a normalised
    /// convolution, so the masked pixels neither darken nor lighten their neighbours.
    static func blurred(_ values: [Float], mask: [Bool]? = nil, width: Int, height: Int, sigma: Float)
        -> [Float]
    {
        guard sigma > 0.05 else { return values }
        let kernel = gaussian(sigma)
        let radius = kernel.count / 2
        func pass(_ input: [Float]) -> [Float] {
            var across = [Float](repeating: 0, count: input.count)
            for row in 0..<height {
                let base = row * width
                for column in 0..<width {
                    var sum: Float = 0
                    for k in max(-radius, -column)...min(radius, width - 1 - column) {
                        sum += input[base + column + k] * kernel[k + radius]
                    }
                    across[base + column] = sum
                }
            }
            var down = [Float](repeating: 0, count: input.count)
            for row in 0..<height {
                for k in max(-radius, -row)...min(radius, height - 1 - row) {
                    let weight = kernel[k + radius]
                    let from = (row + k) * width
                    let to = row * width
                    for column in 0..<width { down[to + column] += across[from + column] * weight }
                }
            }
            return down
        }
        guard let mask else { return pass(values) }
        let weights: [Float] = pass(mask.map { (seen: Bool) -> Float in seen ? 1 : 0 })
        let light: [Float] = pass(
            zip(values, mask).map { (value: Float, seen: Bool) -> Float in seen ? value : 0 })
        return zip(light, weights).map { (value: Float, weight: Float) -> Float in
            weight > 1e-3 ? value / weight : 0
        }
    }

    /// Stars already turned to the screen before the roll, in kiloparsecs.
    struct Screen {
        var points: [SIMD2<Float>]
        var light: [Float]
        var centres: [SIMD2<Double>]

        init(_ stars: Stars, centres: [SIMD3<Float>], elevation: Double, azimuth: Double) {
            let (x, y) = View.screenRows(elevation: elevation, azimuth: azimuth)
            points = stars.positions.map { SIMD2(dot(x, $0), dot(y, $0)) }
            light = stars.light
            self.centres = centres.map { SIMD2(Double(dot(x, $0)), Double(dot(y, $0))) }
        }
    }

    /// The take's light on a target's grid, blurred as the picture was.
    static func render(_ screen: Screen, view: View, on target: Target) -> [Float] {
        let width = target.width
        let height = target.height
        var grid = [Float](repeating: 0, count: width * height)
        let m = view.placement * Double(width)
        let o = view.origin * Double(width) - SIMD2(0.5, 0.5)
        let (xx, xy, yx, yy) = (Float(m.x), Float(m.y), Float(m.z), Float(m.w))
        let (ox, oy) = (Float(o.x), Float(o.y))
        let right = Float(width - 1)
        let bottom = Float(height - 1)
        for (point, light) in zip(screen.points, screen.light) {
            let px = ox + xx * point.x + xy * point.y
            let py = oy + yx * point.x + yy * point.y
            guard px > -1, py > -1, px < Float(width), py < Float(height) else { continue }
            let fx = px.rounded(.down)
            let fy = py.rounded(.down)
            let dx = px - fx
            let dy = py - fy
            let ix = Int(fx)
            let iy = Int(fy)
            if fx >= 0, fy >= 0 { grid[iy * width + ix] += light * (1 - dx) * (1 - dy) }
            if fx + 1 <= right, fy >= 0 { grid[iy * width + ix + 1] += light * dx * (1 - dy) }
            if fx >= 0, fy + 1 <= bottom { grid[(iy + 1) * width + ix] += light * (1 - dx) * dy }
            if fx + 1 <= right, fy + 1 <= bottom { grid[(iy + 1) * width + ix + 1] += light * dx * dy }
        }
        return blurred(grid, width: width, height: height, sigma: target.sigma)
    }

    static func score(_ screen: Screen, view: View, on target: Target) -> Double {
        target.score(render(screen, view: view, on: target))
    }

    // MARK: The search

    /// The placements that put the two first galaxies' centres on the two marked nuclei, one
    /// for each way of pairing them. With the scale known, the pair's middle goes on the
    /// nuclei's.
    static func placements(_ screen: Screen, nuclei: [SIMD2<Double>], view: View, kpcPerWidth: Double? = nil)
        -> [View]
    {
        guard nuclei.count >= 2, screen.centres.count >= 2 else { return [] }
        var views: [View] = []
        for (a, b) in [(0, 1), (1, 0)] {
            let s = screen.centres[1] - screen.centres[0]
            let n = nuclei[b] - nuclei[a]
            let length = (s.x * s.x + s.y * s.y).squareRoot()
            let span = (n.x * n.x + n.y * n.y).squareRoot()
            guard length > 1e-6, span > 1e-6 else { continue }
            var placed = view
            placed.roll = (atan2(n.y, n.x) - atan2(s.y, s.x)) * 180 / .pi
            placed.kpcPerWidth = kpcPerWidth ?? length / span
            placed.origin = SIMD2(0, 0)
            let middle = (screen.centres[0] + screen.centres[1]) / 2
            placed.origin = (nuclei[a] + nuclei[b]) / 2 - placed.placementApplied(middle)
            views.append(placed)
        }
        return views
    }

    /// A placement from the light alone: the centres of light on each other and the radii
    /// holding most of it in proportion, at the given roll.
    static func moments(
        _ screen: Screen, target: Target, picture: Picture, view: View, kpcPerWidth: Double? = nil
    ) -> View {
        var total: Double = 0
        var centre = SIMD2<Double>(0, 0)
        for (point, light) in zip(screen.points, screen.light) {
            total += Double(light)
            centre += SIMD2(Double(point.x), Double(point.y)) * Double(light)
        }
        centre /= max(total, 1e-12)
        let radii: [Float] = screen.points.map { (p: SIMD2<Float>) -> Float in
            let d: SIMD2<Double> = SIMD2<Double>(Double(p.x), Double(p.y)) - centre
            let radius: Double = (d.x * d.x + d.y * d.y).squareRoot()
            return Float(radius)
        }
        let takeRadius = Double(percentile(radii, 0.9))
        var pictureTotal: Double = 0
        var pictureCentre = SIMD2<Double>(0, 0)
        var lit: [(SIMD2<Double>, Double)] = []
        for index in target.seen {
            let value = Double(picture.light[Int(index)])
            guard value > 0 else { continue }
            let at = SIMD2(
                (Double(Int(index) % picture.width) + 0.5) / Double(picture.width),
                (Double(Int(index) / picture.width) + 0.5) / Double(picture.width))
            pictureTotal += value
            pictureCentre += at * value
            lit.append((at, value))
        }
        pictureCentre /= max(pictureTotal, 1e-12)
        var reach: [(radius: Double, value: Double)] = []
        reach.reserveCapacity(lit.count)
        for (at, value) in lit {
            let d: SIMD2<Double> = at - pictureCentre
            let radius: Double = (d.x * d.x + d.y * d.y).squareRoot()
            reach.append((radius, value))
        }
        reach.sort { $0.radius < $1.radius }
        var running: Double = 0
        var pictureRadius = 0.25
        for (radius, value) in reach {
            running += value
            if running >= 0.9 * pictureTotal {
                pictureRadius = radius
                break
            }
        }
        var placed = view
        placed.kpcPerWidth = kpcPerWidth ?? max(takeRadius, 1e-3) / max(pictureRadius, 1e-3)
        placed.origin = SIMD2(0, 0)
        placed.origin = pictureCentre - placed.placementApplied(centre)
        return placed
    }

    /// A compass search: each parameter tried a step either way, the steps halved when none
    /// helps, until they are all below their floors or the budget is spent.
    static func climb(
        _ start: [Double], steps: [Double], floors: [Double], budget: Int,
        _ score: ([Double]) -> Double
    ) -> (point: [Double], score: Double, spent: Int) {
        var point = start
        var best = score(point)
        var steps = steps
        var spent = 1
        while spent < budget, zip(steps, floors).contains(where: { $0 > $1 }) {
            var moved = false
            for dimension in point.indices where steps[dimension] > floors[dimension] {
                for sign in [1.0, -1.0] {
                    var trial = point
                    trial[dimension] += sign * steps[dimension]
                    let value = score(trial)
                    spent += 1
                    if value > best {
                        best = value
                        point = trial
                        moved = true
                        break
                    }
                }
                if spent >= budget { break }
            }
            if !moved { steps = steps.map { $0 / 2 } }
        }
        return (point, best, spent)
    }

    /// Directions spread evenly over the sphere, `step` degrees apart, as (elevation, azimuth).
    static func directions(step: Double) -> [SIMD2<Double>] {
        let radians = step * .pi / 180
        let count = max(Int((4 * .pi / (radians * radians)).rounded()), 12)
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { index in
            let share: Double = (Double(index) + 0.5) / Double(count)
            let z: Double = 1 - 2 * share
            let azimuth: Double = (Double(index) * golden).truncatingRemainder(dividingBy: 2 * .pi)
            let degrees: Double = 180 / .pi
            return SIMD2<Double>(asin(z) * degrees, azimuth * degrees)
        }
    }

    /// Searches `frames` for the moment and the view that overlap `picture` best.
    public static func search(
        _ picture: Picture, frames: some Frames, options: Options = Options(),
        progress: (String) -> Void = { _ in }
    ) throws -> Outcome {
        guard frames.count > 0 else { throw Failure.take("no frame") }
        let scaleToFull = Float(picture.width) / 256
        let fine = Target(
            picture, ceiling: options.ceiling, sigma: options.blur * scaleToFull, measure: options.measure)
        guard !fine.seen.isEmpty else { throw Failure.picture("every pixel masked") }
        let factor = max(picture.width / max(options.coarseWidth, 8), 1)
        let coarsePicture = picture.reduced(by: factor)
        let coarse = Target(
            coarsePicture, ceiling: options.ceiling,
            sigma: max(options.blur * Float(coarsePicture.width) / 256, 0.7), measure: options.measure)
        let nuclei = picture.nuclei?.count ?? 0 >= 2 ? picture.nuclei : nil

        // The window and the frames the coarse pass looks at.
        let window: [Int] = (0..<frames.count).filter { frame in
            guard let moment = options.moment else { return true }
            return abs(frames.megayears(frame) - moment) <= options.within
        }
        guard !window.isEmpty else {
            throw Failure.take("no frame within \(options.within) Myr of \(options.moment ?? 0)")
        }
        let stride = max((window.count + options.coarseFrames - 1) / options.coarseFrames, 1)
        let coarseFrames = Swift.stride(from: 0, to: window.count, by: stride).map { window[$0] }
        let guessed = options.view
        let directions = directions(step: options.directionStep).filter { direction in
            guard let guessed else { return true }
            return View(elevation: direction.x, azimuth: direction.y).angle(to: guessed) <= options.span
        }
        let pairs = coarseFrames.flatMap { frame in directions.map { (frame, $0) } }
        progress(
            "coarse: \(coarseFrames.count) frames x \(directions.count) directions on a \(coarse.width) x \(coarse.height) map"
        )
        let coarseStars = coarseFrames.map { frames.stars($0, limit: options.coarseStars) }
        let coarseCentres = coarseFrames.map { frames.centres($0) }
        let slot = Dictionary(uniqueKeysWithValues: coarseFrames.enumerated().map { ($1, $0) })

        let known = options.kpcPerWidth
        let scaleStep = known == nil ? 1.0 : 0

        // Fits the placement of one direction at one frame: roll, scale and shift.
        func fit(_ screen: Screen, view: View, target: Target, picture: Picture, budget: Int)
            -> (View, Double, Int)
        {
            var spent = 0
            var starts: [View] = []
            if let nuclei {
                starts = placements(screen, nuclei: nuclei, view: view, kpcPerWidth: known)
            }
            if starts.isEmpty {
                // The roll is the one thing the moments leave open.
                var best = view
                var bestScore = -1.0
                for roll in Swift.stride(from: 0.0, to: 360, by: 20) {
                    let trial = moments(
                        screen, target: target, picture: picture,
                        view: View(elevation: view.elevation, azimuth: view.azimuth, roll: roll),
                        kpcPerWidth: known)
                    let value = score(screen, view: trial, on: target)
                    spent += 1
                    if value > bestScore {
                        bestScore = value
                        best = trial
                    }
                }
                starts = [best]
            }
            var best = starts[0]
            var bestScore = -1.0
            for start in starts {
                func placed(_ p: [Double]) -> View {
                    View(
                        elevation: view.elevation, azimuth: view.azimuth, roll: p[0],
                        kpcPerWidth: known ?? exp(p[1]), origin: SIMD2(p[2], p[3]))
                }
                let climbed = climb(
                    [start.roll, log(start.kpcPerWidth), start.origin.x, start.origin.y],
                    steps: [8, 0.15 * scaleStep, 0.03, 0.03], floors: [1, 0.02 * scaleStep, 0.004, 0.004],
                    budget: budget
                ) { score(screen, view: placed($0), on: target) }
                spent += climbed.spent
                if climbed.score > bestScore {
                    bestScore = climbed.score
                    best = placed(climbed.point)
                }
            }
            return (best, bestScore, spent)
        }

        var coarseTrials = [Trial?](repeating: nil, count: pairs.count)
        var spent = [Int](repeating: 0, count: pairs.count)
        coarseTrials.withUnsafeMutableBufferPointer { out in
            spent.withUnsafeMutableBufferPointer { counts in
                concurrentPerform(iterations: pairs.count) { index in
                    let (frame, direction) = pairs[index]
                    let s = slot[frame]!
                    let screen = Screen(
                        coarseStars[s], centres: coarseCentres[s], elevation: direction.x,
                        azimuth: direction.y)
                    let (view, value, used) = fit(
                        screen, view: View(elevation: direction.x, azimuth: direction.y),
                        target: coarse, picture: coarsePicture, budget: 40)
                    out[index] = Trial(
                        frame: frame, megayears: frames.megayears(frame), view: view, score: value)
                    counts[index] = used
                }
            }
        }
        var trials = spent.reduce(0, +)
        let ranked = coarseTrials.compactMap { $0 }.sorted { $0.score > $1.score }
        var picked: [Trial] = []
        for trial in ranked where picked.count < options.candidates {
            let near = picked.contains {
                abs($0.frame - trial.frame) <= stride
                    && $0.view.angle(to: trial.view) < 2 * options.directionStep
            }
            if !near { picked.append(trial) }
        }
        guard let leader = picked.first else { throw Failure.take("no trial scored") }
        progress(
            String(
                format: "coarse best %.3f at %.0f Myr; refining %d candidates", leader.score,
                leader.megayears, picked.count))

        // The fine pass: every frame around each candidate, all six numbers climbed.
        var fineStars: [Int: Stars] = [:]
        var fineCentres: [Int: [SIMD3<Float>]] = [:]
        func load(_ frame: Int) {
            guard fineStars[frame] == nil else { return }
            fineStars[frame] = frames.stars(frame, limit: options.stars)
            fineCentres[frame] = frames.centres(frame)
        }
        func refine(_ stars: Stars, _ centres: [SIMD3<Float>], from view: View, floor: Double, budget: Int)
            -> (View, Double, Int)
        {
            func placed(_ p: [Double]) -> View {
                View(
                    elevation: p[0], azimuth: p[1], roll: p[2], kpcPerWidth: known ?? exp(p[3]),
                    origin: SIMD2(p[4], p[5]))
            }
            let climbed = climb(
                [
                    view.elevation, view.azimuth, view.roll, log(view.kpcPerWidth), view.origin.x,
                    view.origin.y,
                ],
                steps: [4, 4, 4, 0.06 * scaleStep, 0.012, 0.012],
                floors: [floor, floor, floor, 0.012 * floor * scaleStep, 0.002 * floor, 0.002 * floor],
                budget: budget
            ) { p in
                score(
                    Screen(stars, centres: centres, elevation: p[0], azimuth: p[1]), view: placed(p), on: fine
                )
            }
            return (placed(climbed.point), climbed.score, climbed.spent)
        }
        var best = leader
        best.score = -1
        for candidate in picked {
            let around = window.filter { abs($0 - candidate.frame) <= stride }
            for frame in around { load(frame) }
            var results = [Trial?](repeating: nil, count: around.count)
            var used = [Int](repeating: 0, count: around.count)
            let loadedStars = fineStars
            let loadedCentres = fineCentres
            results.withUnsafeMutableBufferPointer { out in
                used.withUnsafeMutableBufferPointer { counts in
                    concurrentPerform(iterations: around.count) { index in
                        let frame = around[index]
                        let (view, value, spent) = refine(
                            loadedStars[frame]!, loadedCentres[frame]!, from: candidate.view, floor: 0.5,
                            budget: 120)
                        out[index] = Trial(
                            frame: frame, megayears: frames.megayears(frame), view: view, score: value)
                        counts[index] = spent
                    }
                }
            }
            trials += used.reduce(0, +)
            if let top = results.compactMap({ $0 }).max(by: { $0.score < $1.score }), top.score > best.score {
                best = top
            }
        }
        let (finalView, finalScore, finalSpent) = refine(
            fineStars[best.frame]!, fineCentres[best.frame]!, from: best.view, floor: 0.2, budget: 600)
        trials += finalSpent
        if finalScore > best.score {
            best.view = finalView
            best.score = finalScore
        }
        best.view.roll = wrapped(best.view.roll)
        best.view.azimuth = wrapped(best.view.azimuth)
        progress(String(format: "best %.3f at %.0f Myr after %d trials", best.score, best.megayears, trials))

        // The curves around the best.
        let stars = fineStars[best.frame]!
        let centres = fineCentres[best.frame]!
        func held(_ change: (inout View) -> Void) -> Double {
            var view = best.view
            change(&view)
            return score(
                Screen(stars, centres: centres, elevation: view.elevation, azimuth: view.azimuth),
                view: view, on: fine)
        }
        let elevationCurve = Swift.stride(from: -90.0, through: 90, by: 2).map { e in
            SIMD2(e, held { $0.elevation = e })
        }
        let azimuthCurve = Swift.stride(from: -180.0, through: 180, by: 4).map { d in
            SIMD2(best.view.azimuth + d, held { $0.azimuth = best.view.azimuth + d })
        }
        let rollCurve = Swift.stride(from: -180.0, through: 180, by: 4).map { d in
            SIMD2(best.view.roll + d, held { $0.roll = best.view.roll + d })
        }
        let timeStride = max((window.count + 119) / 120, 1)
        let timeFrames = Swift.stride(from: 0, to: window.count, by: timeStride).map { window[$0] }
        var timeCurve = [SIMD2<Double>](repeating: .zero, count: timeFrames.count)
        let timeStars = timeFrames.map { frames.stars($0, limit: options.coarseStars * 2) }
        let timeCentres = timeFrames.map { frames.centres($0) }
        timeCurve.withUnsafeMutableBufferPointer { out in
            concurrentPerform(iterations: timeFrames.count) { index in
                let screen = Screen(
                    timeStars[index], centres: timeCentres[index], elevation: best.view.elevation,
                    azimuth: best.view.azimuth)
                let (_, value, _) = fit(screen, view: best.view, target: fine, picture: picture, budget: 30)
                out[index] = SIMD2(frames.megayears(timeFrames[index]), value)
            }
        }
        let takeLight = render(
            Screen(stars, centres: centres, elevation: best.view.elevation, azimuth: best.view.azimuth),
            view: best.view, on: fine)
        let takeLevels = levels(takeLight, at: fine.seen, depth: fine.depth)
        return Outcome(
            best: best, time: timeCurve, elevation: elevationCurve, azimuth: azimuthCurve,
            roll: rollCurve, pictureLevels: fine.levels, takeLevels: takeLevels, trials: trials)
    }

    static func wrapped(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }
}

extension PhotoMatch.View {
    /// Roll and scale alone, before the origin is added.
    func placementApplied(_ s: SIMD2<Double>) -> SIMD2<Double> {
        let m = placement
        return SIMD2(m.x * s.x + m.y * s.y, m.z * s.x + m.w * s.y)
    }
}

private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
