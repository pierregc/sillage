import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

@Suite("Tracer walk dump")
struct TracerWalkDumpTests {
    private func disk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    /// A dump holds every buffer the walk reads at its stride, its probe is the solver's own,
    /// and a run that dumps goes on to the bit as one that does not (#271).
    @Test func aDumpMovesNothingAndHoldsTheSolversProbe() throws {
        let massive = disk(3_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: disk(12_000), massive: massive)
        let dumping = try MetalBarnesHutSolver(scene: massive, particles: split, tracers: tracers)
        let plain = try MetalBarnesHutSolver(scene: massive, particles: split, tracers: tracers)
        dumping.step(count: 13)
        plain.step(count: 13)
        let dump = try #require(dumping.walkDump())

        func buffer(_ name: String) throws -> TracerWalkDump.Buffer {
            try #require(dump.buffers.first { $0.name == name })
        }
        let probe = try buffer("accelerations").bytes.withUnsafeBytes {
            Array($0.bindMemory(to: SIMD3<Float>.self))
        }
        #expect(probe == Array(dumping.accelerations.prefix(tracers)))
        let before = try buffer("motions").bytes
        let after = try buffer("motions-mode1").bytes
        #expect(before.count == after.count && before != after)

        dumping.step(count: 7)
        plain.step(count: 7)
        #expect(dumping.particles.positions == plain.particles.positions)
        #expect(dumping.particles.velocities == plain.particles.velocities)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-dump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try dump.write(
            to: directory,
            run: .init(
                scene: "disk", label: "settled", frame: 4, step: 13, timeMyr: 1, dtScale: 8, commit: "",
                device: ""))
        #expect(folder.lastPathComponent == "frame-00004")
        let text = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: text) as? [String: Any])
        #expect(manifest["format"] as? String == "sillage-walk-dump")
        #expect(manifest["version"] as? Int == 1)
        let params = try #require(manifest["params"] as? [String: Any])
        #expect(params["tracerCount"] as? Int == tracers)
        #expect(params["mode"] as? Int == 1)
        let entries = try #require(manifest["buffers"] as? [String: [String: Any]])
        let strides = [
            "states": 16, "motions": 16, "sorted": 16, "nodes": 32, "moments": 16, "order": 4, "frame": 4,
            "halos": 48, "holes": 32, "massive": 16, "disks": 64, "params": 48, "accelerations": 16,
            "motions-mode1": 16,
        ]
        #expect(Set(entries.keys) == Set(strides.keys))
        for (name, stride) in strides {
            let entry = try #require(entries[name])
            let count = try #require(entry["count"] as? Int)
            #expect(entry["stride"] as? Int == stride, "\(name)")
            let file = folder.appendingPathComponent(try #require(entry["file"] as? String))
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
            #expect(size == count * stride, "\(name)")
        }
        #expect((entries["states"]?["count"] as? Int) == tracers)
    }
}
