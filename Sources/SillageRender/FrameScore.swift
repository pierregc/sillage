import Foundation
import simd

/// How good a rendered frame looks, from 0 to 1, measured on its pixels. Every part is 0 to 1
/// too, and the total is their weighted mean.
public struct FrameScore: Sendable, Equatable, Codable {
    /// The raw measures the parts are read from.
    public struct Measures: Sendable, Equatable, Codable {
        /// Share of the lit pixels with a channel at the top of its range.
        public var clipped: Float
        /// Mean display luma of the lit pixels.
        public var litLuma: Float
        /// Luma under which the brightest twentieth of the lit pixels starts.
        public var peakLuma: Float
        /// Hasler and Süsstrunk's colourfulness of the lit pixels, on 0 to 255 values.
        public var colourfulness: Float
        /// Smallest distance between two galaxies' drawn colours at the common lightness; nil
        /// with fewer than two galaxies in sight.
        public var nearest: Float?
        /// Median deviation of a sky pixel from its neighbours, on 0 to 255 values.
        public var skyNoise: Float
        /// Mean local contrast of the lit pixels against a 7 pixel box around them.
        public var detail: Float
        /// Mean distance of the galaxies' drawn colours to the nearest reference tone.
        public var referenceMiss: Float?
        /// Mean over the galaxies of how far their lit pixels spread in hue and saturation at
        /// the common lightness (the standard deviation in the chromatic plane); nil with no
        /// galaxy in sight.
        public var spread: Float?
    }

    public var clipping: Float
    public var exposure: Float
    public var colourfulness: Float
    public var separation: Float
    public var noise: Float
    /// Structure left in the galaxies: low when glow washes the arms and knots into blobs.
    public var detail: Float
    /// Only in the telescope world, with the reference files of #125.
    public var reference: Float?
    /// Only for a palette with a ramp per galaxy (#120): whether the ramps show, each galaxy
    /// drawn in more than one colour.
    public var variety: Float?
    public var total: Float
    public var measures: Measures

    static let weights:
        (
            clipping: Float, exposure: Float, colourfulness: Float, separation: Float,
            noise: Float, detail: Float, reference: Float, variety: Float
        ) = (0.1, 0.15, 0.2, 0.2, 0.1, 0.1, 0.15, 0.1)

    /// Display luma above which a pixel belongs to something rather than to the sky.
    static let litLuma: Float = 0.1
    /// An 8-bit channel at or above this is clipped.
    static let clipLevel: UInt8 = 250
    /// Local contrast at which a galaxy counts as fully drawn.
    static let sharpDetail: Float = 0.12
    /// Spread at which a ramp counts as fully shown. On three night scenes the free world's
    /// ramps spread 0.05 to 0.06 against 0.03 to 0.05 for one colour, the telescope's 0.02.
    static let fullSpread: Float = 0.08

