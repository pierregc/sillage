import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// One format of a run's videos, as an engine draws and encodes it (#278): its renderer, which
/// each frame is prepared on, and its encoder, a video or a segment of one at a time.
public protocol RunVideoDrawing: AnyObject {
    /// What a frame is prepared on: the look, the palette, the time and the painted arms.
    var styling: any FramePreparing { get }
    /// Starts a video at `url`: the whole of it, or one segment.
    func begin(_ url: URL) throws
    /// Draws a frame through `camera` into the video begun; `still`, when given, sees the
    /// picture the encoder takes.
    func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws
    /// Closes the video begun.
    func end() throws
}

/// A frame of a run's video as its encoder took it.
public protocol RunVideoStill {
    func writePNG(to url: URL) throws
}

/// A scene's videos drawn while its full pass runs (#239). Each frame is drawn as soon as the
/// solver has it, in every format, with what an export of the massive take draws: its look,
/// its shots, the arms painted on its disks, its time and its exposure. Only the positions and
/// the smoothing are the run's, every drawn particle of it. A run of a hundred million keeps no
/// take of its history, so this is where its videos come from. The engine draws and encodes
/// (`RunVideoDrawing`); the shots, the segments and the check against the massive take are
/// here, the same for Metal and CUDA (#278).
public final class RunVideos {
    public struct Format: Sendable, Equatable {
        public var preset: VideoPreset
        public var codec: VideoCodec
        public var width: Int
        public var height: Int
        public var bitsPerSecond: Int?
        /// Where the video lands once whole; it is written to its partial path until then.
        public var url: URL

        /// As `export` draws `preset` with nothing else asked: its size with even sides, its own
        /// codec, and its rate for `frames` at `framesPerSecond`. `divisor` draws it smaller by
        /// that much on each side, for checks (`--draw-divisor`, #278).
        public init(
            preset: VideoPreset, frames: Int, framesPerSecond: Int, url: URL, divisor: Int = 1
        ) throws {
            self.preset = preset
            codec = preset.defaultCodec
            let divisor = max(divisor, 1)
            width = max(preset.width / divisor / 2 * 2, 16)
            height = max(preset.height / divisor / 2 * 2, 16)
            bitsPerSecond = try preset.bitRate(
                forSeconds: Double(frames) / Double(max(framesPerSecond, 1)))
            self.url = url
        }
    }

    public struct Report: Sendable {
        public var format: Format
        public var frames: Int
        /// Spent drawing this format and handing it to the encoder, the solver's time apart.
        public var seconds: Double
    }

    public typealias Progress = VideoProgress

    /// Joins whole segments into one video at `into` without encoding them again, and checks it
    /// holds `frames` frames.
    public typealias Joining = (
        _ parts: [URL], _ into: URL, _ frames: Int, _ framesPerSecond: Int, _ metadata: VideoMetadata?
    ) throws -> Void

    /// Makes the drawing of a format: its exposure (`luminosityNormalisation`) the framing take's,
    /// as an export of that take has it, and its grain moved on by the `drawn` frames before.
    public typealias Making = (_ format: Format, _ exposure: Float, _ drawn: Int) throws ->
        any RunVideoDrawing

    public enum Failure: Error, CustomStringConvertible {
        case join(String)

        public var description: String {
            switch self {
            case .join(let why): "the video segments did not join: \(why)"
            }
        }
    }

    public let formats: [Format]
    public let look: LookFile
    public let framing: RecordingFile.Loaded
    public let capturedRate: Int
    /// Where segments are written, one a checkpoint interval; nil writes each video whole.
    public let segments: URL?
    private let metadata: VideoMetadata?
    private let drawings: [any RunVideoDrawing]
    private let replays: [ShotReplay]
    private let joining: Joining
    private var progress: Progress
    public var frames: Int { progress.frames }
    /// What each format took on the last frame, in seconds.
    public private(set) var lastSeconds: [Double]
    /// The galaxies' centres against the massive take's, on the frames it stored: zero while
    /// the massive part of this run repeats the massive pass to the bit.
    public var drift: Float { progress.drift }
    /// The first stored frame whose centres differ at all, nil while none has.
    public var firstDrift: Int? { progress.firstDrift }
    public var checkedFrames: Int { progress.checkedFrames }
    /// The largest gap of a centre from the massive take's on each stored frame checked (#278).
    public var gaps: [CentreGap] { progress.gaps ?? [] }

