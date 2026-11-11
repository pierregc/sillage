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
/// The folder of the Mac's draw and Metal runs, from branch `assets/cuda-checks`.
private let tracerRuns = ProcessInfo.processInfo.environment["SILLAGE_CUDA_TRACER_CHECKS"]
private let needsTracerRuns: Comment =
    "needs the Metal runs of branch assets/cuda-checks: SILLAGE_CUDA_TRACER_CHECKS names their folder"

/// The light tracers of the CUDA solver (#275), with `LightTracerTests`' checks of the Metal
/// solver. Part of the solver's suite, which is serialized: some tests move the solver's
/// settings, which are global.
extension CUDABarnesHutSolverTests {
    /// `LightTracerTests`' disk: self-gravitating, with a live halo, cooled.
    func tracedDisk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    /// Runs `work` for each index on a context of its own, side by side, and throws the first
    /// failure.
    private func sideBySide(_ count: Int, _ work: @escaping (Int) throws -> CUDABarnesHutSolver) throws
        -> [CUDABarnesHutSolver]
    {
        nonisolated(unsafe) var runs = [CUDABarnesHutSolver?](repeating: nil, count: count)
        nonisolated(unsafe) var failures: [String] = []
        let lock = NSLock()
        concurrentPerform(iterations: count) { index in
            do {
                let solver = try work(index)
                lock.withLock { runs[index] = solver }
            } catch {
                lock.withLock { failures.append("run \(index): \(error)") }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        return try runs.map { try #require($0) }
    }

    /// The tree is the massive particles' alone, so adding tracers moves none of them: the
    /// massive part of a run with tracers repeats the run without them to the bit, black hole and
    /// star formation included, as on Metal (#239). 20 k massive and 80 k tracers, then a black
    /// hole pass.
    @Test func theMassiveParticlesRepeatTheRunWithoutTracersToTheBit() throws {
        let hole = Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 12_000)
        let scenes = [
            (tracedDisk(100_000), tracedDisk(20_000), 20),
            (hole, Archetype.blackHolePass.scene(batchSeed: 5, occurrence: 1, particleCount: 3_000), 40),
        ]
        for (drawn, massive, steps) in scenes {
            let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
            let alone = split.slice(tracers..<split.count)
            #expect(tracers > 0)
            let runs = try sideBySide(2) { index in
                let solver =
                    index == 0
                    ? try CUDABarnesHutSolver(context: CUDAContext(), scene: massive, massive: alone)
                    : try CUDABarnesHutSolver(
                        context: CUDAContext(), scene: massive, particles: split, tracers: tracers)
                try solver.advance(steps: steps)
                return solver
            }
            let (reference, traced) = (runs[0], runs[1])
            #expect(traced.tracerCount == tracers && reference.tracerCount == 0)
            let expected = reference.particles
            let run = traced.particles
            #expect(run.count == split.count && run.visibleCount == split.visibleCount)
            #expect(bits(Array(run.positions[tracers...])) == bits(expected.positions), "\(drawn.name)")
            #expect(bits(Array(run.velocities[tracers...])) == bits(expected.velocities), "\(drawn.name)")
            #expect(
                run.formation[tracers...].map(\.bitPattern) == expected.formation.map(\.bitPattern),
                "\(drawn.name)")
            #expect(traced.centers == reference.centers)
            #expect(disks(traced.diskFrames) == disks(reference.diskFrames))
            // And the tracers moved, with the massive particles.
            #expect(bits(Array(run.positions[..<tracers])) != bits(Array(split.positions[..<tracers])))
        }
    }

    /// A merger with tracers, 200 steps twice: the same bits. Stopped at step 100, saved with the
    /// Metal solver's checkpoint files and resumed in a solver that samples nothing, whose tracers
    /// come from the checkpoint and take no first half kick: the same bits at step 200, tracers
    /// included. Star formation, the cooling disks and the analytic halos all ran.
    @Test func aRunWithTracersRepeatsAndResumesFromItsCheckpoint() throws {
        let massive = merger(10_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: merger(30_000), massive: massive)
        let alone = split.slice(tracers..<split.count)
        let folder = temporary("tracer-checkpoint")
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = RunCheckpoint(directory: folder)
        try checkpoint.saveMassive(alone)
        let file = folder.appendingPathComponent("particles.bin")

        nonisolated(unsafe) var saved: SolverState?
        let lock = NSLock()
        let written = DispatchSemaphore(value: 0)
        let runs = try sideBySide(3) { index in
            if index == 2 {
                written.wait()
                guard let state = lock.withLock({ saved }) else { throw CUDAError(.unknown, "nothing saved") }
                let set = try checkpoint.massiveSet()
                let context = try CUDAContext()
                let store = try CUDALightTracerStore(
                    context: context, capacity: state.count, awaiting: state.tracers)
                let solver = try CUDABarnesHutSolver(
                    context: context, scene: massive, massive: set, tracers: store)
                let reading = try FileHandle(forReadingFrom: file)
                try solver.restore(state, from: reading)
                try reading.close()
                try solver.advance(steps: 100)
                return solver
            }
            let solver = try CUDABarnesHutSolver(
                context: CUDAContext(), scene: massive, particles: split, tracers: tracers)
            do {
                try solver.advance(steps: 100)
                if index == 1 {
                    let state = solver.state
                    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: file)
                    try solver.writeParticles(to: handle)
                    try handle.close()
                    lock.withLock { saved = state }
                }
            } catch {
                if index == 1 { written.signal() }
                throw error
            }
            if index == 1 { written.signal() }
            try solver.advance(steps: 100)
            return solver
        }
        try expectSameRun(runs[0], runs[1], "the same run twice")
        try expectSameRun(runs[0], runs[2], "resumed from step 100")
        let state = try #require(saved)
        #expect(state.tracers == tracers && state.count == split.count)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size == runs[0].particleBytes && size == split.count * 32 + alone.count * 4)

        // The massive gas formed stars, so the draws of star formation ran on both sides of the
        // checkpoint; the tracers' pass ran with them (cuda/tests/solver_fixture.cu checks what it
        // writes). The tracers moved, and the disks cooled.
        let end = runs[0].particles
        let formed = (tracers..<end.visibleCount).filter { end.formation[$0] > 0 && end.formation[$0] < 1e8 }
        #expect(!formed.isEmpty)
        #expect(runs[0].host.dissipates && runs[0].host.params.haloCount == 2)
        #expect(bits(Array(end.positions[..<tracers])) != bits(Array(split.positions[..<tracers])))
    }

