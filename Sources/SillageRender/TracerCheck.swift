import Foundation
import SillageCore

/// The run both engines make for the light tracers' comparison of #275, as #238 checked them on
/// Metal: a draw with light tracers stepped up to the first pericentre, with the density maps of
/// the tracers and of the massive visible particles that `scripts/tracer-drift.py` scores. The
/// Mac draws once and writes the draw beside its runs, and the CUDA run reads it: a draw made on
/// Linux is the Mac's to rounding, not to the bit (#272).
///
/// A draw is a folder: `scene.json`, `sample.json`, `massive.bin` (`RunCheckpoint.saveMassive`)
/// and `tracers.bin`, the tracers as drawn, before any kick: every state, then every motion, 16
/// bytes each, as `LightTracerChunk` holds them. A run is a folder in it: `run.log`, with the
/// lines `tracer-drift.py` reads; `density.tracers.npy` and `density.massive.npy`; `curves.csv`
/// (`SolverCurves`, tracers included, which weigh nothing); `accelerations-<step>.bin`, tracers
/// first, 16 bytes each; and at the snapshots a checkpoint's `particles-<step>.bin` and
/// `state-<step>.json`. The Mac's are on branch `assets/cuda-checks`.
public enum TracerCheck {
    /// What the Mac drew and how it ran it, `sample.json`.
    public struct Sample: Codable, Sendable {
        /// The massive scene and the solver's settings, as the solver check writes them: its
        /// `particles` is the massive count the scene was built for.
        public var massive: SolverCheck.Sample
        public var drawn: Int
        public var tracers: Int
        public var tracerOpeningAngle: Float
        public var tracerOpeningAngleBits: String
        public var tracerSortInterval: Int
        public var tracerSortChunk: Int
        public var steps: Int
        public var maps: Int
        public var extent: Float

        public init(
            scenes: (drawn: SceneConfig, massive: SceneConfig), massive set: ParticleSystem,
            particles: (drawn: Int, massive: Int), tracers: Int, steps: Int, maps: Int,
            extent: Float
        ) {
            massive = SolverCheck.Sample(scene: scenes.massive, sample: set, particles: particles.massive)
            drawn = particles.drawn
            self.tracers = tracers
            tracerOpeningAngle = scenes.massive.openingAngle
            tracerOpeningAngleBits = String(format: "0x%08x", scenes.massive.openingAngle.bitPattern)
            tracerSortInterval = BarnesHutHost.tracerSortInterval
            tracerSortChunk = BarnesHutHost.tracerSortChunk
            self.steps = steps
            self.maps = maps
            self.extent = extent
        }

        public static func load(_ folder: URL) throws -> Sample {
            try JSONDecoder().decode(
                Sample.self, from: Data(contentsOf: folder.appendingPathComponent("sample.json")))
        }
    }

    /// The two scenes `sillage-render hires --particles drawn --massive massive` builds from a
    /// scene file: the draw, whose disks drawn for their response hold at the massive softening,
    /// and the massive count's, whose softening and step the run takes.
    public static func scenes(file: URL, drawn: Int, massive: Int) throws -> (
        drawn: SceneConfig, massive: SceneConfig
    ) {
        var file = try SceneFile.decoded(from: Data(contentsOf: file))
        file.solver = .barnesHut
        let heavy = file.scene(particleCount: massive)
        var light = file.scene(particleCount: drawn)
        light.solveToomreQ(softening: heavy.softening)
        return (light, heavy)
    }

    /// The draw `MetalBarnesHutSolver.lightTracers` makes, the tracers kept in one chunk.
    public static func draw(drawn: SceneConfig, massive: SceneConfig) -> (
        tracers: LightTracerChunk, massive: ParticleSystem
    ) {
        var all = LightTracerChunk()
        let (set, _) = ParticleSystem.streamingLightTracers(drawn: drawn, massive: massive) { chunk in
            all.states += chunk.states
            all.motions += chunk.motions
        }
        return (all, set)
    }

