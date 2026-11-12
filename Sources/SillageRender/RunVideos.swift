import AVFoundation
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
    private let device: MTLDevice
    private let renderers: [Renderer]
    private let replays: [ShotReplay]
    private var writers: [VideoWriter]
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

    /// `drawing` is the run's own renderer, over the solver's buffers: every format reads its
    /// particles from there, so their buffers are paid for once. `smoothing` is the field the
    /// run refreshes before each frame. With `segments`, each video is written in pieces that
    /// `cut` closes, and `resume` is where a checkpoint left them.
    public init(
        formats: [Format], look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int,
        drawing: Renderer, smoothing: MTLBuffer?, metadata: VideoMetadata? = nil,
        segments: URL? = nil, resume: Progress? = nil
    ) throws {
        self.formats = formats
        self.look = look
        self.framing = framing
        self.capturedRate = max(capturedRate, 1)
        self.segments = segments
        self.metadata = metadata
        device = drawing.device
        let plan =
            look.camera.mode == .director
            ? ShotPlan(take: framing, file: look, framesPerSecond: self.capturedRate) : nil
        let exposure = Renderer.luminosityNormalisation(formation: framing.particles.formation)
        var progress = resume ?? Progress()
        if progress.seconds.count != formats.count {
            progress.seconds = Array(repeating: 0, count: formats.count)
        }
        if progress.segments.count != formats.count {
            progress.segments = Array(repeating: [], count: formats.count)
        }
        var renderers: [Renderer] = []
        var replays: [ShotReplay] = []
        for format in formats {
            let renderer = try Renderer(
                sharing: drawing, settings: look.renderSettings(width: format.width, height: format.height))
            renderer.setSmoothing(smoothing)
            renderer.luminosityNormalisation = exposure
            // The grain of the frames already drawn; the cameras catch up by themselves.
            renderer.skipFrames(progress.frames)
            renderers.append(renderer)
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
        self.renderers = renderers
        self.replays = replays
        self.progress = progress
        lastSeconds = Array(repeating: 0, count: formats.count)
        writers = []
        writers = try formats.indices.map { try writer($0) }
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

    private func writer(_ index: Int) throws -> VideoWriter {
        let format = formats[index]
        let url =
            segments.map { $0.appendingPathComponent(segmentName(index)) }
            ?? SceneFolder.partial(format.url)
        return try VideoWriter(
            width: format.width, height: format.height, framesPerSecond: Int32(capturedRate),
            codec: format.codec, bitsPerSecond: format.bitsPerSecond, metadata: metadata, to: url)
    }

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
                let shot = TakeFraming.prepare(
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
            try writers[index].finish()
            progress.seconds[index] += Date().timeIntervalSince(started)
            progress.segments[index].append(segmentName(index))
        }
        progress.segment += 1
        progress.segmentStart = progress.frames
        writers = try formats.indices.map { try writer($0) }
    }

    /// Closes every video. Segments are joined into each video's partial path, without encoding
    /// them again; the caller commits them.
    public func finish() throws -> [Report] {
        for index in formats.indices {
            let started = Date()
            try writers[index].finish()
            if let segments {
                progress.segments[index].append(segmentName(index))
                try Self.join(
                    progress.segments[index].map { segments.appendingPathComponent($0) },
                    into: SceneFolder.partial(formats[index].url), frames: progress.frames,
                    framesPerSecond: capturedRate, metadata: metadata)
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
        for (live, taken) in zip(centres, kept) where live != taken {
            progress.drift = max(progress.drift, simd_distance(live, taken))
            if progress.firstDrift == nil { progress.firstDrift = frame }
        }
    }
}

extension RunVideos {
    /// Joins whole segments into one video without encoding them again, their timestamps moved
    /// on by the frames before them, and checks the video holds `frames` frames.
    public static func join(
        _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let mp4 = url.pathExtension.lowercased() == "mp4"
        let writer = try AVAssetWriter(outputURL: url, fileType: mp4 ? .mp4 : .mov)
        if let metadata { writer.metadata = metadata.items(quickTime: !mp4) }
        var input: AVAssetWriterInput?
        let rate = CMTimeScale(max(framesPerSecond, 1))
        var written = 0
        for part in parts {
            let (reader, output) = try passthrough(part)
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                // The reader's markers, at either end of a segment, hold no frame.
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                if input == nil {
                    // The first segment's description, which every segment of the run shares.
                    let made = AVAssetWriterInput(
                        mediaType: .video, outputSettings: nil,
                        sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
                    made.expectsMediaDataInRealTime = false
                    guard writer.canAdd(made) else { throw Failure.join("the writer refused the track") }
                    writer.add(made)
                    guard writer.startWriting() else {
                        throw Failure.join(writer.error?.localizedDescription ?? "the writer did not start")
                    }
                    writer.startSession(atSourceTime: .zero)
                    input = made
                }
                guard let input else { break }
                let moved = try retimed(sample, by: CMTime(value: CMTimeValue(written), timescale: rate))
                while !input.isReadyForMoreMediaData && writer.status == .writing {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard input.append(moved) else {
                    throw Failure.join(writer.error?.localizedDescription ?? "a frame was refused")
                }
                count += 1
            }
            guard reader.status == .completed else {
                throw Failure.join(
                    "\(part.lastPathComponent): \(reader.error?.localizedDescription ?? "unreadable")")
            }
            written += count
        }
        guard let input else { throw Failure.join("no frame in the segments") }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(written), timescale: rate))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.join(writer.error?.localizedDescription ?? "the video was not finished")
        }
        let (check, output) = try passthrough(url)
        var counted = 0
        while let sample = output.copyNextSampleBuffer() {
            counted += CMSampleBufferGetNumSamples(sample)
        }
        guard check.status == .completed, counted == frames, written == frames else {
            throw Failure.join("\(counted) frames in the video, \(written) in the segments, \(frames) drawn")
        }
    }

    /// A video's compressed frames, in decode order, as they lie in the file.
    private static func passthrough(_ url: URL) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        let loaded = TrackBox()
        let ready = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            loaded.track = tracks?.first
            ready.signal()
        }
        ready.wait()
        guard let track = loaded.track else { throw Failure.join("\(url.lastPathComponent) has no video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.join("\(url.lastPathComponent) cannot be read") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.join(
                reader.error?.localizedDescription ?? "\(url.lastPathComponent) cannot be read")
        }
        return (reader, output)
    }

    private static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset
            }
        }
        var moved: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
            sampleTimingArray: &timing, sampleBufferOut: &moved)
        guard status == noErr, let moved else { throw Failure.join("a frame could not be retimed") }
        return moved
    }

    /// Carries a track out of its loading callback.
    private final class TrackBox: @unchecked Sendable { var track: AVAssetTrack? }
}