    /// `pixels` are 8-bit sRGB RGBA, `width` by `height`. `owners` gives each pixel's galaxy
    /// plus one, 0 where none or several share it; without it the frame counts as one galaxy.
    /// `references` are #125's sets, given in the telescope world only. `ramps` says the
    /// palette gives each galaxy several colours, so the frame is also judged on showing them.
    public init(
        pixels: [UInt8], width: Int, height: Int, owners: [UInt8]? = nil,
        references: [TelescopeReference] = [], ramps: Bool = false
    ) {
        let count = width * height
        precondition(pixels.count >= count * 4)
        var luma = [Float](repeating: 0, count: count)
        var lit = 0
        var clipped = 0
        var litSum: Float = 0
        var rg: (sum: Double, square: Double) = (0, 0)
        var yb: (sum: Double, square: Double) = (0, 0)
        for i in 0..<count {
            let r = Float(pixels[4 * i]) / 255
            let g = Float(pixels[4 * i + 1]) / 255
            let b = Float(pixels[4 * i + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luma[i] = y
            guard y >= Self.litLuma else { continue }
            lit += 1
            litSum += y
            if max(pixels[4 * i], pixels[4 * i + 1], pixels[4 * i + 2]) >= Self.clipLevel {
                clipped += 1
            }
            let a = Double(r - g) * 255
            let c = Double(0.5 * (r + g) - b) * 255
            rg.sum += a
            rg.square += a * a
            yb.sum += c
            yb.square += c * c
        }

        var m = Measures(
            clipped: 0, litLuma: 0, peakLuma: Self.percentile(luma.filter { $0 >= Self.litLuma }, 0.95),
            colourfulness: 0,
            nearest: nil, skyNoise: Self.skyNoise(luma, width: width, height: height),
            detail: Self.detail(luma, width: width, height: height),
            referenceMiss: nil, spread: nil)
        if lit > 0 {
            let n = Double(lit)
            m.clipped = Float(clipped) / Float(lit)
            m.litLuma = litSum / Float(lit)
            let mean = (rg.sum / n, yb.sum / n)
            let deviation = (
                max(rg.square / n - mean.0 * mean.0, 0), max(yb.square / n - mean.1 * mean.1, 0)
            )
            m.colourfulness = Float(
                (deviation.0 + deviation.1).squareRoot()
                    + 0.3 * (mean.0 * mean.0 + mean.1 * mean.1).squareRoot())
        }

        let groups = Self.litColours(pixels: pixels, luma: luma, owners: owners)
        let drawn = Self.drawnColours(groups)
        m.spread = Self.spread(groups)
        if drawn.count > 1 {
            var nearest = Float.infinity
            for i in drawn.indices {
                for j in drawn.indices where j > i {
                    nearest = min(
                        nearest,
                        simd_distance(
                            TelescopeReference.plane(drawn[i]), TelescopeReference.plane(drawn[j])))
                }
            }
            m.nearest = nearest
        }
        if !references.isEmpty, !drawn.isEmpty {
            m.referenceMiss =
                drawn.map { lab in
                    references.map { $0.distance(lab: lab) }.min() ?? .infinity
                }.reduce(0, +) / Float(drawn.count)
        }
        self.init(measures: m, ramps: ramps)
    }

    /// The parts and the total from measures already taken.
    public init(measures m: Measures, ramps: Bool = false) {
        measures = m
        // A star field always clips a little; a tenth of what is lit is a blown core.
        clipping = 1 - PaletteScore.smooth((m.clipped - 0.01) / 0.12)
        // Dim lit areas read as murk, bright ones as wash; the brightest parts should reach
        // near white.
        let level = 1 - min(abs(log2(max(m.litLuma, 1e-3) / 0.3)) / 1.2, 1)
        let peak = PaletteScore.smooth((m.peakLuma - 0.3) / 0.45)
        exposure = level * (0.5 + 0.5 * peak)
        // Hasler and Süsstrunk call 45 fairly colourful and 110 extremely: past that it is
        // neon.
        colourfulness =
            PaletteScore.smooth(m.colourfulness / 40)
            * (1 - 0.7 * PaletteScore.smooth((m.colourfulness - 80) / 70))
        separation = m.nearest.map { PaletteScore.smooth($0 / 0.06) } ?? 1
        // The looks' own grain sits near 2; twice that shows.
        noise = 1 - PaletteScore.smooth((m.skyNoise - 1.5) / 4)
        detail = PaletteScore.smooth(m.detail / Self.sharpDetail)
        reference = m.referenceMiss.map {
            let ratio = $0 / PaletteScore.referenceScale
            return 1 / (1 + ratio * ratio)
        }
        variety = ramps ? m.spread.map { PaletteScore.smooth($0 / Self.fullSpread) } : nil
        let w = Self.weights
        var sum =
            w.clipping * clipping + w.exposure * exposure + w.colourfulness * colourfulness
            + w.separation * separation + w.noise * noise + w.detail * detail
        var weight =
            w.clipping + w.exposure + w.colourfulness + w.separation + w.noise + w.detail
        if let reference {
            sum += w.reference * reference
            weight += w.reference
        }
        if let variety {
            sum += w.variety * variety
            weight += w.variety
        }
        total = sum / weight
    }

    /// The OKLab colour of every lit, unclipped pixel, by galaxy.
    static func litColours(pixels: [UInt8], luma: [Float], owners: [UInt8]?) -> [Int: [SIMD3<Float>]] {
        var groups: [Int: [SIMD3<Float>]] = [:]
        for i in luma.indices where luma[i] >= Self.litLuma {
            let galaxy = owners.map { Int($0[i]) } ?? 1
            guard galaxy > 0 else { continue }
            let r = pixels[4 * i]
            let g = pixels[4 * i + 1]
            let b = pixels[4 * i + 2]
            guard max(r, g, b) < Self.clipLevel else { continue }
            groups[galaxy, default: []].append(
                OKLab.lab(SIMD3(linear[Int(r)], linear[Int(g)], linear[Int(b)])))
        }
        return groups
    }

    /// Fewest pixels a galaxy needs to be judged.
    static let minimumPixels = 24

    /// Each galaxy's colour as drawn, in OKLab: the mean of the most saturated sixth of its
    /// lit, unclipped pixels, as #125 measured the pictures. Galaxies with too few pixels in
    /// sight are left out.
    static func drawnColours(_ groups: [Int: [SIMD3<Float>]]) -> [SIMD3<Float>] {
        groups.keys.sorted().compactMap { key in
            let labs = groups[key]!
            guard labs.count >= minimumPixels else { return nil }
            let vivid = labs.sorted {
                simd_length(TelescopeReference.plane($0)) > simd_length(TelescopeReference.plane($1))
            }.prefix(max(labs.count / 6, 1))
            return vivid.reduce(SIMD3<Float>.zero, +) / Float(vivid.count)
        }
    }

    /// Mean over the galaxies of the standard deviation of their pixels in the chromatic plane
    /// at the common lightness.
    static func spread(_ groups: [Int: [SIMD3<Float>]]) -> Float? {
        let spreads = groups.keys.sorted().compactMap { key -> Float? in
            let planes = groups[key]!.map(TelescopeReference.plane)
            guard planes.count >= minimumPixels else { return nil }
            let mean = planes.reduce(SIMD2<Float>.zero, +) / Float(planes.count)
            let variance =
                planes.reduce(Float(0)) { $0 + simd_length_squared($1 - mean) } / Float(planes.count)
            return variance.squareRoot()
        }
        return spreads.isEmpty ? nil : spreads.reduce(0, +) / Float(spreads.count)
    }

    /// The median deviation of a sky pixel from the mean of its eight neighbours, ×255, so
    /// field stars, which are few, do not count as noise.
    static func skyNoise(_ luma: [Float], width: Int, height: Int) -> Float {
        guard width > 2, height > 2 else { return 0 }
        var deviations: [Float] = []
        deviations.reserveCapacity(luma.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard luma[i] < Self.litLuma else { continue }
                var around: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 { around += luma[i + dy * width + dx] }
                }
                deviations.append(abs(luma[i] - around / 8) * 255)
            }
        }
        return percentile(deviations, 0.5)
    }

