import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Metal solver")
struct MetalSolverTests {
    /// The GPU kernel and the CPU reference implement the same kick-drift-kick with the same
    /// analytic potentials, so they must agree to floating point noise.
    @Test func matchesCPUReference() throws {
        let scene = SceneConfig.merger(particleCount: 20_000, seed: 17)
        let seeded = RestrictedSolver.sampleParticles(for: scene)
        let gpu = try MetalSolver(scene: scene, particles: seeded)
        let cpu = RestrictedSolver(scene: scene, particles: seeded)

        gpu.step(count: 400)
        cpu.step(count: 400)

        let gpuPositions = gpu.particles.positions
        let cpuPositions = cpu.particles.positions
        #expect(gpuPositions.count == cpuPositions.count)

        var worst: Float = 0
        var scale: Float = 0
        for index in cpuPositions.indices {
            worst = max(worst, simd_length(gpuPositions[index] - cpuPositions[index]))
            scale = max(scale, simd_length(cpuPositions[index]))
        }
        #expect(worst / scale < 1e-3)
    }

    @Test func centresTrackTheCPUReference() throws {
        let scene = SceneConfig.merger(particleCount: 1_000)
        let gpu = try MetalSolver(scene: scene)
        let cpu = RestrictedSolver(scene: scene)
        gpu.step(count: 500)
        cpu.step(count: 500)
        for index in cpu.centers.indices {
            #expect(simd_length(gpu.centers[index] - cpu.centers[index]) < 1e-4)
        }
        #expect(abs(gpu.time - cpu.time) < 1e-4)
    }

    /// Shaders are compiled at runtime, so a syntax error would otherwise only surface the
    /// first time a given pipeline is built. This forces both libraries through the compiler.
    @Test func allShadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let render = try device.makeLibrary(source: Shaders.source, options: nil)
        for name in [
            "splatVertex", "splatFragment", "resolve", "brightPass", "downsample", "upsampleAdd",
            "composite",
        ] {
            #expect(render.makeFunction(name: name) != nil, "missing \(name)")
        }
        let solver = try device.makeLibrary(source: SolverShaders.source, options: nil)
        #expect(solver.makeFunction(name: "integrate") != nil)
    }

    @Test func structLayoutsMatchTheShader() {
        #expect(MemoryLayout<GalaxyGPU>.stride == 48)
        #expect(MemoryLayout<IntegrateParams>.stride == 16)
        #expect(MemoryLayout<SplatUniforms>.stride == 80)
        #expect(MemoryLayout<BloomParams>.stride == 16)
        #expect(MemoryLayout<CompositeParams>.stride == 16)
        #expect(MemoryLayout<SIMD3<Float>>.stride == 16)
    }

    @Test func isolatedDiskStaysStableOnGPU() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let solver = try MetalSolver(scene: scene)
        func meanRadius() -> Double {
            var total = 0.0
            for position in solver.particles.positions { total += Double(simd_length(position)) }
            return total / Double(solver.particles.count)
        }
        let before = meanRadius()
        solver.step(count: 400)
        #expect(abs(meanRadius() - before) / before < 0.01)
    }

    @Test func rendererProducesNonEmptyImage() throws {
        let scene = SceneConfig.merger(particleCount: 50_000)
        let solver = try MetalSolver(scene: scene)
        solver.step(count: 1_500)
        let renderer = try Renderer(
            particles: RestrictedSolver.sampleParticles(for: scene),
            settings: RenderSettings(width: 320, height: 180, supersample: 2, bloomLevels: 4),
            externalPositions: solver.positions)
        let pixels = renderer.render(camera: Camera.framing(radius: 70))
        #expect(pixels.count == 320 * 180 * 4)
        #expect(pixels.contains { $0 > 8 })
    }
}
