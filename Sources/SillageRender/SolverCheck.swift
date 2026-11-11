import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What a run of the massive particles is compared by, one engine against another (#274):
/// the galaxy centres, each disk's thickness, the momentum and the stars formed, sampled along
/// the run, with the positions kept at a few steps. Written by the same code on the Mac, over
/// the Metal solver, and on Linux, over the CUDA one.
public struct SolverCurves: Codable, Sendable {
    public var engine: String
    public var scene: String
    /// Particles the scene was asked for, then what the solver steps and how many it draws.
    public var particles: Int
    public var massive: Int
    public var visible: Int
    /// What the scene worked out on the machine that ran it, for the other to step alike.
    public var timeStep: Float
    public var softening: Float
    public var openingAngle: Float
    public var every: Int
    public var steps: [Int] = []
    public var timeMyr: [Double] = []
    /// Per sample, per galaxy.
    public var centers: [[SIMD3<Float>]] = []
    public var thickness: [[Float]] = []
    public var coherence: [[Float]] = []
    /// The massive particles' total momentum, summed in double.
    public var momentum: [SIMD3<Double>] = []
    /// What the momentum is measured against: the sum of each particle's own.
    public var momentumScale: [Double] = []
    public var formed: [Int] = []
    /// The steps whose positions are in `positions-<step>.bin`, 16 bytes a massive particle.
    public var snapshots: [Int] = []

    public static func load(_ directory: URL) throws -> SolverCurves {
        try JSONDecoder().decode(
            SolverCurves.self, from: Data(contentsOf: directory.appendingPathComponent("curves.json")))
    }

    public static func positions(_ directory: URL, step: Int) throws -> [SIMD3<Float>] {
        let data = try Data(contentsOf: directory.appendingPathComponent(snapshot(step)))
        return data.withUnsafeBytes { Array($0.bindMemory(to: SIMD3<Float>.self)) }
    }

    static func snapshot(_ step: Int) -> String { String(format: "positions-%05d.bin", step) }
}

/// The run both engines make for the comparison of #274, and how two of them are compared.
public enum SolverCheck {
    /// The scene of the comparison as a hires steps it: its file's own step scale, opening
    /// angle and live halos, at `particles` drawn.
    public static func scene(file: URL, particles: Int) throws -> SceneConfig {
        try SceneFile.decoded(from: Data(contentsOf: file)).scene(particleCount: particles)
    }

    /// The steps a run of `steps` keeps its positions at: its ends, and five steps between.
    public static func snapshots(steps: Int) -> [Int] {
        Array(Set([0, steps / 20, steps / 10, steps / 4, steps / 2, steps * 3 / 4, steps])).sorted()
    }

    /// The same particles with one position moved by its last bit: how far a run started from
    /// them drifts from the first is the scale chaos alone gives.
    public static func oneBitMoved(_ particles: ParticleSystem) -> ParticleSystem {
        var moved = particles
        guard !moved.positions.isEmpty else { return moved }
        moved.positions[0].x = moved.positions[0].x.nextUp
        return moved
    }

    /// Every position moved by its last bit: what parts two runs when every particle differs at
    /// rounding, as it does between two engines, and not one particle alone.
    public static func everyBitMoved(_ particles: ParticleSystem) -> ParticleSystem {
        var moved = particles
        for index in moved.positions.indices { moved.positions[index].x = moved.positions[index].x.nextUp }
        return moved
    }

    /// Steps a solver `steps` times through `advance`, sampling its curves every `every` steps
    /// and writing its positions at `snapshots`, then `curves.json`, into `directory`.
    @discardableResult
    public static func record(
        engine: String, scene: SceneConfig, particles asked: Int, host: BarnesHutHost, steps: Int,
        every: Int, snapshots: [Int], into directory: URL, advance: (Int) throws -> Void,
        particles: () throws -> ParticleSystem
    ) throws -> SolverCurves {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var curves = SolverCurves(
            engine: engine, scene: scene.name, particles: asked, massive: host.massive,
            visible: host.massiveVisible, timeStep: scene.timeStep, softening: host.softening,
            openingAngle: host.openingAngle, every: max(every, 1))
        var step = 0
        while true {
            let system = try particles()
            var total = SIMD3<Double>.zero
            var scale = 0.0
            for index in 0..<min(system.count, host.particleMass.count) {
                let weight = Double(host.particleMass[index])
                let velocity = SIMD3<Double>(system.velocities[index])
                total += velocity * weight
                scale += (velocity * velocity).sum().squareRoot() * weight
            }
            curves.steps.append(step)
            curves.timeMyr.append(Double(host.time) * Physics.megayearsPerTimeUnit)
            curves.centers.append(host.centers)
            curves.thickness.append(host.diskFrames.map(\.thickness))
            curves.coherence.append(host.diskFrames.map(\.coherence))
            curves.momentum.append(total)
            curves.momentumScale.append(scale)
            curves.formed.append(system.formation.filter { $0 > 0 && $0 < 1e8 }.count)
            if snapshots.contains(step) {
                try system.positions.withUnsafeBytes { Data($0) }
                    .write(to: directory.appendingPathComponent(SolverCurves.snapshot(step)))
                curves.snapshots.append(step)
            }
            guard step < steps else { break }
            let next = min(curves.every, steps - step)
            try advance(next)
            step += next
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(curves).write(to: directory.appendingPathComponent("curves.json"))
        return curves
    }

    /// How far apart two runs of the same particles stand at one step.
    public struct Gap: Sendable {
        public var step: Int
        public var timeMyr: Double
        /// The distance between the two runs' positions of each drawn particle, in kpc.
        public var median: Float
        public var ninetieth: Float
        public var furthest: Float
        /// The density maps of the drawn particles, chi-square a cell as `tracer-drift.py`
        /// scores two samples of one distribution, at the grid's cells and binned 4 x 4.
        public var chiSquare: Double
        public var chiSquareBinned: Double
        /// The furthest two centres of the same galaxy stand apart, in kpc.
        public var centers: Float
        /// The largest gap between the two runs' thickness of the same disk, as a share of it.
        public var thickness: Float
        /// The gap between the two momenta, against the sum of the particles' own.
        public var momentum: Double
    }

    /// The gaps at every step both runs kept their positions at.
    public static func gaps(
        _ first: URL, _ second: URL, extent: Float = 80, size: Int = 64
    ) throws -> [Gap] {
        let (a, b) = (try SolverCurves.load(first), try SolverCurves.load(second))
        var gaps: [Gap] = []
        for step in a.snapshots where b.snapshots.contains(step) {
            guard let i = a.steps.firstIndex(of: step), let j = b.steps.firstIndex(of: step) else {
                continue
            }
            let (p, q) = (
                try SolverCurves.positions(first, step: step), try SolverCurves.positions(second, step: step)
            )
            let drawn = min(a.visible, b.visible, p.count, q.count)
            var apart = (0..<drawn).map { simd_distance(p[$0], q[$0]) }
            apart.sort()
            func quantile(_ share: Double) -> Float {
                apart.isEmpty ? 0 : apart[min(Int(Double(apart.count) * share), apart.count - 1)]
            }
            let (m, n) = (counts(p, drawn, extent, size), counts(q, drawn, extent, size))
            var centers: Float = 0
            for galaxy in 0..<min(a.centers[i].count, b.centers[j].count) {
                centers = max(centers, simd_distance(a.centers[i][galaxy], b.centers[j][galaxy]))
            }
            var thickness: Float = 0
            for galaxy in 0..<min(a.thickness[i].count, b.thickness[j].count) {
                let reference = max(a.thickness[i][galaxy], 1e-6)
                thickness = max(thickness, abs(b.thickness[j][galaxy] - a.thickness[i][galaxy]) / reference)
            }
            let momentum = a.momentum[i] - b.momentum[j]
            gaps.append(
                Gap(
                    step: step, timeMyr: a.timeMyr[i], median: quantile(0.5), ninetieth: quantile(0.9),
                    furthest: apart.last ?? 0, chiSquare: chiSquare(m, n),
                    chiSquareBinned: chiSquare(binned(m, size, 4), binned(n, size, 4)), centers: centers,
                    thickness: thickness,
                    momentum: (momentum * momentum).sum().squareRoot() / max(a.momentumScale[i], 1e-30)))
        }
        return gaps
    }

    /// The first `drawn` positions counted on a square grid in the xy plane, as `DensityMap`.
    static func counts(_ positions: [SIMD3<Float>], _ drawn: Int, _ extent: Float, _ size: Int) -> [Double] {
        var map = [Double](repeating: 0, count: size * size)
        let scale = Float(size) / (2 * extent)
        for index in 0..<drawn {
            let x = Int(((positions[index].x + extent) * scale).rounded(.down))
            let y = Int(((positions[index].y + extent) * scale).rounded(.down))
            guard x >= 0, x < size, y >= 0, y < size else { continue }
            map[y * size + x] += 1
        }
        return map
    }

    static func binned(_ map: [Double], _ size: Int, _ factor: Int) -> [Double] {
        let side = size / factor
        var coarse = [Double](repeating: 0, count: side * side)
        for y in 0..<side * factor {
            for x in 0..<side * factor { coarse[(y / factor) * side + x / factor] += map[y * size + x] }
        }
        return coarse
    }

    /// Chi-square a cell of two maps of counts against their own Poisson noise, over the cells
    /// that hold 20 or more between them: `chi2` of `scripts/tracer-drift.py`, with as many
    /// particles in each map.
    static func chiSquare(_ a: [Double], _ b: [Double], floor: Double = 20) -> Double {
        var total = 0.0
        var kept = 0
        for index in 0..<min(a.count, b.count) where a[index] + b[index] >= floor {
            let expected = (a[index] + b[index]) / 2
            let (first, second) = (a[index] - expected, b[index] - expected)
            total += (first * first + second * second) / expected
            kept += 1
        }
        return total / Double(max(kept, 1))
    }
}