    /// Mean over the lit pixels of their distance to the mean of the 7 by 7 box around them,
    /// relative to that mean.
    static func detail(_ luma: [Float], width: Int, height: Int) -> Float {
        let r = 3
        guard width > 2 * r, height > 2 * r else { return 0 }
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row: Double = 0
            for x in 0..<width {
                row += Double(luma[y * width + x])
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + row
            }
        }
        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
        }
        let area = Double((2 * r + 1) * (2 * r + 1))
        var sum: Double = 0
        var count = 0
        for y in r..<(height - r) {
            for x in r..<(width - r) {
                let value = luma[y * width + x]
                guard value >= Self.litLuma else { continue }
                let around = Float(box(x - r, y - r, x + r + 1, y + r + 1) / area)
                sum += Double(abs(value - around) / max(around, 0.05))
                count += 1
            }
        }
        return count == 0 ? 0 : Float(sum / Double(count))
    }

    static func percentile(_ values: [Float], _ p: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Float(sorted.count - 1) * p), sorted.count - 1)]
    }

    /// 8-bit sRGB to linear.
    static let linear: [Float] = (0..<256).map {
        let c = Float($0) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The mean total of several frames.
    public static func mean(_ scores: [FrameScore]) -> Float {
        scores.isEmpty ? 0 : scores.map(\.total).reduce(0, +) / Float(scores.count)
    }
}

extension TelescopeReference {
    /// Distance from an OKLab colour to the nearest tone, at the common lightness.
    func distance(lab: SIMD3<Float>) -> Float {
        let point = Self.plane(lab)
        return tones.map { simd_distance(point, Self.plane($0.lab)) }.min() ?? .infinity
    }
}
