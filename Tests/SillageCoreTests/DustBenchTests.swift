import Foundation
import Testing

@testable import SillageCore

/// A bench for a ring's dust (docs/notes/sombrero-dust-bench.md): samples a scene and writes
/// its dust grains alone, with no run and no GPU, for `references/sombrero/tools/dust_map.py`
/// to draw. Runs only when asked:
/// `SILLAGE_DUST_BENCH=scene.json SILLAGE_DUST_BENCH_OUT=grains.f32 scripts/linux.sh test-core --filter DustBench`.
@Suite struct DustBenchTests {
    static let scenePath = ProcessInfo.processInfo.environment["SILLAGE_DUST_BENCH"]

    @Test(.enabled(if: scenePath != nil, "set SILLAGE_DUST_BENCH to a scene.json"))
    func writesTheGrains() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["SILLAGE_DUST_BENCH_COUNT"] ?? "") ?? 4_000_000
        let out = environment["SILLAGE_DUST_BENCH_OUT"] ?? "dust-bench.f32"
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.scenePath ?? ""))
        let scene = try SceneFile.decoded(from: data).scene(particleCount: count)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: scene.seed)
        DiskSampler.sample(scene.galaxies[0], galaxyIndex: 0, into: &system, using: &generator)
        // Seven floats a grain: where it stands, its opacity, how it moves.
        var grains: [Float] = []
        for index in system.positions.indices where system.component[index] == ParticleComponent.dust.rawValue
        {
            let at = system.positions[index]
            let speed = system.velocities[index]
            grains += [at.x, at.y, at.z, system.luminosity[index], speed.x, speed.y, speed.z]
        }
        try grains.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: out))
        print("dust bench: \(grains.count / 7) grains written to \(out)")
    }
}
