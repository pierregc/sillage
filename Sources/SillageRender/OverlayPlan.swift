import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// One frame's overlay in pixels from the top left: what `OverlayPainter` draws, with nothing
/// left to decide but the width of a line set flush right.
public struct OverlayFrame: Sendable, Equatable {
    public enum Weight: Sendable, Equatable {
        case light, regular
    }

    public struct Line: Sendable, Equatable {
        public var text: String
        /// Where the baseline starts, or where it ends for a line set flush right.
        public var x: Double
        public var baseline: Double
        public var flushRight: Bool
        public var size: Double
        public var weight: Weight
        public var tracking: Double
        /// Digits of one width, so a clock does not shake as it counts.
        public var tabular: Bool
        public var alpha: Double
    }

    public struct Bar: Sendable, Equatable {
        public var x: Double
        /// The middle of its stroke.
        public var y: Double
        public var length: Double
        public var thickness: Double
        /// How far each end rises above the stroke.
        public var tick: Double
        public var alpha: Double
    }

    public var lines: [Line] = []
    public var bars: [Bar] = []
    public var font: String?
    /// The blur of the dark halo under every mark, in pixels.
    public var shadow: Double = 0

    public var isEmpty: Bool { lines.isEmpty && bars.isEmpty }
}

/// Where each event of a story falls in a take, in its captured frames (#317).
public enum OverlayMoments {
    /// A pair whose centres stay closer than this to the end has merged. Measured on the Mice
    /// of the README: after the merger the centres wander within half a kiloparsec, and the
    /// last passage before it dips to 1.5.
    public static let mergedKpc = 2.0

    /// From the take's own centres, and the share of stars in tails from its curves when given.
    public static func find(take: RecordingFile.Loaded, curves: [KeyFrames.Sample] = []) -> [OverlayEvent:
        Int]
    {
        let recording = take.recording
        var times: [Double] = []
        var centres: [[SIMD3<Double>]] = []
        for frame in 0..<recording.capturedFrames {
            guard let blend = recording.blend(atCaptured: frame) else { break }
            times.append(Double(blend.time) * Physics.megayearsPerTimeUnit)
            centres.append(recording.centers(at: blend).map { SIMD3<Double>($0) })
        }
        var tidal: [Int: Double] = [:]
        for sample in curves { tidal[sample.frame] = sample.tidal }
        return find(times: times, centres: centres, story: Story(scene: take.scene), tidal: tidal)
    }

    /// `tidal` is the share of stars in tails at captured frames; without it, no tails.
    public static func find(
        times: [Double], centres: [[SIMD3<Double>]], story: Story, tidal: [Int: Double] = [:]
    ) -> [OverlayEvent: Int] {
        let samples = zip(times, centres).map {
            Story.Sample(timeMyr: $0, centres: $1, extent: 0, tails: 0, disruption: [])
        }
        guard let first = story.firstApproach(samples), first.pair.count == 2 else { return [:] }
        let (i, j) = (first.pair[0], first.pair[1])
        let separation = centres.map { simd_distance($0[i], $0[j]) }
        let passage = first.index
        var found: [OverlayEvent: Int] = [.passage: passage]

        let halfway = (separation[0] + separation[passage]) / 2
        if let approach = (1..<passage).first(where: { separation[$0] <= halfway }) {
            found[.approach] = approach
        }
        let last = separation.count - 1
        var merged = last + 1
        while merged > passage + 1, separation[merged - 1] < mergedKpc { merged -= 1 }
        if merged <= last { found[.merger] = merged }
        if let back = dips(separation).first(where: {
            $0 > passage && $0 < merged && separation[$0] >= mergedKpc
        }) {
            found[.returning] = back
        }
        // The first rise of the tails, up to the return: a merger raises them again later.
        let end = found[.returning] ?? last
        if let base = tidal[passage],
            let top = (passage...end).compactMap({ tidal[$0] }).max(), top - base >= 0.05,
            let rising = (passage...end).first(where: { (tidal[$0] ?? 0) >= (base + top) / 2 })
        {
            found[.tails] = rising
        }
        return found
    }

