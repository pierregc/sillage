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
/// `CUDAStillChecks`, which needs the files of the `assets/cuda-checks` branch for the frames of
/// a take of 200 k, and `Tests/Fixtures/engines/frames` for the three of the repository.
@Suite("CUDA post-processing")
struct CUDAPostTests {
    static let frames = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/engines/frames")

    @Test(arguments: ["red-vs-cyan", "ember", "webb"])
    func measuresTheReferenceFrames(_ look: String) throws {
        let context = try CUDAContext()
        let reference = [UInt8](
            try Data(contentsOf: Self.frames.appendingPathComponent("\(look).rgba")))
        for halves in [false, true] {
            let drawn = try CUDAStillChecks.fixtureFrame(
                context: context, take: Self.frames.appendingPathComponent("take.sillage"),
                look: Self.frames.appendingPathComponent("\(look).look.json"), halfFloats: halves)
            let measure = CUDAStillChecks.measure(drawn, channels: 3, reference, channels: 4)
            print("CUDAPOST", look, halves ? "half floats" : "fixed point", measure)
        }
    }

    // MARK: - Against Metal

    private static let targets = ProcessInfo.processInfo.environment["SILLAGE_CUDA_RENDER_TARGETS"]

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
    }
}
