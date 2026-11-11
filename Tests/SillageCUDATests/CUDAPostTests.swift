import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment = "needs an NVIDIA GPU and libsillagecuda.a: #283 runs it"

/// The post-processing of a frame on CUDA (#277), drawn here on the CPU target at small sizes:
/// the passes of a `PostPlan` over the light the particle passes left, the shared kernels of
/// `Shaders`, and the picture as bytes. Against Metal's own pictures the comparison is
/// `CUDAStillChecks`: the three frames of `Tests/Fixtures/engines/frames` in every check, and
/// the frames of a take of 200 k with the files of the `assets/cuda-checks` branch.
@Suite("CUDA post-processing")
struct CUDAPostTests {
    static let frames = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/engines/frames")

    // MARK: - Against Metal, in every check

    /// What the CUDA picture is held to against Metal's, with room over what #277 measured
    /// (docs/notes/cuda-engine.md): the look without grain agrees to rounding, and the two with
    /// it but for the 0.1 % of the pixels whose grain hash lands the other side of a rounding.
    static let tolerances: [(look: String, psnr: Double, largest: Int, overEight: Double)] = [
        ("red-vs-cyan", 60, 6, 0.0001),
        ("ember", 48, 40, 0.003),
        ("webb", 48, 40, 0.003),
    ]

    @Test(arguments: tolerances)
    func theReferenceFramesAreMetalsWithinTheTolerance(
        _ tolerance: (look: String, psnr: Double, largest: Int, overEight: Double)
    ) throws {
        let context = try CUDAContext()
        let look = tolerance.look
        let reference = [UInt8](
            try Data(contentsOf: Self.frames.appendingPathComponent("\(look).rgba")))
        let drawn = try CUDAStillChecks.fixtureFrame(
            context: context, take: Self.frames.appendingPathComponent("take.sillage"),
            look: Self.frames.appendingPathComponent("\(look).look.json"))
        let measure = CUDAStillChecks.measure(drawn, channels: 3, reference, channels: 4)
        print("CUDAPOST", look, "reference frame:", measure)
        #expect(measure.psnr >= tolerance.psnr, "\(look): \(measure)")
        #expect(measure.largest <= tolerance.largest, "\(look): \(measure)")
        #expect(measure.overEight <= tolerance.overEight, "\(look): \(measure)")
        #expect(abs(measure.meanA - measure.meanB) < 0.1, "\(look): the exposure moved")
    }

    // MARK: - The frame as a picture

    /// A renderer over the fixture take, as `sillage-cuda still` draws it.
    static func drawing(
        look: String = "ember", width: Int = 128, height: Int = 72, context: CUDAContext? = nil
    ) throws -> CUDATakeStills {
        try CUDATakeStills(
            context: context ?? CUDAContext(),
            take: RecordingFile.read(from: frames.appendingPathComponent("take.sillage")),
            look: LookFile.decoded(
                from: Data(contentsOf: frames.appendingPathComponent("\(look).look.json"))),
            capturedRate: 30, width: width, height: height, laceTexels: 256)
    }

    @Test func aPictureIsThreeBytesAPixelAndTheOtherFormatsAreTheSameBytes() throws {
        let still = try Self.drawing()
        let rgb = [UInt8](try still.still(atCaptured: 0, frame: 0, format: .rgb))
        let rgba = [UInt8](try still.still(atCaptured: 0, frame: 0, format: .rgba))
        let bgra = [UInt8](try still.still(atCaptured: 0, frame: 0, format: .bgra))
        #expect(rgb.count == 128 * 72 * 3)
        #expect(rgba.count == 128 * 72 * 4 && bgra.count == rgba.count)
        for pixel in stride(from: 0, to: 128 * 72, by: 97) {
            #expect(Array(rgb[(pixel * 3)..<(pixel * 3 + 3)]) == Array(rgba[(pixel * 4)..<(pixel * 4 + 3)]))
            #expect(rgba[pixel * 4 + 3] == 255 && bgra[pixel * 4 + 3] == 255)
            #expect(bgra[pixel * 4] == rgba[pixel * 4 + 2] && bgra[pixel * 4 + 2] == rgba[pixel * 4])
            #expect(bgra[pixel * 4 + 1] == rgba[pixel * 4 + 1])
        }
        #expect(rgb.contains { $0 > 100 } && rgb.contains { $0 < 20 }, "a picture with light in it")
    }

