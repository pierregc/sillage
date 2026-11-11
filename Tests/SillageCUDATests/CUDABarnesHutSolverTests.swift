import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment = "needs an NVIDIA GPU and libsillagecuda.a: #283 runs it"
/// The folder of the Metal runs the comparison reads, from branch `assets/cuda-checks`.
private let metalRuns = ProcessInfo.processInfo.environment["SILLAGE_CUDA_CHECKS"]
private let needsMetalRuns: Comment =
    "needs the Metal runs of branch assets/cuda-checks: SILLAGE_CUDA_CHECKS names their folder"

/// The CUDA solver of the massive particles (#274), with `BarnesHutTests`' and
/// `CheckpointTests`' checks of the Metal solver. On the CPU target every pass runs, slowly, over
/// the CPU's own tree. Serialized: some tests move the solver's settings, which are global.
@Suite("CUDA solver", .serialized)
struct CUDABarnesHutSolverTests {
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

    private func clusterScene(_ count: Int, angle: Float = 0.4) -> SceneConfig {
        // diskMassFraction 1 leaves no halo mass, so the result is pure self-gravity.
        var scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: count,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, timeStep: 0.001, openingAngle: angle, softening: 0.25)
        scene.softening = 0.25
        return scene
    }

    private func system(_ positions: [SIMD3<Float>], _ mass: [Float]) -> ParticleSystem {
        var particles = ParticleSystem(capacity: positions.count)
        for index in positions.indices {
            particles.append(
                position: positions[index], velocity: .zero, galaxy: 0, radius: 1, mass: mass[index])
        }
        return particles
    }

    /// A merger of two disks that cool, with gas that forms stars, in rigid analytic halos or,
    /// with `liveHalos`, in halos of particles as a hires has them: every pass of a step runs.
    private func merger(_ count: Int, liveHalos: Bool = false) -> SceneConfig {
        var scene = Archetype.antennae.scene(batchSeed: 5, occurrence: 1, particleCount: count)
        if liveHalos {
            for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
            scene.retune()
        }
        return scene
    }

    private func disks(_ states: [DiskState]) -> [Float] {
        states.flatMap {
            [
                $0.axis.x, $0.axis.y, $0.axis.z, $0.coherence, $0.reference, $0.thickness,
                $0.thicknessReference, $0.disruption, $0.thinnest, $0.fullest, $0.layered, $0.torn,
            ]
        }
    }

    private func bits(_ values: [SIMD3<Float>]) -> [UInt32] {
        values.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
    }

    private func expectSameRun(
        _ a: CUDABarnesHutSolver, _ b: CUDABarnesHutSolver, _ what: Comment
    ) throws {
        let (first, second) = (a.particles, b.particles)
        #expect(bits(first.positions) == bits(second.positions), what)
        #expect(bits(first.velocities) == bits(second.velocities), what)
        #expect(first.formation.map(\.bitPattern) == second.formation.map(\.bitPattern), what)
        #expect(bits(try a.accelerations) == bits(try b.accelerations), what)
        #expect(a.time == b.time && a.centers == b.centers, what)
        #expect(disks(a.diskFrames) == disks(b.diskFrames), what)
    }

    /// The whole point of the tree is that it approximates direct summation: the tolerance
    /// `accelerationMatchesDirectSummation` holds the Metal solver to, at its 3,000 particles
    /// and at the ticket's 2,000 and 20,000.
    @Test(arguments: [2_000, 3_000, 20_000])
    func accelerationMatchesDirectSummation(count: Int) throws {
        try expectDirectSummation(count: count)
    }

    private func expectDirectSummation(count: Int) throws {
        let (positions, mass) = cluster(count: count)
        let solver = try CUDABarnesHutSolver(
            context: CUDAContext(), scene: clusterScene(count), massive: system(positions, mass))
        let computed = try solver.accelerations

        var worst: Float = 0
        var meanError: Float = 0
        var samples = 0
        for index in stride(from: 0, to: count, by: max(37, count / 500)) {
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
        #expect(try solver.traversalCosts.allSatisfy { $0 > 0 })
    }

    /// `aBlackHolePullsDirectlyAndTakesTheReaction`, with the reactions summed a block of
    /// particles at a time and no barrier: the pull on the hole to rounding, and no net force.
    @Test(arguments: [SIMD3<Float>(0.3, -0.2, 0.1), SIMD3<Float>(9, 2, -1)])
    func aBlackHolePullsDirectlyAndTakesTheReaction(at place: SIMD3<Float>) throws {
        let count = 3_000
        let (positions, mass) = cluster(count: count, seed: 9)
        let holeMass: Float = 3
        let holeSoftening: Float = 0.6
        var particles = system(positions, mass)
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
        let solver = try CUDABarnesHutSolver(context: CUDAContext(), scene: scene, massive: particles)
        let computed = try solver.accelerations
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

    /// 200 steps of a merger of 20,000, twice: the same bits. Stopped at step 100, saved with
    /// the Metal solver's checkpoint files and resumed in a solver that samples nothing: the
    /// same bits at step 200. Star formation, the cooling disks and dissipation all ran.
    @Test func aMergerRepeatsToTheBitAndResumesFromItsCheckpoint() throws {
        try expectARunRepeatsAndResumes(merger(20_000))
    }

    private func expectARunRepeatsAndResumes(_ scene: SceneConfig) throws {
        let sample = RestrictedSolver.sampleParticles(for: scene)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-cuda-solver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = RunCheckpoint(directory: folder)
        try checkpoint.saveMassive(sample)
        let file = folder.appendingPathComponent("particles.bin")

        // Three runs side by side, each on its own context: one straight through, one that
        // saves itself at step 100, and one that starts from what the second saved.
        nonisolated(unsafe) var runs: [CUDABarnesHutSolver?] = [nil, nil, nil]
        nonisolated(unsafe) var failures: [String] = []
        nonisolated(unsafe) var saved: SolverState?
        let lock = NSLock()
        let written = DispatchSemaphore(value: 0)
        concurrentPerform(iterations: 3) { index in
            do {
                if index == 2 {
                    // A new process: nothing sampled, the massive set and the state read back.
                    written.wait()
                    guard let state = lock.withLock({ saved }) else { return }
                    let solver = try CUDABarnesHutSolver(
                        context: CUDAContext(), scene: scene, massive: try checkpoint.massiveSet())
                    let reading = try FileHandle(forReadingFrom: file)
                    try solver.restore(state, from: reading)
                    try reading.close()
                    try solver.advance(steps: 100)
                    lock.withLock { runs[index] = solver }
                    return
                }
                let solver = try CUDABarnesHutSolver(
                    context: CUDAContext(), scene: scene, massive: sample)
                try solver.advance(steps: 100)
                if index == 1 {
                    let state = solver.state
                    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: file)
                    try solver.writeParticles(to: handle)
                    try handle.close()
                    lock.withLock { saved = state }
                    written.signal()
                }
                try solver.advance(steps: 100)
                lock.withLock { runs[index] = solver }
            } catch {
                lock.withLock { failures.append("run \(index): \(error)") }
                if index == 1 { written.signal() }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        let straight = try #require(runs[0])
        let again = try #require(runs[1])
        let resumed = try #require(runs[2])
        try expectSameRun(straight, again, "the same run twice")
        try expectSameRun(straight, resumed, "resumed from step 100")
        let state = try #require(saved)
        #expect(state.time > 0 && straight.time > state.time)

        // The checkpoint is the Metal solver's: 32 bytes a particle, then its formation time.
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size == straight.particleBytes && size == sample.count * 36)

        // The run did what a merger does: it moved, stars formed, and both disks were measured.
        let end = straight.particles
        #expect(end.formation.filter { $0 > 0 && $0 < 1e8 }.count > 0)
        #expect(straight.host.dissipates && straight.diskFrames.count == 2)
        #expect(bits(end.positions) != bits(sample.positions))
        var total = SIMD3<Float>.zero
        for index in 0..<end.count { total += end.velocities[index] * end.mass[index] }
        #expect(try straight.momentum() == total)

        // A state of another run is refused.
        let other = try CUDABarnesHutSolver(context: CUDAContext(), scene: merger(2_000))
        let wrong = try FileHandle(forReadingFrom: file)
        #expect(throws: RunCheckpointError.self) { try other.restore(state, from: wrong) }
        try wrong.close()
    }

    /// The force pass in pieces of 700 slots, and a tree used for two steps and gathered again
    /// in between, against one piece and a tree a step: `splittingTheForcePassChangesNothing`,
    /// and the reused tree keeps its run close.
    @Test func thePiecesOfTheForcePassAndAReusedTree() throws {
        let scene = merger(3_000, liveHalos: true)
        #expect(scene.hasLiveHalos)
        let sample = RestrictedSolver.sampleParticles(for: scene)
        func run(chunk: Int, reuse: Int, profiling: Bool = false) throws -> CUDABarnesHutSolver {
            let (wasChunk, wasReuse) = (BarnesHutHost.forceChunk, BarnesHutHost.treeReuse)
            defer { (BarnesHutHost.forceChunk, BarnesHutHost.treeReuse) = (wasChunk, wasReuse) }
            BarnesHutHost.forceChunk = chunk
            BarnesHutHost.treeReuse = reuse
            let solver = try CUDABarnesHutSolver(context: CUDAContext(), scene: scene, massive: sample)
            solver.profiling = profiling
            try solver.advance(steps: 20)
            return solver
        }
        let whole = try run(chunk: 1_000_000, reuse: 1)
        try expectSameRun(whole, try run(chunk: 700, reuse: 1), "the force pass in pieces")

        // Profiled, every pass is run and waited for on its own: the same bits, and its phases.
        let profiled = try run(chunk: 1_000_000, reuse: 1, profiling: true)
        try expectSameRun(whole, profiled, "profiled")
        let profile = profiled.takeProfile()
        #expect(profile.steps == 20 && profile.treeBuilds == 20)
        for phase in ["star formation", "drift", "halo centres", "disk frames", "force", "kick", "step"] {
            #expect(profile.milliseconds[phase] != nil, "\(phase)")
        }

        let reused = try run(chunk: 1_000_000, reuse: 2)
        let (a, b) = (whole.particles.positions, reused.particles.positions)
        #expect(bits(a) != bits(b))
        var furthest: Float = 0
        for index in a.indices { furthest = max(furthest, simd_distance(a[index], b[index])) }
        #expect(furthest < 0.05, "\(furthest) kpc apart after 20 steps")
    }

    /// The smoothing lengths the renderer reads come from the solver's own tree.
    @Test func smoothingComesFromTheSolversOwnTree() throws {
        let count = 5_000
        let (positions, mass) = cluster(count: count)
        let context = try CUDAContext()
        let solver = try CUDABarnesHutSolver(
            context: context, scene: clusterScene(count), massive: system(positions, mass))
        let lengths = try context.makeBuffer(length: count * 4)
        #expect(try solver.writeSmoothing(into: lengths, drawn: count))
        let written = try lengths.download(Float.self, count: count)
        #expect(written.allSatisfy { $0 > 0 && $0.isFinite })

        let builder = try CUDATreeBuilder(context: context, count: count)
        try builder.buildCells(positions: try context.makeBuffer(positions))
        let alone = try context.makeBuffer(length: count * 4)
        try builder.buildSmoothing(into: alone, drawn: count)
        #expect(try alone.download(Float.self, count: count) == written)
    }

    /// A checkpoint of another size, or one cut short, is refused.
    @Test func aStateOfAnotherSizeIsRefused() throws {
        let solver = try CUDABarnesHutSolver(context: CUDAContext(), scene: clusterScene(500))
        var state = solver.state
        state.count += 1
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-cuda-solver-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = FileManager.default.createFile(atPath: file.path, contents: Data(count: 8))
        let handle = try FileHandle(forReadingFrom: file)
        #expect(throws: RunCheckpointError.self) { try solver.restore(state, from: handle) }
        // The right state, and a file cut short.
        #expect(throws: RunCheckpointError.self) { try solver.restore(solver.state, from: handle) }
        try handle.close()
    }

    // MARK: - On a GPU only (#283)

    /// The tests above at 500 k, where the tree comes from its own kernels, the radix sort and
    /// the split among them.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func accelerationMatchesDirectSummationAt500k() throws {
        try expectDirectSummation(count: 500_000)
    }

    /// 200 k drawn and 300 k of live halos: 200 steps twice, and resumed from step 100.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aMergerOf500kRepeatsToTheBitAndResumesFromItsCheckpoint() throws {
        try expectARunRepeatsAndResumes(merger(200_000, liveHalos: true))
    }

    /// A step at 2 M and 5 M massive particles, without tracers, phase by phase: the mean of
    /// ten steps after two, printed on `CUDASOLVER` lines. On the M4 Max the massive passes are
    /// about 150 ms of a step at 2 M drawn and 3 M of halo (#238), its tree 11 ms of them
    /// (docs/notes/gpu-tree.md).
    @Test(.enabled(if: onAGPU, needsAGPU), arguments: [2_000_000, 5_000_000])
    func aStepIsTimed(count: Int) throws {
        let scene = merger(count * 2 / 5, liveHalos: true)
        let solver = try CUDABarnesHutSolver(context: CUDAContext(), scene: scene)
        try solver.advance(steps: 2)
        solver.profiling = true
        try solver.advance(steps: 10)
        let profile = solver.takeProfile()
        #expect(profile.steps == 10)
        let phases = StepProfile.phases + ["black holes"]
        let line = phases.compactMap { phase in
            profile.milliseconds[phase].map { String(format: "%@ %.2f", phase, $0 / 10) }
        }
        print(
            "CUDASOLVER a step at \(solver.host.massive) massive on \(solver.context.name), ms:"
                + " \(line.joined(separator: ", "))")
    }

    // MARK: - Against Metal

    private static let sceneFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/scene/scene.json")

    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "sillage-cuda-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func recorded(
        _ engine: String, scene: SceneConfig, particles: Int, sample: ParticleSystem, steps: Int,
        every: Int, snapshots: [Int], into directory: URL
    ) throws -> SolverCurves {
        let solver = try CUDABarnesHutSolver(context: CUDAContext(), scene: scene, massive: sample)
        return try SolverCheck.record(
            engine: engine, scene: scene, particles: particles, host: solver.host, steps: steps,
            every: every, snapshots: snapshots, into: directory,
            advance: { try solver.advance(steps: $0) }, particles: { solver.particles })
    }

    /// The curves a run is compared by, and the gaps between two runs: none between a run and
    /// itself, some once a position has moved by its last bit.
    @Test func theCurvesOfTwoRunsAndTheirGaps() throws {
        let folder = temporary("curves")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = try SolverCheck.scene(file: Self.sceneFile, particles: 2_000)
        #expect(scene.hasLiveHalos && scene.galaxies.count == 2)
        let sample = RestrictedSolver.sampleParticles(for: scene)
        let sets = [("first", sample), ("again", sample), ("moved", SolverCheck.oneBitMoved(sample))]
        let all = SolverCheck.everyBitMoved(sample)
        #expect(zip(all.positions, sample.positions).allSatisfy { $0.x == $1.x.nextUp && $0.y == $1.y })
        for (name, set) in sets {
            let curves = try recorded(
                name, scene: scene, particles: 2_000, sample: set, steps: 60, every: 10,
                snapshots: SolverCheck.snapshots(steps: 60), into: folder.appendingPathComponent(name))
            #expect(curves.steps == [0, 10, 20, 30, 40, 50, 60] && curves.snapshots == [0, 30, 60])
            #expect(curves.massive == sample.count && curves.visible == sample.visibleCount)
            #expect(curves.centers.allSatisfy { $0.count == 2 } && curves.thickness.last?.count == 2)
            #expect(curves.timeMyr.last ?? 0 > 0 && curves.momentumScale.allSatisfy { $0 > 0 })
        }
        let same = try SolverCheck.gaps(
            folder.appendingPathComponent("first"), folder.appendingPathComponent("again"))
        #expect(same.count == 3 && same.map(\.step) == [0, 30, 60])
        #expect(same.allSatisfy { $0.furthest == 0 && $0.chiSquare == 0 })
        #expect(same.allSatisfy { $0.centers == 0 && $0.thickness == 0 && $0.momentum == 0 })
        let moved = try SolverCheck.gaps(
            folder.appendingPathComponent("first"), folder.appendingPathComponent("moved"))
        // One particle a bit away at the start; 60 steps on the two runs are still as one.
        #expect(moved[0].furthest > 0 && moved[0].furthest < 1e-5 && moved[0].ninetieth == 0)
        #expect(moved[2].furthest < 1e-2 && moved[2].chiSquare < 0.01)
    }

    /// Scene-0031 at 20 k over the massive particles the Mac sampled, 2,000 steps, against the
    /// Metal run over the same particles: the centres, each disk's thickness, the density maps
    /// and the momentum. They do not agree to the bit; they part as two Metal runs part when one
    /// position differs by its last bit, the scale chaos alone gives. The counts and the steps
    /// are those of the Metal runs, so the same test reads the runs at 500 k on a GPU (#283).
    @Test(.enabled(if: metalRuns != nil, needsMetalRuns))
    func aRunStaysWithinWhatChaosPartsTwoMetalRunsBy() throws {
        let folder = URL(fileURLWithPath: try #require(metalRuns), isDirectory: true)
        let metal = try SolverCurves.load(folder.appendingPathComponent("metal"))
        let steps = try #require(metal.steps.last)
        var scene = try SolverCheck.scene(file: Self.sceneFile, particles: metal.particles)
        print(
            "CUDASOLVER scene \(metal.particles) drawn, \(metal.massive) massive:"
                + " step \(scene.timeStep) here and \(metal.timeStep) on the Mac,"
                + " softening \(scene.softening) and \(metal.softening)")
        // What the Mac worked out, so both engines step the same scene.
        scene.timeStep = metal.timeStep
        scene.softening = metal.softening
        scene.openingAngle = metal.openingAngle
        let sample = try RunCheckpoint(directory: folder).massiveSet()
        #expect(sample.count == metal.massive && sample.visibleCount == metal.visible)

        let engine = CUDAContext.target == .cpu ? "cuda-cpu" : "cuda"
        let out =
            ProcessInfo.processInfo.environment["SILLAGE_CUDA_CHECKS_OUT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? temporary("checks")
        let started = Date()
        let mine = try recorded(
            engine, scene: scene, particles: metal.particles, sample: sample, steps: steps,
            every: metal.every, snapshots: metal.snapshots, into: out.appendingPathComponent(engine))
        print(
            String(
                format: "CUDASOLVER %@: %d steps in %.0f s, %d stars formed, %d on the Mac", engine,
                steps, Date().timeIntervalSince(started), mine.formed.last ?? 0, metal.formed.last ?? 0))

        // What parts two Metal runs: one position moved by its last bit, and every one.
        var scales: [(name: String, gaps: [SolverCheck.Gap])] = []
        for name in ["metal-one-bit", "metal-every-bit"] {
            let run = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: run.appendingPathComponent("curves.json").path)
            else { continue }
            scales.append((name, try SolverCheck.gaps(folder.appendingPathComponent("metal"), run)))
        }
        let gaps = try SolverCheck.gaps(
            folder.appendingPathComponent("metal"), out.appendingPathComponent(engine))
        let chaos = try #require(scales.last?.gaps)
        #expect(gaps.count == chaos.count && !gaps.isEmpty)
        func line(_ name: String, _ gap: SolverCheck.Gap) -> String {
            String(
                format: "CUDASOLVER %-15@ step %5d %6.1f Myr  apart %.3g median %.3g 90%% %.3g max kpc"
                    + "  chi2 %.4f binned %.4f  centres %.3g kpc  thickness %.3g  momentum %.3g",
                name, gap.step, gap.timeMyr, gap.median, gap.ninetieth, gap.furthest, gap.chiSquare,
                gap.chiSquareBinned, gap.centers, gap.thickness, gap.momentum)
        }
        for index in gaps.indices {
            print(line(engine, gaps[index]))
            for scale in scales where index < scale.gaps.count { print(line(scale.name, scale.gaps[index])) }
        }
        // Within what chaos gives: no further from Metal than a few times what a last bit parts
        // two Metal runs by, once that has grown past rounding.
        for (gap, scale) in zip(gaps, chaos) where gap.step > 0 {
            #expect(gap.median < 10 * max(scale.median, 1e-4), "step \(gap.step)")
            #expect(gap.centers < 10 * max(scale.centers, 1e-3), "step \(gap.step)")
            #expect(gap.chiSquareBinned < 10 * max(scale.chiSquareBinned, 0.01), "step \(gap.step)")
        }
    }
}