    /// Every pass of a pair: a dip counts once the pair has separated again by five per cent,
    /// as `Story.firstApproach` counts one, and one at the very first sample is the clip's edge.
    static func dips(_ separation: [Double]) -> [Int] {
        var found: [Int] = []
        var lowest: Int? = 0
        var previous = Double.infinity
        for (index, distance) in separation.enumerated() {
            defer { previous = distance }
            guard let low = lowest else {
                if distance < previous { lowest = index }
                continue
            }
            if distance < separation[low] {
                lowest = index
            } else if distance > separation[low] * 1.05 + 0.2 {
                if low > 0 { found.append(low) }
                lowest = nil
            }
        }
        return found
    }
}

/// The overlay of every frame of a video, worked out before the first is drawn so any frame
/// is the same whatever was drawn before it, as a resumed run needs (#317). Portable: the CUDA
/// pass can lay it out, only the drawing needs Core Text.
public struct OverlayPlan: Sendable {
    public let frames: [OverlayFrame]
    /// The captions kept, by the first video frame each shows on.
    public let captions: [(event: OverlayEvent, frame: Int)]
    /// What was asked and could not be done, for the log.
    public let notes: [String]

    public static let lightYearsPerKpc = 3_261.563_777

    /// Seconds of video: the title's entrance, fades and hold, a caption's, the clock's and
    /// the scale's entrance, and how long a scale bar's change of length takes.
    static let titleStart = 0.3
    static let titleIn = 1.0
    static let titleHold = 3.5
    static let titleShortest = 2.0
    static let titleOut = 1.2
    static let captionIn = 0.7
    static let captionHold = 2.8
    static let captionOut = 1.0
    static let captionGap = 0.4
    /// The most a caption waits for the one before it to go.
    static let captionWait = 1.5
    static let instrumentsStart = 1.0
    static let instrumentsIn = 1.5
    static let scaleChange = 0.8
    /// How early each caption comes before its moment: a passage is read as it happens.
    static func lead(_ event: OverlayEvent) -> Double {
        switch event {
        case .passage: 1.0
        case .returning: 2.0
        case .merger: 0.5
        case .approach, .tails: 0
        }
    }

    /// Which caption keeps its place when two would overlap.
    static let priority: [OverlayEvent] = [.passage, .merger, .tails, .returning, .approach]

    /// The scale bar's lengths, in its unit: one of them always lies between a tenth and a
    /// quarter of the frame, since no two neighbours are more than 2.5 apart.
    static func lengths(_ unit: Overlay.Scale.Unit) -> [Double] {
        let decades: [Double] = unit == .lightYears ? [1e3, 1e4, 1e5, 1e6] : [0.1, 1, 10, 100, 1000]
        return decades.flatMap { [$0, 2 * $0, 5 * $0] }
    }

    static let barShare: ClosedRange<Double> = 0.1...0.25
    /// The share a new length is chosen nearest to: short, a quiet mark about a galaxy's size.
    static let barAim = 0.13

    /// `positions` are the captured positions of the take each video frame shows, `cameras`
    /// what each is drawn through. `curves` give the tails' moment.
    public init(
        overlay: Overlay, texts: OverlayTexts, take: RecordingFile.Loaded,
        curves: [KeyFrames.Sample] = [], positions: [Double], framesPerSecond: Int,
        cameras: [Camera], width: Int, height: Int
    ) {
        let events =
            overlay.captions != nil || overlay.clock?.from == .passage
            ? OverlayMoments.find(take: take, curves: curves) : [:]
        let times = positions.map {
            take.recording.blend(atCaptured: $0).map { Double($0.time) * Physics.megayearsPerTimeUnit } ?? 0
        }
        self.init(
            overlay: overlay, texts: texts, scene: take.scene, events: events, times: times,
            positions: positions, framesPerSecond: framesPerSecond,
            pixelsPerKpc: cameras.map { Self.pixelsPerKpc($0, height: height) }, width: width,
            height: height)
    }