    @Test func aFrameDrawnTwiceIsTheSameBytes() throws {
        let still = try Self.drawing()
        let first = [UInt8](try still.still(atCaptured: 0, frame: 5))
        let again = [UInt8](try still.still(atCaptured: 0, frame: 5))
        #expect(first == again)
        let other = try Self.drawing()
        #expect([UInt8](try other.still(atCaptured: 0, frame: 5, threads: 3)) == first)
    }

    @Test func theFilmGrainMovesOnWithTheFrameOfTheVideo() throws {
        let still = try Self.drawing()
        let first = [UInt8](try still.still(atCaptured: 0, frame: 0))
        let second = [UInt8](try still.still(atCaptured: 0, frame: 1))
        #expect(first != second, "the grain stands still between two frames")
        // Of two frames of one moment the grain is all that differs: a few levels, no more.
        let measure = CUDAStillChecks.measure(first, channels: 3, second, channels: 3)
        #expect(measure.largest > 0 && measure.largest < 40, "\(measure)")
        #expect(measure.psnr > 30, "\(measure)")
        // Frame 1 is where the grain stands after one frame before it, whatever was drawn.
        #expect([UInt8](try still.still(atCaptured: 0, frame: 1)) == second)
    }

    @Test func theRawLookDrawsNoGrainAndNeedsNoBloom() throws {
        var settings = RenderSettings(width: 64, height: 36, supersample: 1)
        settings.plain = true
        var grain = FrameGrain()
        let plan = PostPlan(settings: settings, fade: 1, grain: &grain)
        let context = try CUDAContext()
        let post = try CUDAPost(context: context, sizes: plan.sizes)
        let light = try context.makeBuffer(
            [Float](repeating: 0.5, count: plan.sizes.light.width * plan.sizes.light.height * 4))
        try post.run(plan, light: light)
        let bytes = [UInt8](try post.pack(.rgb))
        // 1 - exp(-0.5) to the power 1 / 2.2, in levels of 255.
        let expected = UInt8((Float(pow(1 - exp(-0.5), 1 / 2.2)) * 255).rounded())
        #expect(bytes.count == 64 * 36 * 3)
        #expect(bytes.allSatisfy { $0 == expected })
    }

    @Test func aPlanForOtherSizesOrALightThatIsTooSmallIsRefused() throws {
        let context = try CUDAContext()
        var grain = FrameGrain()
        let small = RenderSettings(width: 64, height: 36)
        let plan = PostPlan(settings: small, fade: 1, grain: &grain)
        let post = try CUDAPost(context: context, sizes: plan.sizes)
        let other = PostPlan(settings: RenderSettings(width: 80, height: 36), fade: 1, grain: &grain)
        let light = try context.makeBuffer(length: plan.sizes.light.width * plan.sizes.light.height * 16)
        #expect(throws: CUDAError.self) { try post.run(other, light: light) }
        let short = try context.makeBuffer(length: 1024)
        #expect(throws: CUDAError.self) { try post.run(plan, light: short) }
        try post.run(plan, light: light)
        let sky = [UInt8](try post.pack(.rgb))
        #expect(sky.count == 64 * 36 * 3 && sky.contains { $0 > 0 }, "the sky is not black")
    }

