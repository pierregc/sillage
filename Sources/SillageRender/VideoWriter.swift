import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Encodes frames to H.264 as they are produced, each one drawn by the GPU straight into a
/// pixel buffer of the encoder's own pool: no read back, no swizzle. The encoder works on a
/// queue of its own, so the next frame renders while this one compresses.
///
/// `.mp4` gets an MP4 container, anything else a QuickTime movie. Not laid out for streaming:
/// that rewrite leaves a stray copy of the file beside it when the process exits right after.
public final class VideoWriter: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case writerUnavailable(String)
        case pixelBuffer

        public var description: String {
            switch self {
            case .writerUnavailable(let message): "L'encodeur n'a pas démarré : \(message)"
            case .pixelBuffer: "Impossible d'allouer une image"
            }
        }
    }

    public let width: Int
    public let height: Int
    public let framesPerSecond: Int32
    public private(set) var count = 0
    /// How long the GPU spent on the last frame drawn.
    public private(set) var lastGPUTime: Double = 0

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let encoding = DispatchQueue(label: "dev.pierregc.sillage.video", qos: .userInitiated)
    /// Frames handed over and not yet taken by the encoder. Bounded, so a slow encoder holds
    /// the renderer back instead of the pool growing without end.
    private let inFlight = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var failure: (any Error)?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var textures: CVMetalTextureCache?

    /// A galaxy is mostly faint gradient on black, which a mean bit rate smears into banding,
    /// hence a generous default of twelve bits a pixel a second.
    public static func defaultBitRate(width: Int, height: Int) -> Int { width * height * 12 }

    public init(
        width: Int, height: Int, framesPerSecond: Int32 = 30, bitsPerSecond: Int? = nil,
        to url: URL
    ) throws {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond

        try? FileManager.default.removeItem(at: url)
        let mp4 = url.pathExtension.lowercased() == "mp4"
        writer = try AVAssetWriter(outputURL: url, fileType: mp4 ? .mp4 : .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitsPerSecond
                        ?? Self.defaultBitRate(width: width, height: height),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(input) else { throw Failure.writerUnavailable("entrée refusée") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writerUnavailable(writer.error?.localizedDescription ?? "inconnu")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Draws the next frame on the GPU into `target`, a BGRA texture over the encoder's pixel
    /// buffer, through `buffer`. `read`, when given, sees the finished frame before the encoder
    /// takes it.
    public func append(
        on device: MTLDevice, drawing draw: (_ target: MTLTexture, _ buffer: MTLCommandBuffer) -> Void,
        read: ((CVPixelBuffer) throws -> Void)? = nil
    ) throws {
        let (queue, cache) = try metal(device)
        defer { CVMetalTextureCacheFlush(cache, 0) }
        try append(filling: { pixels in
            var wrapped: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixels,
                [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue]
                    as CFDictionary,
                .bgra8Unorm, width, height, 0, &wrapped)
            guard let wrapped, let target = CVMetalTextureGetTexture(wrapped),
                let buffer = queue.makeCommandBuffer()
            else { throw Failure.pixelBuffer }
            draw(target, buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime
            if let error = buffer.error { throw error }
            try read?(pixels)
        })
    }

    /// Fills the next frame on the CPU, for frames that never touch the GPU.
    public func append(filling fill: (CVPixelBuffer) throws -> Void) throws {
        try check()
        inFlight.wait()
        var handed = false
        defer { if !handed { inFlight.signal() } }
        guard let pool = adaptor.pixelBufferPool else { throw Failure.pixelBuffer }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let pixels = made else { throw Failure.pixelBuffer }
        try fill(pixels)

        let time = CMTime(value: CMTimeValue(count), timescale: framesPerSecond)
        count += 1
        handed = true
        let frame = Frame(pixels: pixels)
        encoding.async { [self] in
            defer { inFlight.signal() }
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !adaptor.append(frame.pixels, withPresentationTime: time) {
                record(
                    Failure.writerUnavailable(writer.error?.localizedDescription ?? "image refusée"))
            }
        }
    }

    public func finish() throws {
        encoding.sync {}
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        try check()
        if writer.status == .failed {
            throw Failure.writerUnavailable(writer.error?.localizedDescription ?? "inconnu")
        }
    }

    private func metal(_ device: MTLDevice) throws -> (MTLCommandQueue, CVMetalTextureCache) {
        if let queue, let textures, self.device === device { return (queue, textures) }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache, let made = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        queue = made
        textures = cache
        return (made, cache)
    }

    private func record(_ error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    private func check() throws {
        lock.lock()
        let failure = self.failure
        lock.unlock()
        if let failure { throw failure }
    }

    /// The pool recycles a buffer only once the encoder lets go of it, so handing one across
    /// queues is safe; the wrapper says so to the compiler.
    private struct Frame: @unchecked Sendable { let pixels: CVPixelBuffer }
}
