import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Barnes-Hut")
struct BarnesHutTests {
    private func cluster(count: Int, seed: UInt64 = 3) -> (
        positions: [SIMD3<Float>], mass: [Float]
    ) {
        var generator = SeededGenerator(seed: seed)
        var positions: [SIMD3<Float>] = []
        var mass: [Float] = []
        for _ in 0..<count {
            positions.append(
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 7)
            mass.append(0.002)
        }
        return (positions, mass)
    }

    @Test func treeConservesMassAndCentreOfMass() {
        let (positions, mass) = cluster(count: 5_000)
        let tree = BarnesHutTree()
        tree.build(positions: positions, mass: mass)

        let total = mass.reduce(0, +)
        #expect(abs(tree.nodes[0].comMass.w - total) / total < 1e-4)

        var reference = SIMD3<Float>.zero
        for index in positions.indices { reference += positions[index] * mass[index] }
        reference /= total
        let root = tree.nodes[0].comMass
        #expect(simd_length(SIMD3<Float>(root.x, root.y, root.z) - reference) < 1e-3)

        #expect(Set(tree.order).count == positions.count)
        var inLeaves = 0
        for node in tree.nodes where node.isLeaf { inLeaves += node.particleCount }
        #expect(inLeaves == positions.count)
    }

    @Test func mortonCodesInterleaveConsistently() {
        #expect(BarnesHutTree.morton(0, 0, 0) == 0)
        #expect(BarnesHutTree.morton(1, 0, 0) == 4)
        #expect(BarnesHutTree.morton(0, 1, 0) == 2)
        #expect(BarnesHutTree.morton(0, 0, 1) == 1)
        // The digit at depth 0 is the top bit of each axis.
        #expect(BarnesHutTree.octant(BarnesHutTree.morton(512, 0, 512), depth: 0) == 5)
    }

    /// The whole point of the tree is that it approximates direct summation. This is the test
    /// that says whether the traversal is right.
    @Test func accelerationMatchesDirectSummation() throws {
        let count = 3_000
        let (positions, mass) = cluster(count: count)
        var particles = ParticleSystem(capacity: count)
        for index in 0..<count {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1,
                mass: mass[index])
        }

