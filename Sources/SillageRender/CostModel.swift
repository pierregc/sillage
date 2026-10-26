import Foundation

/// What a job costs on this Mac, fitted on the runs the library remembers, so plans and
/// estimated ends follow the code and the machine without hand-tuned constants.
/// Kept in `library/.sillage/costs.json` and refreshed after every finished job.
public struct CostModel: Codable, Sendable, Equatable {
    /// `seconds = fixedSeconds + secondsPerUnit * units` for one kind of job.
    public struct Line: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable {
            /// Both terms fitted on the history.
            case fitted
            /// Too little history or too little spread to fit both: the fallback's shape,
            /// scaled to what the runs took.
            case scaled
            /// No history at all.
            case fallback
        }

        public var fixedSeconds: Double
        public var secondsPerUnit: Double
        public var source: Source
        public var samples: Int
        /// Runs left out as contention: slower than twice the median.
        public var rejected: Int

        public init(
            fixedSeconds: Double, secondsPerUnit: Double, source: Source = .fallback,
            samples: Int = 0, rejected: Int = 0
        ) {
            self.fixedSeconds = fixedSeconds
            self.secondsPerUnit = secondsPerUnit
            self.source = source
            self.samples = samples
            self.rejected = rejected
        }

        public func seconds(_ units: Double) -> Double { fixedSeconds + secondsPerUnit * units }
    }

    /// One finished run: how much work, how long, and when it ended. An explored scene's
    /// `seconds` are per slot, its wall clock divided by `alongside`.
    public struct Sample: Sendable, Equatable {
        public var units: Double
        public var seconds: Double
        public var date: Date
        /// `<batch>/<scene>`, or `<batch>` for an export.
        public var id: String
        public var alongside: Double

        public init(
            units: Double, seconds: Double, date: Date, id: String = "", alongside: Double = 1
        ) {
            self.units = units
            self.seconds = seconds
            self.date = date
            self.id = id
            self.alongside = alongside
        }
    }

    public var version = 1
    public var updated: Date
    /// Per explored scene and per scene slot: a scene's own wall clock divided by how many
    /// ran at once. Units are particle steps, settle included.
    public var explore: Line
    /// Per hires run. Units are visible particle steps, settle included.
    public var hires: Line
    /// Per export, keyed `<preset>/<codec>`. Units are frames.
    public var exports: [String: Line]

    public init(updated: Date, explore: Line, hires: Line, exports: [String: Line] = [:]) {
        self.updated = updated
        self.explore = explore
        self.hires = hires
        self.exports = exports
    }

    /// One explored scene's own wall clock with `jobs` running at once.
    public func exploreSeconds(particles: Int, steps: Int, jobs: Int = Self.exploreJobs) -> Double {
        Double(max(jobs, 1)) * explore.seconds(Double(particles) * Double(steps))
    }

    /// A batch of scenes at `jobs` at once, ignoring the tail where fewer run.
    public func exploreBatchSeconds(scenes: [(particles: Int, steps: Int)]) -> Double {
        scenes.reduce(0) { $0 + explore.seconds(Double($1.particles) * Double($1.steps)) }
    }

    public func hiresSeconds(particles: Int, steps: Int) -> Double {
        hires.seconds(Double(particles) * Double(steps))
    }

    public func exportSeconds(preset: VideoPreset, codec: VideoCodec, frames: Int) -> Double {
        exportLine(preset: preset, codec: codec).seconds(Double(frames))
    }

    public func exportLine(preset: VideoPreset, codec: VideoCodec) -> Line {
        exports[Self.exportKey(preset: preset.name, codec: codec.rawValue)]
            ?? Self.fallbackExport(preset)
    }

    public static func exportKey(preset: String, codec: String) -> String { "\(preset)/\(codec)" }
}

// MARK: - Fallback

extension CostModel {
    /// What `explore-batch.sh` runs by default, and what the explore fallback was measured at.
    public static let exploreJobs = 4
    /// Measured by `explore-batch.sh --benchmark` on the M4 Max: per scene finished with four
    /// at once, at the sizes a budget lands on.
    public static let fallbackExplore = Line(fixedSeconds: 4, secondsPerUnit: 126e-9)
    /// #19: flat from one to ten million. The 2026-10-24 fidelity runs put the start under a
    /// minute, so it is left at zero until runs say otherwise.
    public static let fallbackHires = Line(
        fixedSeconds: 0, secondsPerUnit: SceneFolder.nanosecondsPerParticleStep / 1e9)
    /// #24, on a 2 M take at 30 fps: 1080p at 1.23x real time, 4K at 0.64x. Other sizes
    /// follow 1080p by their pixel count.
    public static let fallbackSpeed1080p = 1.23
    public static let fallbackSpeed4K = 0.64
    public static let fallbackExportFramesPerSecond = 30.0

