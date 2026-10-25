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
        case pixelBuffer
        case tooShort

        public var description: String {
            switch self {
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
        metadata: VideoMetadata? = nil,
        to url: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        guard recording.count >= 2 else { throw Failure.tooShort }
        let writer = try VideoWriter(
            width: settings.width, height: settings.height, framesPerSecond: framesPerSecond,
            metadata: metadata, to: url)
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
        // One picture per frame the run was captured at, whether the take kept it or keeps
        // one in several and the rest are drawn through the ones around them.
        let pictures = recording.capturedCount
        for picture in 0..<pictures {
            guard let blend = recording.blend(atCaptured: picture) else { continue }
            guard
                expander.expand(blend, of: recording, through: snapshots, into: positions)
            else { continue }
            // Densities move slowly and the tree costs more than the frame does.
            if picture % 12 == 0 { smoothing.update(from: positions) }
            renderer.setDiskFrames(
                DiskFrame.make(
                    scene: scene, centers: recording.centers(at: blend), time: blend.time,
                    strength: armStrength))
            try writer.append(on: device) { target, buffer in
                renderer.encode(camera: camera, into: buffer, present: target)
            }
            progress(Double(picture + 1) / Double(pictures))
        }

        try writer.finish()
    }
}
