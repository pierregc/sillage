import Foundation

/// Up to 256 colours chosen for a whole animation, and frames mapped onto them with Floyd
/// Steinberg dithering.
///
/// ImageIO picks a palette of its own for every frame, which spends it on the bright cores and
/// leaves the faint tails in a few flat steps. Here the palette is cut from the colours of the
/// whole animation, at full precision so the darkest levels stay apart, and one palette for
/// every frame keeps a still region from flickering between them.
public struct GIFPalette: Sendable {
    /// RGB triplets.
    public private(set) var colors: [SIMD3<UInt8>]
    /// The colours sorted by green, for the nearest colour search.
    private let byGreen: [(green: Int32, index: UInt8)]

    public init(colors: [SIMD3<UInt8>]) {
        precondition(!colors.isEmpty && colors.count <= 256)
        self.colors = colors
        byGreen = colors.enumerated().map { (Int32($0.element.y), UInt8($0.offset)) }
            .sorted { $0.green < $1.green }
    }

    /// Median cut over the colours of `frames`, RGBA, sampling about `samples` pixels across them.
    public init(frames: [[UInt8]], count: Int = 256, samples: Int = 2_000_000) {
        var histogram: [UInt32: UInt32] = [:]
        let pixels = frames.reduce(0) { $0 + $1.count / 4 }
        let step = max(pixels / max(samples, 1), 1)
        var skip = 0
        for frame in frames {
            frame.withUnsafeBufferPointer { bytes in
                var pixel = skip
                while pixel < bytes.count / 4 {
                    let key =
                        UInt32(bytes[pixel * 4]) << 16 | UInt32(bytes[pixel * 4 + 1]) << 8
                        | UInt32(bytes[pixel * 4 + 2])
                    histogram[key, default: 0] += 1
                    pixel += step
                }
                skip = pixel - bytes.count / 4
            }
        }
        let entries = histogram.map {
            Entry(
                color: SIMD3(Int32($0.key >> 16), Int32($0.key >> 8 & 0xFF), Int32($0.key & 0xFF)),
                weight: Double($0.value))
        }
        self.init(colors: Self.medianCut(entries, count: count))
    }

    private struct Entry {
        var color: SIMD3<Int32>
        var weight: Double
    }

    private struct Box {
        var entries: ArraySlice<Entry>
        var low: SIMD3<Int32>
        var high: SIMD3<Int32>
        var weight: Double

        init(_ entries: ArraySlice<Entry>) {
            self.entries = entries
            low = entries.reduce(SIMD3(repeating: 255)) { pointwiseMin($0, $1.color) }
            high = entries.reduce(SIMD3(repeating: 0)) { pointwiseMax($0, $1.color) }
            weight = entries.reduce(0) { $0 + $1.weight }
        }

        var span: Int32 { (high &- low).max() }
        /// Splitting the box that holds the most pixels over the widest range spends colours
        /// on the levels that cover the frame, which on a galaxy are the dark ones, without
        /// starving a small bright range entirely.
        var priority: Double { entries.count < 2 ? -1 : sqrt(weight) * Double(span) }

        var mean: SIMD3<UInt8> {
            var sum = SIMD3<Double>()
            for entry in entries { sum += SIMD3<Double>(entry.color) * entry.weight }
            return SIMD3<UInt8>(
                clamping: SIMD3<Int32>(sum / max(weight, 1), rounding: .toNearestOrEven))
        }
    }

    private static func medianCut(_ entries: [Entry], count: Int) -> [SIMD3<UInt8>] {
        guard !entries.isEmpty else { return [SIMD3(0, 0, 0)] }
        var all = entries
        var boxes = [Box(all[...])]
        while boxes.count < count {
            guard let pick = boxes.indices.max(by: { boxes[$0].priority < boxes[$1].priority }),
                boxes[pick].priority > 0
            else { break }
            let box = boxes[pick]
            let range = box.high &- box.low
            let axis = range.x >= range.y && range.x >= range.z ? 0 : range.y >= range.z ? 1 : 2
            let bounds = box.entries.startIndex..<box.entries.endIndex
            all[bounds].sort { $0.color[axis] < $1.color[axis] }
            // Halve the pixels the box holds, not its colours.
            var half = box.weight / 2
            var cut = bounds.lowerBound
            while cut < bounds.upperBound - 1 && half > 0 {
                half -= all[cut].weight
                cut += 1
            }
            cut = min(max(cut, bounds.lowerBound + 1), bounds.upperBound - 1)
            boxes[pick] = Box(all[bounds.lowerBound..<cut])
            boxes.append(Box(all[cut..<bounds.upperBound]))
        }
        return boxes.map(\.mean)
    }

    /// The palette entry closest to `color`, searched outwards from its green.
    func nearest(_ color: SIMD3<Int32>) -> UInt8 {
        var low = 0
        var high = byGreen.count
        while low < high {
            let middle = (low + high) / 2
            if byGreen[middle].green < color.y { low = middle + 1 } else { high = middle }
        }
        var best: Int32 = .max
        var found: UInt8 = 0
        var up = low
        var down = low - 1
        while up < byGreen.count || down >= 0 {
            if up < byGreen.count {
                let green = byGreen[up].green - color.y
                if green * green >= best {
                    up = byGreen.count
                } else {
                    let distance = distanceSquared(colors[Int(byGreen[up].index)], color)
                    if distance < best { (best, found) = (distance, byGreen[up].index) }
                    up += 1
                }
            }
            if down >= 0 {
                let green = color.y - byGreen[down].green
                if green * green >= best {
                    down = -1
                } else {
                    let distance = distanceSquared(colors[Int(byGreen[down].index)], color)
                    if distance < best { (best, found) = (distance, byGreen[down].index) }
                    down -= 1
                }
            }
        }
        return found
    }

    private func distanceSquared(_ entry: SIMD3<UInt8>, _ color: SIMD3<Int32>) -> Int32 {
        let delta = SIMD3<Int32>(truncatingIfNeeded: entry) &- color
        return (delta &* delta).wrappedSum()
    }

    /// `frame`, RGBA, as palette indices, with each pixel's error carried to its neighbours
    /// in sixteenths: 7 right, 3 below left, 5 below, 1 below right.
    public func indices(of frame: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        // Errors in sixteenths of a level, for this row and the next.
        var current = [SIMD3<Int32>](repeating: .zero, count: width + 2)
        var next = current
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let source = SIMD3<Int32>(
                    Int32(frame[pixel]), Int32(frame[pixel + 1]), Int32(frame[pixel + 2]))
                let wanted = (source &+ (current[x + 1] &+ 8) &>> 4)
                    .clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
                let index = nearest(wanted)
                out[y * width + x] = index
                let error = wanted &- SIMD3<Int32>(truncatingIfNeeded: colors[Int(index)])
                current[x + 2] &+= error &* 7
                next[x] &+= error &* 3
                next[x + 1] &+= error &* 5
                next[x + 2] &+= error
            }
            swap(&current, &next)
            for index in next.indices { next[index] = .zero }
        }
        return out
    }
}
