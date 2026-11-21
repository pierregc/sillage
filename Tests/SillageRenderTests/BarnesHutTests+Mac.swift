import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

extension BarnesHutTests {
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

    /// What the quadrupole is for: at the same opening angle, a fraction of the monopole's error.
    @Test func theQuadrupoleCutsTheErrorAtTheSameAngle() throws {
        let count = 3_000
        let (positions, mass) = cluster(count: count, seed: 5)
        var particles = ParticleSystem(capacity: count)
        for index in 0..<count {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1,
                mass: mass[index])
        }
        let scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: count,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, openingAngle: 0.7, softening: 0.25)
        func meanError(quadrupole: Bool) throws -> Float {
            let solver = try MetalBarnesHutSolver(
                scene: scene, particles: particles, quadrupole: quadrupole)
            let computed = solver.accelerations
            var total: Float = 0
            var samples = 0
            for index in stride(from: 0, to: count, by: 29) {
                let reference = BarnesHutTree.directAcceleration(
                    at: positions[index], positions: positions, mass: mass, softening: 0.25,
                    skipping: index)
                total += simd_length(computed[index] - reference) / max(simd_length(reference), 1e-6)
                samples += 1
            }
            return total / Float(samples)
        }
        #expect(try meanError(quadrupole: true) < meanError(quadrupole: false) / 2)
    }

    /// A black hole pulls outside the tree, at its own softening, and takes the exact
    /// reaction: inside a cluster or beside it, its pull and the cluster's on it match direct
    /// summation, and the total force on everything is nothing.
    @Test(arguments: [SIMD3<Float>(0.3, -0.2, 0.1), SIMD3<Float>(9, 2, -1)])
    func aBlackHolePullsDirectlyAndTakesTheReaction(at place: SIMD3<Float>) throws {
        let count = 3_000
        let (positions, mass) = cluster(count: count, seed: 9)
        let holeMass: Float = 3
        let holeSoftening: Float = 0.6
        var particles = ParticleSystem(capacity: count + 1)
        for index in 0..<count {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1,
                mass: mass[index])
        }
        particles.append(
            position: place, velocity: .zero, galaxy: 1, radius: 0, component: .hole,
            mass: holeMass)
        var hole = GalaxyConfig.blackHole(mass: holeMass, softening: holeSoftening)
        hole.position = place
        let scene = SceneConfig(
            name: "cluster and hole",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: count,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1, haloParticleRatio: 0),
                hole,
            ],
            solver: .barnesHut, openingAngle: 0.5, softening: 0.25)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
        let computed = solver.accelerations
        let all = positions + [place]
        let masses = mass + [holeMass]
        func direct(_ index: Int) -> SIMD3<Float> {
            var total = SIMD3<Float>.zero
            for other in all.indices where other != index {
                let soft = index == count || other == count ? holeSoftening : 0.25
                let offset = all[other] - all[index]
                let r2 = simd_length_squared(offset) + soft * soft
                total += offset * (masses[other] / (r2 * r2.squareRoot()))
            }
            return total
        }
        let onHole = direct(count)
        #expect(simd_length(computed[count] - onHole) / simd_length(onHole) < 1e-4)
        var worst: Float = 0
        for index in stride(from: 0, to: count, by: 17) {
            let reference = direct(index)
            worst = max(worst, simd_length(computed[index] - reference) / simd_length(reference))
        }
        #expect(worst < 0.05)
        var net = SIMD3<Float>.zero
        var scale: Float = 0
        for index in all.indices {
            net += computed[index] * masses[index]
            scale += simd_length(computed[index]) * masses[index]
        }
        #expect(simd_length(net) / scale < 0.01)
    }

    /// What the default angle is chosen on. With the quadrupole, momentum no longer tracks the
    /// force error, and the orbit does: a merger's separation through its second approach stays
    /// closer to a run at 0.5 than the monopole's at 0.7. Measured from 12 000 to 200 000
    /// visible particles, the default sits at 0.2 to 0.7 of the monopole's deviation; summed
    /// here over three seeds, near 0.45.
    @Test func theQuadrupoleKeepsAMergersOrbit() throws {
        func separations(seed: UInt64, angle: Float?, quadrupole: Bool) throws -> [Float] {
            var scene = SceneConfig.merger(particleCount: 12_000, seed: seed)
            scene.solver = .barnesHut
            scene.timeStepScale = 8
            scene.retune()
            if let angle { scene.openingAngle = angle }
            let solver = try MetalBarnesHutSolver(
                scene: scene, particles: RestrictedSolver.sampleParticles(for: scene),
                quadrupole: quadrupole)
            let every = max(Int(25 / (scene.timeStep * Float(Physics.megayearsPerTimeUnit))), 1)
            return try (0..<14).map { _ in
                solver.step(count: every)
                let centres = solver.centers
                return simd_distance(try #require(centres.first), try #require(centres.last))
            }
        }
        func deviation(_ run: [Float], from reference: [Float]) -> Float {
            zip(run, reference).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        }
        var current: Float = 0
        var monopole: Float = 0
        for seed in UInt64(1)...3 {
            let reference = try separations(seed: seed, angle: 0.5, quadrupole: true)
            current += deviation(
                try separations(seed: seed, angle: nil, quadrupole: true), from: reference)
            monopole += deviation(
                try separations(seed: seed, angle: 0.7, quadrupole: false), from: reference)
        }
        #expect(current.squareRoot() < 0.8 * monopole.squareRoot())
    }

    /// A light cluster far out on a diagonal from a heavy one sits in the corner of the root
    /// opposite the mass, farther from the root's centre of mass than the angle asks, and its
    /// particles took the whole root as one point: none of their own cluster's pull (#221).
    /// Tracers took it too, having no guard at all.
    @Test func aLightClusterFarOnADiagonalKeepsItsOwnPull() throws {
        var generator = SeededGenerator(seed: 21)
        func blob(_ centre: SIMD3<Float>, _ spread: Float) -> SIMD3<Float> {
            centre + SIMD3<Float>(generator.normal(), generator.normal(), generator.normal()) * spread
        }
        let far = SIMD3<Float>(repeating: 120)
        var particles = ParticleSystem(capacity: 5_500)
        // Tracers first, in the light cluster.
        for _ in 0..<500 {
            particles.append(position: blob(far, 1.5), velocity: .zero, galaxy: 1, radius: 1, mass: 0)
        }
        for _ in 0..<4_000 {
            particles.append(position: blob(.zero, 3), velocity: .zero, galaxy: 0, radius: 1, mass: 0.0025)
        }
        for _ in 0..<1_000 {
            particles.append(position: blob(far, 1.5), velocity: .zero, galaxy: 1, radius: 1, mass: 0.0005)
        }
        particles.setVisibleCount(particles.count)
        func galaxy(_ name: String, _ count: Int, _ mass: Float) -> GalaxyConfig {
            GalaxyConfig(
                name: name, particleCount: count,
                potential: GalaxyPotential(profile: .plummer, mass: mass, scaleRadius: 3),
                diskScaleLength: 3, diskMassFraction: 1)
        }
        let scene = SceneConfig(
            name: "far pair", galaxies: [galaxy("heavy", 4_000, 10), galaxy("light", 1_500, 0.5)],
            solver: .barnesHut, openingAngle: 0.9, softening: 0.1)
        let massive = Array(particles.positions[500...])
        let mass = Array(particles.mass[500...])

        func meanErrors(opensHoldingCells: Bool) throws -> (light: Float, tracers: Float) {
            let solver = try MetalBarnesHutSolver(
                scene: scene, particles: particles, tracers: 500, opensHoldingCells: opensHoldingCells)
            let computed = solver.accelerations
            func error(_ index: Int) -> Float {
                let reference = BarnesHutTree.directAcceleration(
                    at: particles.positions[index], positions: massive, mass: mass, softening: 0.1,
                    skipping: index - 500)
                return simd_length(computed[index] - reference) / simd_length(reference)
            }
            let light = stride(from: 4_500, to: 5_500, by: 7).map(error)
            let tracers = stride(from: 0, to: 500, by: 7).map(error)
            return (
                light.reduce(0, +) / Float(light.count), tracers.reduce(0, +) / Float(tracers.count)
            )
        }
        let before = try meanErrors(opensHoldingCells: false)
        #expect(before.light > 0.9 && before.tracers > 0.9, "otherwise this tests nothing")
        // The usual error at this angle, as `accelerationMatchesDirectSummation` bounds it.
        let after = try meanErrors(opensHoldingCells: true)
        #expect(after.light < 0.02)
        #expect(after.tracers < 0.02)
    }

    /// Where no cell around a particle was ever taken whole, nothing changes, to the bit: the
    /// test is a branch away from the arithmetic, and fast math moves nothing.
    @Test func aWalkThatNeverTookACellAroundAParticleIsUnchanged() throws {
        let count = 3_000
        let (positions, mass) = cluster(count: count)
        var particles = ParticleSystem(capacity: count)
        for index in 0..<count {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1, mass: mass[index])
        }
        let scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: count,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, openingAngle: 0.9, softening: 0.25)
        let current = try MetalBarnesHutSolver(scene: scene, particles: particles).accelerations
        let before = try MetalBarnesHutSolver(
            scene: scene, particles: particles, opensHoldingCells: false
        ).accelerations
        #expect(current.count == count)
        #expect(
            zip(current, before).allSatisfy { a, b in
                (0..<3).allSatisfy { a[$0].bitPattern == b[$0].bitPattern }
            })
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

    /// A command buffer the GPU loses stops the run where it is and surfaces (#301): no step
    /// after it runs or counts its time, and no checkpoint is written of what it left.
    @Test func aCommandBufferTheGPULosesStopsTheRunAndSurfaces() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 2_000)
        let solver = try MetalBarnesHutSolver(
            scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))
        try solver.advance(steps: 2)
        let (time, positions) = (solver.time, solver.particles.positions)
        solver.failsNextCommandBuffer = RenderError.commandBuffer("a pass lost on purpose")
        solver.step(count: 3)
        #expect(solver.failure != nil)
        #expect(solver.time == time)
        #expect(solver.particles.positions == positions)
        #expect(throws: RenderError.self) { try solver.advance(steps: 1) }
        #expect(throws: RenderError.self) { try solver.drawnDrift(by: 0.5) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-solver-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        #expect(throws: RenderError.self) { try solver.writeParticles(to: handle) }
        try handle.close()
        #expect(try Data(contentsOf: file).isEmpty)
    }

    /// A bulge is flattened because it rotates, and it has to still be flattened later.
    ///
    /// Sampled flattened with nothing but random motion holding it up, it rounded off: the
    /// vertical spread more than doubled over five hundred megayears, which on screen is a
    /// core slowly inflating. Forty is enough to catch it, because the failure is fastest at
    /// the start — the old sampling put on twenty-five per cent inside the first thirty.
    @Test func theBulgeKeepsItsShape() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 60_000)
        scene.timeStepScale = 8
        scene.retune()
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
        let bulge = (0..<particles.count).filter {
            particles.component[$0] == ParticleComponent.bulge.rawValue
        }
        try #require(!bulge.isEmpty)

        func spread() -> Double {
            let positions = solver.particles.positions
            var total = 0.0
            for index in bulge { total += Double(positions[index].z * positions[index].z) }
            return (total / Double(bulge.count)).squareRoot()
        }

        let before = spread()
        let megayears: Float = 40
        solver.step(count: Int(megayears / (scene.timeStep * Float(Physics.megayearsPerTimeUnit))))
        #expect(spread() / before < 1.12)
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
        #expect(solver.diskFrames[0].layered > 0.9)
        #expect(solver.diskFrames[0].torn == 0)
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
        #expect(solver.diskFrames[1].torn > 0.9)
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

    /// Summed in blocks on every core, and in double precision because the float running sum
    /// it replaced was 23 pc off here. Enough particles for several blocks, and two galaxies
    /// so a block writing into the other one's slot would show. The centre is the nucleus:
    /// the disk material and the bulge inside one and a half scale lengths of where the
    /// galaxy was, not the centre of mass of everything visible (#167).
    @Test func haloCentresSummedInBlocksAreTheCentresOfMass() throws {
        var scene = SceneConfig.merger(particleCount: 120_000)
        scene.solver = .barnesHut
        for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.count > 3 * 65_536, "otherwise there is a single block")
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
        let positions = solver.particles.positions

        var weighted = [SIMD3<Double>](repeating: .zero, count: scene.galaxies.count)
        var totals = [Double](repeating: 0, count: scene.galaxies.count)
        let outside = [ParticleComponent.halo.rawValue, ParticleComponent.outskirt.rawValue]
        for index in particles.positions.indices where !outside.contains(particles.component[index]) {
            let galaxy = Int(particles.galaxyIndex[index])
            let home = scene.galaxies[galaxy]
            let reach = home.diskScaleLength * 1.5
            guard simd_length_squared(positions[index] - home.position) < reach * reach else { continue }
            let m = Double(max(particles.mass[index], 1e-20))
            weighted[galaxy] += SIMD3<Double>(positions[index]) * m
            totals[galaxy] += m
        }
        let centers = solver.centers
        for galaxy in scene.galaxies.indices {
            let expected = weighted[galaxy] / totals[galaxy]
            #expect(simd_distance(SIMD3<Double>(centers[galaxy]), expected) < 1e-4)
        }
    }

    /// A rigid analytic halo stays on the centre of mass of its galaxy's visible particles,
    /// whatever the nucleus the camera follows: on the nucleus it pulls on its own lopsided
    /// stars with nothing pulling back, and the galaxy pushes itself along.
    @Test func aRigidHaloSitsOnTheCentreOfMass() throws {
        var scene = SceneConfig.merger(particleCount: 120_000)
        scene.solver = .barnesHut
        for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 0 }
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)
        solver.step(count: 2)
        let system = solver.particles
        var weighted = [SIMD3<Double>](repeating: .zero, count: scene.galaxies.count)
        var totals = [Double](repeating: 0, count: scene.galaxies.count)
        for index in system.positions.indices
        where system.component[index] != ParticleComponent.halo.rawValue {
            let galaxy = Int(system.galaxyIndex[index])
            let m = Double(max(system.mass[index], 1e-20))
            weighted[galaxy] += SIMD3<Double>(system.positions[index]) * m
            totals[galaxy] += m
        }
        for galaxy in scene.galaxies.indices {
            let expected = weighted[galaxy] / totals[galaxy]
            // Taken at the last tree build, one drift before the positions read here.
            #expect(simd_distance(SIMD3<Double>(solver.massCenters[galaxy]), expected) < 0.05)
        }
    }

    /// A rigid halo carries mass but no inertia, so it cannot take momentum from the system:
    /// following its galaxy's centre of mass makes it do work. This is the guard against that
    /// regression. Whether the orbit actually decays takes hundreds of megayears to show and
    /// is measured separately; the numbers are in docs/reference.md.
    ///
    /// Over three realisations, because one is not a measurement here. The rigid halo's leak
    /// depends on the details of the encounter and swings by a factor of four between seeds,
    /// so the ratio of a single pair runs anywhere from 0.05 to 0.32 — and this test used to
    /// assert it was under 0.25, which it was, on the one seed it happened to be written for.
    /// The first unrelated change to touch the sampler's random stream moved that draw and the
    /// check failed with nothing wrong. Summed over three, the ratio sits near 0.15.
    ///
    /// Measured with the monopole at 0.7, where the tree's own drift is a tenth of the leak.
    /// At the default 0.9 with the quadrupole it is two thirds of it (#37), which would hide
    /// the halo this is about; `theQuadrupoleKeepsAMergersOrbit` guards the default instead.
    @Test func liveHalosConserveMomentumFarBetterThanARigidOne() throws {
        func drift(ratio: Float, seed: UInt64) throws -> Float {
            var scene = SceneConfig.merger(particleCount: 12_000, seed: seed)
            scene.solver = .barnesHut
            scene.timeStep = 0.01
            scene.softening = 0.3
            scene.openingAngle = 0.7
            for index in scene.galaxies.indices {
                scene.galaxies[index].haloParticleRatio = ratio
            }
            let solver = try MetalBarnesHutSolver(
                scene: scene, particles: RestrictedSolver.sampleParticles(for: scene),
                quadrupole: false)
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

    /// A frame counts every star its own steps lit, however many steps it holds (#306). Counted
    /// from just after the frame's start, the first step's never showed: the curves had a third
    /// fewer stars at twice the step, and none at one step a frame.
    @Test func aFrameCountsEveryStarItsStepsLit() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 30_000)
        scene.galaxies[0].kind = .spiral
        scene.timeStepScale = 8
        scene.retune()
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        for stepsPerFrame in [1, 3] {
            let solver = try MetalBarnesHutSolver(scene: scene, particles: sampled)
            var previous = solver.time
            var counted = 0
            for _ in 0..<(120 / stepsPerFrame) {
                solver.step(count: stepsPerFrame)
                counted += solver.formed(since: previous, before: solver.time)
                previous = solver.time
            }
            let lit = solver.particles.formation.count { $0 >= 0 && $0 < 1e8 }
            #expect(lit > 0)
            #expect(counted == lit)
        }
    }

    /// What `--sf-leaves` reads off the tree is what the pass forms from (#306): the gas the
    /// leaves hold falls by exactly the stars formed, and the rate they give is the rate seen.
    @Test func theLeavesGiveTheRateThatForms() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 30_000)
        scene.galaxies[0].kind = .spiral
        scene.timeStepScale = 8
        scene.retune()
        let solver = try MetalBarnesHutSolver(
            scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))
        let gas = solver.formationLeaves().gas
        var expected = 0.0
        for _ in 0..<240 {
            expected += solver.formationLeaves().drawnRate * Double(scene.timeStep)
            solver.step()
        }
        let lit = solver.particles.formation.count { $0 >= 0 && $0 < 1e8 }
        #expect(gas - solver.formationLeaves().gas == lit)
        #expect(expected > 20)
        #expect(abs(Double(lit) - expected) < 4 * expected.squareRoot())
    }

    /// A take written after a run holds the stars that formed during it (#150). The solver
    /// writes formation times only to its own buffer, so the sampled system a take is written
    /// from still has the start state's.
    @Test func aTakeKeepsTheStarsFormedDuringTheRun() throws {
        var scene = SceneConfig.isolatedDisk(particleCount: 30_000)
        scene.galaxies[0].kind = .spiral
        scene.timeStepScale = 8
        scene.retune()
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: sampled)
        solver.step(count: 240)

        let captured = solver.capturedParticles(from: sampled)
        #expect(captured.formation == solver.particles.formation)
        #expect(captured.formation != sampled.formation)
        #expect(captured.positions == sampled.positions)

        let count = 500
        let recording = Recording(particleCount: count, galaxyCount: 1)
        let positions = [SIMD3<Float>](repeating: .zero, count: count)
        for frame in 0..<3 {
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame), centers: [.zero])
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stars-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: captured, to: url)
        let loaded = try RecordingFile.read(from: url)
        #expect(loaded.particles.formation == Array(captured.formation[0..<count]))
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
        func perWindow(merging: Bool, over megayears: Float, seed: UInt64) throws -> [Int] {
            var scene =
                merging
                ? SceneConfig.merger(particleCount: 60_000, seed: seed)
                : SceneConfig.isolatedDisk(particleCount: 60_000, seed: seed)
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
        /// sign. Measured at sixty thousand particles: 299, 262, 237, 225, 190, 186 for a disk
        /// left alone, and 195, 201, 467, 148, 461, 517 for an encounter, whose third window
        /// holds pericentre and whose last holds coalescence — an excursion of 1.0 against
        /// 2.65.
        ///
        /// The upper bar was two and a half and has been moved down, because 2.65 against 2.5
        /// is a six per cent margin and a test with a six per cent margin goes red on a driver
        /// update rather than on a regression. What it has to do is separate one from two and
        /// a half, and two does that with room on both sides.
        ///
        /// Summed over two seeds. A window holds about a hundred knots, and one of them moved the
        /// quiet excursion from 1.26 to 1.59 when the opening angle changed (#37), while three
        /// other seeds stayed between 1.10 and 1.38. Summed, 1.27 against 3.2.
        func excursion(merging: Bool) throws -> Float {
            let counts = try zip(
                perWindow(merging: merging, over: 450, seed: 1),
                perWindow(merging: merging, over: 450, seed: 2)
            ).map { $0 + $1 }
            return excursion(counts)
        }
        func excursion(_ counts: [Int]) -> Float {
            Float(counts.max() ?? 0) / Float(max(counts.first ?? 1, 1))
        }

        #expect(try excursion(merging: false) < 1.5)
        #expect(try excursion(merging: true) > 2.0)
    }

    /// The lengths read off the solver's tree are the ones the field would compute from that
    /// same tree, counting only the drawn particles and writing nothing past them.
    @Test func smoothingComesFromTheSolversOwnTree() throws {
        var scene = SceneConfig.merger(particleCount: 20_000)
        scene.solver = .barnesHut
        for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let drawn = particles.visibleCount
        #expect(drawn > 0 && drawn < particles.count)
        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles)

        let tree = BarnesHutTree(
            leafCapacity: MetalBarnesHutSolver.leafCapacity,
            maximumDepth: MetalBarnesHutSolver.maximumTreeDepth)
        tree.build(positions: particles.positions, mass: particles.mass)
        var expected = [Float](repeating: 0, count: drawn)
        for node in tree.nodes where node.isLeaf {
            let slots = node.particleStart..<(node.particleStart + node.particleCount)
            let mine = slots.filter { Int(tree.order[$0]) < drawn }
            guard !mine.isEmpty else { continue }
            let length = sqrt(node.packed.x) * pow(1 / Float(mine.count), 1.0 / 3.0)
            for slot in mine { expected[Int(tree.order[slot])] = length }
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let sentinel: Float = -1
        let buffer = try #require(
            device.makeBuffer(
                bytes: [Float](repeating: sentinel, count: drawn + 1), length: (drawn + 1) * 4,
                options: .storageModeShared))
        #expect(solver.writeSmoothing(into: buffer, drawn: drawn))
        let lengths = buffer.contents().bindMemory(to: Float.self, capacity: drawn + 1)
        var worst: Float = 0
        for index in 0..<drawn {
            worst = max(worst, abs(lengths[index] - expected[index]) / expected[index])
        }
        #expect(expected.allSatisfy { $0 > 0 })
        #expect(worst < 1e-5)
        #expect(lengths[drawn] == sentinel)
    }

    @Test func allBarnesHutShadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: BarnesHutShaders.source, options: nil)
        for name in ["bhKickDrift", "bhKick", "bhGather", "bhAcceleration"] {
            #expect(library.makeFunction(name: name) != nil, "missing \(name)")
        }
    }
}
