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
        /// A hires's light tracer steps, settle included; 0 for any other run.
        public var tracerUnits: Double
        public var seconds: Double
        public var date: Date
        /// `<batch>/<scene>`, or `<batch>` for an export.
        public var id: String
        public var alongside: Double

        public init(
            units: Double, tracerUnits: Double = 0, seconds: Double, date: Date, id: String = "",
            alongside: Double = 1
        ) {
            self.units = units
            self.tracerUnits = tracerUnits
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
    /// Per hires run. Units are the steps of the visible particles that carry the mass, settle
    /// included: all of them in a run without light tracers.
    public var hires: Line
    /// What a hires's light tracers add to it (#211), fitted apart on what the runs with
    /// tracers took past `hires`. Units are tracer steps, settle included; no fixed part.
    public var tracers: Line
    /// Per export, keyed `<preset>/<codec>`. Units are frames.
    public var exports: [String: Line]
    /// Per frame a full pass draws as it runs (#239), keyed `<preset>/<codec>`: a frame costs
    /// the fixed part at any count, and the rate for each particle drawn. Units are particles.
    public var draws: [String: Line]

    public init(
        updated: Date, explore: Line, hires: Line, tracers: Line = CostModel.fallbackTracers,
        exports: [String: Line] = [:], draws: [String: Line] = [:]
    ) {
        self.updated = updated
        self.explore = explore
        self.hires = hires
        self.tracers = tracers
        self.exports = exports
        self.draws = draws
    }

    /// A file written before light tracers has no line for them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updated = try c.decode(Date.self, forKey: .updated)
        explore = try c.decode(Line.self, forKey: .explore)
        hires = try c.decode(Line.self, forKey: .hires)
        tracers = try c.decodeIfPresent(Line.self, forKey: .tracers) ?? Self.fallbackTracers
        exports = try c.decodeIfPresent([String: Line].self, forKey: .exports) ?? [:]
        draws = try c.decodeIfPresent([String: Line].self, forKey: .draws) ?? [:]
    }

    /// One explored scene's own wall clock with `jobs` running at once.
    public func exploreSeconds(particles: Int, steps: Int, jobs: Int = Self.exploreJobs) -> Double {
        Double(max(jobs, 1)) * explore.seconds(Double(particles) * Double(steps))
    }

    /// A batch of scenes at `jobs` at once, ignoring the tail where fewer run.
    public func exploreBatchSeconds(scenes: [(particles: Int, steps: Int)]) -> Double {
        scenes.reduce(0) { $0 + explore.seconds(Double($1.particles) * Double($1.steps)) }
    }

    /// `units` steps of the particles that carry the mass, `tracerUnits` of light tracers.
    public func hiresSeconds(units: Double, tracerUnits: Double = 0) -> Double {
        hires.seconds(units) + (tracerUnits > 0 ? tracers.seconds(tracerUnits) : 0)
    }

    /// `particles` drawn over `steps`, settle included, `massive` of them carrying the mass
    /// (all when nil) and the others light tracers.
    public func hiresSeconds(particles: Int, massive: Int? = nil, steps: Int) -> Double {
        let carrying = min(massive ?? particles, particles)
        return hiresSeconds(
            units: Double(carrying) * Double(steps),
            tracerUnits: Double(particles - carrying) * Double(steps))
    }

    /// A scene's own hires at `particles`, from `massive` when given: its story's steps at the
    /// step the massive count takes, settle included, so a short story costs less than the
    /// clip it was explored in.
    public func hiresSeconds(_ folder: SceneFolder, particles: Int, massive: Int? = nil) throws -> Double {
        let record = try folder.hiresArguments(
            ["--particles", String(particles)] + (massive.map { ["--massive", String($0)] } ?? []),
            maximumParticles: particles
        ).record
        return hiresSeconds(
            particles: particles, massive: record.massive, steps: record.settle + record.steps)
    }

    /// Drawing `frames` of `preset` over `particles` while a full pass runs.
    public func drawSeconds(preset: VideoPreset, particles: Int, frames: Int) -> Double {
        drawLine(preset: preset).seconds(Double(particles)) * Double(frames)
    }

    public func drawLine(preset: VideoPreset) -> Line {
        draws[Self.exportKey(preset: preset.name, codec: preset.defaultCodec.rawValue)]
            ?? Self.fallbackDraw(preset)
    }

    /// A full pass (#239): the run of every particle again, and `presets` drawn as it goes.
    public func fullPassSeconds(
        particles: Int, massive: Int?, steps: Int, frames: Int, presets: [String]
    ) -> Double {
        hiresSeconds(particles: particles, massive: massive, steps: steps)
            + presets.compactMap(VideoPreset.named).reduce(0) {
                $0 + drawSeconds(preset: $1, particles: particles, frames: frames)
            }
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
    /// A tracer walks the massive tree as a massive particle does, about 21 ns a step at the
    /// opening angle of 0.9 from 8 M to 200 M drawn on 2 M massive (#187, #238, #241).
    public static let fallbackTracers = Line(
        fixedSeconds: 0, secondsPerUnit: SceneFolder.nanosecondsPerTracerStep / 1e9)
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

    /// Measured alone on the M4 Max (#239, docs/notes/render-during-hires.md): a frame drawn
    /// during a full pass of scene-0031 in the Webb look, at 8 M and 30 M drawn on the same
    /// shots, scaled to the whole story by what it cost at 8 M (101 ms at 4K, 50 ms vertical).
    /// 4K runs through that 8 M frame and the 1.70 s of one at 200 M through the immersed camera
    /// (#241, docs/notes/200m-preview.md). Other sizes follow 1080p's pixels, as the exports do.
    public static let fallbackDrawFixed4K = 0.034
    public static let fallbackDrawPerParticle4K = 8.35e-9
    public static let fallbackDrawFixed1080p = 0.0095
    public static let fallbackDrawPerParticle1080p = 5.0e-9

    public static func fallbackDraw(_ preset: VideoPreset) -> Line {
        if preset.width * preset.height >= 3840 * 2160 {
            return Line(fixedSeconds: fallbackDrawFixed4K, secondsPerUnit: fallbackDrawPerParticle4K)
        }
        let pixels = Double(preset.width * preset.height) / (1920 * 1080)
        return Line(
            fixedSeconds: fallbackDrawFixed1080p * pixels, secondsPerUnit: fallbackDrawPerParticle1080p)
    }

    public static func fallback(at date: Date = Date()) -> CostModel {
        CostModel(updated: date, explore: fallbackExplore, hires: fallbackHires, tracers: fallbackTracers)
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

    /// `proportional` keeps the fallback's shape however many runs there are: a line through
    /// zero, scaled to what they took.
    public static func fit(_ samples: [Sample], fallback: Line, proportional: Bool = false) -> Line {
        let usable = samples.filter { $0.units > 0 && $0.seconds > 0 }
        guard let newest = usable.map(\.date).max() else { return fallback }
        // Against the fallback, so runs of different sizes compare.
        let ratios = usable.map { $0.seconds / max(fallback.seconds($0.units), 1e-9) }
        let limit = contentionFactor * median(ratios)
        let kept = usable.filter { $0.seconds / max(fallback.seconds($0.units), 1e-9) <= limit }
        let weights = kept.map { pow(0.5, newest.timeIntervalSince($0.date) / 86_400 / halfLifeDays) }
        let rejected = usable.count - kept.count

        let units = kept.map(\.units)
        if !proportional, kept.count >= minimumFitSamples, let low = units.min(), let high = units.max(),
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

    /// The two terms of a hires apart: the massive particles' as before light tracers, on the
    /// runs without any, and the tracers' on what the runs with tracers took past that. Every
    /// night draws 8 M from 2 M, so its runs alone could not tell the two apart.
    public static func fitHires(_ samples: [Sample]) -> (massive: Line, tracers: Line) {
        let massive = fit(samples.filter { $0.tracerUnits == 0 }, fallback: fallbackHires)
        let beyond = samples.filter { $0.tracerUnits > 0 }.map {
            Sample(
                units: $0.tracerUnits, seconds: $0.seconds - massive.seconds($0.units), date: $0.date,
                id: $0.id, alongside: $0.alongside)
        }
        return (massive, fit(beyond, fallback: fallbackTracers, proportional: true))
    }

    public static func fit(_ history: CostHistory, at date: Date = Date()) -> CostModel {
        let hires = fitHires(history.hires)
        var model = CostModel(
            updated: date, explore: fit(history.explore, fallback: fallbackExplore),
            hires: hires.massive, tracers: hires.tracers)
        for (key, samples) in history.exports {
            let name = String(key.prefix { $0 != "/" })
            let preset =
                VideoPreset.all.first { $0.name == name }
                ?? VideoPreset(name: name, width: 1920, height: 1080)
            model.exports[key] = fit(samples, fallback: fallbackExport(preset))
        }
        for (key, samples) in history.draws {
            let name = String(key.prefix { $0 != "/" })
            let preset =
                VideoPreset.all.first { $0.name == name }
                ?? VideoPreset(name: name, width: 1920, height: 1080)
            model.draws[key] = fit(samples, fallback: fallbackDraw(preset))
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
    /// A full pass's frames, one sample a preset: the particles drawn and a frame's seconds.
    public var draws: [String: [CostModel.Sample]] = [:]

    public init() {}

    public var isEmpty: Bool { explore.isEmpty && hires.isEmpty && exports.isEmpty && draws.isEmpty }

    public static func read(library: URL) -> CostHistory {
        var history = CostHistory()
        for batch in directories(in: library) {
            history.explore += exploreSamples(batch: batch)
            for scene in directories(in: batch) {
                let folder = SceneFolder(scene)
                if let sample = hiresSample(folder) { history.hires.append(sample) }
                if let full = fullPassSamples(folder) {
                    history.hires.append(full.run)
                    for (key, sample) in full.draws { history.draws[key, default: []].append(sample) }
                }
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
        let steps = Double(record.stepsRun ?? record.settle + record.steps)
        return CostModel.Sample(
            units: Double(record.massiveParticles) * steps,
            tracerUnits: Double(record.simulatedTracers) * steps, seconds: seconds,
            date: modified(folder.hires) ?? .distantPast, id: folder.sceneID)
    }

    /// A full pass (#239): the run, its drawing left out, as a hires with tracers, and each
    /// preset's frame against the particles drawn.
    static func fullPassSamples(_ folder: SceneFolder) -> (
        run: CostModel.Sample, draws: [String: CostModel.Sample]
    )? {
        guard let record = folder.storedHires(), let full = record.full, full.seconds > 0, full.frames > 0
        else { return nil }
        let steps = Double(record.settle + record.steps)
        let date = modified(folder.hires) ?? .distantPast
        var draws: [String: CostModel.Sample] = [:]
        for (name, seconds) in full.drawSeconds where seconds > 0 {
            let codec = (VideoPreset.named(name)?.defaultCodec ?? .hevc).rawValue
            draws[CostModel.exportKey(preset: name, codec: codec)] = CostModel.Sample(
                units: Double(record.particles), seconds: seconds / Double(full.frames), date: date,
                id: folder.sceneID)
        }
        return (
            CostModel.Sample(
                units: Double(record.massiveParticles) * steps,
                tracerUnits: Double(record.tracers) * steps,
                seconds: full.seconds - full.drawingSeconds, date: date, id: folder.sceneID),
            draws
        )
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
                // A full pass's videos are priced by `draws`.
                object["pass"] as? String != "full",
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
                format: "hires      %.0f s + %.1f ns a massive particle step, %@",
                hires.fixedSeconds, hires.secondsPerUnit * 1e9, Self.origin(hires)),
            String(
                format: "           2 M over 10 000 steps: %.0f min",
                hiresSeconds(particles: 2_000_000, steps: 10_000) / 60),
            String(
                format: "tracers    %.1f ns a light tracer step, %@", tracers.secondsPerUnit * 1e9,
                Self.origin(tracers)),
            String(
                format: "           8 M drawn from 2 M over 10 000 steps: %.0f min",
                hiresSeconds(particles: 8_000_000, massive: 2_000_000, steps: 10_000) / 60),
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
        var drawn = Set(draws.keys)
        drawn.formUnion(NightRecipe.defaultExports.map { "\($0)/hevc" })
        for key in drawn.sorted() {
            let name = String(key.prefix { $0 != "/" })
            let line =
                draws[key]
                ?? Self.fallbackDraw(
                    VideoPreset.all.first { $0.name == name }
                        ?? VideoPreset(name: name, width: 1920, height: 1080))
            lines.append(
                String(
                    format: "draw       %@ %.1f ms + %.2f ns a particle drawn, a frame, %@:"
                        + " %.0f ms at 8 M, %.2f s at 200 M",
                    key, line.fixedSeconds * 1e3, line.secondsPerUnit * 1e9, Self.origin(line),
                    line.seconds(8e6) * 1e3, line.seconds(2e8)))
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
        typealias Prediction = (Sample) -> Double
        func rows(_ kind: String, _ samples: [Sample], fitted: ([Sample]) -> Prediction) -> [CheckRow] {
            let mine = samples.filter { $0.id.hasPrefix(batch + "/") }
            guard
                let start = mine.map({ $0.date.addingTimeInterval(-$0.seconds * $0.alongside) })
                    .min()
            else { return [] }
            let earlier = fitted(samples.filter { $0.date < start })
            return mine.map { sample in
                let others = fitted(samples.filter { $0 != sample })
                return CheckRow(
                    kind: kind, id: sample.id, took: sample.seconds * sample.alongside,
                    predicted: others(sample) * sample.alongside,
                    before: earlier(sample) * sample.alongside)
            }
        }
        let explore = { (samples: [Sample]) -> Prediction in
            let line = fit(samples, fallback: fallbackExplore)
            return { line.seconds($0.units) }
        }
        let hires = { (samples: [Sample]) -> Prediction in
            let (massive, tracers) = fitHires(samples)
            let model = CostModel(
                updated: Date(), explore: fallbackExplore, hires: massive, tracers: tracers)
            return { model.hiresSeconds(units: $0.units, tracerUnits: $0.tracerUnits) }
        }
        return rows("explore", history.explore, fitted: explore)
            + rows("hires", history.hires, fitted: hires)
    }
}
