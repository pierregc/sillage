import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// The Metal side of the comparison with the CUDA solver (#274): the massive particles the Mac
/// samples, which the CUDA run reads rather than sampling its own, the curves and positions of
/// the Metal run over them, and those of two more Metal runs, with one position moved by its last
/// bit and with every one, which give the scale chaos alone parts two runs by. Written only when
/// asked:
///
///     SILLAGE_SOLVER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter SolverCheckTests
///
/// The folder goes to branch `assets/cuda-checks`, and `CUDABarnesHutSolverTests` reads it.
@Suite("Solver check")
struct SolverCheckTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let out = environment["SILLAGE_SOLVER_CHECK_OUT"]
    static let scene = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/scene/scene.json")

    @Test(.enabled(if: out != nil, "writes the Metal runs where SILLAGE_SOLVER_CHECK_OUT says"))
    func theMetalRunsOfTheComparison() throws {
        let directory = URL(fileURLWithPath: try #require(Self.out), isDirectory: true)
        let particles = Self.environment["SILLAGE_SOLVER_CHECK_PARTICLES"].flatMap(Int.init) ?? 20_000
        let steps = Self.environment["SILLAGE_SOLVER_CHECK_STEPS"].flatMap(Int.init) ?? 2_000
        let scene = try SolverCheck.scene(file: Self.scene, particles: particles)
        let sample = RestrictedSolver.sampleParticles(for: scene)
        _ = try RunCheckpoint(directory: directory).saveMassive(sample)
        let sets = [
            ("metal", sample), ("metal-one-bit", SolverCheck.oneBitMoved(sample)),
            ("metal-every-bit", SolverCheck.everyBitMoved(sample)),
        ]
        for (engine, set) in sets {
            let solver = try MetalBarnesHutSolver(scene: scene, particles: set)
            let curves = try SolverCheck.record(
                engine: engine, scene: scene, particles: particles, host: solver.host, steps: steps,
                every: 10, snapshots: SolverCheck.snapshots(steps: steps),
                into: directory.appendingPathComponent(engine, isDirectory: true),
                advance: { solver.step(count: $0) }, particles: { solver.particles })
            #expect(curves.steps.last == steps && curves.massive == sample.count)
        }
    }
}