    /// The same from what a take gives: `events` in captured frames, `times` in Myr for each
    /// video frame, `pixelsPerKpc` at each frame's target.
    init(
        overlay: Overlay, texts: OverlayTexts, scene: SceneConfig, events: [OverlayEvent: Int],
        times: [Double], positions: [Double], framesPerSecond: Int, pixelsPerKpc: [Double],
        width: Int, height: Int
    ) {
        let rate = Double(max(framesPerSecond, 1))
        let count = positions.count
        let layout = OverlayLayout(overlay: overlay, width: width, height: height)
        var notes: [String] = []
        var frames = Array(repeating: OverlayFrame(), count: count)
        for index in frames.indices {
            frames[index].font = overlay.font
            frames[index].shadow = layout.shadow
        }
        func fade(_ index: Int, start: Double, in fadeIn: Double, hold: Double, out: Double) -> Double {
            let t = Double(index) / rate - start
            guard t > 0 else { return 0 }
            if t < fadeIn { return Self.ease(t / fadeIn) }
            if t < fadeIn + hold { return 1 }
            return 1 - Self.ease((t - fadeIn - hold) / out)
        }
        let instruments = { (index: Int) in
            fade(index, start: Self.instrumentsStart, in: Self.instrumentsIn, hold: .infinity, out: 0)
        }

        // Each caption where its moment puts it. The title gives way to the first passage's if
        // it can keep a short hold; then, in order of priority, a caption that would overlap the
        // title or one already placed waits for it to end if that is not long, or goes.
        let length = Self.captionIn + Self.captionHold + Self.captionOut
        let videoSeconds = Double(count) / rate
        var wanted: [(event: OverlayEvent, text: String, start: Double)] = []
        for event in Self.priority {
            guard let asked = overlay.captions, let moment = events[event],
                let text = asked[event.rawValue] ?? texts.captions[event.rawValue], !text.isEmpty,
                let first = positions.first, let last = positions.last,
                Double(moment) >= first, Double(moment) <= last,
                let anchor = positions.firstIndex(where: { $0 >= Double(moment) })
            else { continue }
            wanted.append((event, text, max(Double(anchor) / rate - Self.lead(event), 0)))
        }
        var busy: [ClosedRange<Double>] = []
        if let title = overlay.title {
            var hold = max(title.seconds ?? Self.titleHold, 0)
            if let passage = wanted.first(where: { $0.event == .passage })?.start {
                // A hair short, so the title's end and the caption's gap do not meet in rounding.
                let room = passage - Self.captionGap - Self.titleStart - Self.titleIn - Self.titleOut - 1e-6
                if room < hold { hold = max(room, min(hold, Self.titleShortest)) }
            }
            busy.append(Self.titleStart...(Self.titleStart + Self.titleIn + hold + Self.titleOut))
            let text = title.text ?? Self.titleText(scene: scene, texts: texts)
            let subtitle = title.subtitle ?? Self.subtitle(scene: scene, texts: texts)
            for index in frames.indices {
                let alpha = fade(
                    index, start: Self.titleStart, in: Self.titleIn, hold: hold, out: Self.titleOut)
                guard alpha > 0 else { continue }
                frames[index].lines += layout.title(
                    text, subtitle: subtitle.isEmpty ? nil : subtitle, alpha: alpha)
            }
        }
        var windows: [(event: OverlayEvent, text: String, window: ClosedRange<Double>)] = []
        for caption in wanted {
            func clashes(_ start: Double) -> [ClosedRange<Double>] {
                busy.filter {
                    $0.lowerBound - Self.captionGap < start + length
                        && start < $0.upperBound + Self.captionGap
                }
            }
            var start = caption.start
            if let wait = clashes(start).map(\.upperBound).max() {
                start = wait + Self.captionGap + 1e-6
                guard start - caption.start <= Self.captionWait, clashes(start).isEmpty else { continue }
            }
            guard start + length <= videoSeconds else { continue }
            busy.append(start...(start + length))
            windows.append((caption.event, caption.text, start...(start + length)))
            for index in frames.indices {
                let alpha = fade(
                    index, start: start, in: Self.captionIn, hold: Self.captionHold, out: Self.captionOut)
                if alpha > 0 { frames[index].lines.append(layout.caption(caption.text, alpha: alpha)) }
            }
        }
        let kept = windows.map { ($0.event, Int(($0.window.lowerBound * rate).rounded(.up))) }
            .sorted { $0.1 < $1.1 }

        if let clock = overlay.clock {
            var origin = Self.startTime(times: times, positions: positions)
            var signed = false
            if clock.from == .passage {
                if let passage = events[.passage], let time = Self.time(atCaptured: passage, times, positions)
                {
                    (origin, signed) = (time, true)
                } else {
                    notes.append("no first passage in this video: the clock counts from the take's start")
                }
            }
            let step = Self.clockStep(times: times, framesPerSecond: framesPerSecond)
            for index in frames.indices {
                let alpha = instruments(index)
                guard alpha > 0 else { continue }
                let text = Self.clockText(times[index] - origin, step: step, signed: signed, texts: texts)
                frames[index].lines.append(layout.clock(text, alpha: alpha))
            }
        }

        if let scale = overlay.scale {
            let unit = scale.unit ?? .lightYears
            let track = Self.scaleTrack(
                pixelsPerKpc: pixelsPerKpc, width: Double(width), unit: unit,
                framesPerSecond: framesPerSecond)
            for index in frames.indices {
                let alpha = instruments(index)
                guard alpha > 0 else { continue }
                for bar in track[index] {
                    let label = Self.lengthText(bar.length, unit: unit, texts: texts)
                    let (line, stroke) = layout.scale(
                        label, length: bar.pixels, alpha: alpha * bar.alpha)
                    frames[index].lines.append(line)
                    frames[index].bars.append(stroke)
                }
            }
        }
        self.frames = frames
        captions = kept
        self.notes = notes
    }

