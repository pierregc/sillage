import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// The Metal side of the comparison with the CUDA solver (#274): the massive particles the Mac
/// samples, which the CUDA run reads rather than sampling its own, the Metal run over them, and
/// the same run four more times from positions a last bit away (one particle three times over,
/// then every particle), which give the scale chaos alone parts two runs by. Written only when
/// asked, into the folder that goes to branch `assets/cuda-checks`:
///
///     SILLAGE_SOLVER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter SolverCheckTests
///
/// `SILLAGE_SOLVER_CHECK_PARTICLES` (20,000) and `SILLAGE_SOLVER_CHECK_STEPS` (2,000) change
/// the run, for #283's at 500 k. `CUDABarnesHutSolverTests` reads the folder on Linux.
@Suite("Solver check")
struct SolverCheckTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let out = environment["SILLAGE_SOLVER_CHECK_OUT"]
    static let scene = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/scene/scene.json")

    @Test(.enabled(if: out != nil, "writes the Metal runs where SILLAGE_SOLVER_CHECK_OUT says"))
    func theMetalRunsOfTheComparison() throws {
        let folder = URL(fileURLWithPath: try #require(Self.out), isDirectory: true)
        let particles = Self.environment["SILLAGE_SOLVER_CHECK_PARTICLES"].flatMap(Int.init) ?? 20_000
        let steps = Self.environment["SILLAGE_SOLVER_CHECK_STEPS"].flatMap(Int.init) ?? 2_000
        let scene = try SolverCheck.scene(file: Self.scene, particles: particles)
        let sample = RestrictedSolver.sampleParticles(for: scene)
        try RunCheckpoint(directory: folder).saveMassive(sample)
        try SolverCheck.Sample(scene: scene, sample: sample, particles: particles).write(into: folder)
        try Data(contentsOf: Self.scene).write(to: folder.appendingPathComponent("scene.json"))

        let runs: [(name: String, nudge: Int??)] = [
            ("metal", nil), ("metal-bit-a", 0), ("metal-bit-b", sample.visibleCount - 1),
            ("metal-bit-c", sample.count - 1), ("metal-bit-all", .some(nil)),
        ]
        for run in runs {
            let set = run.nudge.map { SolverCheck.nudged(sample, $0) } ?? sample
            let solver = try MetalBarnesHutSolver(scene: scene, massive: set, tracers: nil)
            try SolverCheck.record(
                solver, sampled: set.formation, steps: steps, mapsEvery: max(steps / 8, 1),
                snapshots: run.name == "metal" ? SolverCheck.snapshots(steps: steps) : [],
                into: folder.appendingPathComponent(run.name, isDirectory: true))
        }
        let read = try SolverCheck.Run(folder.appendingPathComponent("metal"))
        #expect(read.steps.last == steps && read.maps.count == 9)
    }
}
