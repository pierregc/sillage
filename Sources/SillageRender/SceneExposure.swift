import Foundation

/// An exposure taken from the frames' own light (#340): the look's brightness and stretch scaled
/// until the lit pixels' median and 99th centile of OKLab L land on `median` and `top`, as
/// `scripts/photo-ruler.py` reads them. `brightness`, `stretch` and `whitePoint` are absolute, so
/// without it a scene with another light profile lands elsewhere on the curve.
public struct LookExposure: Codable, Sendable, Equatable {
    public var median: Float
    public var top: Float

    public init(median: Float = 0.47, top: Float = 0.93) {
        self.median = median
        self.top = top
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookExposure()
        self.init(median: try c.value(.median, or: d.median), top: try c.value(.top, or: d.top))
    }
}

/// What an exposure multiplies the look's brightness and stretch by.
public struct ExposureScale: Sendable, Equatable {
    public var brightness: Float
    public var stretch: Float

    public static let unit = ExposureScale(brightness: 1, stretch: 1)

    public init(brightness: Float, stretch: Float) {
        self.brightness = brightness
        self.stretch = stretch
    }

    public func applied(to look: RenderLook) -> RenderLook {
        var look = look
        look.brightness *= brightness
        look.stretch *= stretch
        return look
    }
}

/// The lit pixels' light in a frame, as the ruler measures it.
public struct ExposureReading: Sendable, Equatable {
    /// OKLab L at the median and the 99th centile.
    public var median: Float
    public var top: Float
    /// Share of the frame lit.
    public var lit: Float
}

/// `photo-ruler.py`'s L50 and L99, on a frame read back as RGBA.
public enum ExposureMeter {
    /// The ruler's width: every frame is read at it.
    static let width = 960
    /// Lit is this far in L above the sky, the sky being a low centile of L blurred at 4 px.
    static let litMargin: Float = 0.10
    static let skyCentile: Float = 0.05
    static let minimumLit = 100

    public static func read(rgba: [UInt8], width: Int, height: Int) -> ExposureReading? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let (lightness, w, h) = self.lightness(rgba, width: width, height: height)
        var blurred = lightness
        // The ruler's three box passes for a Gaussian of 4 px.
        for size in [7, 7, 9] {
            blurred = box(blurred, width: w, height: h, size: size, horizontal: true)
            blurred = box(blurred, width: w, height: h, size: size, horizontal: false)
        }
        let sky = centile(blurred.sorted(), skyCentile)
        var lit = lightness.filter { $0 > sky + litMargin }
        guard lit.count >= minimumLit else { return nil }
        lit.sort()
        return ExposureReading(
            median: centile(lit, 0.5), top: centile(lit, 0.99),
            lit: Float(lit.count) / Float(lightness.count))
    }

    /// OKLab L of every pixel, area-averaged down to `width` first when wider.
    static func lightness(_ rgba: [UInt8], width: Int, height: Int) -> ([Float], Int, Int) {
        let w = min(width, Self.width)
        let h = max(Int((Double(height) * Double(w) / Double(width)).rounded()), 1)
        let linear = (0..<256).map { value -> Float in
            let c = Float(value) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * height / h
            let y1 = max((y + 1) * height / h, y0 + 1)
            for x in 0..<w {
                let x0 = x * width / w
                let x1 = max((x + 1) * width / w, x0 + 1)
                var sum = SIMD3<Float>(repeating: 0)
                for sy in y0..<y1 {
                    var index = (sy * width + x0) * 4
                    for _ in x0..<x1 {
                        sum += SIMD3(Float(rgba[index]), Float(rgba[index + 1]), Float(rgba[index + 2]))
                        index += 4
                    }
                }
                let area = Float((y1 - y0) * (x1 - x0))
                let rgb = sum / (area * 255)
                // Averaged as the ruler's resize does, in sRGB, then made linear.
                let r = linear[Int((rgb.x * 255).rounded())]
                let g = linear[Int((rgb.y * 255).rounded())]
                let b = linear[Int((rgb.z * 255).rounded())]
                let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
                let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
                let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
                out[y * w + x] = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            }
        }
        return (out, w, h)
    }

    /// A centred box mean along one axis, mirrored at the edges.
    static func box(_ a: [Float], width: Int, height: Int, size: Int, horizontal: Bool) -> [Float] {
        let (lines, length) = horizontal ? (height, width) : (width, height)
        let r = size / 2
        var out = a
        var line = [Float](repeating: 0, count: length)
        for index in 0..<lines {
            func at(_ i: Int) -> Int { horizontal ? index * width + i : i * width + index }
            for i in 0..<length { line[i] = a[at(i)] }
            func value(_ i: Int) -> Float {
                var j = i
                if j < 0 { j = -j - 1 }
                if j >= length { j = 2 * length - j - 1 }
                return line[min(max(j, 0), length - 1)]
            }
            var sum: Float = 0
            for i in -r...r { sum += value(i) }
            for i in 0..<length {
                out[at(i)] = sum / Float(size)
                sum += value(i + r + 1) - value(i - r)
            }
        }
        return out
    }

    /// numpy's linear centile of sorted values.
    static func centile(_ sorted: [Float], _ q: Float) -> Float {
        guard let first = sorted.first else { return 0 }
        let position = q * Float(sorted.count - 1)
        let low = Int(position)
        guard low + 1 < sorted.count else { return sorted.last ?? first }
        return sorted[low] + (sorted[low + 1] - sorted[low]) * (position - Float(low))
    }
}