    /// Smooth in and out between 0 and 1.
    static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// How many pixels a kiloparsec spans at the depth of the camera's target.
    public static func pixelsPerKpc(_ camera: Camera, height: Int) -> Double {
        let distance = Double(simd_distance(camera.eye, camera.target))
        let half = tan(Double(camera.fieldOfView) / 2)
        guard distance > 0, half > 0 else { return 0 }
        return Double(height) / (2 * distance * half)
    }

    /// The bars drawn on each frame: the length kept while it stays between a tenth and a
    /// quarter of the width, and, when it leaves, the one of that range nearest `barAim`,
    /// faded in as the old one fades out unless the frame jumped (a cut).
    static func scaleTrack(
        pixelsPerKpc: [Double], width: Double, unit: Overlay.Scale.Unit, framesPerSecond: Int
    ) -> [[(length: Double, pixels: Double, alpha: Double)]] {
        let lengths = lengths(unit)
        let perKpc = unit == .lightYears ? lightYearsPerKpc : 1
        let change = max(Int((scaleChange * Double(max(framesPerSecond, 1))).rounded()), 1)
        var current: Int?
        var previous: Int?
        var since = 0
        return pixelsPerKpc.enumerated().map { index, scale in
            guard scale > 0, scale.isFinite else { return [] }
            func share(_ choice: Int) -> Double { lengths[choice] / perKpc * scale / width }
            let fitting = lengths.indices.filter { barShare.contains(share($0)) }
            let best = (fitting.isEmpty ? Array(lengths.indices) : fitting).min {
                abs(log(share($0) / barAim)) < abs(log(share($1) / barAim))
            }!
            if let shown = current, !barShare.contains(share(shown)) {
                // Far out of range, the frame cut to another shot: the bar follows it at once.
                previous = (0.04...0.5).contains(share(shown)) ? shown : nil
                current = best
                since = index
            } else if current == nil {
                current = best
            }
            guard let shown = current else { return [] }
            let t = ease(Double(index - since) / Double(change))
            var bars = [(lengths[shown], lengths[shown] / perKpc * scale, previous == nil ? 1 : t)]
            if let old = previous {
                if t < 1 {
                    bars.insert((lengths[old], lengths[old] / perKpc * scale, 1 - t), at: 0)
                } else {
                    previous = nil
                }
            }
            return bars
        }
    }