        // diskMassFraction 1 leaves no halo mass, so the GPU result is pure self-gravity.
        var scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: count,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, timeStep: 0.001, openingAngle: 0.4, softening: 0.25)
        scene.softening = 0.25

        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
        let computed = solver.accelerations

        var worst: Float = 0
        var meanError: Float = 0
        var samples = 0
        for index in stride(from: 0, to: count, by: 37) {
            let reference = BarnesHutTree.directAcceleration(
                at: positions[index], positions: positions, mass: mass, softening: 0.25,
                skipping: index)
            let scale = max(simd_length(reference), 1e-6)
            let error = simd_length(computed[index] - reference) / scale
            worst = max(worst, error)
            meanError += error
            samples += 1
        }
        meanError /= Float(samples)

        #expect(meanError < 0.02)
        #expect(worst < 0.15)
    }

    @Test func tighterOpeningAngleReducesError() throws {
        let count = 2_000
        let (positions, mass) = cluster(count: count, seed: 9)
        var particles = ParticleSystem(capacity: count)
        for index in 0..<count {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1,
                mass: mass[index])
        }
        func meanError(theta: Float) throws -> Float {
            let scene = SceneConfig(
                name: "cluster",
                galaxies: [
                    GalaxyConfig(
                        name: "cluster", particleCount: count,
                        potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                        diskScaleLength: 3, diskMassFraction: 1)
                ],
                solver: .barnesHut, openingAngle: theta, softening: 0.25)
            let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
            let computed = solver.accelerations
            var total: Float = 0
            var samples = 0
            for index in stride(from: 0, to: count, by: 53) {
                let reference = BarnesHutTree.directAcceleration(
                    at: positions[index], positions: positions, mass: mass, softening: 0.25,
                    skipping: index)
                total += simd_length(computed[index] - reference) / max(simd_length(reference), 1e-6)
                samples += 1
            }
            return total / Float(samples)
        }
        #expect(try meanError(theta: 0.3) < meanError(theta: 0.9))
    }

    /// The equilibrium model is what makes level 2 usable, so it is checked directly rather
    /// than through a dynamical run: watching a disk heat up takes several orbits, which does
    /// not belong in a fast test suite. The measured behaviour over an orbit is in the README.
    @Test(arguments: [Float(0.8), 1.4, 2.0])
    func equilibriumRealisesTheRequestedToomreQ(target: Float) {
        var galaxy = SceneConfig.isolatedDisk(particleCount: 1).galaxies[0]
        galaxy.toomreQ = target
        galaxy.diskMassFraction = 0.5
        let equilibrium = DiskEquilibrium(config: galaxy)

        for radius in [Float(2), 4, 8, 14] {
            let sigma = equilibrium.radialDispersion(atRadius: radius)
            let realised = equilibrium.toomreQ(atRadius: radius, radialDispersion: sigma)
            #expect(abs(realised - target) / target < 1e-3)
            // The epicyclic ratio fixes the anisotropy; it is never a free choice.
            let azimuthal = equilibrium.azimuthalDispersion(atRadius: radius)
            #expect(azimuthal > 0 && azimuthal < sigma)
            // Pressure support makes the mean rotation lag the circular speed.
            #expect(
                equilibrium.streamingSpeed(atRadius: radius)
                    <= equilibrium.circularSpeed(atRadius: radius) + 1e-4)
        }
    }

    @Test func sampledDiskCarriesTheDispersionTheEquilibriumAsks() {
        var scene = SceneConfig.isolatedDisk(particleCount: 60_000)
        scene.solver = .barnesHut
        scene.galaxies[0].toomreQ = 1.4
        scene.galaxies[0].diskMassFraction = 0.6
        let hot = RestrictedSolver.sampleParticles(for: scene)

        scene.galaxies[0].toomreQ = 0.4
        let cold = RestrictedSolver.sampleParticles(for: scene)

        func radialDispersion(_ system: ParticleSystem) -> Float {
            var total: Float = 0
            for index in 0..<system.count {
                let p = system.positions[index]
                let radius = max(sqrt(p.x * p.x + p.y * p.y), 1e-3)
                let outward = SIMD2<Float>(p.x / radius, p.y / radius)
                let v = system.velocities[index]
                let radial = v.x * outward.x + v.y * outward.y
                total += radial * radial
            }
            return sqrt(total / Float(system.count))
        }
        #expect(radialDispersion(hot) > 2 * radialDispersion(cold))
    }

    @Test func selfGravitatingSamplingAssignsMass() {
        var scene = SceneConfig.merger(particleCount: 2_000)
        scene.solver = .barnesHut
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.mass.allSatisfy { $0 > 0 })

        let expected =
            scene.galaxies[0].potential.mass * scene.galaxies[0].diskMassFraction
        let actual = zip(particles.mass, particles.galaxyIndex)
            .filter { $0.1 == 0 }.map(\.0).reduce(0, +)
        #expect(abs(actual - expected) / expected < 1e-3)

        var restricted = scene
        restricted.solver = .restricted
        #expect(RestrictedSolver.sampleParticles(for: restricted).mass.allSatisfy { $0 == 0 })
    }

    @Test func layoutsMatchTheShader() {
        #expect(MemoryLayout<BHNode>.stride == 32)
        #expect(MemoryLayout<HaloGPU>.stride == 48)
        #expect(MemoryLayout<BHParams>.stride == 32)
    }

    @Test func allBarnesHutShadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: BarnesHutShaders.source, options: nil)
        for name in ["bhKickDrift", "bhKick", "bhAcceleration"] {
            #expect(library.makeFunction(name: name) != nil, "missing \(name)")
        }
    }
}