    public static func fallbackExport(_ preset: VideoPreset) -> Line {
        let perFrame1080p = 1 / (fallbackSpeed1080p * fallbackExportFramesPerSecond)
        let perFrame =
            preset.width * preset.height >= 3840 * 2160
            ? 1 / (fallbackSpeed4K * fallbackExportFramesPerSecond)
            : perFrame1080p * Double(preset.width * preset.height) / (1920 * 1080)
        return Line(fixedSeconds: 0, secondsPerUnit: perFrame)
    }

    public static func fallback(at date: Date = Date()) -> CostModel {
        CostModel(updated: date, explore: fallbackExplore, hires: fallbackHires)
    }
}

// MARK: - Fit

extension CostModel {
    /// How fast older runs fade: a run a day older than the newest counts half, so last night's
    /// runs outweigh a code or machine change before them.
    public static let halfLifeDays = 1.0
    /// A run this many times slower than the median shared the machine with something else.
    public static let contentionFactor = 2.0
    /// Fewer runs, or sizes closer than this ratio, cannot separate the fixed part from the
    /// rate; the fallback's shape is scaled instead.
    public static let minimumFitSamples = 3
    public static let minimumSpread = 1.3

    public static func fit(_ samples: [Sample], fallback: Line) -> Line {
        let usable = samples.filter { $0.units > 0 && $0.seconds > 0 }
        guard let newest = usable.map(\.date).max() else { return fallback }
        // Against the fallback, so runs of different sizes compare.
        let ratios = usable.map { $0.seconds / max(fallback.seconds($0.units), 1e-9) }
        let limit = contentionFactor * median(ratios)
        let kept = usable.filter { $0.seconds / max(fallback.seconds($0.units), 1e-9) <= limit }
        let weights = kept.map { pow(0.5, newest.timeIntervalSince($0.date) / 86_400 / halfLifeDays) }
        let rejected = usable.count - kept.count

        let units = kept.map(\.units)
        if kept.count >= minimumFitSamples, let low = units.min(), let high = units.max(),
            high >= low * minimumSpread
        {
            let total = weights.reduce(0, +)
            let meanX = zip(weights, units).reduce(0) { $0 + $1.0 * $1.1 } / total
            let meanY = zip(weights, kept).reduce(0) { $0 + $1.0 * $1.1.seconds } / total
            var covariance = 0.0
            var variance = 0.0
            for (weight, sample) in zip(weights, kept) {
                covariance += weight * (sample.units - meanX) * (sample.seconds - meanY)
                variance += weight * (sample.units - meanX) * (sample.units - meanX)
            }
            let rate = covariance / variance
            let fixed = meanY - rate * meanX
            if rate > 0, fixed >= 0 {
                return Line(
                    fixedSeconds: fixed, secondsPerUnit: rate, source: .fitted,
                    samples: kept.count, rejected: rejected)
            }
        }
        let took = zip(weights, kept).reduce(0) { $0 + $1.0 * $1.1.seconds }
        let expected = zip(weights, kept).reduce(0) { $0 + $1.0 * fallback.seconds($1.1.units) }
        let scale = took / expected
        return Line(
            fixedSeconds: fallback.fixedSeconds * scale,
            secondsPerUnit: fallback.secondsPerUnit * scale, source: .scaled,
            samples: kept.count, rejected: rejected)
    }