    /// A step a calm clock counts in: about three changes a second at the video's usual pace.
    static func clockStep(times: [Double], framesPerSecond: Int) -> Double {
        let steps = zip(times.dropFirst(), times).map { abs($0 - $1) }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return 1 }
        let aim = steps[steps.count / 2] * Double(max(framesPerSecond, 1)) / 3
        return [1.0, 2, 5, 10, 20, 50, 100, 200, 500].min { abs(log($0 / aim)) < abs(log($1 / aim)) }!
    }

    static func clockText(_ myr: Double, step: Double, signed: Bool, texts: OverlayTexts) -> String {
        let value = Int((myr / step).rounded() * step)
        let sign = signed && value != 0 ? (value < 0 ? texts.minus : texts.plus) : ""
        return texts.fill(texts.clock, ["n": sign + texts.number(value)])
    }

    static func lengthText(_ length: Double, unit: Overlay.Scale.Unit, texts: OverlayTexts) -> String {
        guard unit == .kiloparsecs else {
            return texts.fill(texts.lightYears, ["n": texts.number(Int(length.rounded()))])
        }
        let number =
            length < 1 ? String(format: "%g", length) : texts.number(Int(length.rounded()))
        return texts.fill(length == 1 ? texts.kiloparsec : texts.kiloparsecs, ["n": number])
    }

    /// The time at the take's first captured frame, where a clock from the start reads zero.
    static func startTime(times: [Double], positions: [Double]) -> Double {
        guard let first = positions.first, let time = times.first else { return 0 }
        guard first > 0, let second = positions.dropFirst().first, second > first,
            times.count > 1
        else { return time }
        // A video cut later than the take's start: back along its own pace to the first frame.
        return time - (times[1] - times[0]) / (second - first) * first
    }

    static func time(atCaptured frame: Int, _ times: [Double], _ positions: [Double]) -> Double? {
        guard let after = positions.firstIndex(where: { $0 >= Double(frame) }) else { return nil }
        guard after > 0, positions[after] > Double(frame) else { return times[after] }
        let before = after - 1
        let t = (Double(frame) - positions[before]) / (positions[after] - positions[before])
        return times[before] + (times[after] - times[before]) * t
    }

    /// The scene's own name, unless it is the one a generator gives every scene it draws.
    static func titleText(scene: SceneConfig, texts: OverlayTexts) -> String {
        ["Archetype", "Free", ""].contains(scene.name) ? texts.title : scene.name
    }

    /// How many galaxies, of what kind, how large across where their light ends.
    static func subtitle(scene: SceneConfig, texts: OverlayTexts) -> String {
        let galaxies = scene.galaxies.filter { $0.kind != .blackHole }
        guard !galaxies.isEmpty else { return "" }
        let sizes = galaxies.map { 2 * Double(SceneCheck.brightReach($0)) * lightYearsPerKpc }
        func rounded(_ value: Double) -> String {
            let step = value >= 20_000 ? 10_000.0 : 1_000
            return texts.number(Int((value / step).rounded() * step))
        }
        let kind = texts.kinds[galaxies[0].kind.rawValue] ?? galaxies[0].kind.rawValue
        let count = galaxies.count < texts.counts.count ? texts.counts[galaxies.count] : "\(galaxies.count)"
        if galaxies.count == 1 {
            return texts.fill(texts.subtitleOne, ["kind": kind, "size": rounded(sizes[0])])
        }
        let alike =
            Set(galaxies.map(\.kind)).count == 1 && sizes.max()! <= 1.5 * sizes.min()!
        return alike
            ? texts.fill(
                texts.subtitleEach,
                ["count": count, "kind": kind, "size": rounded(sizes.reduce(0, +) / Double(sizes.count))])
            : texts.fill(texts.subtitleLargest, ["count": count, "size": rounded(sizes.max()!)])
    }
}