/// Every drawn particle at a few frames of a full pass (#239), the key frames of the massive
/// pass's curves, kept in a take of their own for posters and thumbnails in any style: one
/// stored frame each, in order, with `keyframes.json` beside it saying which frame each was.
/// With `blocks`, each key frame goes to disk as soon as it is taken, so a run that resumes
/// keeps those it took before (#240), and the take is put together from them at the end.
public final class KeyFrameTake {
    public typealias Entry = KeyFrameEntry

    /// One key frame on disk: its box and what the take keeps beside the positions.
    struct Block: Codable {
        var time: Float
        var origin: SIMD3<Float>
        var extent: Float
        var centers: [SIMD3<Float>]
        var disks: [DiskState]
    }

    public let keys: [KeyFrame]
    public let blocks: URL?
    private let particleCount: Int
    private let galaxyCount: Int
    private let recording: Recording
    public private(set) var entries: [Entry] = []

    /// `taken` are the key frames a checkpoint says were kept before; any other block in
    /// `blocks` was left by the interval it lost and is removed.
    public init(
        keys: [KeyFrame], particleCount: Int, galaxyCount: Int, blocks: URL? = nil,
        taken: [Entry] = []
    ) throws {
        self.keys = keys.sorted { $0.frame < $1.frame }
        self.blocks = blocks
        self.particleCount = particleCount
        self.galaxyCount = galaxyCount
        recording = Recording(particleCount: particleCount, galaxyCount: galaxyCount, interval: 1)
        if let blocks {
            try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
            let kept = Set(taken.map(\.frame))
            for name in (try? FileManager.default.contentsOfDirectory(atPath: blocks.path)) ?? []
            where !kept.contains(Self.frame(of: name) ?? -1) {
                try? FileManager.default.removeItem(at: blocks.appendingPathComponent(name))
            }
            entries = taken
        } else {
            recording.reserve(frames: keys.count)
        }
    }

