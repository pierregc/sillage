import Foundation
import Metal
import SillageCore
import Testing

@testable import SillageRender

@Suite("Kernel width per population")
struct PopulationWidthTests {
    /// The linear light an isolated disk's stars leave, before the post stages, as RGB.
    static func light(_ change: (inout RenderSettings) -> Void = { _ in }) throws -> [SIMD3<Float>] {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        var settings = RenderSettings(
            width: 320, height: 180, supersample: 1, brightness: 0.12, dustStrength: 0,
            starCount: 0, noiseLevel: 0)
        change(&settings)
        let renderer = try Renderer(particles: particles, settings: settings)
        let field = try SmoothingField(device: renderer.device, particleCount: particles.visibleCount)
        field.update(from: renderer.positions)
        renderer.setSmoothing(field.buffer)
        renderer.time = 3
        renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 3, strength: 1))
        _ = renderer.render(camera: Camera.framing(radius: 20, elevation: 1.2))
        let file = try #require(renderer.particleTargets()?.target.first { $0.name == "light.f16" })
        let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        return stride(from: 0, to: halves.count, by: 4).map {
            SIMD3(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]))
        }
    }

    static func total(_ light: [SIMD3<Float>]) -> Double {
        light.reduce(0) { $0 + Double($1.x + $1.y + $1.z) }
    }

    /// The light finer than a pixel's neighbours, over the whole light: the sand.
    static func fine(_ light: [SIMD3<Float>], width: Int = 320, height: Int = 180) -> Double {
        let sum = light.map { Double($0.x + $0.y + $0.z) }
        var rough = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let at = y * width + x
                let around = (sum[at - 1] + sum[at + 1] + sum[at - width] + sum[at + width]) / 4
                rough += abs(sum[at] - around)
            }
        }
        return rough / max(sum.reduce(0, +), 1e-9)
    }

    @Test func aWidthOfOneDrawsWhatTheTreeGives() throws {
        let tree = try Self.light()
        let ones = try Self.light {
            $0.oldWidth = 1
            $0.bulgeWidth = 1
            $0.youngWidth = 1
            $0.knotWidth = 1
        }
        #expect(ones == tree)
    }

    /// Wider young stars spread the same light thinner: the frame keeps its light and loses
    /// its sand.
    @Test func wideYoungStarsKeepTheLightAndLoseTheSand() throws {
        let tree = try Self.light()
        let wide = try Self.light { $0.youngWidth = 3 }
        #expect(wide != tree)
        let (a, b) = (Self.total(wide), Self.total(tree))
        #expect(abs(a / b - 1) < 0.02, "\(a) against \(b)")
        let (smooth, sandy) = (Self.fine(wide), Self.fine(tree))
        #expect(smooth < 0.9 * sandy, "\(smooth) against \(sandy)")
    }

    /// Every width reaches a population the disk holds.
    @Test func everyWidthMovesThePicture() throws {
        let tree = try Self.light()
        let changes: [(String, (inout RenderSettings) -> Void)] = [
            ("old", { $0.oldWidth = 2 }), ("bulge", { $0.bulgeWidth = 2 }),
            ("young", { $0.youngWidth = 2 }), ("knot", { $0.knotWidth = 2 }),
        ]
        for (name, change) in changes {
            #expect(try Self.light(change) != tree, "\(name)")
        }
    }
}
