import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

/// The black hole close up on CUDA (#336), run here on the CPU target against what Metal gave
/// in `Tests/Fixtures/hole`. The stills and the command build lens tables, most of a minute each
/// on the CPU of a test build, and are held by `sillage-cuda check` instead (`CUDAHoleCheck`),
/// in an optimised build and a process of its own. docs/notes/cuda-engine.md gives the measures.
@Suite("CUDA black hole")
struct CUDAHoleTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/hole")

    @Test func theRunStepsAsMetalsWithinTheTolerance() throws {
        let measure = try CUDAHoleCheck.run(context: CUDAContext(), folder: Self.folder)
        print("CUDAHOLE run", measure)
        #expect(measure.passed, "\(measure)")
    }

    @Test func aRunRepeatsToTheBit() throws {
        let manifest = try CUDAHoleCheck.manifest(Self.folder)
        let start = try CUDAHoleCheck.frame(Self.folder, "start.bin", tracers: manifest.tracers)
        let scene = try CUDAHoleCheck.scene(Self.folder).blackHole
        let context = try CUDAContext()
        var ends: [TidalFrame] = []
        for split in [10, 4] {
            let run = try CUDATidalRun(context: context, scene: scene, gas: manifest.gas)
            run.resume(from: start, step: manifest.startStep)
            run.step(split)
            run.step(10 - split)
            #expect(run.failure == nil && run.stepsTaken == manifest.startStep + 10)
            ends.append(run.frame)
        }
        #expect(ends[0] == ends[1])
    }
}