    @Test func theBloomOfASingleStarSpreadsItAndKeepsItsLight() throws {
        let context = try CUDAContext()
        var settings = RenderSettings(width: 128, height: 72, supersample: 1)
        settings.bloomIntensity = 1
        settings.bloomThreshold = 0.1
        settings.bloomSoftKnee = 0.5
        settings.spikeArms = 0
        settings.skyLevel = 0
        settings.noiseLevel = 0
        var grain = FrameGrain()
        let plan = PostPlan(settings: settings, fade: 1, grain: &grain)
        let post = try CUDAPost(context: context, sizes: plan.sizes)
        var texels = [Float](repeating: 0, count: 128 * 72 * 4)
        let star = (36 * 128 + 64) * 4
        texels[star] = 50
        texels[star + 1] = 50
        texels[star + 2] = 50
        let light = try context.makeBuffer(texels)
        try post.run(plan, light: light)
        let up = try post.image(.up(0))
        let down = try post.image(.down(0))
        let lit = stride(from: 0, to: up.count, by: 4).filter { up[$0] > 1e-4 }.count
        #expect(lit > 20, "the bloom stays on the star's own pixels: \(lit) lit")
        #expect(down.contains { $0 > 0 })
        // The pyramid's filters conserve the light: what the first level holds, the last holds
        // up to the light the borders let out.
        let total = stride(from: 0, to: down.count, by: 4).reduce(Float(0)) { $0 + down[$1] }
        #expect(total > 1, "the bright pass keeps most of the star")
        let bytes = [UInt8](try post.pack(.rgb))
        let centre = (36 * 128 + 64) * 3
        #expect(bytes[centre] > bytes[centre - 3 * 40], "the star is brighter than its surroundings")
    }

    // MARK: - PNG

    @Test func aPNGWrittenIsAPNGReadBack() throws {
        var bytes: [UInt8] = []
        for y in 0..<20 {
            for x in 0..<30 { bytes += [UInt8(x * 8), UInt8(y * 12), UInt8((x * y) % 256)] }
        }
        let image = PNG.Image(width: 30, height: 20, channels: 3, bytes: bytes)
        let data = PNG.encode(image)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(try PNG.decode(data) == image)
        let grey = PNG.Image(width: 4, height: 3, channels: 1, bytes: Array(0..<12))
        #expect(try PNG.decode(PNG.encode(grey)) == grey)
        let alpha = PNG.Image(width: 2, height: 2, channels: 4, bytes: Array(0..<16))
        #expect(try PNG.decode(PNG.encode(alpha)) == alpha)
        #expect(throws: PNG.Failure.self) { try PNG.decode(Data([1, 2, 3, 4, 5, 6, 7, 8, 9])) }
    }

    @Test func aPictureCompressesAndAFileWithoutZlibStillHoldsThePicture() throws {
        let flat = PNG.Image(
            width: 200, height: 100, channels: 3, bytes: [UInt8](repeating: 90, count: 60_000))
        let stored = PNG.encode(flat, compressed: false)
        #expect(try PNG.decode(stored) == flat)
        if PNG.compresses {
            #expect(PNG.encode(flat).count < stored.count / 20)
        }
        var noise: [UInt8] = []
        var state: UInt32 = 7
        for _ in 0..<(70_000 * 3) {
            state = state &* 1_664_525 &+ 1_013_904_223
            noise.append(UInt8(state >> 24))
        }
        // More than one stored block of 65,535 bytes.
        let big = PNG.Image(width: 700, height: 100, channels: 3, bytes: Array(noise.prefix(210_000)))
        #expect(try PNG.decode(PNG.encode(big, compressed: false)) == big)
    }

    // MARK: - The stills of a take

    @Test func aVideosFramesAreCountedAtItsRate() throws {
        let still = try Self.drawing()
        #expect(still.capturedRate == 30)
        #expect(still.position(ofFrame: 4) == 4)
        #expect(still.position(ofFrame: 4, framesPerSecond: 60) == 2)
        #expect(still.position(ofFrame: 10, framesPerSecond: 15) == 20)
    }

    // MARK: - Against Metal, with the files of the assets branch

    private static let targets = ProcessInfo.processInfo.environment["SILLAGE_CUDA_RENDER_TARGETS"]