    /// The force pass and the tracers' pass in pieces of 700 slots, every pass profiled and
    /// waited for: the same bits as one piece, and the tracers' phases timed.
    @Test func theTracersPassInPiecesAndProfiled() throws {
        let massive = merger(2_000, liveHalos: true)
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: merger(6_000, liveHalos: true), massive: massive)
        func run(chunk: Int, profiling: Bool) throws -> CUDABarnesHutSolver {
            let (wasChunk, wasInterval) = (BarnesHutHost.forceChunk, BarnesHutHost.tracerSortInterval)
            defer { (BarnesHutHost.forceChunk, BarnesHutHost.tracerSortInterval) = (wasChunk, wasInterval) }
            BarnesHutHost.forceChunk = chunk
            BarnesHutHost.tracerSortInterval = 3
            let solver = try CUDABarnesHutSolver(
                context: CUDAContext(), scene: massive, particles: split, tracers: tracers)
            solver.profiling = profiling
            try solver.advance(steps: 10)
            return solver
        }
        let whole = try run(chunk: 1_000_000, profiling: false)
        let pieced = try run(chunk: 700, profiling: true)
        try expectSameRun(whole, pieced, "in pieces and profiled")
        let profile = pieced.takeProfile()
        for phase in ["tracer formation", "tracer force", "tracer sort", "drift", "force", "step"] {
            #expect(profile.milliseconds[phase] != nil, "\(phase)")
        }
    }

    /// A tracer anywhere feels what direct summation over the massive particles says, to the
    /// tolerance `aTracerFeelsTheMassiveField` holds Metal to.
    @Test func aTracerFeelsTheMassiveField() throws {
        var generator = SeededGenerator(seed: 5)
        var particles = ParticleSystem(capacity: 6_000)
        var massive: [SIMD3<Float>] = []
        var mass: [Float] = []
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
        let solver = try CUDABarnesHutSolver(
            context: CUDAContext(), scene: clusterScene(4_000), particles: particles, tracers: 2_000)
        let computed = try solver.accelerations
        #expect(computed.count == 6_000)
        var meanError: Float = 0
        var worst: Float = 0
        var samples = 0
        for index in stride(from: 0, to: 2_000, by: 23) {
            let reference = BarnesHutTree.directAcceleration(
                at: particles.positions[index], positions: massive, mass: mass, softening: 0.25,
                skipping: -1)
            let error = simd_length(computed[index] - reference) / max(simd_length(reference), 1e-6)
            meanError += error
            worst = max(worst, error)
            samples += 1
        }
        meanError /= Float(samples)
        #expect(meanError < 0.02)
        #expect(worst < 0.15)
    }

    /// Sampled a chunk at a time straight into the solver's buffers, the draw is the one the
    /// whole sample splits into, and a run over it the same run, to the bit (#238).
    @Test func theDrawGoesStraightIntoTheSolversBuffers() throws {
        let (drawn, massive) = (tracedDisk(30_000), tracedDisk(6_000))
        let context = try CUDAContext()
        let (store, set) = try CUDABarnesHutSolver.lightTracers(
            context: context, drawn: drawn, massive: massive)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
        #expect(store.count == tracers && store.capacity == split.count && !store.awaitsCheckpoint)
        let alone = split.slice(tracers..<split.count)
        #expect(bits(set.positions) == bits(alone.positions) && set.mass == alone.mass)
        let states = try store.positions.download(SIMD4<Float>.self, count: tracers)
        #expect(
            states.indices.allSatisfy {
                SIMD3(states[$0].x, states[$0].y, states[$0].z) == split.positions[$0]
            })
        let streamed = try CUDABarnesHutSolver(context: context, scene: massive, massive: set, tracers: store)
        let packed = try CUDABarnesHutSolver(
            context: CUDAContext(), scene: massive, particles: split, tracers: tracers)
        try streamed.advance(steps: 5)
        try packed.advance(steps: 5)
        try expectSameRun(streamed, packed, "streamed and packed")
        #expect(
            try streamed.tracerWord(7)
                == TracerWord(
                    galaxy: split.galaxyIndex[7], component: split.component[7],
                    kernelScale: split.kernelScale[7],
                    luminosity: split.luminosity[7], birthRadius: split.birthRadius[7]))
    }

    /// With tracers the smoothing lengths and the spacing records come from the solver's tree,
    /// each massive particle standing for its share of everything drawn, as on Metal (#238).
    @Test func theSpacingRecordsComeFromTheSolversTree() throws {
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: tracedDisk(20_000), massive: tracedDisk(5_000))
        let context = try CUDAContext()
        let solver = try CUDABarnesHutSolver(
            context: context, scene: tracedDisk(5_000), particles: split, tracers: tracers)
        #expect(solver.tracerSpacing == nil)
        let visible = split.visibleCount - tracers
        let lengths = try context.makeBuffer(length: visible * 4)
        #expect(try solver.writeSmoothing(into: lengths, drawn: visible))
        let spacing = try #require(solver.tracerSpacing)
        #expect(spacing.depth == BarnesHutHost.maximumTreeDepth)

        // The same as a builder over the same positions writes them with the same ratio.
        let ratio = Float(tracers + visible) / Float(visible)
        let massive = Array(solver.particles.positions[tracers...])
        let builder = try CUDATreeBuilder(context: context, count: massive.count)
        try builder.buildCells(positions: try context.makeBuffer(massive))
        let alone = try context.makeBuffer(length: visible * 4)
        try builder.buildSmoothing(into: alone, drawn: visible, ratio: ratio)
        try builder.buildSpacing(drawn: visible, ratio: ratio)
        #expect(
            try alone.download(Float.self, count: visible) == lengths.download(Float.self, count: visible))
        let nodes = try builder.nodeCount
        let theirs = try #require(builder.spacing).download(SIMD2<UInt32>.self, count: nodes)
        #expect(try spacing.cells.download(SIMD2<UInt32>.self, count: nodes) == theirs)
    }

    /// What a run holds on the device, counted from its allocations, is what
    /// `CUDABarnesHutSolver.footprint` works out from the counts: 36 bytes a tracer, the massive
    /// particles and their tree, the sort's chunk, the lists.
    @Test func theMemoryIsWhatTheAllocationsHold() throws {
        let massive = tracedDisk(20_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: tracedDisk(100_000), massive: massive)
        let context = try CUDAContext()
        #expect(context.memoryHeld.now == 0)
        let solver = try CUDABarnesHutSolver(
            context: context, scene: massive, particles: split, tracers: tracers)
        try solver.advance(steps: 1)
        let visible = split.visibleCount - tracers
        let lengths = try context.makeBuffer(length: visible * 4)
        #expect(try solver.writeSmoothing(into: lengths, drawn: visible))
        let held = context.memoryHeld.now - lengths.length
        let paper = CUDABarnesHutSolver.footprint(
            tracers: tracers, massive: solver.host.massive, galaxies: massive.galaxies.count,
            dissipates: solver.host.dissipates)
        print(
            "CUDATRACERS \(tracers) tracers and \(solver.host.massive) massive hold \(held) bytes,"
                + " \(paper.total) on paper: tracers \(paper.tracers), massive \(paper.massive),"
                + " tree \(paper.tree), sort \(paper.sort), lists \(paper.lists);"
                + " \(context.memoryHeld.peak) at the peak")
        #expect(held == paper.total)
        #expect(paper.tracers == tracers * 36)
    }

    // MARK: - On a GPU only (#283)

    /// The scene-0031 draws of the tracer check, at `drawn` from 2 M massive.
    private func scene0031(drawn: Int) throws -> (drawn: SceneConfig, massive: SceneConfig) {
        try TracerCheck.scenes(file: Self.sceneFile, drawn: drawn, massive: 2_000_000)
    }

    /// The checks above at 8 M drawn from 2 M massive, where the walk order comes from the radix
    /// sort: the massive part repeats the run without tracers, and a run resumes to the bit.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func theTracersOf8MRepeatAndResume() throws {
        let scenes = try scene0031(drawn: 8_000_000)
        let context = try CUDAContext()
        let (store, set) = try CUDABarnesHutSolver.lightTracers(
            context: context, drawn: scenes.drawn, massive: scenes.massive)
        let traced = try CUDABarnesHutSolver(
            context: context, scene: scenes.massive, massive: set, tracers: store)
        let reference = try CUDABarnesHutSolver(context: CUDAContext(), scene: scenes.massive, massive: set)
        try traced.advance(steps: 20)
        try reference.advance(steps: 20)
        let tracers = traced.tracerCount
        #expect(bits(Array(traced.particles.positions[tracers...])) == bits(reference.particles.positions))
        #expect(traced.centers == reference.centers)

        let file = temporary("tracers-8m")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try traced.writeParticles(to: handle)
        try handle.close()
        let state = traced.state
        try traced.advance(steps: 20)
        let again = try CUDAContext()
        let resumed = try CUDABarnesHutSolver(
            context: again, scene: scenes.massive, massive: set,
            tracers: CUDALightTracerStore(context: again, capacity: state.count, awaiting: state.tracers))
        let reading = try FileHandle(forReadingFrom: file)
        try resumed.restore(state, from: reading)
        try reading.close()
        try resumed.advance(steps: 20)
        try expectSameRun(traced, resumed, "resumed at 8 M")
    }

    /// A step at 8 M, 50 M and 200 M drawn from 2 M massive (sampling 200 M costs about five
    /// minutes of CPU), phase by phase, the mean of ten steps after two, with the device memory
    /// at its peak against the footprint, on `CUDATRACERS` lines: the walk in ns a tracer a step,
    /// against 21.0 on the M4 Max at 100 M (#238) and #283's own timing of the walk.
    @Test(.enabled(if: onAGPU, needsAGPU), arguments: [8_000_000, 50_000_000, 200_000_000])
    func aStepWithTracersIsTimed(drawn: Int) throws {
        let scenes = try scene0031(drawn: drawn)
        let context = try CUDAContext()
        let sampling = Date()
        let (store, set) = try CUDABarnesHutSolver.lightTracers(
            context: context, drawn: scenes.drawn, massive: scenes.massive)
        let sampled = Date().timeIntervalSince(sampling)
        let solver = try CUDABarnesHutSolver(
            context: context, scene: scenes.massive, massive: set, tracers: store)
        try solver.advance(steps: 2)
        solver.profiling = true
        try solver.advance(steps: 10)
        let profile = solver.takeProfile()
        let lengths = try context.makeBuffer(length: set.visibleCount * 4)
        _ = try solver.writeSmoothing(into: lengths, drawn: set.visibleCount)
        let tracers = solver.tracerCount
        let walk = (profile.milliseconds["tracer force"] ?? 0) / 10
        let sort = (profile.milliseconds["tracer sort"] ?? 0) / 10
        let step = (profile.milliseconds["step"] ?? 0) / 10
        let paper = CUDABarnesHutSolver.footprint(
            tracers: tracers, massive: solver.host.massive, galaxies: scenes.massive.galaxies.count,
            dissipates: solver.host.dissipates)
        print(
            String(
                format: "CUDATRACERS %d tracers from %d massive on %@: a step %.1f ms, the walk %.1f ms"
                    + " (%.2f ns a tracer a step), the sort %.2f ms a step, sampled in %.0f s;"
                    + " memory %.2f GB at the peak, %.2f GB held, %.2f GB on paper",
                tracers, solver.host.massive, context.name, step, walk, walk * 1e6 / Double(tracers), sort,
                sampled, Double(context.memoryHeld.peak) / 1e9, Double(context.memoryHeld.now) / 1e9,
                Double(paper.total + lengths.length) / 1e9))
        #expect(profile.steps == 10)
    }

    // MARK: - Against Metal

    /// Whether the light stays on the mass, as #238 checked on Metal: scene-0031 drawn at 200 k
    /// from 50 k massive by the Mac, stepped here up to the first pericentre. At each of nine
    /// instants the density maps of the tracers against the massive particles are scored as
    /// `scripts/tracer-drift.py` scores them, and both against the Metal run of the same draw;
    /// the tracers' accelerations at step 0 are Metal's to rounding. Two float machines part as
    /// Metal parts from itself a last bit away (`metal-bit-all`). The counts and the steps are the
    /// folder's, so the same test reads #283's runs at 8 M.
    @Test(.enabled(if: tracerRuns != nil, needsTracerRuns))
    func theLightStaysOnTheMassAsOnMetal() throws {
        let folder = URL(fileURLWithPath: try #require(tracerRuns), isDirectory: true)
        let mac = try TracerCheck.Sample.load(folder)
        var scene = try TracerCheck.scenes(
            file: folder.appendingPathComponent("scene.json"), drawn: mac.drawn,
            massive: mac.massive.particles
        ).massive
        print(
            "CUDATRACERS the scene here and on the Mac: step"
                + " \(String(format: "0x%08x", scene.timeStep.bitPattern)) \(mac.massive.timeStepBits),"
                + " softening \(String(format: "0x%08x", scene.softening.bitPattern)) \(mac.massive.softeningBits)"
        )
        scene.timeStep = mac.massive.timeStep
        scene.softening = mac.massive.softening
        scene.openingAngle = mac.massive.openingAngle
        let massive = try RunCheckpoint(directory: folder).massiveSet()
        let tracers = try TracerCheck.tracers(in: folder)
        #expect(massive.count == mac.massive.count && tracers.count == mac.tracers)

        let (wasInterval, wasChunk) = (BarnesHutHost.tracerSortInterval, BarnesHutHost.tracerSortChunk)
        defer { (BarnesHutHost.tracerSortInterval, BarnesHutHost.tracerSortChunk) = (wasInterval, wasChunk) }
        BarnesHutHost.tracerSortInterval = mac.tracerSortInterval
        BarnesHutHost.tracerSortChunk = mac.tracerSortChunk
        let context = try CUDAContext()
        let store = try CUDALightTracerStore(context: context, capacity: tracers.count + massive.count)
        try store.append(tracers)
        let solver = try CUDABarnesHutSolver(context: context, scene: scene, massive: massive, tracers: store)
        solver.tracerOpeningAngle = mac.tracerOpeningAngle
        let engine = CUDAContext.target == .cpu ? "cuda-cpu" : "cuda"
        let out =
            (ProcessInfo.processInfo.environment["SILLAGE_CUDA_CHECKS_OUT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? temporary("tracer-checks")).appendingPathComponent(engine, isDirectory: true)
        let started = Date()
        try TracerCheck.record(
            solver, tracers: tracers.count, sampled: tracers.states.map(\.w) + massive.formation,
            steps: mac.steps, maps: mac.maps, extent: mac.extent,
            snapshots: TracerCheck.snapshots(steps: mac.steps), into: out)
        print(
            String(
                format: "CUDATRACERS %@: %d steps of %d tracers and %d massive in %.0f s, written to %@",
                engine, mac.steps, tracers.count, massive.count, Date().timeIntervalSince(started), out.path))

        let mine = try TracerCheck.Run(out)
        let metal = try TracerCheck.Run(folder.appendingPathComponent("metal"))
        let chaos = try? TracerCheck.Run(folder.appendingPathComponent("metal-bit-all"))
        let theirs = try #require(try metal.accelerations(step: 0))
        let ours = try #require(try mine.accelerations(step: 0))
        let light = SolverCheck.spread(
            Array(theirs[..<tracers.count]), Array(ours[..<tracers.count]), relative: true)
        print(
            String(
                format: "CUDATRACERS the tracers' accelerations at step 0, relative: median %.3g, 99 %% %.3g,"
                    + " most %.3g", light.median, light.high, light.most))
        #expect(light.median < 1e-6 && light.high < 1e-4)

        let counts = (mine.tracers, mine.visible)
        #expect(mine.tracerMaps.count == metal.tracerMaps.count && mine.size == metal.size)
        print(
            "CUDATRACERS instant  Myr   own: chi2 4x4  elsewhere  noise | Metal's own: chi2 4x4  elsewhere"
                + " | against Metal: tracers  massive | Metal a bit away: tracers  massive")
        for index in 0..<min(mine.tracerMaps.count, metal.tracerMaps.count) {
            let own = TracerCheck.score(
                mine.tracerMaps[index], mine.massiveMaps[index], size: mine.size, counts: counts)
            let theirsOwn = TracerCheck.score(
                metal.tracerMaps[index], metal.massiveMaps[index], size: metal.size, counts: counts)
            let across = (
                TracerCheck.score(
                    mine.tracerMaps[index], metal.tracerMaps[index], size: mine.size,
                    counts: (counts.0, counts.0)),
                TracerCheck.score(
                    mine.massiveMaps[index], metal.massiveMaps[index], size: mine.size,
                    counts: (counts.1, counts.1))
            )
            let apart = chaos.map {
                (
                    TracerCheck.score(
                        metal.tracerMaps[index], $0.tracerMaps[index], size: mine.size,
                        counts: (counts.0, counts.0)),
                    TracerCheck.score(
                        metal.massiveMaps[index], $0.massiveMaps[index], size: mine.size,
                        counts: (counts.1, counts.1))
                )
            }
            print(
                String(
                    format:
                        "CUDATRACERS %7d %5.0f   %.3f  %.2f %%  %.2f %%  |  %.3f  %.2f %%  |  %.4f  %.4f  |  %.4f  %.4f",
                    index, index < mine.times.count ? mine.times[index] : .nan, own.chiSquareBinned,
                    own.elsewhere * 100, own.noise * 100, theirsOwn.chiSquareBinned,
                    theirsOwn.elsewhere * 100,
                    across.0.chiSquareBinned, across.1.chiSquareBinned, apart?.0.chiSquareBinned ?? .nan,
                    apart?.1.chiSquareBinned ?? .nan))
            // The light stays on the mass here as on Metal: chi-square a cell near one, the light
            // elsewhere at the noise.
            #expect(own.chiSquareBinned < 1.3 && own.elsewhere < 1.25 * own.noise, "instant \(index)")
            #expect(abs(own.chiSquareBinned - theirsOwn.chiSquareBinned) < 0.15, "instant \(index)")
            // Both sets stay within what chaos alone parts two Metal runs by, three times over.
            if let apart {
                #expect(
                    across.0.chiSquareBinned <= 3 * max(apart.0.chiSquareBinned, 1e-3), "instant \(index)")
                #expect(
                    across.1.chiSquareBinned <= 3 * max(apart.1.chiSquareBinned, 1e-3), "instant \(index)")
            }
        }
    }
}