    public static func fit(_ history: CostHistory, at date: Date = Date()) -> CostModel {
        var model = CostModel(
            updated: date, explore: fit(history.explore, fallback: fallbackExplore),
            hires: fit(history.hires, fallback: fallbackHires))
        for (key, samples) in history.exports {
            let name = String(key.prefix { $0 != "/" })
            let preset =
                VideoPreset.all.first { $0.name == name }
                ?? VideoPreset(name: name, width: 1920, height: 1080)
            model.exports[key] = fit(samples, fallback: fallbackExport(preset))
        }
        return model
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - File

extension CostModel {
    public static func url(library: URL) -> URL {
        library.appendingPathComponent(".sillage", isDirectory: true)
            .appendingPathComponent("costs.json")
    }

    public static func stored(library: URL) -> CostModel? {
        guard let data = try? Data(contentsOf: url(library: library)) else { return nil }
        return try? decoder.decode(CostModel.self, from: data)
    }

    /// The stored model, or the fallback for a library with no runs yet.
    public static func current(library: URL) -> CostModel {
        stored(library: library) ?? fallback()
    }

    /// Fits the library's history again and writes it. A folder with no runs at all gets no
    /// file, so a scene explored outside a library leaves nothing behind.
    @discardableResult
    public static func refresh(library: URL, at date: Date = Date()) throws -> CostModel {
        let history = CostHistory.read(library: library)
        let model = fit(history, at: date)
        guard !history.isEmpty else { return model }
        let file = url(library: library)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try model.encoded().write(to: file, options: .atomic)
        return model
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - History

/// The finished runs a library remembers: `index.csv` for explored scenes, `hires.json` for
/// hires runs, and the `export.done` events of `events.jsonl` for exports.
public struct CostHistory: Sendable, Equatable {
    public var explore: [CostModel.Sample] = []
    public var hires: [CostModel.Sample] = []
    public var exports: [String: [CostModel.Sample]] = [:]

    public init() {}

    public var isEmpty: Bool { explore.isEmpty && hires.isEmpty && exports.isEmpty }

    public static func read(library: URL) -> CostHistory {
        var history = CostHistory()
        for batch in directories(in: library) {
            history.explore += exploreSamples(batch: batch)
            for scene in directories(in: batch) {
                if let sample = hiresSample(SceneFolder(scene)) { history.hires.append(sample) }
            }
            for (key, samples) in exportSamples(batch: batch) {
                history.exports[key, default: []] += samples
            }
        }
        return history
    }

    /// Each scene's wall clock divided by how many scenes ran alongside it on average, itself
    /// included. A scene at the end of a batch shares the GPU with fewer, and a batch of three
    /// never ran four at once. The scene's log ends when the scene does; without logs, the
    /// batch's own `N at once` stands for every scene.
    static func exploreSamples(batch: URL) -> [CostModel.Sample] {
        let rows = SceneLibrary.indexRows(batch.appendingPathComponent("index.csv"))
        let jobs = Double(declaredJobs(batch: batch) ?? CostModel.exploreJobs)
        let fallbackDate = modified(batch.appendingPathComponent("index.csv")) ?? .distantPast
        struct Run {
            var id: String
            var units: Double
            var seconds: Double
            var end: Date?
        }
        let runs: [Run] = rows.compactMap { id, row in
            guard row["status"] == "ok", let particles = row["particles"].flatMap(Double.init),
                let steps = row["steps"].flatMap(Double.init),
                let seconds = row["wall_seconds"].flatMap(Double.init), seconds > 0
            else { return nil }
            let settle = row["settle"].flatMap(Double.init) ?? 0
            let log = batch.appendingPathComponent(".logs/\(id).log")
            return Run(
                id: "\(batch.lastPathComponent)/\(id)", units: particles * (settle + steps),
                seconds: seconds, end: modified(log))
        }
        let timed = runs.compactMap { run in
            run.end.map { (start: $0.addingTimeInterval(-run.seconds), end: $0) }
        }
        return runs.map { run in
            var alongside = jobs
            if let end = run.end {
                let start = end.addingTimeInterval(-run.seconds)
                let overlap = timed.reduce(0.0) {
                    $0 + max(0, min(end, $1.end).timeIntervalSince(max(start, $1.start)))
                }
                alongside = max(overlap / run.seconds, 1)
            }
            return CostModel.Sample(
                units: run.units, seconds: run.seconds / alongside, date: run.end ?? fallbackDate,
                id: run.id, alongside: alongside)
        }
        .sorted { $0.date < $1.date }
    }

    /// `batch.log` opens each run with `start: seed S, N at once, ...`; the last run stands.
    static func declaredJobs(batch: URL) -> Int? {
        guard
            let text = try? String(
                contentsOf: batch.appendingPathComponent("batch.log"), encoding: .utf8)
        else { return nil }
        var jobs: Int?
        for line in text.split(whereSeparator: \.isNewline) where line.contains(" start: ") {
            let words = line.split(separator: " ")
            if let index = words.firstIndex(of: "at"), index > 0, index + 1 < words.count,
                words[index + 1].hasPrefix("once"), let count = Int(words[index - 1])
            {
                jobs = count
            }
        }
        return jobs
    }

    static func hiresSample(_ folder: SceneFolder) -> CostModel.Sample? {
        guard let record = folder.storedHires(), let seconds = record.seconds, seconds > 0
        else { return nil }
        return CostModel.Sample(
            units: Double(record.particles) * Double(record.settle + record.steps),
            seconds: seconds, date: modified(folder.hires) ?? .distantPast, id: folder.sceneID)
    }

    /// #101's `export.done` lines: `t`, `preset`, `codec`, `frames`, `seconds`. Lines of any
    /// other kind, or that do not parse, are skipped.
    static func exportSamples(batch: URL) -> [String: [CostModel.Sample]] {
        guard
            let text = try? String(
                contentsOf: batch.appendingPathComponent("events.jsonl"), encoding: .utf8)
        else { return [:] }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDates = ISO8601DateFormatter()
        var samples: [String: [CostModel.Sample]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                object["kind"] as? String == "export.done",
                let preset = object["preset"] as? String,
                let frames = (object["frames"] as? NSNumber)?.doubleValue,
                let seconds = (object["seconds"] as? NSNumber)?.doubleValue, frames > 0, seconds > 0
            else { continue }
            let codec =
                (object["codec"] as? String)
                ?? (VideoPreset.all.first { $0.name == preset }?.defaultCodec ?? .hevc).rawValue
            let stamp = object["t"] as? String ?? ""
            let date = dates.date(from: stamp) ?? plainDates.date(from: stamp) ?? .distantPast
            samples[CostModel.exportKey(preset: preset, codec: codec), default: []].append(
                CostModel.Sample(
                    units: frames, seconds: seconds, date: date, id: batch.lastPathComponent))
        }
        return samples
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func directories(in url: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
            ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Printing

extension CostModel {
    /// What `sillage-render costs` prints: each line with an example a night would run.
    public var lines: [String] {
        var lines = [
            String(
                format: "explore    %.1f s + %.1f ns a particle step, per scene slot, %@",
                explore.fixedSeconds, explore.secondsPerUnit * 1e9, Self.origin(explore)),
            String(
                format: "           200 000 particles over 4 000 steps, %d at once: %.1f min a scene",
                Self.exploreJobs, exploreSeconds(particles: 200_000, steps: 4_000) / 60),
            String(
                format: "hires      %.0f s + %.1f ns a visible particle step, %@",
                hires.fixedSeconds, hires.secondsPerUnit * 1e9, Self.origin(hires)),
            String(
                format: "           2 M over 10 000 steps: %.0f min",
                hiresSeconds(particles: 2_000_000, steps: 10_000) / 60),
        ]
        var keys = Set(exports.keys)
        keys.formUnion(["1080p/hevc", "4k/hevc"])
        for key in keys.sorted() {
            let name = String(key.prefix { $0 != "/" })
            let line =
                exports[key]
                ?? Self.fallbackExport(
                    VideoPreset.all.first { $0.name == name }
                        ?? VideoPreset(name: name, width: 1920, height: 1080))
            lines.append(
                String(
                    format: "export     %@ %.1f s + %.1f ms a frame, %@: 900 frames in %.0f s",
                    key, line.fixedSeconds, line.secondsPerUnit * 1e3, Self.origin(line),
                    line.seconds(900)))
        }
        return lines
    }

    private static func origin(_ line: Line) -> String {
        let rejected = line.rejected > 0 ? ", \(line.rejected) left out" : ""
        switch line.source {
        case .fitted: return "fitted on \(line.samples) runs\(rejected)"
        case .scaled: return "fallback scaled on \(line.samples) runs\(rejected)"
        case .fallback: return "fallback, no runs yet"
        }
    }
}

// MARK: - Check

extension CostModel {
    /// One run of a batch against what the model would have said.
    public struct CheckRow: Sendable, Equatable {
        public var kind: String
        public var id: String
        public var took: Double
        /// Fitted on every other run of the library.
        public var predicted: Double
        /// Fitted on the runs that ended before the batch's first one started.
        public var before: Double

        public var error: Double { predicted / took - 1 }
        public var errorBefore: Double { before / took - 1 }
    }

    /// Each explored scene and hires run of `batch`, predicted with it left out of the fit.
    /// Explored scenes are compared at the number of scenes that really ran alongside them.
    public static func check(_ history: CostHistory, batch: String) -> [CheckRow] {
        func rows(_ kind: String, _ samples: [Sample], fallback: Line) -> [CheckRow] {
            let mine = samples.filter { $0.id.hasPrefix(batch + "/") }
            guard
                let start = mine.map({ $0.date.addingTimeInterval(-$0.seconds * $0.alongside) })
                    .min()
            else { return [] }
            let earlier = fit(samples.filter { $0.date < start }, fallback: fallback)
            return mine.map { sample in
                let others = fit(samples.filter { $0 != sample }, fallback: fallback)
                return CheckRow(
                    kind: kind, id: sample.id, took: sample.seconds * sample.alongside,
                    predicted: others.seconds(sample.units) * sample.alongside,
                    before: earlier.seconds(sample.units) * sample.alongside)
            }
        }
        return rows("explore", history.explore, fallback: fallbackExplore)
            + rows("hires", history.hires, fallback: fallbackHires)
    }
}