/// Where the overlay's marks go on a frame of a given size, and how large they are: set on the
/// frame's short side, so a 4K frame carries the text of a 1080p one at twice the pixels, and
/// kept inside what the platforms of the 9:16 and square presets cover with their own buttons.
struct OverlayLayout {
    let width: Double
    let height: Double
    /// One pixel of a 1080 frame, times the asked size.
    let unit: Double
    let opacity: Double
    let left: Double
    let right: Double
    let top: Double
    let bottom: Double
    let narration: Overlay.Corner
    let clockCorner: Overlay.Corner
    let scaleCorner: Overlay.Corner
    var shadow: Double { 6 * unit }

    static let titleSize = 46.0
    static let subtitleSize = 21.0
    static let captionSize = 26.0
    static let clockSize = 19.0
    static let labelSize = 15.0

    init(overlay: Overlay, width: Int, height: Int) {
        self.width = Double(width)
        self.height = Double(height)
        let short = Double(min(width, height))
        let portrait = height * 5 > width * 6
        let square = !portrait && width * 5 < height * 6
        // A 9:16 or square video is watched on a phone, its 1080 pixels across a few inches.
        unit = short / 1080 * (portrait || square ? 1.25 : 1) * Double(overlay.size ?? 1)
        opacity = Double(min(max(overlay.opacity ?? 0.9, 0), 1))
        if portrait {
            // Shorts, Reels and TikTok: their buttons down the right, the channel and its
            // caption over the bottom fifth.
            (left, right, top, bottom) = (
                0.06 * self.width, 0.15 * self.width, 0.09 * self.height, 0.22 * self.height
            )
        } else {
            let margin = (square ? 0.07 : 0.06) * short
            (left, right, top, bottom) = (
                margin * (square ? 1 : 1.25), margin * (square ? 1 : 1.25), margin, margin
            )
        }
        narration = portrait ? .topLeft : .bottomLeft
        let instruments: Overlay.Corner = portrait ? .bottomLeft : .bottomRight
        clockCorner = overlay.clock?.corner ?? instruments
        scaleCorner = overlay.scale?.corner ?? instruments
        hasClock = overlay.clock != nil
        hasScale = overlay.scale != nil
    }

    private let hasClock: Bool
    private let hasScale: Bool

    private func x(_ corner: Overlay.Corner) -> Double { corner.isLeft ? left : width - right }

    private func line(
        _ text: String, corner: Overlay.Corner, baseline: Double, size: Double,
        weight: OverlayFrame.Weight, tracking: Double, alpha: Double, tabular: Bool = false
    ) -> OverlayFrame.Line {
        OverlayFrame.Line(
            text: text, x: x(corner), baseline: baseline, flushRight: !corner.isLeft,
            size: size * unit, weight: weight, tracking: tracking * size * unit,
            tabular: tabular, alpha: alpha * opacity)
    }

