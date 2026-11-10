import CoreGraphics
import Foundation
import Metal
import SillageCore
import simd

/// A scene's videos drawn while its full pass runs (#239). Each frame is drawn as soon as the
/// solver has it, in every format, with what an export of the massive take draws: its look,
/// its shots, the arms painted on its disks, its time and its exposure. Only the positions and
/// the smoothing are the run's, every drawn particle of it. A run of a hundred million keeps no
/// take of its history, so this is where its videos come from.
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
        /// codec, and its rate for `frames` at `framesPerSecond`.
        public init(preset: VideoPreset, frames: Int, framesPerSecond: Int, url: URL) throws {
            self.preset = preset
            codec = preset.defaultCodec
            width = preset.width / 2 * 2
            height = preset.height / 2 * 2
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

    public let formats: [Format]
    public let look: LookFile
    public let framing: RecordingFile.Loaded
    public let capturedRate: Int
    private let device: MTLDevice
    private let renderers: [Renderer]
    private let replays: [ShotReplay]
    private let writers: [VideoWriter]
    private var seconds: [Double]
    public private(set) var frames = 0
    /// What each format took on the last frame, in seconds.
    public private(set) var lastSeconds: [Double]
    /// The galaxies' centres against the massive take's, on the frames it stored: zero while
    /// the massive part of this run repeats the massive pass to the bit.
    public private(set) var drift: Float = 0
    /// The first stored frame whose centres differ at all, nil while none has.
    public private(set) var firstDrift: Int?
    public private(set) var checkedFrames = 0

    /// `drawing` is the run's own renderer, over the solver's buffers: every format reads its
    /// particles from there, so their buffers are paid for once. `smoothing` is the field the
    /// run refreshes before each frame.
    public init(
        formats: [Format], look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int,
        drawing: Renderer, smoothing: MTLBuffer?, metadata: VideoMetadata? = nil
    ) throws {
        self.formats = formats
        self.look = look
        self.framing = framing
        self.capturedRate = max(capturedRate, 1)
        device = drawing.device
        let plan =
            look.camera.mode == .director
            ? ShotPlan(take: framing, file: look, framesPerSecond: self.capturedRate) : nil
        let exposure = Renderer.luminosityNormalisation(formation: framing.particles.formation)
        var renderers: [Renderer] = []
        var replays: [ShotReplay] = []
        var writers: [VideoWriter] = []
        for format in formats {
            let renderer = try Renderer(
                sharing: drawing, settings: look.renderSettings(width: format.width, height: format.height))
            renderer.setSmoothing(smoothing)
            renderer.luminosityNormalisation = exposure
            renderers.append(renderer)
            replays.append(
                TakeExport.replay(
                    look: look, framing: framing, capturedRate: self.capturedRate,
                    width: format.width, height: format.height, plan: plan))
            try FileManager.default.createDirectory(
                at: format.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writers.append(
                try VideoWriter(
                    width: format.width, height: format.height,
                    framesPerSecond: Int32(self.capturedRate), codec: format.codec,
                    bitsPerSecond: format.bitsPerSecond, metadata: metadata,
                    to: SceneFolder.partial(format.url)))
        }
        self.renderers = renderers
        self.replays = replays
        self.writers = writers
        seconds = Array(repeating: 0, count: formats.count)
        lastSeconds = seconds
    }

    /// The director's shots, one line each, for the log.
    public var shots: [String] { replays.first?.plan?.summary ?? [] }

    /// Draws captured frame `frame` in every format, once the solver has stepped to it and the
    /// smoothing is refreshed. `centres` are the solver's, checked against the massive take's.
    /// `still` sees a format's finished frame when given.
    public func draw(
        frame: Int, centres: [SIMD3<Float>],
        still: ((_ format: Format, _ image: CGImage) throws -> Void)? = nil
    ) throws {
        check(frame: frame, centres: centres)
        for index in formats.indices {
            let started = Date()
            let renderer = renderers[index]
            guard
                let shot = TakeExport.prepare(
                    renderer, look: look, replay: replays[index], framing: framing,
                    at: Double(frame))
            else { throw RecordingFile.Failure.truncated }
            let format = formats[index]
            try writers[index].append(
                on: device,
                drawing: { target, buffer in
                    renderer.encode(camera: shot.camera, into: buffer, present: target)
                },
                read: still.map { grab in
                    { pixels in if let image = PNGWriter.image(bgra: pixels) { try grab(format, image) } }
                })
            lastSeconds[index] = Date().timeIntervalSince(started)
            seconds[index] += lastSeconds[index]
        }
        frames += 1
    }

    /// Closes every video; they stay at their partial paths for the caller to commit.
    public func finish() throws -> [Report] {
        let reports = formats.indices.map {
            Report(format: formats[$0], frames: frames, seconds: seconds[$0])
        }
        for (index, writer) in writers.enumerated() {
            let started = Date()
            try writer.finish()
            seconds[index] += Date().timeIntervalSince(started)
        }
        return reports
    }

    private func check(frame: Int, centres: [SIMD3<Float>]) {
        let recording = framing.recording
        guard let blend = recording.blend(atCaptured: frame),
            blend.fraction == 0 || blend.fraction == 1
        else { return }
        let stored = Int(blend.fraction == 0 ? blend.keys[1] : blend.keys[2])
        let kept = recording.centers(at: stored)
        guard kept.count == centres.count else { return }
        checkedFrames += 1
        for (live, taken) in zip(centres, kept) where live != taken {
            drift = max(drift, simd_distance(live, taken))
            if firstDrift == nil { firstDrift = frame }
        }
    }
}

/// Every drawn particle at a few frames of a full pass (#239), the key frames of the massive
/// pass's curves, kept in a take of their own for posters and thumbnails in any style: one
/// stored frame each, in order, with `keyframes.json` beside it saying which frame each was.
public final class KeyFrameTake {
    public struct Entry: Codable, Sendable, Equatable {
        /// The captured frame of the run, as the curves count it.
        public var frame: Int
        public var role: String
        public var timeMyr: Double
    }

    public let keys: [KeyFrame]
    private let recording: Recording
    public private(set) var entries: [Entry] = []

    public init(keys: [KeyFrame], particleCount: Int, galaxyCount: Int) {
        self.keys = keys.sorted { $0.frame < $1.frame }
        recording = Recording(particleCount: particleCount, galaxyCount: galaxyCount, interval: 1)
        recording.reserve(frames: keys.count)
    }

    public func wants(frame: Int) -> Bool { keys.contains { $0.frame == frame } }

    public func offer(
        frame: Int, positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        disks: [DiskState]
    ) {
        guard let key = keys.first(where: { $0.frame == frame }) else { return }
        recording.append(positions: positions, time: time, centers: centers, disks: disks)
        entries.append(
            Entry(
                frame: frame, role: key.role.rawValue,
                timeMyr: Double(time) * Physics.megayearsPerTimeUnit))
    }

    /// The take, and its list beside it at `list`.
    public func write(scene: SceneConfig, particles: ParticleSystem, to url: URL, list: URL) throws {
        guard !entries.isEmpty else { return }
        try RecordingFile.write(recording, scene: scene, particles: particles, to: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: list, options: .atomic)
    }
}
