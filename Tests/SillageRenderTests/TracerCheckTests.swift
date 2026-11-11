import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

/// The Metal side of the light tracers' comparison with the CUDA engine (#275): scene-0031 drawn
/// at 200 k from 50 k massive as a hires draws it, the draw written for the CUDA run to read, the
/// Metal run over it up to the first pericentre, and the same run from positions a last bit away,
/// which gives the scale chaos alone parts two runs by. Written only when asked, into the folder
/// that goes to branch `assets/cuda-checks`:
///
///     SILLAGE_TRACER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter TracerCheckTests
///
/// `SILLAGE_TRACER_CHECK_DRAWN` (200,000), `SILLAGE_TRACER_CHECK_MASSIVE` (50,000) and
/// `SILLAGE_TRACER_CHECK_STEPS` (1,560) change the run, for #283's at 8 M from 2 M.
/// `CUDABarnesHutSolverTests` reads the folder on Linux.
@Suite("Tracer check")
struct TracerCheckTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let out = environment["SILLAGE_TRACER_CHECK_OUT"]

    @Test(.enabled(if: out != nil, "writes the Metal runs where SILLAGE_TRACER_CHECK_OUT says"))
    func theMetalRunsOfTheComparison() throws {
        let folder = URL(fileURLWithPath: try #require(Self.out), isDirectory: true)
        let drawn = Self.environment["SILLAGE_TRACER_CHECK_DRAWN"].flatMap(Int.init) ?? 200_000
        let massiveCount = Self.environment["SILLAGE_TRACER_CHECK_MASSIVE"].flatMap(Int.init) ?? 50_000
        let steps = Self.environment["SILLAGE_TRACER_CHECK_STEPS"].flatMap(Int.init) ?? 1_560
        let scenes = try TracerCheck.scenes(file: SolverCheckTests.scene, drawn: drawn, massive: massiveCount)
        let (tracers, massive) = TracerCheck.draw(drawn: scenes.drawn, massive: scenes.massive)
        let sample = TracerCheck.Sample(
            scenes: scenes, massive: massive, particles: (drawn, massiveCount), tracers: tracers.count,
            steps: steps, maps: 9, extent: 60)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TracerCheck.save(
            sample, tracers: tracers, massive: massive, scene: SolverCheckTests.scene, into: folder)

        let device = try #require(MTLCreateSystemDefaultDevice())
        for (name, nudge) in [("metal", false), ("metal-bit-all", true)] {
            let light = nudge ? TracerCheck.nudged(tracers) : tracers
            let heavy = nudge ? SolverCheck.nudged(massive, nil) : massive
            let store = try LightTracerStore(device: device, capacity: light.count + heavy.count)
            store.append(light)
            let solver = try MetalBarnesHutSolver(
                device: device, scene: scenes.massive, massive: heavy, tracers: store)
            try TracerCheck.record(
                solver, tracers: light.count, sampled: light.states.map(\.w) + heavy.formation,
                steps: steps, maps: sample.maps, extent: sample.extent,
                snapshots: name == "metal" ? TracerCheck.snapshots(steps: steps) : [],
                into: folder.appendingPathComponent(name, isDirectory: true))
        }
        let run = try TracerCheck.Run(folder.appendingPathComponent("metal"))
        #expect(run.tracers == tracers.count && run.visible == massive.visibleCount)
        #expect(run.tracerMaps.count == 9 && run.massiveMaps.count == 9 && run.times.count == 9)
        #expect(try run.accelerations(step: 0)?.count == tracers.count + massive.count)
    }
}