    /// What the stills of a take of 200 k are held to, a little under what #277 measured: with
    /// no grain 50 dB (52 to 62 drawn, 61 to 68 from Metal's own light), with it 47 (49 to 53).
    /// Metal's accumulation developed here is exactly Metal's in the raw look.
    @Test(
        .enabled(
            if: targets != nil,
            "set SILLAGE_CUDA_RENDER_TARGETS to the render folder of the assets/cuda-checks branch"))
    func theStillsAgreeWithMetal() throws {
        let folder = URL(fileURLWithPath: try #require(Self.targets))
        let output = ProcessInfo.processInfo.environment["SILLAGE_CUDA_STILLS_OUT"]
        let rows = try CUDAStillChecks.compareWithMetal(
            folder: folder, output: output.map { URL(fileURLWithPath: $0) },
            log: { print("CUDAPOST", $0) })
        #expect(!rows.isEmpty)
        for row in rows {
            let name = "\(row.look) \(row.frame)"
            let grained = row.look.hasPrefix("hubble")
            #expect(row.drawn.psnr >= (grained ? 47 : 50), "\(name): \(row.drawn)")
            #expect(row.drawn.overEight < (grained ? 0.003 : 0.0003), "\(name): \(row.drawn)")
            #expect(abs(row.drawn.meanA - row.drawn.meanB) < 0.1, "\(name): the exposure moved")
            #expect(row.postOnly.psnr >= (grained ? 47 : 60), "\(name): \(row.postOnly)")
            // Half floats in the particle passes put the picture nearer Metal's.
            #expect(row.halfFloats.psnr >= row.drawn.psnr - 0.1, "\(name): half floats")
            if row.look == "raw" { #expect(row.postOnly.largest == 0, "\(name): \(row.postOnly)") }
        }
    }

    // MARK: - Written now, run on a GPU in #283

    private static let fourK = ProcessInfo.processInfo.environment["SILLAGE_CUDA_STILLS_4K"]

    /// The comparison above at 3840 by 2160, from a take at 8 M drawn from 2 M massive. The
    /// Mac fills the folder as the render folder of the assets branch is filled, with
    /// `export --width 3840 --height 2160 --dump-targets` and `--stills`.
    @Test(
        .enabled(if: onAGPU && fourK != nil, needsAGPU),
        .enabled(if: fourK != nil, "set SILLAGE_CUDA_STILLS_4K to the Mac's folder of 4K stills"))
    func theStillsAgreeWithMetalAt4K() throws {
        let rows = try CUDAStillChecks.compareWithMetal(
            folder: URL(fileURLWithPath: try #require(Self.fourK)), log: { print("CUDAPOST4K", $0) })
        #expect(!rows.isEmpty)
        for row in rows {
            let grained = row.look.hasPrefix("hubble")
            #expect(row.drawn.psnr >= (grained ? 40 : 50), "\(row.look) \(row.frame): \(row.drawn)")
        }
    }

    /// The post-processing of a 4K frame, supersampled twice, with the passes of a look that has
    /// bloom and sharp spikes: the median of five after a first, against Metal's.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func thePostProcessingOfA4KFrameIsTimed() throws {
        let context = try CUDAContext()
        var settings = RenderSettings(width: 3840, height: 2160, supersample: 2)
        settings.bloomIntensity = 0.45
        settings.spikeArms = 4
        settings.spikeIntensity = 0.35
        settings.spikeLength = 90
        settings.spikeSharpness = 1
        settings.noiseLevel = 0.0016
        var grain = FrameGrain()
        let sizes = PostPlan.sizes(for: settings)
        let post = try CUDAPost(context: context, sizes: sizes)
        let light = try context.makeBuffer(length: sizes.light.width * sizes.light.height * 16)
        try light.fill(0x3C)
        var seconds: [Double] = []
        for round in 0..<6 {
            let plan = PostPlan(settings: settings, fade: 1, grain: &grain)
            let started = Date()
            try post.run(plan, light: light)
            _ = try post.pack(.bgra)
            try context.synchronize()
            if round > 0 { seconds.append(Date().timeIntervalSince(started)) }
        }
        seconds.sort()
        print(
            "CUDAPOST4K",
            String(
                format: "post-processing of a 4K frame: median %.1f ms of %@", seconds[2] * 1000,
                seconds.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")))
        #expect(seconds[2] < 5)
    }
}