    public func wants(frame: Int) -> Bool {
        keys.contains { $0.frame == frame } && !entries.contains { $0.frame == frame }
    }

    public func offer(
        frame: Int, positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        disks: [DiskState]
    ) throws {
        guard let key = keys.first(where: { $0.frame == frame }) else { return }
        if let blocks {
            let one = Recording(
                particleCount: particleCount, galaxyCount: galaxyCount, interval: 1,
                bitsPerAxis: recording.bitsPerAxis)
            one.append(positions: positions, time: time, centers: centers, disks: disks)
            let contents = one.contents()
            guard let box = contents.frames.first else { return }
            let data = blocks.appendingPathComponent(Self.name(frame, "positions"))
            FileManager.default.createFile(atPath: data.path, contents: nil)
            let handle = try FileHandle(forWritingTo: data)
            try one.streamPositionBytes { try handle.write(contentsOf: Data($0)) }
            try handle.close()
            // Written last: a block without it was cut short.
            try JSONEncoder().encode(
                Block(
                    time: box.time, origin: box.origin, extent: box.extent, centers: contents.centers,
                    disks: contents.disks)
            ).write(to: blocks.appendingPathComponent(Self.name(frame, "json")), options: .atomic)
        } else {
            recording.append(positions: positions, time: time, centers: centers, disks: disks)
        }
        entries.append(
            Entry(
                frame: frame, role: key.role.rawValue,
                timeMyr: Double(time) * Physics.megayearsPerTimeUnit))
    }

    /// The take, and its list beside it at `list`.
    public func write(scene: SceneConfig, particles: ParticleSystem, to url: URL, list: URL) throws {
        guard !entries.isEmpty else { return }
        let ordered = entries.sorted { $0.frame < $1.frame }
        if let blocks {
            // The blocks' positions one after another, mapped rather than read in.
            let all = blocks.appendingPathComponent("all.positions")
            FileManager.default.createFile(atPath: all.path, contents: nil)
            let handle = try FileHandle(forWritingTo: all)
            var frames: [Recording.Frame] = []
            var centers: [SIMD3<Float>] = []
            var disks: [DiskState] = []
            for entry in ordered {
                let block = try JSONDecoder().decode(
                    Block.self,
                    from: Data(contentsOf: blocks.appendingPathComponent(Self.name(entry.frame, "json"))))
                frames.append(Recording.Frame(time: block.time, origin: block.origin, extent: block.extent))
                centers += block.centers
                disks += block.disks
                try handle.write(
                    contentsOf: Data(
                        contentsOf: blocks.appendingPathComponent(Self.name(entry.frame, "positions")),
                        options: .alwaysMapped))
            }
            try handle.close()
            let assembled = Recording(
                particleCount: particleCount, galaxyCount: galaxyCount, frames: frames, centers: centers,
                disks: disks, interval: 1, capturedCount: frames.count, bitsPerAxis: recording.bitsPerAxis,
                mapped: try Data(contentsOf: all, options: .alwaysMapped))
            try RecordingFile.write(assembled, scene: scene, particles: particles, to: url)
            try? FileManager.default.removeItem(at: all)
        } else {
            try RecordingFile.write(recording, scene: scene, particles: particles, to: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ordered).write(to: list, options: .atomic)
    }

    private static func name(_ frame: Int, _ kind: String) -> String {
        String(format: "frame-%06d.%@", frame, kind)
    }

    private static func frame(of name: String) -> Int? {
        guard name.hasPrefix("frame-") else { return nil }
        return Int(name.dropFirst(6).prefix { $0.isNumber })
    }
}
