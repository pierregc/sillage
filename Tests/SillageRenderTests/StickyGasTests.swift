import Metal
import Testing

@testable import SillageCore
@testable import SillageRender
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

@Suite("Sticky gas")
struct StickyGasTests {
    /// Two clouds on their way into each other, each of gas and of stars, too light to pull.
    private func streams(count: Int, speed: Float) -> ParticleSystem {
        var generator = SeededGenerator(seed: 11)
        var particles = ParticleSystem(capacity: count * 2)
        for index in 0..<count * 2 {
            let side: Float = index % 2 == 0 ? -1 : 1
            let place =
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal()) * 0.4
                + SIMD3(side, 0, 0)
            let gas = index < count
            particles.append(
                position: place, velocity: SIMD3(-side * speed, 0, 0), galaxy: 0,
                radius: 1, formation: gas ? ParticleSystem.unformed : ParticleSystem.ancient,
                component: gas ? .dust : .star, mass: 1e-9)
        }
        return particles
    }

    private func scene(count: Int, gas: StickyGas?) -> SceneConfig {
        // No disk here to cool towards.
        var cloud = GalaxyConfig(
            name: "streams", particleCount: count,
            potential: GalaxyPotential(profile: .plummer, mass: 1e-6, scaleRadius: 3),
            diskScaleLength: 3, diskMassFraction: 1)
        cloud.dissipationTime = 0
        var scene = SceneConfig(
            name: "streams", galaxies: [cloud],
            solver: .barnesHut, timeStep: 0.01, openingAngle: 0.7, softening: 0.25)
        scene.stickyGas = gas
        return scene
    }

    @Test func gasStreamsStopAgainstEachOtherAndStarsPassThrough() throws {
        let count = 4_000
        let unit = Float(Physics.kilometersPerSecondPerVelocityUnit)
        let speed = 100 / unit
        var gas = StickyGas()
        gas.rate = 20
        let solver = try MetalBarnesHutSolver(
            scene: scene(count: count * 2, gas: gas), particles: streams(count: count, speed: speed))
        solver.step(count: 300)
        let after = solver.particles
        var gasSpeed: Float = 0
        var starSpeed: Float = 0
        var momentum = SIMD3<Float>.zero
        for index in 0..<count * 2 {
            let velocity = after.velocities[index]
            if index < count {
                gasSpeed += simd_length(velocity)
                momentum += velocity
            } else {
                starSpeed += simd_length(velocity)
            }
        }
        gasSpeed *= unit / Float(count)
        starSpeed *= unit / Float(count)
        // Only what closes on the gas ahead is lost, so the gas is left with more than its sound
        // speed, across the lines it met its cells along.
        #expect(gasSpeed < 50, "gas still at \(gasSpeed) km/s")
        #expect(abs(starSpeed - 100) < 1, "stars at \(starSpeed) km/s")
        // Nothing gives the gas that was met the push back, so momentum is kept on average only.
        #expect(simd_length(momentum) / (Float(count) * speed) < 0.25)
    }

    @Test func gasNoFasterThanItsSoundSpeedIsLeftAlone() throws {
        let count = 3_000
        let speed = 100 / Float(Physics.kilometersPerSecondPerVelocityUnit)
        func run(_ gas: StickyGas?) throws -> ParticleSystem {
            let solver = try MetalBarnesHutSolver(
                scene: scene(count: count * 2, gas: gas), particles: streams(count: count, speed: speed))
            solver.step(count: 5)
            return solver.particles
        }
        var calm = StickyGas()
        calm.soundSpeed = 1e6
        let without = try run(nil)
        let with = try run(calm)
        #expect(without.positions == with.positions)
        #expect(without.velocities == with.velocities)
    }

    @Test func aSceneAsksForItInItsFileAndOnlyThen() throws {
        let plain = SceneConfig.merger(particleCount: 1_000)
        let written = try SceneFile(plain).encoded()
        #expect(!String(decoding: written, as: UTF8.self).contains("stickyGas"))
        #expect(try SceneFile.decoded(from: written).scene(particleCount: 1_000).stickyGas == nil)

        var asked = plain
        asked.stickyGas = StickyGas(parsing: "12:0.5::24")
        #expect(asked.stickyGas?.soundSpeed == 12)
        #expect(asked.stickyGas?.rate == 0.5)
        #expect(asked.stickyGas?.crossing == 0)
        #expect(asked.stickyGas?.cellGas == 24)
        #expect(asked.stickyGas?.reach == 2)
        #expect(asked.stickyGas?.jeans == 2)
        let file = try SceneFile.decoded(from: SceneFile(asked).encoded())
        #expect(file.scene(particleCount: 1_000).stickyGas == asked.stickyGas)
        #expect(try SceneConfig.decoded(from: asked.encoded()).stickyGas == asked.stickyGas)
        #expect(StickyGas(parsing: "on") == StickyGas())
        #expect(StickyGas(parsing: "fast") == nil)
        #expect(StickyGas(parsing: "-1") == nil)
    }
}