    /// `drawing` makes each format's drawing. With `segments`, each video is written in pieces
    /// that `cut` closes and `join` puts together, and `resume` is where a checkpoint left them.
    public init(
        formats: [Format], look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int,
        metadata: VideoMetadata? = nil, segments: URL? = nil, resume: Progress? = nil,
        drawing: Making, join: @escaping Joining
    ) throws {
        self.formats = formats
        self.look = look
        self.framing = framing
        self.capturedRate = max(capturedRate, 1)
        self.segments = segments
        self.metadata = metadata
        joining = join
        let plan =
            look.camera.mode == .director
            ? ShotPlan(take: framing, file: look, framesPerSecond: self.capturedRate) : nil
        let exposure = ParticleAttributes.luminosityNormalisation(formation: framing.particles.formation)
        var progress = resume ?? Progress()
        if progress.seconds.count != formats.count {
            progress.seconds = Array(repeating: 0, count: formats.count)
        }
        if progress.segments.count != formats.count {
            progress.segments = Array(repeating: [], count: formats.count)
        }
        var drawings: [any RunVideoDrawing] = []
        var replays: [ShotReplay] = []
        for format in formats {
            // The grain of the frames already drawn; the cameras catch up by themselves.
            drawings.append(try drawing(format, exposure, progress.frames))
            replays.append(
                TakeFraming.replay(
                    look: look, framing: framing, capturedRate: self.capturedRate,
                    width: format.width, height: format.height, plan: plan))
            try FileManager.default.createDirectory(
                at: format.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let segments {
            try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        }
        self.drawings = drawings
        self.replays = replays
        self.progress = progress
        lastSeconds = Array(repeating: 0, count: formats.count)
        try beginAll()
    }

    /// The director's shots, one line each, for the log.
    public var shots: [String] { replays.first?.plan?.summary ?? [] }

    /// The current progress, for a checkpoint taken right after `cut`.
    public var state: Progress { progress }

    private func segmentName(_ index: Int) -> String {
        String(
            format: "%@-%04d.%@", formats[index].preset.name, progress.segment,
            formats[index].codec.fileExtension)
    }

    private func beginAll() throws {
        for index in formats.indices {
            try drawings[index].begin(
                segments.map { $0.appendingPathComponent(segmentName(index)) }
                    ?? SceneFolder.partial(formats[index].url))
        }
    }

    /// Draws captured frame `frame` in every format, once the solver has stepped to it and the
    /// smoothing is refreshed. `centres` are the solver's, checked against the massive take's.
    /// `keeping` sees a format's finished frame when given.
    public func drawFrame(
        _ frame: Int, centres: [SIMD3<Float>],
        keeping: ((_ format: Format, _ still: any RunVideoStill) throws -> Void)? = nil
    ) throws {
        check(frame: frame, centres: centres)
        for index in formats.indices {
            let started = Date()
            let drawing = drawings[index]
            guard
                let shot = TakeFraming.prepare(
                    drawing.styling, look: look, replay: replays[index], framing: framing,
                    at: Double(frame))
            else { throw RecordingFile.Failure.truncated }
            let format = formats[index]
            try drawing.append(
                camera: shot.camera, still: keeping.map { keep in { try keep(format, $0) } })
            lastSeconds[index] = Date().timeIntervalSince(started)
            progress.seconds[index] += lastSeconds[index]
        }
        progress.frames += 1
    }

    /// Closes the segment of every video and opens the next, so a checkpoint taken now has every
    /// frame drawn so far in whole files.
    public func cut() throws {
        // Nothing drawn yet in this segment, as through the settle: nothing to close.
        guard segments != nil, progress.frames > progress.segmentStart else { return }
        for index in formats.indices {
            let started = Date()
            try drawings[index].end()
            progress.seconds[index] += Date().timeIntervalSince(started)
            progress.segments[index].append(segmentName(index))
        }
        progress.segment += 1
        progress.segmentStart = progress.frames
        try beginAll()
    }

    /// Closes every video. Segments are joined into each video's partial path, without encoding
    /// them again; the caller commits them.
    public func finish() throws -> [Report] {
        for index in formats.indices {
            let started = Date()
            try drawings[index].end()
            if let segments {
                progress.segments[index].append(segmentName(index))
                try joining(
                    progress.segments[index].map { segments.appendingPathComponent($0) },
                    SceneFolder.partial(formats[index].url), progress.frames, capturedRate, metadata)
            }
            progress.seconds[index] += Date().timeIntervalSince(started)
        }
        return formats.indices.map {
            Report(format: formats[$0], frames: progress.frames, seconds: progress.seconds[$0])
        }
    }

    private func check(frame: Int, centres: [SIMD3<Float>]) {
        let recording = framing.recording
        guard let blend = recording.blend(atCaptured: frame),
            blend.fraction == 0 || blend.fraction == 1
        else { return }
        let stored = Int(blend.fraction == 0 ? blend.keys[1] : blend.keys[2])
        let kept = recording.centers(at: stored)
        guard kept.count == centres.count else { return }
        progress.checkedFrames += 1
        var gap: Float = 0
        for (live, taken) in zip(centres, kept) where live != taken {
            gap = max(gap, simd_distance(live, taken))
            progress.drift = max(progress.drift, simd_distance(live, taken))
            if progress.firstDrift == nil { progress.firstDrift = frame }
        }
        progress.gaps = (progress.gaps ?? []) + [CentreGap(frame: frame, kpc: gap)]
    }
}
