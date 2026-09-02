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
        // The digit at depth 0 is the top bit of each axis, which is bit 20 of 21.
        let top: UInt32 = 1 << 20
        #expect(BarnesHutTree.octant(BarnesHutTree.morton(top, 0, top), depth: 0) == 5)
        // And the deepest digit the code can still separate is at the far end.
        #expect(BarnesHutTree.octant(BarnesHutTree.morton(1, 1, 0), depth: 20) == 6)
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

    /// A disk of stars alone can only heat: every spiral it raises stirs it further until
    /// nothing can be amplified and the arms stop coming. Dissipation stands in for the gas
    /// that keeps a real disk cool, and the thing it has to do is hold the dispersion down.
    @Test func dissipationHoldsTheDiskCool() throws {
        func dispersion(_ time: Float, dissipation: Float) throws -> Double {
            var scene = SceneConfig.isolatedDisk(particleCount: 25_000)
            scene.galaxies[0].kind = .spiral
            scene.galaxies[0].dissipationTime = dissipation
            scene.timeStepScale = 8
            scene.retune()
            let particles = RestrictedSolver.sampleParticles(for: scene)
            let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
            solver.step(
                count: Int(time / (scene.timeStep * Float(Physics.megayearsPerTimeUnit))))

            let scale = scene.galaxies[0].diskScaleLength
            let system = solver.particles
            var total = 0.0
            var counted = 0.0
            for index in 0..<system.count
            where system.component[index] == ParticleComponent.star.rawValue {
                let p = system.positions[index]
                let radius = (p.x * p.x + p.y * p.y).squareRoot()
                guard radius > scale, radius < 4 * scale else { continue }
                let outward = SIMD2<Float>(p.x / radius, p.y / radius)
                let v = system.velocities[index]
                let radial = Double(v.x * outward.x + v.y * outward.y)
                total += radial * radial
                counted += 1
            }
            return counted > 0 ? (total / counted).squareRoot() : 0
        }

        let hot = try dispersion(180, dissipation: 0)
        let cool = try dispersion(180, dissipation: 250)
        // A tenth over this stretch. The disk self-regulates rather than staying cold: the
        // cooler it is the stronger the spirals it raises, and those heat it again. What
        // dissipation buys is that the balance keeps making arms instead of settling into a
        // smooth spheroid, which is visible in a render long before it is in one number.
        #expect(cool < hot * 0.93)
        // And not cooled into fragmentation: the floor is the equilibrium dispersion, so it
        // has to stay well clear of zero.
        #expect(cool > hot * 0.2)
    }

    /// The plane the cooling pulls a disk towards has to be the plane the disk is *in*, not
    /// the one it was configured with. Rotating the particles without touching the config
    /// separates the two: `orientation` still says the disk is flat in z, and the frame has
    /// to disagree.
    @Test func theDiskFrameIsMeasuredRatherThanAssumed() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        scene.galaxies[0].spin = .retrograde
        scene.timeStepScale = 8
        scene.retune()

        let tilt: Float = 1.1
        let turn = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, cos(tilt), sin(tilt)),
            SIMD3<Float>(0, -sin(tilt), cos(tilt)))
        var particles = RestrictedSolver.sampleParticles(for: scene)
        for index in 0..<particles.count {
            particles.positions[index] = turn * particles.positions[index]
            particles.velocities[index] = turn * particles.velocities[index]
        }
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)

        // Retrograde, so the sign is being checked too: an axis that has lost the sense of
        // rotation comes back pointing the other way and would cool every star head-on.
        let natal = scene.galaxies[0].orientation * SIMD3<Float>(0, 0, 1)
        let expected = turn * natal * scene.galaxies[0].spin.sign
        #expect(simd_dot(solver.diskFrames[0].axis, expected) > cos(3 * .pi / 180))

        // And a disk left alone is neither disturbed nor written off. Both gates staying shut
        // is what keeps dissipation working at all.
        solver.step(count: 200)
        // Against its own starting order, since a disk's absolute figure depends on how thick
        // it was laid down.
        #expect(solver.diskFrames[0].coherence > solver.diskFrames[0].reference * 0.9)
        #expect(solver.diskFrames[0].disruption == 0)
    }

    /// A disk a merger has taken apart must stay taken apart.
    ///
    /// It did not. The cooling pulled disk stars towards a circular orbit about the axis the
    /// galaxy was *configured* with, which is a spring back to the natal plane and the one
    /// thing a collisionless system cannot do. On a three-galaxy run the steeply inclined disk
    /// heated from 0.24 kpc thick to 11.7 through the encounter and was back to 1.04 four
    /// hundred megayears later, still in the plane it was born in and eighty-three degrees
    /// from the remnant it should have joined: a cold disk inside an elliptical, refusing to
    /// mix.
    ///
    /// The primary is what this watches, because it is the cleanest statement of the fault.
    /// A galaxy of a third its mass plunges through it, and its disk has to be left thicker
    /// for it. With the cooling ungated it was not: on this scene, 0.62 kpc thick before the
    /// encounter, 0.81 at its worst and back to 0.69 at the end — held near its birth
    /// thickness right through a merger. It now reaches 1.13 and finishes at 1.12.
    @Test func aMergerLeavesTheDisksHeated() throws {
        let scene = SceneConfig(
            name: "Inclined minor merger",
            galaxies: [
                GalaxyConfig(
                    name: "Primary",
                    particleCount: 18_000,
                    potential: GalaxyPotential(profile: .hernquist, mass: 175, scaleRadius: 15),
                    diskScaleLength: 12,
                    diskTruncation: 5,
                    diskThickness: 0.68,
                    position: SIMD3<Float>(-22.4, 0, 0),
                    velocity: SIMD3<Float>(0.2988, -0.112, 0)),
                GalaxyConfig(
                    name: "Secondary",
                    particleCount: 9_000,
                    kind: .disk,
                    potential: GalaxyPotential(profile: .hernquist, mass: 58, scaleRadius: 11),
                    diskScaleLength: 8.66,
                    diskTruncation: 5,
                    diskThickness: 0.29,
                    position: SIMD3<Float>(67.6, 0, 0),
                    velocity: SIMD3<Float>(-0.9013, 0.338, 0),
                    // Steeply inclined, which is the geometry that made the fault obvious:
                    // the disk came back to a plane at right angles to everything else.
                    inclination: 1.32,
                    positionAngle: 1.66),
            ],
            solver: .barnesHut,
            seed: 156_567)
        var tuned = scene
        tuned.timeStepScale = 8
        tuned.retune()

        let particles = RestrictedSolver.sampleParticles(for: tuned)
        let solver = try MetalBarnesHutSolver(scene: tuned, particles: particles)

        /// RMS height of the primary's disk stars above its own plane, which is z: it starts
        /// flat and stays where it is, so this needs no axis of its own.
        func thickness() -> Float {
            let system = solver.particles
            let centre = solver.centers[0]
            var total: Float = 0
            var counted: Float = 0
            for index in 0..<system.count
            where system.galaxyIndex[index] == 0
                && system.component[index] == ParticleComponent.star.rawValue
            {
                let height = system.positions[index].z - centre.z
                total += height * height
                counted += 1
            }
            return counted > 0 ? (total / counted).squareRoot() : 0
        }

        let myrPerStep = tuned.timeStep * Float(Physics.megayearsPerTimeUnit)
        let leg = max(Int(40 / myrPerStep), 1)
        let cold = thickness()
        var hottest = cold
        for _ in 0..<14 {
            solver.step(count: leg)
            hottest = max(hottest, thickness())
        }
        let final = thickness()

        // Heated, and left heated. The ungated cooling gave 1.18 and 0.86 of these.
        #expect(final > cold * 1.5)
        #expect(final > hottest * 0.93)
        // Because the companion's disk was written off rather than rebuilt.
        #expect(solver.diskFrames[1].disruption > 0.9)
    }

    /// The force pass is dispatched in pieces so a very large scene does not hold the GPU
    /// for the length of one kernel. Every piece has to know where it starts: without that
    /// the second piece recomputes the first one's particles and leaves the rest of the scene
    /// carrying whatever was in the acceleration buffer, which no test at one chunk can see.
    @Test func splittingTheForcePassChangesNothing() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 8_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let whole = MetalBarnesHutSolver.forceChunk
        defer { MetalBarnesHutSolver.forceChunk = whole }

        MetalBarnesHutSolver.forceChunk = 1_000_000
        let single = try MetalBarnesHutSolver(scene: scene, particles: particles)
        single.step(count: 1)
        let reference = single.accelerations

        MetalBarnesHutSolver.forceChunk = 700
        let split = try MetalBarnesHutSolver(scene: scene, particles: particles)
        split.step(count: 1)
        let pieces = split.accelerations

        #expect(reference.count == pieces.count)
        var worst: Float = 0
        for index in reference.indices {
            worst = max(worst, simd_length(reference[index] - pieces[index]))
        }
        #expect(worst == 0)
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
    ///
    /// Over three realisations, because one is not a measurement here. The rigid halo's leak
    /// depends on the details of the encounter and swings by a factor of four between seeds,
    /// so the ratio of a single pair runs anywhere from 0.05 to 0.32 — and this test used to
    /// assert it was under 0.25, which it was, on the one seed it happened to be written for.
    /// The first unrelated change to touch the sampler's random stream moved that draw and the
    /// check failed with nothing wrong. Summed over three, the ratio sits near 0.15.
    @Test func liveHalosConserveMomentumFarBetterThanARigidOne() throws {
        func drift(ratio: Float, seed: UInt64) throws -> Float {
            var scene = SceneConfig.merger(particleCount: 12_000, seed: seed)
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
        var live: Float = 0
        var rigid: Float = 0
        for seed in UInt64(1)...3 {
            live += try drift(ratio: 2, seed: seed)
            rigid += try drift(ratio: 0, seed: seed)
        }
        #expect(live < rigid / 4)
    }

    /// Gas turns into stars, and a particle's formation time is written once and never again.
    ///
    /// That invariant is what a take leans on. Positions are recorded every frame but the
    /// formation times are stored once, so replaying at any moment can only show the right
    /// knots if the array is a history rather than a state: written the moment a particle
    /// forms and untouched afterwards.
    @Test func gasFormsStarsExactlyOnce() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 30_000)
        scene.galaxies[0].kind = .spiral
        scene.timeStepScale = 8
        scene.retune()
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: sampled)

        func formed(_ system: ParticleSystem) -> Int {
            (0..<system.count).count { system.formation[$0] > -1e8 && system.formation[$0] < 1e8 }
        }
        // Every star carries a real age now, and the light per unit mass follows from it.
        // Dark matter never does, and gas has made nothing yet.
        let myrPer = Float(Physics.megayearsPerTimeUnit)
        var oldest: Float = 0
        for index in 0..<sampled.count {
            let born = sampled.formation[index]
            let stamped = born > -1e8 && born < 1e8
            switch sampled.component[index] {
            case ParticleComponent.star.rawValue, ParticleComponent.bulge.rawValue:
                #expect(stamped)
                // Nothing in the initial conditions is younger than the floor: material that
                // young is the run's own doing, and is meant to stand out against this.
                #expect(-born * myrPer >= StarFormation.youngestSampledMyr - 1)
                oldest = max(oldest, -born * myrPer)
            case ParticleComponent.halo.rawValue:
                #expect(!stamped)
            case ParticleComponent.dust.rawValue:
                #expect(born > 1e8)
            default:
                break
            }
        }
        // And the spread reaches back to a bulge's age, or there is no mass-to-light contrast
        // to speak of.
        #expect(oldest > 9_000)

        let first = solver.particles
        solver.step(count: 120)
        let second = solver.particles
        solver.step(count: 120)
        let third = solver.particles

        // Something formed, and it kept forming.
        #expect(formed(second) > formed(first))
        #expect(formed(third) > formed(second))

        // And nothing already stamped ever moved. A rewritten time would make a take replay a
        // knot that lights up, goes out and lights up again somewhere else.
        for index in 0..<second.count where second.formation[index] < 1e8 {
            #expect(third.formation[index] == second.formation[index])
        }
        // Gas is spent, not recycled: what formed is gone from the reservoir for good.
        for index in 0..<second.count where second.formation[index] > 1e8 {
            #expect(third.formation[index] >= second.formation[index] || third.formation[index] < 1e8)
        }
    }

    /// New stars arrive in places, not everywhere at once.
    ///
    /// This is the difference between a galaxy with star-forming regions in it and a galaxy
    /// that is faintly pink all over, and nothing else in the suite would catch losing it: the
    /// counts, the rate and the depletion time are identical either way. They were identical,
    /// in fact, while two knots in a thousand had so much as one lit neighbour.
    @Test func newStarsArriveInPlacesRatherThanEverywhere() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 120_000)
        scene.galaxies[0].kind = .spiral
        scene.timeStepScale = 4
        scene.retune()
        let solver = try MetalBarnesHutSolver(
            scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))

        /// Share of the lit knots that have at least three other lit knots within 200 pc.
        func grouped() -> Float {
            let system = solver.particles
            let now = solver.time
            var lit: [SIMD3<Float>] = []
            for index in 0..<system.count {
                let born = system.formation[index]
                guard born > -1e8, born < 1e8 else { continue }
                let age = (now - born) * Float(Physics.megayearsPerTimeUnit)
                if age >= 0, age < StarFormation.ionisedMyr { lit.append(system.positions[index]) }
            }
            guard !lit.isEmpty else { return 0 }
            let cell: Float = 0.2
            func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
                SIMD3<Int32>(
                    Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                    Int32((p.z / cell).rounded(.down)))
            }
            var grid: [SIMD3<Int32>: [Int]] = [:]
            for (index, point) in lit.enumerated() { grid[key(point), default: []].append(index) }
            var close = 0
            for (index, point) in lit.enumerated() {
                var near = 0
                let base = key(point)
                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            let cellKey = base &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                            for other in grid[cellKey] ?? [] where other != index {
                                if simd_distance(lit[other], point) < cell { near += 1 }
                            }
                        }
                    }
                }
                if near >= 3 { close += 1 }
            }
            return Float(close) / Float(lit.count)
        }

        // The galaxy is born with regions, rather than with knots sprinkled over it. Measured
        // at a quarter of a million particles: two per thousand when the seeded ages were
        // drawn per particle, two fifths once they are drawn per nursery. At the hundred and
        // twenty thousand used here, 0.33 and 0.36. The bar is set two orders of magnitude
        // above what a regression looks like and well below what passing looks like, because
        // the quantity itself moves several points from one realisation to the next.
        #expect(grouped() > 0.20)
        // And the ones the run makes for itself are grouped too, which is the zone rule in the
        // formation kernel rather than anything the sampler did.
        solver.step(count: 400)
        #expect(grouped() > 0.20)
    }

    /// Nothing the sampler places may be young enough to be ionised.
    ///
    /// The two numbers are independent constants that have to stay in this order, and there is
    /// no way to see from either one that the other exists. Raising the window past the floor
    /// once put sixty-six thousand particles inside it, carrying seven tenths of the light: the
    /// disk itself glowed, evenly, and no other check in the suite moved at all.
    @Test func onlyWhatAGalaxyMadeRecentlyIsLit() {
        #expect(StarFormation.ionisedMyr < StarFormation.youngestSampledMyr)

        var scene = SceneConfig.isolatedDisk(particleCount: 40_000)
        scene.galaxies[0].kind = .spiral
        scene.retune()
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let myrPer = Float(Physics.megayearsPerTimeUnit)
        var litStars = 0
        for index in 0..<sampled.count
        where sampled.component[index] == ParticleComponent.star.rawValue {
            if -sampled.formation[index] * myrPer < StarFormation.ionisedMyr { litStars += 1 }
        }
        #expect(litStars == 0)
    }

    /// The thing an encounter is watched for: a burst, in the places the physics puts it.
    ///
    /// Density alone does not give one, and that is why the compression term exists. Star
    /// formation eats the densest gas first, so a merger driven by density arrives at its
    /// pericentre with the nucleus already spent and the rate only ever falling — measured,
    /// forty knots a megayear at the start and nine at coalescence, with nothing in between.
    @Test func anEncounterBurstsAndAQuietDiskDoesNot() throws {
        /// Knots formed in each of six equal windows. A rate, not a total: a merger's total is
        /// dominated by the long quiescent approach either way, and comparing halves of a run
        /// says nothing — measured, the two halves of a merger came out within one per cent of
        /// each other while the rate inside them varied threefold.
        func perWindow(merging: Bool, over megayears: Float) throws -> [Int] {
            var scene =
                merging
                ? SceneConfig.merger(particleCount: 60_000)
                : SceneConfig.isolatedDisk(particleCount: 60_000)
            scene.timeStepScale = 8
            scene.retune()
            let solver = try MetalBarnesHutSolver(
                scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))
            let perStep = scene.timeStep * Float(Physics.megayearsPerTimeUnit)
            func counted() -> Int {
                let system = solver.particles
                return (0..<system.count).count {
                    system.formation[$0] > -1e8 && system.formation[$0] < 1e8
                }
            }
            let windows = 6
            let steps = max(Int(megayears / Float(windows) / perStep), 1)
            var counts: [Int] = []
            var previous = counted()
            for _ in 0..<windows {
                solver.step(count: steps)
                let now = counted()
                counts.append(now - previous)
                previous = now
            }
            return counts
        }

        /// How far the rate ever rises above where it started. Monotonicity is too strong a
        /// thing to ask of a self-gravitating disk — its arms come and go and the rate breathes
        /// with them — so what separates the two cases is the size of the excursion, not its
        /// sign. Measured at sixty thousand particles: 330, 355, 366, 351, 271, 266 for a disk
        /// left alone, and 213, 261, 544, 210, 437, 739 for an encounter, whose third window
        /// holds pericentre and whose last holds coalescence. At double the particles, 1.0 and
        /// 3.0. Anything between one and a half and two and a half separates them.
        func excursion(_ counts: [Int]) -> Float {
            Float(counts.max() ?? 0) / Float(max(counts.first ?? 1, 1))
        }

        #expect(excursion(try perWindow(merging: false, over: 450)) < 1.5)
        #expect(excursion(try perWindow(merging: true, over: 450)) > 2.5)
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
