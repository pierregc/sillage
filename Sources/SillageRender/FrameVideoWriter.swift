import AVFoundation
import CoreVideo
import Foundation

/// Encodes frames to H.264 as they are produced, rather than from a finished take.
///
/// `VideoExport` replays a recording through one fixed camera, which is what the application
/// needs. A headless run computes its own camera per frame and already holds the pixels, so it
/// wants to hand them over one at a time and never build a recording at all.
public final class FrameVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let framesPerSecond: Int32
    private var index: Int = 0

    public init(width: Int, height: Int, framesPerSecond: Int32 = 30, to url: URL) throws {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // Generous, for the same reason as in `VideoExport`: a galaxy is mostly
                    // faint gradient on black, which a mean bitrate smears into banding.
                    AVVideoAverageBitRateKey: width * height * 12,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw VideoExport.Failure.writerUnavailable("entrée refusée")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExport.Failure.writerUnavailable(
                writer.error?.localizedDescription ?? "inconnu")
        }
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ pixels: [UInt8]) throws {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        guard let pool = adaptor.pixelBufferPool else { throw VideoExport.Failure.pixelBuffer }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw VideoExport.Failure.pixelBuffer }
        VideoExport.copy(pixels, into: buffer, width: width, height: height)
        adaptor.append(
            buffer,
            withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond))
        index += 1
    }

    public func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed {
            throw VideoExport.Failure.writerUnavailable(
                writer.error?.localizedDescription ?? "inconnu")
        }
    }
}
