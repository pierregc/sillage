import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Light tracers")
struct LightTracerTests {
    private func selfGravitatingDisk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    @Test func splittingKeepsEachGalaxysMassAndPutsTheTracersFirst() {
        let scene = selfGravitatingDisk(20_000)
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: scene, massive: selfGravitatingDisk(5_000))

        #expect(split.visibleCount == sampled.visibleCount)
        #expect(abs(split.visibleCount - tracers - 5_000) < 400)
        #expect((0..<tracers).allSatisfy { split.mass[$0] == 0 })
        #expect((tracers..<split.count).allSatisfy { split.mass[$0] > 0 })
        #expect(
            (0..<split.visibleCount).allSatisfy {
                split.component[$0] != ParticleComponent.halo.rawValue
            })
        func mass(_ system: ParticleSystem, halo: Bool) -> Double {
            (0..<system.count).reduce(0) {
                (system.component[$1] == ParticleComponent.halo.rawValue) == halo
                    ? $0 + Double(system.mass[$1]) : $0
            }
        }
        for halo in [false, true] {
            let before = mass(sampled, halo: halo)
            #expect(abs(mass(split, halo: halo) - before) / before < 1e-4)
        }
        // The dark matter is drawn at the massive count, 1.5 a massive particle, and none of it
        // was drawn only to be thrown away.
        #expect(split.count - split.visibleCount == 7_500)
        #expect(sampled.count - sampled.visibleCount == 30_000)
    }

    /// Split alone, a sample keeps all of its dark matter: the halo is drawn at the massive
    /// count before, and nothing else moves.
    @Test func theDarkMatterIsDrawnAtTheMassiveCount() {
        let drawn = selfGravitatingDisk(20_000)
        let massive = selfGravitatingDisk(5_000)
        let sampled = RestrictedSolver.sampleParticles(
            for: drawn, haloCounts: massive.galaxies.map(\.haloParticleCount))
        #expect(sampled.visibleCount == 20_000 && sampled.count == 27_500)
        let haloMass = (sampled.visibleCount..<sampled.count).map { Double(sampled.mass[$0]) }
        let expected = Double(drawn.galaxies[0].potential.mass * (1 - drawn.galaxies[0].diskMassFraction))
        #expect(abs(haloMass.reduce(0, +) / expected - 1) < 1e-4)
        let (split, _) = sampled.splittingLightTracers(massive: 5_000, seed: 3)
        #expect(split.count - split.visibleCount == 7_500)
        // Without halo counts, the sample is the one every run without tracers has always had.
        let plain = RestrictedSolver.sampleParticles(for: drawn)
        let again = RestrictedSolver.sampleParticles(for: drawn, haloCounts: nil)
        #expect(plain.positions == again.positions && plain.mass == again.mass)
    }

    /// A tracer walks at the scene's opening angle: at 1.3 the tracers were pulled short and
    /// drifted 4 % off the mass over a merger (docs/notes/light-tracers.md).
    @Test func theTracersWalkAtTheScenesOpeningAngle() throws {
        for angle: Float in [0.9, 0.7] {
            var scene = selfGravitatingDisk(4_000)
            scene.openingAngle = angle
            let (split, tracers) = ParticleSystem.lightTracers(
                drawn: scene, massive: selfGravitatingDisk(1_000))
            let solver = try MetalBarnesHutSolver(scene: scene, particles: split, tracers: tracers)
            #expect(solver.tracerOpeningAngle == angle)
        }
    }

    /// The tree is the massive particles' alone, so adding tracers moves none of them: the
    /// massive part of a run with tracers repeats the run without them to the bit, black hole
    /// and star formation included, which is what lets a full pass be framed on a massive
    /// pass (#239).
    @Test func theMassiveParticlesRepeatTheRunWithoutTracersToTheBit() throws {
        let hole = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 12_000)
        let scenes = [
            (selfGravitatingDisk(12_000), selfGravitatingDisk(3_000)),
            (hole, Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 3_000)),
        ]
        for (drawn, massive) in scenes {
            let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
            let alone = split.slice(tracers..<split.count)
            #expect(tracers > 0)

            let reference = try MetalBarnesHutSolver(scene: massive, particles: alone)
            let traced = try MetalBarnesHutSolver(scene: massive, particles: split, tracers: tracers)
            reference.step(count: 40)
            traced.step(count: 40)
            let expected = reference.particles
            let run = traced.particles
            #expect(Array(run.positions[tracers...]) == expected.positions, "\(drawn.name)")
            #expect(Array(run.velocities[tracers...]) == expected.velocities, "\(drawn.name)")
            #expect(Array(run.formation[tracers...]) == expected.formation, "\(drawn.name)")
            func read(_ disks: [DiskState]) -> [Float] {
                disks.flatMap { [$0.axis.x, $0.axis.y, $0.axis.z, $0.coherence, $0.disruption, $0.torn] }
            }
            #expect(traced.centers == reference.centers)
            #expect(read(traced.diskFrames) == read(reference.diskFrames))
        }
    }

    /// A tracer anywhere feels what direct summation over the massive particles says.
    @Test func aTracerFeelsTheMassiveField() throws {
        var generator = SeededGenerator(seed: 5)
        var particles = ParticleSystem(capacity: 6_000)
        var massive: [SIMD3<Float>] = []
        var mass: [Float] = []
        // Tracers first, then the massive cluster.
        for _ in 0..<2_000 {
            let position =
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 9
            particles.append(position: position, velocity: .zero, galaxy: 0, radius: 1, mass: 0)
        }
        for _ in 0..<4_000 {
            let position =
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 7
            particles.append(position: position, velocity: .zero, galaxy: 0, radius: 1, mass: 0.002)
            massive.append(position)
            mass.append(0.002)
        }
        particles.setVisibleCount(particles.count)
        var scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: 4_000,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, timeStep: 0.001, openingAngle: 0.4, softening: 0.25)
        scene.softening = 0.25

        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles, tracers: 2_000)
        let computed = solver.accelerations
        var meanError: Float = 0
        var worst: Float = 0
        var samples = 0
        for index in stride(from: 0, to: 2_000, by: 23) {
            let reference = BarnesHutTree.directAcceleration(
                at: particles.positions[index], positions: massive, mass: mass, softening: 0.25,
                skipping: -1)
            let error =
                simd_length(computed[index] - reference) / max(simd_length(reference), 1e-6)
            meanError += error
            worst = max(worst, error)
            samples += 1
        }
        meanError /= Float(samples)
        #expect(meanError < 0.02)
        #expect(worst < 0.15)
    }

    /// Tracer gas forms stars at the rate the massive gas around it does, provided the
    /// softening is the massive count's: softened for twice as many, the massive particles
    /// cluster among themselves, which the tracers cannot, and tracer gas formed a third less.
    @Test func tracerGasFormsStarsLikeTheMassiveGas() throws {
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: selfGravitatingDisk(80_000), massive: selfGravitatingDisk(40_000))
        let solver = try MetalBarnesHutSolver(
            scene: selfGravitatingDisk(40_000), particles: split, tracers: tracers)
        solver.step(count: 400)
        let after = solver.particles

        func share(_ range: Range<Int>) -> (formed: Double, gas: Int) {
            var gas = 0
            var formed = 0
            for index in range where after.component[index] == ParticleComponent.dust.rawValue {
                gas += 1
                if after.formation[index] < 1e8 { formed += 1 }
            }
            return (Double(formed) / Double(max(gas, 1)), gas)
        }
        let light = share(0..<tracers)
        let heavy = share(tracers..<after.visibleCount)
        #expect(light.gas > 0 && heavy.gas > 0)
        #expect(heavy.formed > 0)
        #expect(light.formed > heavy.formed * 0.75 && light.formed < heavy.formed * 1.33)
        // Only gas forms anything.
        for index in 0..<tracers where after.component[index] != ParticleComponent.dust.rawValue {
            #expect(after.formation[index] == split.formation[index])
        }
    }

    /// Streamed a chunk at a time, the split keeps the same massive set to the bit and every
    /// tracer as it was, its attributes to the steps they are packed at (#238).
    @Test func streamingSplitsAsTheWholeSampleDid() {
        let drawn = selfGravitatingDisk(30_000)
        let massive = selfGravitatingDisk(6_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
        var chunks: [LightTracerChunk] = []
        let (set, streamed) = ParticleSystem.streamingLightTracers(
            drawn: drawn, massive: massive, chunk: 4_096
        ) { chunks.append($0) }
        #expect(streamed == tracers)
        #expect(ParticleSystem.lightTracerTotal(drawn: drawn, massive: massive) == split.count)

        let alone = split.slice(tracers..<split.count)
        #expect(set.count == alone.count && set.visibleCount == alone.visibleCount)
        #expect(set.positions == alone.positions && set.velocities == alone.velocities)
        #expect(set.mass == alone.mass && set.galaxyIndex == alone.galaxyIndex)
        #expect(set.component == alone.component && set.formation == alone.formation)
        #expect(set.luminosity == alone.luminosity && set.kernelScale == alone.kernelScale)
        #expect(set.birthRadius == alone.birthRadius && set.population == alone.population)

        let states = chunks.flatMap(\.states)
        let motions = chunks.flatMap(\.motions)
        #expect(states.count == tracers && motions.count == tracers)
        let exact = (0..<min(tracers, states.count)).allSatisfy { index in
            let word = TracerWord(bits: motions[index].w)
            let velocity = SIMD3(
                Float(bitPattern: motions[index].x), Float(bitPattern: motions[index].y),
                Float(bitPattern: motions[index].z))
            return SIMD3(states[index].x, states[index].y, states[index].z) == split.positions[index]
                && velocity == split.velocities[index] && states[index].w == split.formation[index]
                && word.galaxy == split.galaxyIndex[index] && word.component == split.component[index]
                && word.kernelScale == split.kernelScale[index]
        }
        #expect(exact)
        var light: Float = 0
        var radius: Float = 0
        for index in 0..<min(tracers, motions.count) {
            let word = TracerWord(bits: motions[index].w)
            light = max(light, abs(word.luminosity / split.luminosity[index] - 1))
            radius = max(radius, abs(word.birthRadius / max(split.birthRadius[index], 1e-3) - 1))
        }
        #expect(light < 0.03)
        #expect(radius < 6e-4)
    }

    @Test func aTracerWordKeepsItsAttributes() {
        for galaxy: UInt32 in [0, 7, 15] {
            for component in ParticleComponent.allCases {
                for scale in TracerWord.kernelScales {
                    for (light, radius) in [(Float(1), Float(3.2)), (0.05, 0.01), (37, 140), (0, 0)] {
                        let word = TracerWord(
                            galaxy: galaxy, component: component.rawValue, kernelScale: scale,
                            luminosity: light, birthRadius: radius)
                        #expect(word.galaxy == galaxy && word.component == component.rawValue)
                        #expect(word.kernelScale == scale)
                        #expect(light == 0 ? word.luminosity == 0 : abs(word.luminosity / light - 1) < 0.03)
                        #expect(
                            radius == 0 ? word.birthRadius == 0 : abs(word.birthRadius / radius - 1) < 6e-4)
                    }
                }
            }
        }
    }

    /// A tracer standing where a massive particle stands and moving as it moves stays with it:
    /// its kicks, its cooling and its drift are the massive particle's, fused (#238).
    @Test func aTracerOnAMassiveParticleStaysWithIt() throws {
        let scene = selfGravitatingDisk(8_000)
        #expect(scene.galaxies[0].dissipationTime > 0, "otherwise the cooling goes untested")
        let massive = RestrictedSolver.sampleParticles(for: scene)
        let followed = stride(from: 0, to: massive.visibleCount, by: 37).filter {
            massive.component[$0] < ParticleComponent.halo.rawValue
        }
        var particles = ParticleSystem(capacity: followed.count + massive.count)
        for index in followed {
            particles.append(
                position: massive.positions[index], velocity: massive.velocities[index],
                galaxy: massive.galaxyIndex[index], radius: massive.birthRadius[index],
                population: massive.population[index], luminosity: massive.luminosity[index],
                formation: massive.formation[index],
                component: ParticleComponent(rawValue: massive.component[index]) ?? .star, mass: 0,
                kernelScale: massive.kernelScale[index])
        }
        particles.append(contentsOf: massive)
        particles.setVisibleCount(followed.count + massive.visibleCount)
        let solver = try MetalBarnesHutSolver(
            scene: scene, particles: particles, tracers: followed.count)
        solver.step(count: 60)
        let after = solver.particles.positions
        var worst: Float = 0
        var moved: Float = 0
        for (tracer, index) in followed.enumerated() {
            worst = max(worst, simd_distance(after[tracer], after[followed.count + index]))
            moved = max(moved, simd_distance(after[tracer], massive.positions[index]))
        }
        #expect(moved > 0.1, "otherwise nothing moved")
        #expect(worst < 1e-3)
    }

    /// A tracer's kernel comes off the massive tree one read a level: down to the leaf holding
    /// a massive particle, the walk reads exactly that particle's smoothing length (#238).
    @Test func theSpacingWalkFindsEachMassiveParticlesLength() throws {
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: selfGravitatingDisk(40_000), massive: selfGravitatingDisk(10_000))
        let solver = try MetalBarnesHutSolver(
            scene: selfGravitatingDisk(10_000), particles: split, tracers: tracers)
        let drawn = split.visibleCount - tracers
        let lengths = try #require(
            solver.device.makeBuffer(length: drawn * 4, options: .storageModeShared))
        #expect(solver.tracerSpacing == nil)
        #expect(solver.writeSmoothing(into: lengths, drawn: drawn))
        let spacing = try #require(solver.tracerSpacing)
        let cells = spacing.cells.contents().bindMemory(
            to: SIMD2<UInt32>.self, capacity: spacing.cells.length / 8)
        let frame = spacing.frame.contents().bindMemory(to: Float.self, capacity: 4)
        // `tracerSpacing` in the shaders, and the codes as `gtMorton` takes them.
        func walk(_ position: SIMD3<Float>) -> Float {
            var length = Float(bitPattern: cells[0].x)
            let local = (position - SIMD3(frame[0], frame[1], frame[2])) * frame[3]
            let q = SIMD3<UInt32>(local.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 2_097_151)))
            var node = 0
            for level in 0..<spacing.depth {
                let links = cells[node].y
                let mask = links & 255
                let shift = UInt32(20 - level)
                let digit = ((q.x >> shift) & 1) << 2 | ((q.y >> shift) & 1) << 1 | ((q.z >> shift) & 1)
                guard mask & (1 << digit) != 0 else { break }
                node = Int(links >> 8) + (mask & ((1 << digit) - 1)).nonzeroBitCount
                let here = Float(bitPattern: cells[node].x)
                if here > 0 { length = here }
            }
            return length
        }
        let positions = solver.particles.positions
        let written = lengths.contents().bindMemory(to: Float.self, capacity: drawn)
        let matched = (0..<drawn).filter { walk(positions[tracers + $0]) == written[$0] }.count
        #expect(Double(matched) / Double(drawn) > 0.999)
        // Each massive particle stands for its share of the drawn count, so its kernel is the
        // size it would have among all of them.
        let ratio = Float(split.visibleCount) / Float(drawn)
        let mean = (0..<drawn).reduce(Float(0)) { $0 + written[$1] } / Float(drawn)
        let tracerMean = (0..<tracers).reduce(Float(0)) { $0 + walk(positions[$1]) } / Float(tracers)
        #expect(abs(tracerMean / mean - 1) < 0.2)
        #expect(ratio > 3.5)
    }

    /// Drawn from 32 bytes each with their kernels off the massive tree, the tracers make the
    /// picture the same particles make drawn whole, with a tree of their own (#238).
    @Test func tracersDrawLikeTheParticlesTheyStandFor() throws {
        let drawnScene = selfGravitatingDisk(60_000)
        let massiveScene = selfGravitatingDisk(15_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawnScene, massive: massiveScene)
        let solver = try MetalBarnesHutSolver(scene: massiveScene, particles: split, tracers: tracers)
        let settings = RenderSettings(width: 160, height: 96, supersample: 2, bloomLevels: 2)
        let camera = Camera.framing(radius: 30, elevation: 0.6)
        let frames = DiskFrame.make(
            scene: massiveScene, centers: solver.centers, time: solver.time, strength: 1)

        let alone = split.slice(tracers..<split.count)
        let compact = try Renderer(
            particles: alone, settings: settings, externalPositions: solver.positions,
            externalFormation: solver.formation, externalPositionOffset: tracers * 16)
        try compact.setTracers(solver)
        let field = try SmoothingField(device: compact.device, particleCount: alone.visibleCount)
        field.update(from: solver)
        compact.setSmoothing(field.buffer)
        compact.setDiskFrames(frames)
        let traced = compact.render(camera: camera)

        let whole = try Renderer(particles: split, settings: settings)
        let wholeField = try SmoothingField(device: whole.device, particleCount: split.visibleCount)
        wholeField.update(from: whole.positions)
        whole.setSmoothing(wholeField.buffer)
        whole.setDiskFrames(frames)
        let expected = whole.render(camera: camera)

        func blocks(_ pixels: [UInt8]) -> [Double] {
            var sums = [Double](repeating: 0, count: (160 / 8) * (96 / 8))
            for y in 0..<96 {
                for x in 0..<160 {
                    let base = (y * 160 + x) * 4
                    sums[(y / 8) * 20 + x / 8] +=
                        Double(pixels[base]) + Double(pixels[base + 1]) + Double(pixels[base + 2])
                }
            }
            return sums
        }
        let a = blocks(traced)
        let b = blocks(expected)
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        #expect(meanB > 0)
        #expect(abs(meanA / meanB - 1) < 0.2)
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB)
            varianceA += (x - meanA) * (x - meanA)
            varianceB += (y - meanB) * (y - meanB)
        }
        #expect(covariance / (varianceA * varianceB).squareRoot() > 0.9)
    }
}
