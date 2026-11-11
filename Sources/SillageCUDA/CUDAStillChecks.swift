import Foundation
import SillageCore
import SillageRender

/// The pictures of the CUDA engine measured against Metal's (#277): how far apart two 8-bit
/// pictures of one frame are, and the comparisons the tests and `docs/notes/cuda-engine.md` make.
public enum CUDAStillChecks {
    /// How far one picture is from another, over the red, green and blue of every pixel.
    public struct Measure: Sendable, CustomStringConvertible {
        /// 10 log10 (255^2 / mean squared difference), infinite for the same picture.
        public var psnr: Double
        /// Mean of the absolute differences, in levels of 255.
        public var meanDifference: Double
        public var largest: Int
        /// The share of the pixels where a channel differs by more than 8 levels.
        public var overEight: Double
        /// The mean of each picture, to see a shift of exposure.
        public var meanA: Double
        public var meanB: Double

        public var description: String {
            String(
                format: "PSNR %.2f dB, mean difference %.3f, largest %d, %.3f %% of the pixels over 8",
                psnr, meanDifference, largest, overEight * 100)
        }
    }

    /// `a` and `b` are pixels of `channelsA` and `channelsB` bytes, the first three of each red,
    /// green and blue.
    public static func measure(
        _ a: [UInt8], channels channelsA: Int, _ b: [UInt8], channels channelsB: Int
    ) -> Measure {
        let pixels = min(a.count / channelsA, b.count / channelsB)
        var squares = 0.0
        var absolute = 0.0
        var largest = 0
        var over = 0
        var totals = (a: 0.0, b: 0.0)
        for pixel in 0..<pixels {
            var far = false
            for channel in 0..<3 {
                let first = Int(a[pixel * channelsA + channel])
                let second = Int(b[pixel * channelsB + channel])
                let difference = abs(first - second)
                squares += Double(difference * difference)
                absolute += Double(difference)
                largest = max(largest, difference)
                far = far || difference > 8
                totals.a += Double(first)
                totals.b += Double(second)
            }
            if far { over += 1 }
        }
        let values = Double(max(pixels * 3, 1))
        let mean = squares / values
        return Measure(
            psnr: mean > 0 ? 10 * log10(255 * 255 / mean) : .infinity,
            meanDifference: absolute / values, largest: largest,
            overEight: Double(over) / Double(max(pixels, 1)), meanA: totals.a / values,
            meanB: totals.b / values)
    }

    /// Frame 0 of a one-frame take in a look, 256 by 144 as `EngineFixtures` draws them with
    /// Metal, as 8-bit RGB: the three reference frames of `Tests/Fixtures/engines/frames`.
    public static func fixtureFrame(
        context: CUDAContext, take: URL, look: URL, width: Int = 256, height: Int = 144,
        halfFloats: Bool = false, threads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> [UInt8] {
        let drawing = try CUDATakeStills(
            context: context, take: RecordingFile.read(from: take),
            look: LookFile.decoded(from: Data(contentsOf: look)), capturedRate: 30, width: width,
            height: height)
        drawing.renderer.halfFloats = halfFloats
        let bytes = try drawing.still(
            atCaptured: 0, frame: 0, format: .rgb, threads: halfFloats ? 1 : threads)
        return [UInt8](bytes)
    }
}

extension CUDAStillChecks {
    /// A frame of a look drawn three ways and measured against Metal's PNG of it.
    public struct Row: Sendable {
        public var look: String
        public var frame: String
        /// The CUDA engine as it draws: fixed point, fp32 post-processing.
        public var drawn: Measure
        /// The particle passes blending in half floats as Metal's targets do.
        public var halfFloats: Measure
        /// Metal's own accumulation, developed by the CUDA post-processing alone.
        public var postOnly: Measure
    }

    /// Where the pictures of a row are written under `output`, one PNG a way.
    public static func compareWithMetal(
        folder: URL, looks: Set<String>? = nil, output: URL? = nil,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        log: (String) -> Void = { _ in }
    ) throws -> [Row] {
        guard let manifest = RenderTargetManifest.read(from: folder) else {
            throw CUDARenderChecks.Failure.folder("\(folder.path): no manifest of sillage-render-targets 1")
        }
        let take = try RecordingFile.read(from: folder.appendingPathComponent(manifest.take.file))
        let context = try CUDAContext()
        var drawings: [String: CUDATakeStills] = [:]
        var rows: [Row] = []
        for target in manifest.targets where looks?.contains(target.look) ?? true {
            let png = folder.appendingPathComponent("stills/\(target.look)-\(target.frame).png")
            guard FileManager.default.fileExists(atPath: png.path) else { continue }
            let metal = try PNG.read(png)
            let drawing: CUDATakeStills
            if let held = drawings[target.look] {
                drawing = held
            } else {
                drawing = try CUDATakeStills(
                    context: context, take: take,
                    look: LookFile.decoded(
                        from: Data(contentsOf: folder.appendingPathComponent(target.lookFile))),
                    capturedRate: manifest.take.capturedRate, width: manifest.width,
                    height: manifest.height)
                drawings[target.look] = drawing
            }
            let index = Int(target.captured)

            func picture(_ name: String, _ bytes: UnsafeRawBufferPointer) throws -> [UInt8] {
                let image = PNG.Image(
                    width: manifest.width, height: manifest.height, channels: 3, bytes: [UInt8](bytes))
                if let output {
                    try FileManager.default.createDirectory(
                        at: output, withIntermediateDirectories: true)
                    try PNG.write(
                        image, to: output.appendingPathComponent("\(target.look)-\(target.frame)\(name).png"))
                }
                return image.bytes
            }

            drawing.renderer.halfFloats = false
            let drawn = try picture(
                "",
                drawing.still(atCaptured: target.captured, frame: index, threads: threads))
            drawing.renderer.halfFloats = true
            let halves = try picture(
                "-half", drawing.still(atCaptured: target.captured, frame: index, threads: 1))
            drawing.renderer.halfFloats = false
            var post: [UInt8] = []
            if let entry = target.files["light"] {
                let light = try CUDARenderChecks.halves(entry, in: folder)
                post = try picture(
                    "-post",
                    drawing.still(
                        atCaptured: target.captured, frame: index, threads: 1, light: light))
            }
            let row = Row(
                look: target.look, frame: target.frame,
                drawn: measure(drawn, channels: 3, metal.bytes, channels: metal.channels),
                halfFloats: measure(halves, channels: 3, metal.bytes, channels: metal.channels),
                postOnly: measure(post, channels: 3, metal.bytes, channels: metal.channels))
            log(
                "\(row.look) \(row.frame): drawn \(row.drawn) | half floats \(row.halfFloats)"
                    + " | Metal's light developed here \(row.postOnly)")
            rows.append(row)
        }
        return rows
    }
}
