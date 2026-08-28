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
        // The bulge is held up by the Jeans equation rather than by Q, so leaving it in would
        // only dilute the one thing this measures.
        scene.galaxies[0].bulgeFraction = 0
        let hot = RestrictedSolver.sampleParticles(for: scene)

        scene.galaxies[0].toomreQ = 0.4
        let cold = RestrictedSolver.sampleParticles(for: scene)

        func radialDispersion(_ system: ParticleSystem) -> Float {
            var total: Float = 0
            var samples = 0
            for index in 0..<system.count
            where system.component[index] != ParticleComponent.halo.rawValue {
                let p = system.positions[index]
                let radius = max(sqrt(p.x * p.x + p.y * p.y), 1e-3)
                let outward = SIMD2<Float>(p.x / radius, p.y / radius)
                let v = system.velocities[index]
                let radial = v.x * outward.x + v.y * outward.y
                total += radial * radial
                samples += 1
            }
            return sqrt(total / Float(max(samples, 1)))
        }
        #expect(radialDispersion(hot) > 2 * radialDispersion(cold))
    }

    /// The disk has to hold its own radius once its gravity is switched on. It did not: the
    /// sampler took its rotation curve from the analytic potential the galaxy was defined by,
    /// while laying the mass down as a flattened disk, a bulge and a truncated halo, none of
    /// which pull like that sphere. The disk came out turning at four fifths of what the real
    /// field asks, fell inward and heated, and spread its mean radius by 23 % in 40 Myr.
    ///
    /// Cheap enough to keep in the suite because the step multiplier buys the physical time
    /// without the steps; the drift is the same at eight times the tuned step.
    @Test func aSelfGravitatingDiskHoldsItsRadius() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 40_000)
        scene.timeStepScale = 8
        scene.retune()
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)

        func meanRadius() -> Double {
            let system = solver.particles
            var total = 0.0
            var counted = 0
            for index in 0..<system.count
            where system.component[index] != ParticleComponent.halo.rawValue {
                total += Double(simd_length(system.positions[index]))
                counted += 1
            }
            return total / Double(max(counted, 1))
        }

        let before = meanRadius()
        let megayears: Float = 40
        solver.step(count: Int(megayears / (scene.timeStep * Float(Physics.megayearsPerTimeUnit))))
        #expect(abs(meanRadius() - before) / before < 0.04)
    }

    /// The rotation curve has to describe the mass the sampler lays down, not the sphere the
    /// galaxy was written as. Freeman's disk is the piece that was missing.
    @Test func theRotationCurveCountsTheDiskItselfNotJustTheSphere() {
        var galaxy = SceneConfig.isolatedDisk(particleCount: 10_000).galaxies[0]
        galaxy.bulgeFraction = 0
        let live = DiskEquilibrium(config: galaxy, selfGravitating: true)
        let tracer = DiskEquilibrium(config: galaxy, selfGravitating: false)
        for radius in [Float(3), 6, 10] {
            // The disk and the truncated halo both pull harder in the plane than the sphere.
            #expect(live.circularSpeed(atRadius: radius) > tracer.circularSpeed(atRadius: radius))
        }

        // Freeman's curve for a disk on its own peaks near 2.15 scale lengths, which is what
        // separates a real disk term from any monotonic stand-in for one.
        func diskSpeed(_ radius: Float) -> Float {
            DiskEquilibrium.exponentialDiskSpeedSquared(mass: 10, scaleLength: 4, radius: radius)
        }
        let peak = stride(from: Float(0.4), through: 30, by: 0.05).max { diskSpeed($0) < diskSpeed($1) }
        #expect(abs((peak ?? 0) / 4 - 2.15) < 0.1)
    }

    @Test func selfGravitatingSamplingAssignsMass() {
        var scene = SceneConfig.merger(particleCount: 2_000)
        scene.solver = .barnesHut
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.mass.allSatisfy { $0 > 0 })

        // The disk carries its share and the live halo carries the rest, so a galaxy's
        // particles must add up to the mass its potential claims.
        let galaxy = scene.galaxies[0]
        func mass(of kind: ParticleComponent?) -> Float {
            var total: Float = 0
            for index in 0..<particles.count where particles.galaxyIndex[index] == 0 {
                if let kind, particles.component[index] != kind.rawValue { continue }
                if kind == nil, particles.component[index] == ParticleComponent.halo.rawValue {
                    continue
                }
                total += particles.mass[index]
            }
            return total
        }
        let disk = mass(of: nil)
        let halo = mass(of: .halo)
        #expect(abs(disk - galaxy.potential.mass * galaxy.diskMassFraction) / disk < 1e-3)
        #expect(
            abs(halo - galaxy.potential.mass * (1 - galaxy.diskMassFraction)) / halo < 1e-3)
        #expect(abs(disk + halo - galaxy.potential.mass) / galaxy.potential.mass < 1e-3)
        #expect(particles.count > scene.totalParticleCount)

        var restricted = scene
        restricted.solver = .restricted
        #expect(RestrictedSolver.sampleParticles(for: restricted).mass.allSatisfy { $0 == 0 })
    }

    /// A rigid halo carries mass but no inertia, so it cannot take momentum from the system:
    /// following its galaxy's centre of mass makes it do work. This is the guard against that
    /// regression. Whether the orbit actually decays takes hundreds of megayears to show and
    /// is measured separately; the numbers are in the README.
    @Test func liveHalosConserveMomentumFarBetterThanARigidOne() throws {
        func drift(ratio: Float) throws -> Float {
            var scene = SceneConfig.merger(particleCount: 12_000)
            scene.solver = .barnesHut
            scene.timeStep = 0.01
            scene.softening = 0.3
            for index in scene.galaxies.indices {
                scene.galaxies[index].haloParticleRatio = ratio
            }
            let solver = try MetalBarnesHutSolver(scene: scene)
            let before = solver.momentum()
            solver.step(count: 500)
            return simd_length(solver.momentum() - before)
        }
        #expect(try drift(ratio: 2) < drift(ratio: 0) / 4)
    }

    @Test func haloParticlesAreSampledAndCarryNoLight() {
        var scene = SceneConfig.merger(particleCount: 5_000)
        scene.solver = .barnesHut
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.count == scene.simulatedParticleCount)
        #expect(particles.count > scene.totalParticleCount)

        var halos = 0
        for index in 0..<particles.count
        where particles.component[index] == ParticleComponent.halo.rawValue {
            halos += 1
            #expect(particles.luminosity[index] == 0)
            #expect(particles.mass[index] > 0)
        }
        #expect(halos == scene.galaxies.reduce(0) { $0 + $1.haloParticleCount })
        #expect(!ParticleComponent.halo.isVisible)

        // Level 1 has no live halo: its tracers are massless in a rigid potential.
        var restricted = scene
        restricted.solver = .restricted
        let tracers = RestrictedSolver.sampleParticles(for: restricted)
        #expect(tracers.count == restricted.totalParticleCount)
    }

    @Test func nodeStaysSmall() {
        // Thirty-two bytes rather than forty-eight: the node array is the hottest thing the
        // force kernel reads, so its size is its speed.
        #expect(MemoryLayout<BHNode>.stride == 32)
    }

    @Test func allBarnesHutShadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: BarnesHutShaders.source, options: nil)
        for name in ["bhKickDrift", "bhKick", "bhAcceleration"] {
            #expect(library.makeFunction(name: name) != nil, "missing \(name)")
        }
    }
}