    /// Writes the draw into `folder`, with the scene file it came from.
    public static func save(
        _ sample: Sample, tracers: LightTracerChunk, massive: ParticleSystem, scene: URL,
        into folder: URL
    ) throws {
        try RunCheckpoint(directory: folder).saveMassive(massive)
        var data = tracers.states.withUnsafeBytes { Data($0) }
        tracers.motions.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: folder.appendingPathComponent("tracers.bin"))
        try SolverCheck.encoder.encode(sample).write(to: folder.appendingPathComponent("sample.json"))
        try Data(contentsOf: scene).write(to: folder.appendingPathComponent("scene.json"))
    }

    /// The tracers of a draw's `tracers.bin`.
    public static func tracers(in folder: URL) throws -> LightTracerChunk {
        let data = try Data(contentsOf: folder.appendingPathComponent("tracers.bin"))
        guard data.count % 32 == 0 else { throw RunCheckpointError.truncated }
        let count = data.count / 32
        var chunk = LightTracerChunk()
        data.withUnsafeBytes { raw in
            chunk.states = (0..<count).map {
                raw.loadUnaligned(fromByteOffset: $0 * 16, as: SIMD4<Float>.self)
            }
            chunk.motions = (0..<count).map {
                raw.loadUnaligned(fromByteOffset: (count + $0) * 16, as: SIMD4<UInt32>.self)
            }
        }
        return chunk
    }

    /// The same tracers with every x moved to the next float up, as `SolverCheck.nudged` moves
    /// the massive particles.
    public static func nudged(_ tracers: LightTracerChunk) -> LightTracerChunk {
        var moved = tracers
        for index in moved.states.indices { moved.states[index].x = moved.states[index].x.nextUp }
        return moved
    }

    /// The steps a run of `steps` keeps a checkpoint and the accelerations at.
    public static func snapshots(steps: Int) -> Set<Int> {
        Set([1, steps].filter { $0 >= 1 && $0 <= steps })
    }

    /// Steps `solver`, whose first `tracers` particles are light tracers, `steps` times and writes
    /// its run into `out`: a line of `curves.csv` every `every` steps, `maps` density maps of each
    /// set spread from step 0 to the last over a square of half side `extent`, and at step 0 and
    /// `snapshots` the accelerations, with a checkpoint's files past step 0. `sampled` is the
    /// formation time each particle was drawn with, tracers first.
    public static func record(
        _ solver: some CheckedSolver, tracers: Int, sampled: [Float], steps: Int, maps: Int = 9,
        extent: Float = 60, every: Int = 10, snapshots: Set<Int> = [], into out: URL
    ) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log = ""
        var curves = SolverCurves.header(galaxies: solver.scene.galaxies.count)
        var light = DensityMap(frames: steps + 1, count: maps, extent: extent)
        var heavy = light
        for step in 0...steps {
            if step > 0 { try solver.stepChecked() }
            let lined = step % max(every, 1) == 0
            let mapped = light.wants(frame: step)
            let kept = step == 0 || snapshots.contains(step)
            guard lined || mapped || kept else { continue }
            let particles = solver.particles
            let visible = particles.visibleCount - tracers
            if step == 0 {
                log += String(
                    format: "tracers    %d light, %d massive visible, %d halo\n", tracers, visible,
                    particles.count - particles.visibleCount)
            }
            if lined {
                curves += SolverCurves.line(
                    step: step, time: solver.time, particles: particles, sampled: sampled,
                    centers: solver.centers, disks: solver.diskFrames)
            }
            if mapped {
                particles.positions.withUnsafeBufferPointer {
                    light.add($0.baseAddress!, count: tracers)
                    heavy.add($0.baseAddress! + tracers, count: visible)
                }
                log += String(
                    format: "drift      frame %d t=%.1f Myr\n", step,
                    Double(solver.time) * Physics.megayearsPerTimeUnit)
            }
            guard kept else { continue }
            if step > 0 {
                let url = out.appendingPathComponent("particles-\(step).bin")
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try solver.writeParticles(to: handle)
                try handle.close()
                try SolverCheck.encoder.encode(solver.state).write(
                    to: out.appendingPathComponent("state-\(step).json"))
            }
            var packed = [Float]()
            for value in try solver.forces() { packed += [value.x, value.y, value.z, 0] }
            try packed.withUnsafeBufferPointer { Data(buffer: $0) }.write(
                to: out.appendingPathComponent("accelerations-\(step).bin"))
        }
        try Data(log.utf8).write(to: out.appendingPathComponent("run.log"))
        try Data(curves.utf8).write(to: out.appendingPathComponent("curves.csv"))
        try light.npy().write(to: out.appendingPathComponent("density.tracers.npy"))
        try heavy.npy().write(to: out.appendingPathComponent("density.massive.npy"))
    }

    // MARK: - Reading and scoring

    /// A run read back: its counts, its maps and the accelerations it kept.
    public struct Run {
        public let folder: URL
        public var tracers = 0
        public var visible = 0
        public var times: [Double] = []
        public var size = 0
        public var tracerMaps: [[Float]] = []
        public var massiveMaps: [[Float]] = []

        public init(_ folder: URL) throws {
            self.folder = folder
            let log = try String(contentsOf: folder.appendingPathComponent("run.log"), encoding: .utf8)
            for line in log.split(separator: "\n") {
                let words = line.split(separator: " ")
                if words.first == "tracers", words.count > 4 {
                    tracers = Int(words[1]) ?? 0
                    visible = Int(words[3]) ?? 0
                } else if words.first == "drift", let time = words.first(where: { $0.hasPrefix("t=") }) {
                    times.append(Double(time.dropFirst(2)) ?? .nan)
                }
            }
            (size, tracerMaps) = SolverCheck.maps(
                npy: try Data(contentsOf: folder.appendingPathComponent("density.tracers.npy")))
            (_, massiveMaps) = SolverCheck.maps(
                npy: try Data(contentsOf: folder.appendingPathComponent("density.massive.npy")))
        }

        /// Tracers first, then the massive particles, at a step the run kept.
        public func accelerations(step: Int) throws -> [SIMD3<Float>]? {
            let url = folder.appendingPathComponent("accelerations-\(step).bin")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bytes = [UInt8](try Data(contentsOf: url))
            return bytes.withUnsafeBytes { raw in
                (0..<bytes.count / 16).map {
                    raw.loadUnaligned(fromByteOffset: $0 * 16, as: SIMD3<Float>.self)
                }
            }
        }

        /// Every particle's position in a checkpoint the run kept, tracers first.
        public func positions(step: Int) throws -> [SIMD3<Float>]? {
            let url = folder.appendingPathComponent("particles-\(step).bin")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bytes = [UInt8](try Data(contentsOf: url))
            return bytes.withUnsafeBytes { raw in
                (0..<bytes.count / 36).map {
                    raw.loadUnaligned(fromByteOffset: $0 * 16, as: SIMD3<Float>.self)
                }
            }
        }
    }

    /// How one instant's maps of two sets compare, as `scripts/tracer-drift.py` scores them.
    public struct Score: Sendable {
        /// Chi-square a cell against the Poisson noise of both, at the grid's cells and binned 4 x 4,
        /// over the cells holding 20 counts or more. Near 1 for two draws of one distribution.
        public var chiSquare = 0.0
        public var chiSquareBinned = 0.0
        /// The share of the light that sits elsewhere, binned 4 x 4, and the share Poisson noise
        /// alone would move.
        public var elsewhere = 0.0
        public var noise = 0.0
    }

    /// `first` and `second` are maps of `size` x `size` as shares of `counts.0` and `counts.1`.
    public static func score(
        _ first: [Float], _ second: [Float], size: Int, counts: (Int, Int)
    ) -> Score {
        let (a, b) = (first.map(Double.init), second.map(Double.init))
        let (bigA, bigB) = (binned(a, size: size), binned(b, size: size))
        var score = Score()
        score.chiSquare = chiSquare(a, b, counts: counts)
        score.chiSquareBinned = chiSquare(bigA, bigB, counts: counts)
        let (totalA, totalB) = (bigA.reduce(0, +), bigB.reduce(0, +))
        guard totalA > 0, totalB > 0 else { return score }
        var shift = 0.0
        var sigma = 0.0
        for cell in bigA.indices {
            let (x, y) = (bigA[cell] / totalA, bigB[cell] / totalB)
            shift += abs(x - y)
            let mean = 0.5 * (x + y)
            sigma += (mean / (Double(counts.0) * totalA) + mean / (Double(counts.1) * totalB)).squareRoot()
        }
        score.elsewhere = 0.5 * shift
        score.noise = 0.5 * (2 / Double.pi).squareRoot() * sigma
        return score
    }

    private static func chiSquare(_ a: [Double], _ b: [Double], counts: (Int, Int)) -> Double {
        let (nA, nB) = (Double(counts.0), Double(counts.1))
        var total = 0.0
        var kept = 0
        for cell in a.indices {
            let (x, y) = (a[cell] * nA, b[cell] * nB)
            guard x + y >= 20 else { continue }
            let expected = (x + y) / (nA + nB)
            let (ex, ey) = (expected * nA, expected * nB)
            total += (x - ex) * (x - ex) / max(ex, 1e-12) + (y - ey) * (y - ey) / max(ey, 1e-12)
            kept += 1
        }
        return total / Double(max(kept, 1))
    }

    private static func binned(_ map: [Double], size: Int, factor: Int = 4) -> [Double] {
        let side = size / factor
        var out = [Double](repeating: 0, count: side * side)
        for y in 0..<side * factor {
            for x in 0..<side * factor { out[(y / factor) * side + x / factor] += map[y * size + x] }
        }
        return out
    }
}
