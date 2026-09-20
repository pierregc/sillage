import AVFoundation
import CoreVideo
import Foundation
import Metal
import SillageCore
import simd

/// Encodes a captured run to a video file.
///
/// The take itself is the better thing to keep — it reopens as the run, with every setting
/// that decides the image still live. A video is what leaves the application: it goes in a
/// message, a slide or a browser, and needs nothing to play it.
///
/// Frames are rendered here rather than grabbed from the window, so the resolution has
/// nothing to do with the display and nothing is dropped or recompressed twice.
public enum VideoExport {
    public enum Failure: Error, CustomStringConvertible {
        case writerUnavailable(String)
        case pixelBuffer
        case tooShort

        public var description: String {
            switch self {
            case .writerUnavailable(let message): "L'encodeur n'a pas démarré : \(message)"
            case .pixelBuffer: "Impossible d'allouer une image"
            case .tooShort: "Une prise d'au moins deux images est nécessaire"
            }
        }
    }

    /// Renders every frame of `recording` and writes them out at `framesPerSecond`.
    ///
    /// `progress` is called on the calling thread with a fraction from 0 to 1.
    public static func write(
        recording: Recording,
        particles: ParticleSystem,
        scene: SceneConfig,
        settings: RenderSettings,
        camera: Camera,
        armStrength: Float = 1,
        framesPerSecond: Int32 = 30,
        to url: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        guard recording.count >= 2 else { throw Failure.tooShort }
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: settings.width,
                AVVideoHeightKey: settings.height,
                AVVideoCompressionPropertiesKey: [
                    // Generous: a galaxy is mostly faint gradient on black, which is exactly
                    // what a mean bitrate smears into banding.
                    AVVideoAverageBitRateKey: settings.width * settings.height * 12,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
            ])
        guard writer.canAdd(input) else { throw Failure.writerUnavailable("entrée refusée") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writerUnavailable(writer.error?.localizedDescription ?? "inconnu")
        }
        writer.startSession(atSourceTime: .zero)

        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        guard
            let positions = device.makeBuffer(
                length: recording.particleCount * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared)
        else { throw Failure.pixelBuffer }
        let renderer = try Renderer(
            device: device, particles: particles, settings: settings,
            externalPositions: positions)
        let expander = try SnapshotExpander(
            device: device, particleCount: recording.particleCount)
        let smoothing = try SmoothingField(
            device: device, particleCount: recording.particleCount)
        renderer.setSmoothing(smoothing.buffer)

        guard let snapshots = SnapshotStream(device: device, recording: recording) else {
            throw Failure.pixelBuffer
        }
        for index in 0..<recording.count {
            snapshots.prepare(from: index)
            guard let offset = snapshots.fetch(index), let frame = recording.frame(at: index)
            else { continue }
            let pair = (frame, frame)
            expander.expand(
                first: frame, at: offset, second: frame, at: offset,
                from: snapshots.buffer, blend: 0, into: positions)
            // Densities move slowly and the tree costs more than the frame does.
            if index % 12 == 0 { smoothing.update(from: positions) }
            renderer.setDiskFrames(
                DiskFrame.make(
                    scene: scene, centers: recording.centers(at: index), time: pair.0.time,
                    strength: armStrength))
            let pixels = renderer.render(camera: camera)

            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.pixelBuffer }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.pixelBuffer }
            copy(pixels, into: buffer, width: settings.width, height: settings.height)
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond))
            progress(Double(index + 1) / Double(recording.count))
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed {
            throw Failure.writerUnavailable(writer.error?.localizedDescription ?? "inconnu")
        }
    }

    /// The renderer hands back RGBA and the encoder wants BGRA, and a pixel buffer's rows are
    /// padded to its own stride rather than to the image width.
    static func copy(
        _ pixels: [UInt8], into buffer: CVPixelBuffer, width: Int, height: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let destination = base.bindMemory(to: UInt8.self, capacity: stride * height)
        for row in 0..<height {
            let source = row * width * 4
            let target = row * stride
            for column in 0..<width {
                let from = source + column * 4
                let to = target + column * 4
                destination[to] = pixels[from + 2]
                destination[to + 1] = pixels[from + 1]
                destination[to + 2] = pixels[from]
                destination[to + 3] = 255
            }
        }
    }
}