/// The brightness and stretch scales a frame needs, found by drawing it a few times.
public enum ExposureSolver {
    public struct Solution: Sendable {
        public var scale: ExposureScale
        public var reading: ExposureReading
        public var draws: Int
    }

    /// In L: well under what the ruler tells apart between two runs of the same frame.
    public static let tolerance: Float = 0.004
    public static let maximumDraws = 9
    /// Either scale stays within this factor of the look's own.
    static let range: Float = 16

    /// `draw` draws the frame at a scale and reads it; nil when too little of it is lit to
    /// measure. Newton's method on the logs of both scales, its Jacobian taken by finite
    /// differences once and then updated (Broyden): the light moves smoothly with both and
    /// the median and the top answer them differently. Without `stretches`, the brightness
    /// alone puts the top in place.
    public static func solve(
        target: LookExposure, stretches: Bool,
        draw: (ExposureScale) throws -> ExposureReading?
    ) rethrows -> Solution? {
        var draws = 0
        let bound = logf(range)
        func at(_ x: SIMD2<Float>) throws -> (error: SIMD2<Float>, reading: ExposureReading)? {
            draws += 1
            let scale = ExposureScale(brightness: expf(x.x), stretch: stretches ? expf(x.y) : 1)
            guard let reading = try draw(scale) else { return nil }
            return (SIMD2(stretches ? reading.median - target.median : 0, reading.top - target.top), reading)
        }
        func size(_ e: SIMD2<Float>) -> Float { max(abs(e.x), abs(e.y)) }

        var x = SIMD2<Float>(0, 0)
        guard var current = try at(x) else { return nil }
        var best = (x: x, current: current)
        func keep(_ x: SIMD2<Float>, _ next: (error: SIMD2<Float>, reading: ExposureReading)) {
            if size(next.error) < size(best.current.error) { best = (x, next) }
        }
        func solution() -> Solution {
            Solution(
                scale: ExposureScale(
                    brightness: expf(best.x.x), stretch: stretches ? expf(best.x.y) : 1),
                reading: best.current.reading, draws: draws)
        }
        if size(current.error) < tolerance { return solution() }

        // Columns: how the error moves with the brightness's log, and with the stretch's.
        let h: Float = 0.2
        guard let along = try at(x + SIMD2(h, 0)) else { return solution() }
        keep(x + SIMD2(h, 0), along)
        var du = (along.error - current.error) / h
        var dv = SIMD2<Float>(0, 1)
        if stretches {
            guard let across = try at(x + SIMD2(0, h)) else { return solution() }
            keep(x + SIMD2(0, h), across)
            dv = (across.error - current.error) / h
        }
        while draws < maximumDraws, size(best.current.error) >= tolerance {
            let e = current.error
            var step: SIMD2<Float>
            if stretches {
                let determinant = du.x * dv.y - dv.x * du.y
                guard abs(determinant) > 1e-6 else { break }
                step = SIMD2(
                    (-e.x * dv.y + dv.x * e.y) / determinant, (-du.x * e.y + du.y * e.x) / determinant)
            } else {
                guard abs(du.y) > 1e-6 else { break }
                step = SIMD2(-e.y / du.y, 0)
            }
            step = step.clamped(lowerBound: SIMD2(repeating: -1.5), upperBound: SIMD2(repeating: 1.5))
            let next = (x + step).clamped(
                lowerBound: SIMD2(repeating: -bound), upperBound: SIMD2(repeating: bound))
            let moved = next - x
            guard size(moved) > 1e-5, let reading = try at(next) else { break }
            keep(next, reading)
            // Broyden: the Jacobian corrected along the step just taken.
            let change = reading.error - current.error
            let predicted = du * moved.x + dv * moved.y
            let length = moved.x * moved.x + moved.y * moved.y
            du += (change - predicted) * (moved.x / length)
            dv += (change - predicted) * (moved.y / length)
            (x, current) = (next, reading)
        }
        return solution()
    }

    /// One exposure for frames solved apart, so a clip drawn with it does not pump: the
    /// geometric mean of their scales.
    public static func held(_ solutions: [Solution]) -> ExposureScale {
        guard !solutions.isEmpty else { return .unit }
        let n = Float(solutions.count)
        return ExposureScale(
            brightness: expf(solutions.map { logf($0.scale.brightness) }.reduce(0, +) / n),
            stretch: expf(solutions.map { logf($0.scale.stretch) }.reduce(0, +) / n))
    }
}

/// The exposure a video was drawn with and the frames it was measured on.
public struct ClipExposure: Sendable {
    public var scale: ExposureScale
    /// Each frame measured, and what it alone would have needed.
    public var samples: [Sample]

    public struct Sample: Sendable {
        public var captured: Double
        public var solution: ExposureSolver.Solution
    }

    public init(scale: ExposureScale, samples: [Sample]) {
        self.scale = scale
        self.samples = samples
    }

    /// Frames measured on a clip of `count`: the middles of equal stretches of it.
    public static func samples(of count: Int, at most: Int = 7) -> [Int] {
        let n = min(count, most)
        return (0..<n).map { (2 * $0 + 1) * count / (2 * n) }
    }

    public var summary: String {
        let brightness = samples.map(\.solution.scale.brightness)
        let stretch = samples.map(\.solution.scale.stretch)
        return String(
            format: "brightness x%.3f, stretch x%.3f over %d frames (alone x%.2f-%.2f and x%.2f-%.2f)",
            scale.brightness, scale.stretch, samples.count, brightness.min() ?? 1,
            brightness.max() ?? 1, stretch.min() ?? 1, stretch.max() ?? 1)
    }
}
