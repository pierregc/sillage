import Foundation
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
            "splatVertex", "splatFragment", "starfieldVertex", "resolve", "brightPass",
            "downsample", "upsampleAdd", "diffractionSpikes", "composite",
        ] {
            #expect(render.makeFunction(name: name) != nil, "missing \(name)")
        }
        let solver = try device.makeLibrary(source: SolverShaders.source, options: nil)
        #expect(solver.makeFunction(name: "integrate") != nil)
    }

    /// Sizes the shader's own declaration rather than asserting a number that has to be
    /// edited every time a field is added. A mismatch here means the host is writing bytes the
    /// kernel reads at the wrong offsets, which shows up as nonsense rather than as a crash.
    static func shaderStride(of name: String, in source: String) -> Int? {
        guard let header = source.range(of: "struct \(name) {"),
            let close = source.range(of: "};", range: header.upperBound..<source.endIndex)
        else { return nil }

        var size = 0
        var alignment = 4
        for line in source[header.upperBound..<close.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("//"), let type = text.split(separator: " ").first else {
                continue
            }
            let (width, align): (Int, Int)
            switch type {
            case "float4x4": (width, align) = (64, 16)
            case "float4", "int4", "uint4": (width, align) = (16, 16)
            case "float3", "int3", "uint3": (width, align) = (16, 16)
            case "float2", "int2", "uint2": (width, align) = (8, 8)
            case "float", "int", "uint": (width, align) = (4, 4)
            default: continue
            }
            alignment = max(alignment, align)
            size = (size + align - 1) / align * align + width
        }
        return (size + alignment - 1) / alignment * alignment
    }

    @Test func structLayoutsMatchTheShader() {
        #expect(MemoryLayout<SIMD3<Float>>.stride == 16)

        #expect(
            Self.shaderStride(of: "SplatUniforms", in: Shaders.source)
                == MemoryLayout<SplatUniforms>.stride)
        #expect(
            Self.shaderStride(of: "BloomParams", in: Shaders.source)
                == MemoryLayout<BloomParams>.stride)
        #expect(
            Self.shaderStride(of: "CompositeParams", in: Shaders.source)
                == MemoryLayout<CompositeParams>.stride)
        #expect(
            Self.shaderStride(of: "SpikeParams", in: Shaders.source)
                == MemoryLayout<SpikeParams>.stride)
        #expect(
            Self.shaderStride(of: "ExpandParams", in: RecordingShaders.source)
                == MemoryLayout<ExpandParams>.stride)
        #expect(
            Self.shaderStride(of: "GalaxyGPU", in: SolverShaders.source)
                == MemoryLayout<GalaxyGPU>.stride)
        #expect(
            Self.shaderStride(of: "IntegrateParams", in: SolverShaders.source)
                == MemoryLayout<IntegrateParams>.stride)
        #expect(
            Self.shaderStride(of: "BHNode", in: BarnesHutShaders.source)
                == MemoryLayout<BHNode>.stride)
        #expect(
            Self.shaderStride(of: "HaloGPU", in: BarnesHutShaders.source)
                == MemoryLayout<HaloGPU>.stride)
        #expect(
            Self.shaderStride(of: "BHParams", in: BarnesHutShaders.source)
                == MemoryLayout<BHParams>.stride)
    }

    @Test func isolatedDiskStaysStableOnGPU() throws {
        // Tracer solver, so tracer initial conditions: the preset is self-gravitating, and
        // sampling a disk balanced against its own mass then integrating it in the rigid
        // potential alone leaves it turning too fast for the field it is actually in.
        var scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        scene.solver = .restricted
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