    func title(_ text: String, subtitle: String?, alpha: Double) -> [OverlayFrame.Line] {
        let big = Self.titleSize * unit
        let small = Self.subtitleSize * unit
        var titleBaseline: Double
        var subtitleBaseline: Double
        if narration.isTop {
            titleBaseline = top + 0.74 * big
            subtitleBaseline = titleBaseline + 0.42 * big + 1.05 * small
        } else {
            subtitleBaseline = height - bottom
            titleBaseline = subtitle == nil ? subtitleBaseline : subtitleBaseline - 1.05 * small - 0.42 * big
        }
        var lines = [
            line(
                text, corner: narration, baseline: titleBaseline, size: Self.titleSize, weight: .light,
                tracking: 0.01, alpha: alpha)
        ]
        if let subtitle {
            lines.append(
                line(
                    subtitle, corner: narration, baseline: subtitleBaseline, size: Self.subtitleSize,
                    weight: .regular, tracking: 0.02, alpha: 0.72 * alpha))
        }
        return lines
    }

    func caption(_ text: String, alpha: Double) -> OverlayFrame.Line {
        let size = Self.captionSize * unit
        return line(
            text, corner: narration, baseline: narration.isTop ? top + 0.74 * size : height - bottom,
            size: Self.captionSize, weight: .light, tracking: 0.01, alpha: 0.9 * alpha)
    }

    /// The baselines down a corner, of whichever of the clock and the scale bar live in it:
    /// the clock, then the bar's label, then the bar.
    private func stack(_ corner: Overlay.Corner) -> (clock: Double, label: Double, bar: Double) {
        let clock = Self.clockSize * unit
        let label = Self.labelSize * unit
        let barGap = 0.75 * label
        if corner.isTop {
            let clockBaseline = top + 0.74 * clock
            let withClock = hasClock && clockCorner == corner
            let labelBaseline = withClock ? clockBaseline + 0.5 * clock + 1.0 * label : top + 0.74 * label
            return (clockBaseline, labelBaseline, labelBaseline + barGap)
        }
        let bar = height - bottom
        let labelBaseline = bar - barGap
        let withScale = hasScale && scaleCorner == corner
        return (withScale ? labelBaseline - 1.0 * label - 0.62 * clock : bar, labelBaseline, bar)
    }

    func clock(_ text: String, alpha: Double) -> OverlayFrame.Line {
        line(
            text, corner: clockCorner, baseline: stack(clockCorner).clock, size: Self.clockSize,
            weight: .regular, tracking: 0.03, alpha: 0.8 * alpha, tabular: true)
    }

    func scale(_ label: String, length: Double, alpha: Double) -> (OverlayFrame.Line, OverlayFrame.Bar) {
        let lines = stack(scaleCorner)
        let anchor = x(scaleCorner)
        return (
            line(
                label, corner: scaleCorner, baseline: lines.label, size: Self.labelSize,
                weight: .regular, tracking: 0.04, alpha: 0.68 * alpha),
            OverlayFrame.Bar(
                x: scaleCorner.isLeft ? anchor : anchor - length, y: lines.bar, length: length,
                thickness: 1.4 * unit, tick: 4 * unit, alpha: 0.68 * alpha * opacity)
        )
    }
}

/// An overlay asked of a video, with the words it is written in and the curves its tails are
/// found on.
public struct OverlayRequest: Sendable {
    public var overlay: Overlay
    public var texts: OverlayTexts
    public var curves: [KeyFrames.Sample]

    public init(overlay: Overlay, texts: OverlayTexts = .english, curves: [KeyFrames.Sample] = []) {
        self.overlay = overlay
        self.texts = texts
        self.curves = curves
    }
}

extension OverlayPlan {
    public init(
        _ request: OverlayRequest, take: RecordingFile.Loaded, positions: [Double], framesPerSecond: Int,
        cameras: [Camera], width: Int, height: Int
    ) {
        self.init(
            overlay: request.overlay, texts: request.texts, take: take, curves: request.curves,
            positions: positions, framesPerSecond: framesPerSecond, cameras: cameras, width: width,
            height: height)
    }

    /// The captions kept, one line each for the log.
    public func summary(framesPerSecond: Int) -> [String] {
        captions.map {
            String(
                format: "%@ at %.1f s", $0.event.rawValue, Double($0.frame) / Double(max(framesPerSecond, 1)))
        } + notes
    }
}
