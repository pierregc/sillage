import AVFoundation
import CoreGraphics
import Foundation
import Metal
import SillageCore

/// A format of a run's videos drawn by Metal into VideoToolbox's encoder: a renderer over the
/// run's own (`Renderer(sharing:)`), drawn straight into the encoder's pixel buffers.
public final class MetalRunVideoDrawing: RunVideoDrawing {
    public let renderer: Renderer
    private let format: RunVideos.Format
    private let framesPerSecond: Int
    private let metadata: VideoMetadata?
    private var writer: VideoWriter?

    public init(
        renderer: Renderer, format: RunVideos.Format, framesPerSecond: Int, metadata: VideoMetadata?
    ) {
        self.renderer = renderer
        self.format = format
        self.framesPerSecond = framesPerSecond
        self.metadata = metadata
    }

    public var styling: any FramePreparing { renderer }

    public func begin(_ url: URL) throws {
        writer = try VideoWriter(
            width: format.width, height: format.height, framesPerSecond: Int32(framesPerSecond),
            codec: format.codec, bitsPerSecond: format.bitsPerSecond, metadata: metadata, to: url)
    }

    public func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
        guard let writer else { return }
        let renderer = renderer
        try writer.append(
            on: renderer.device,
            drawing: { target, buffer in
                renderer.encode(camera: camera, into: buffer, present: target)
            },
            read: still.map { grab in
                { pixels in
                    if let image = PNGWriter.image(bgra: pixels) {
                        try grab(MetalRunVideoStill(image: image))
                    }
                }
            })
    }

    public func end() throws { try writer?.finish() }
}

/// A frame of a Metal run's video, as the encoder took it.
public struct MetalRunVideoStill: RunVideoStill {
    public let image: CGImage

    public func writePNG(to url: URL) throws { try PNGWriter.write(image, maximumWidth: nil, to: url) }
}

extension RunVideos {
    /// The videos of a run drawn by Metal: `drawing` is the run's own renderer, over the
    /// solver's buffers, and every format reads its particles from there, so their buffers are
    /// paid for once. `smoothing` is the field the run refreshes before each frame. With
    /// `segments`, each video is written in pieces that `cut` closes, and `resume` is where a
    /// checkpoint left them.
    public convenience init(
        formats: [Format], look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int,
        drawing: Renderer, smoothing: MTLBuffer?, metadata: VideoMetadata? = nil,
        segments: URL? = nil, resume: Progress? = nil
    ) throws {
        let rate = max(capturedRate, 1)
        try self.init(
            formats: formats, look: look, framing: framing, capturedRate: capturedRate,
            metadata: metadata, segments: segments, resume: resume,
            drawing: { format, exposure, drawn in
                let renderer = try Renderer(
                    sharing: drawing,
                    settings: look.renderSettings(width: format.width, height: format.height))
                renderer.setSmoothing(smoothing)
                renderer.luminosityNormalisation = exposure
                renderer.skipFrames(drawn)
                return MetalRunVideoDrawing(
                    renderer: renderer, format: format, framesPerSecond: rate, metadata: metadata)
            },
            join: RunVideos.join)
    }

    /// `drawFrame(_:centres:keeping:)` with each kept frame as an image.
    public func draw(
        frame: Int, centres: [SIMD3<Float>],
        still: ((_ format: Format, _ image: CGImage) throws -> Void)?
    ) throws {
        try drawFrame(
            frame, centres: centres,
            keeping: still.map { grab in
                { format, kept in
                    if let kept = kept as? MetalRunVideoStill { try grab(format, kept.image) }
                }
            })
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
