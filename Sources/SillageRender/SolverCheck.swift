import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What the check asks of a solver of massive particles (#274): `MetalBarnesHutSolver` on the
/// Mac and `CUDABarnesHutSolver` on Linux.
public protocol CheckedSolver: Solver {
    var diskFrames: [DiskState] { get }
    var state: SolverState { get }
    func writeParticles(to handle: FileHandle) throws
    /// The accelerations the last force pass left, one a massive particle.
    func forces() throws -> [SIMD3<Float>]
    /// One step, throwing what the engine left behind.
    func stepChecked() throws
}

/// The curves a solver check compares between engines (#274): one line a sampled step, from
/// what any solver gives of its massive particles. No Metal here, so both engines write the
/// same numbers.
public enum SolverCurves {
    static let perGalaxy = [
        "cx", "cy", "cz", "thickness", "coherence", "disruption", "torn", "ax", "ay", "az",
    ]

    public static func header(galaxies: Int) -> String {
        var columns = ["step", "time"]
        for galaxy in 0..<galaxies { columns += perGalaxy.map { "\($0)_\(galaxy)" } }
        columns += ["px", "py", "pz", "mx", "my", "mz", "formed"]
        return columns.joined(separator: ",") + "\n"
    }

    /// `particles` laid out `[visible | halo]` as the solver holds them now; `sampled` is the
    /// formation time each was sampled with.
    public static func line(
        step: Int, time: Float, particles: ParticleSystem, sampled: [Float],
        centers: [SIMD3<Float>], disks: [DiskState]
    ) -> String {
        func f(_ value: Float) -> String { String(format: "%.9g", Double(value)) }
        func d(_ value: Double) -> String { String(format: "%.17g", value) }
        var fields = ["\(step)", f(time)]
        for galaxy in centers.indices {
            let centre = centers[galaxy]
            let disk = galaxy < disks.count ? disks[galaxy] : DiskState(axis: .zero)
            fields += [
                f(centre.x), f(centre.y), f(centre.z), f(disk.thickness), f(disk.coherence),
                f(disk.disruption), f(disk.torn), f(disk.axis.x), f(disk.axis.y), f(disk.axis.z),
            ]
        }
        // Summed in double, in index order, a component at a time.
        var momentum = (0.0, 0.0, 0.0)
        var moment = (0.0, 0.0, 0.0)
        var total = 0.0
        for index in 0..<particles.count {
            let mass = Double(particles.mass[index])
            let velocity = particles.velocities[index]
            let position = particles.positions[index]
            momentum.0 += mass * Double(velocity.x)
            momentum.1 += mass * Double(velocity.y)
            momentum.2 += mass * Double(velocity.z)
            moment.0 += mass * Double(position.x)
            moment.1 += mass * Double(position.y)
            moment.2 += mass * Double(position.z)
            total += mass
        }
        let scale = total > 0 ? 1 / total : 0
        fields += [d(momentum.0), d(momentum.1), d(momentum.2)]
        fields += [d(moment.0 * scale), d(moment.1 * scale), d(moment.2 * scale)]
        var formed = 0
        for index in 0..<min(particles.visibleCount, sampled.count)
        where particles.formation[index].bitPattern != sampled[index].bitPattern {
            formed += 1
        }
        fields.append("\(formed)")
        return fields.joined(separator: ",") + "\n"
    }

    /// The visible particles counted on the xy grid at each of `instants` sampled steps.
    public static func maps(instants: Int, extent: Float = 80) -> DensityMap {
        DensityMap(frames: instants, count: instants, extent: extent)
    }
}

/// The run both engines make for the comparison of #274, and how far two of them stand apart.
/// A run is a folder: `curves.csv`, `density.npy`, and where asked `particles-<step>.bin`,
/// `state-<step>.json` and `accelerations-<step>.bin`. The Mac's are on branch
/// `assets/cuda-checks` with their formats; `scripts/solver-compare.py` prints two side by side.
public enum SolverCheck {
    /// What the Mac worked out of the scene and wrote beside its sample, `sample.json`: the
    /// other engine steps with the same.
    public struct Sample: Codable, Sendable {
        public var particles: Int
        public var count: Int
        public var visible: Int
        public var timeStep: Float
        public var timeStepBits: String
        public var softening: Float
        public var softeningBits: String
        public var openingAngle: Float
        public var openingAngleBits: String
        public var centerSoftening: Float
        public var megayearsPerStep: Double
        public var forceChunk: Int
        public var leafCapacity: Int
        public var maximumTreeDepth: Int
        public var treeReuse: Int
        public var quadrupole: Bool
        public var frameSample: Int
        public var tidalFloor: Float
        public var tidalCeiling: Float

        public init(scene: SceneConfig, sample: ParticleSystem, particles: Int) {
            func bits(_ value: Float) -> String { String(format: "0x%08x", value.bitPattern) }
            self.particles = particles
            count = sample.count
            visible = sample.visibleCount
            timeStep = scene.timeStep
            timeStepBits = bits(scene.timeStep)
            softening = scene.softening
            softeningBits = bits(scene.softening)
            openingAngle = scene.openingAngle
            openingAngleBits = bits(scene.openingAngle)
            centerSoftening = scene.centerSoftening
            megayearsPerStep = Double(scene.timeStep) * Physics.megayearsPerTimeUnit
            forceChunk = BarnesHutHost.forceChunk
            leafCapacity = BarnesHutHost.leafCapacity
            maximumTreeDepth = BarnesHutHost.maximumTreeDepth
            treeReuse = BarnesHutHost.treeReuse
            quadrupole = BarnesHutHost.quadrupole
            frameSample = BarnesHutHost.frameSample
            tidalFloor = BarnesHutHost.tidalFloor
            tidalCeiling = BarnesHutHost.tidalCeiling
        }

        public static func load(_ folder: URL) throws -> Sample {
            try JSONDecoder().decode(
                Sample.self, from: Data(contentsOf: folder.appendingPathComponent("sample.json")))
        }

        public func write(into folder: URL) throws {
            try SolverCheck.encoder.encode(self).write(to: folder.appendingPathComponent("sample.json"))
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    /// The scene as `sillage-render` builds it from a scene file for the Barnes-Hut solver, at
    /// `particles` drawn.
    public static func scene(file: URL, particles: Int) throws -> SceneConfig {
        var file = try SceneFile.decoded(from: Data(contentsOf: file))
        file.solver = .barnesHut
        return file.scene(particleCount: particles)
    }

    /// The same particles with one x moved to the next float up, or every one with `nil`: how
    /// far a run started from them drifts from the first is the scale chaos alone gives.
    public static func nudged(_ particles: ParticleSystem, _ which: Int?) -> ParticleSystem {
        var moved = particles
        for index in moved.positions.indices where which == nil || which == index {
            moved.positions[index].x = moved.positions[index].x.nextUp
        }
        return moved
    }

    /// The steps a run of `steps` keeps its particles and accelerations at.
    public static func snapshots(steps: Int) -> Set<Int> {
        Set([1, 10, 100, steps / 2, steps].filter { $0 >= 1 && $0 <= steps })
    }

    /// Steps `solver` `steps` times and writes its run into `out`: a line of `curves.csv` every
    /// `every` steps, a density map every `mapsEvery`, and at `snapshots` what a checkpoint
    /// holds and the accelerations, those of step 0 with them. `sampled` is the formation time
    /// each particle was sampled with.
    public static func record(
        _ solver: some CheckedSolver, sampled: [Float], steps: Int, every: Int = 10,
        mapsEvery: Int = 250, snapshots: Set<Int> = [], into out: URL
    ) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var curves = SolverCurves.header(galaxies: solver.scene.galaxies.count)
        var maps = SolverCurves.maps(instants: steps / max(mapsEvery, 1) + 1)
        for step in 0...steps {
            if step > 0 { try solver.stepChecked() }
            let lined = step % max(every, 1) == 0
            let mapped = step % max(mapsEvery, 1) == 0
            let kept = snapshots.contains(step) || (step == 0 && !snapshots.isEmpty)
            guard lined || mapped || kept else { continue }
            let particles = solver.particles
            if lined {
                curves += SolverCurves.line(
                    step: step, time: solver.time, particles: particles, sampled: sampled,
                    centers: solver.centers, disks: solver.diskFrames)
            }
            if mapped {
                particles.positions.withUnsafeBufferPointer {
                    maps.add($0.baseAddress!, count: particles.visibleCount)
                }
            }
            guard kept else { continue }
            if step > 0 {
                let url = out.appendingPathComponent("particles-\(step).bin")
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try solver.writeParticles(to: handle)
                try handle.close()
                try encoder.encode(solver.state).write(
                    to: out.appendingPathComponent("state-\(step).json"))
            }
            // Three floats a particle, the fourth zeroed: the buffer's own is not the force.
            let forces = try solver.forces()
            var packed = [Float](repeating: 0, count: forces.count * 4)
            for (index, value) in forces.enumerated() {
                packed[index * 4] = value.x
                packed[index * 4 + 1] = value.y
                packed[index * 4 + 2] = value.z
            }
            try packed.withUnsafeBufferPointer { Data(buffer: $0) }.write(
                to: out.appendingPathComponent("accelerations-\(step).bin"))
        }
        try Data(curves.utf8).write(to: out.appendingPathComponent("curves.csv"))
        try maps.npy().write(to: out.appendingPathComponent("density.npy"))
    }

    // MARK: - Two runs side by side

    /// A run read back: its curves by column, and its maps.
    public struct Run {
        public let folder: URL
        public var curves: [String: [Double]] = [:]
        public var maps: [[Float]] = []
        public var size = 0

        public init(_ folder: URL) throws {
            self.folder = folder
            let text = try String(
                contentsOf: folder.appendingPathComponent("curves.csv"), encoding: .utf8)
            let lines = text.split(separator: "\n")
            let names = lines.first.map { $0.split(separator: ",").map(String.init) } ?? []
            for name in names { curves[name] = [] }
            for line in lines.dropFirst() {
                for (name, field) in zip(names, line.split(separator: ",")) {
                    curves[name]?.append(Double(field) ?? .nan)
                }
            }
            // A NumPy array of float32, shaped (maps, size, size).
            let data = try Data(contentsOf: folder.appendingPathComponent("density.npy"))
            guard data.count > 10 else { return }
            let header = Int(data[data.startIndex + 8]) | Int(data[data.startIndex + 9]) << 8
            let described = String(decoding: data.dropFirst(10).prefix(header), as: UTF8.self)
            let shape = described.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard shape.count >= 3, let side = shape.last, side > 0 else { return }
            size = side
            let body = [UInt8](data.dropFirst(10 + header))
            let values = body.withUnsafeBytes { raw in
                (0..<body.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            for index in 0..<values.count / (side * side) {
                maps.append(Array(values[index * side * side..<(index + 1) * side * side]))
            }
        }

        public var steps: [Int] { (curves["step"] ?? []).map { Int($0) } }
        public var galaxies: Int { curves.keys.filter { $0.hasPrefix("cx_") }.count }

        /// The first 16 bytes of each record of a file kept at `step`: a checkpoint's positions
        /// (36 bytes a particle in all), or the accelerations.
        private func vectors(_ name: String, step: Int, record: Int) throws -> [SIMD3<Float>]? {
            let url = folder.appendingPathComponent("\(name)-\(step).bin")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bytes = [UInt8](try Data(contentsOf: url))
            return bytes.withUnsafeBytes { raw in
                (0..<bytes.count / record).map {
                    raw.loadUnaligned(fromByteOffset: $0 * 16, as: SIMD3<Float>.self)
                }
            }
        }

        public func positions(step: Int) throws -> [SIMD3<Float>]? {
            try vectors("particles", step: step, record: 36)
        }

        public func accelerations(step: Int) throws -> [SIMD3<Float>]? {
            try vectors("accelerations", step: step, record: 16)
        }
    }

    /// The most each measure reaches along two runs of the same particles, as
    /// `scripts/solver-compare.py` takes them.
    public struct Gap: Sendable {
        /// The furthest two centres of a galaxy stand apart, in kpc.
        public var centers = 0.0
        /// The largest gap between the two thicknesses of a disk.
        public var thickness = 0.0
        public var momentum = 0.0
        /// The largest gap in the stars formed so far.
        public var formed = 0.0
        /// Chi-square a cell of the density maps against Poisson noise, cells binned 4 x 4 and
        /// kept from 20 counts, the largest over the maps.
        public var chiSquare = 0.0

        /// Each measure the larger of the two.
        public func envelope(_ other: Gap) -> Gap {
            var widest = self
            widest.centers = max(centers, other.centers)
            widest.thickness = max(thickness, other.thickness)
            widest.momentum = max(momentum, other.momentum)
            widest.formed = max(formed, other.formed)
            widest.chiSquare = max(chiSquare, other.chiSquare)
            return widest
        }
    }

    public static func gap(_ a: Run, _ b: Run, visible: Int) -> Gap {
        var gap = Gap()
        func apart(_ names: [String]) -> Double {
            let columns = names.map { (a.curves[$0] ?? [], b.curves[$0] ?? []) }
            let rows = columns.map { min($0.0.count, $0.1.count) }.min() ?? 0
            var most = 0.0
            for row in 0..<rows {
                var sum = 0.0
                for (first, second) in columns {
                    sum += (first[row] - second[row]) * (first[row] - second[row])
                }
                most = max(most, sum.squareRoot())
            }
            return most
        }
        for galaxy in 0..<min(a.galaxies, b.galaxies) {
            gap.centers = max(gap.centers, apart(["cx_\(galaxy)", "cy_\(galaxy)", "cz_\(galaxy)"]))
            gap.thickness = max(gap.thickness, apart(["thickness_\(galaxy)"]))
        }
        gap.momentum = apart(["px", "py", "pz"])
        gap.formed = apart(["formed"])
        guard a.size == b.size, a.size > 0, a.size % 4 == 0 else { return gap }
        let side = a.size / 4
        for index in 0..<min(a.maps.count, b.maps.count) {
            var first = [Double](repeating: 0, count: side * side)
            var second = first
            for y in 0..<a.size {
                for x in 0..<a.size {
                    let cell = (y / 4) * side + x / 4
                    first[cell] += Double(a.maps[index][y * a.size + x]) * Double(visible)
                    second[cell] += Double(b.maps[index][y * a.size + x]) * Double(visible)
                }
            }
            var total = 0.0
            var kept = 0
            for cell in first.indices where first[cell] + second[cell] >= 20 {
                let difference = first[cell] - second[cell]
                total += difference * difference / (first[cell] + second[cell])
                kept += 1
            }
            gap.chiSquare = max(gap.chiSquare, kept > 0 ? total / Double(kept) : 0)
        }
        return gap
    }

    /// The median, the 99th percentile and the largest of how far apart two sets of vectors
    /// stand, over the first `count` of them, each as a share of the first's length when
    /// `relative`.
    public static func spread(
        _ a: [SIMD3<Float>], _ b: [SIMD3<Float>], count: Int? = nil, relative: Bool = false
    ) -> (median: Double, high: Double, most: Double) {
        let wanted = min(count ?? a.count, a.count, b.count)
        var apart = (0..<wanted).map { index -> Double in
            let difference = SIMD3<Double>(a[index]) - SIMD3<Double>(b[index])
            let length = (difference * difference).sum().squareRoot()
            guard relative else { return length }
            let own = SIMD3<Double>(a[index])
            return length / max((own * own).sum().squareRoot(), 1e-30)
        }
        apart.sort()
        guard let most = apart.last else { return (0, 0, 0) }
        return (apart[apart.count / 2], apart[min(Int(Double(apart.count) * 0.99), apart.count - 1)], most)
    }
}
