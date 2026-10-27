import Foundation

public enum SolverKind: String, Codable, Sendable, CaseIterable {
    /// Massless test particles in rigid analytic potentials. O(N), the Toomre 1972 model.
    case restricted
    /// Self-gravitating particles on a Barnes-Hut tree. O(N log N).
    case barnesHut

    public var displayName: String {
        switch self {
        case .restricted: "Restricted (test particles)"
        case .barnesHut: "Barnes-Hut (self-gravitating)"
        }
    }

    public var isImplemented: Bool { true }

    /// Level 2 needs disks in Toomre equilibrium and a much smaller time step.
    public var isSelfGravitating: Bool { self == .barnesHut }
}

public struct SceneConfig: Codable, Sendable, Equatable {
    public var name: String
    public var galaxies: [GalaxyConfig]
    public var solver: SolverKind
    public var seed: UInt64
    public var timeStep: Float
    /// Softening applied to the galaxy-galaxy pair force, in kpc.
    public var centerSoftening: Float
    /// Barnes-Hut opening angle. Smaller is more accurate and slower. An accepted cell adds its
    /// quadrupole to its monopole, which makes 0.9 as accurate as the monopole alone was at
    /// 0.7 (#37). Mean force error against direct summation at a million simulated particles,
    /// and the force pass of `--baseline` at five million visible:
    ///
    ///     theta              merger t=0   disk 400 Myr   merger 360 Myr   force pass
    ///     0.7 monopole         0.43 %        0.58 %          0.63 %         362 ms
    ///     0.9 quadrupole       0.48 %        0.42 %          0.37 %         231 ms
    ///
    /// Momentum drift used to choose this angle, and with the quadrupole it no longer follows
    /// the error. Between two similar cells the monopole's leading error cancels and the
    /// quadrupole's does not, so total momentum drifts two to seven times as fast at 0.9 as at
    /// 0.7. What an encounter shows is the orbit, and the orbit follows the error: over
    /// 400 Myr a merger's separation stays 1.4 to 4 times closer to a run at 0.4 than the
    /// monopole's at 0.7 did, on every seed tried from 12 000 to 200 000 visible particles.
    ///
    /// Small-scale structure does not pay for a wider angle, and the reason is worth stating:
    /// an opening angle only decides how far a cell must be before its moments stand in for
    /// it, so it approximates the *far* field. Clumping is set by the near field, summed
    /// particle by particle inside a leaf whatever this is. The clumping measure holds flat
    /// across 0.6, 0.85 and 1.0 — unlike a stale tree, which corrupts the near grouping itself
    /// and takes forty per cent of it.
    public var openingAngle: Float
    /// Force softening between particles, in kpc. It should sit near the mean interparticle
    /// separation: too small and two-body encounters heat the disk, too large and structure
    /// is washed out.
    public var softening: Float
    /// Multiplies the automatic step. The automatic value is chosen for a run worth keeping;
    /// while a scene is being set up what matters is reaching the interesting moment, and
    /// measurement says there is room. On an isolated self-gravitating disk the radial
    /// profile after 40 Myr stays within 0.3 % of a reference run at a quarter of the
    /// automatic step all the way out to 16 times it, and within 1 % at 32. A close
    /// encounter reaches higher speeds than an isolated disk, so it deserves more caution.
    public var timeStepScale: Float = 1
    /// The encounters the galaxies were placed from, if they were. `placeEncounters` turns
    /// them into positions and velocities; the solver reads only those.
    public var encounters: [Encounter] = []
    /// How a generator drew the scene, when one did.
    public var draw: SceneDraw?

    public init(
        name: String,
        galaxies: [GalaxyConfig],
        solver: SolverKind = .barnesHut,
        seed: UInt64 = 1,
        timeStep: Float = 0.01,
        centerSoftening: Float = 0.5,
        openingAngle: Float = 0.9,
        softening: Float = 0.09
    ) {
        self.name = name
        self.galaxies = galaxies
        self.solver = solver
        self.seed = seed
        self.timeStep = timeStep
        self.centerSoftening = centerSoftening
        self.openingAngle = openingAngle
        self.softening = softening
    }

    /// Visible particles only, which is what the setup screen and the renderer count.
    public var totalParticleCount: Int {
        galaxies.reduce(0) { $0 + $1.particleCount }
    }

    /// Everything the solver integrates, halo particles included.
    public var simulatedParticleCount: Int {
        solver.isSelfGravitating
            ? galaxies.reduce(0) { $0 + $1.particleCount + $1.haloParticleCount }
            : totalParticleCount
    }

    /// Softening scaled to the mean interparticle spacing of the densest disk. Too small and
    /// two-body encounters heat the disk artificially; too large and real structure is washed
    /// out. Derived rather than exposed, because nobody can guess it.
    public var recommendedSoftening: Float {
        var best: Float = 0.03
        for galaxy in galaxies where galaxy.particleCount > 0 && galaxy.kind != .blackHole {
            let edge = max(galaxy.diskScaleLength * galaxy.diskTruncation, 0.1)
            let spacing = (Float.pi * edge * edge / Float(galaxy.particleCount)).squareRoot()
            best = max(best, spacing * 1.5)
        }
        return min(best, 1)
    }

    /// Short enough that a particle crosses well under one softening length per step.
    public var recommendedTimeStep: Float {
        guard solver.isSelfGravitating else { return 0.02 }
        var speed: Float = 1
        // A black hole's own pull is softened at its own length, several times this one, so
        // the disks still set the step. Measured in docs/notes/black-holes.md.
        for galaxy in galaxies where galaxy.kind != .blackHole {
            speed = max(
                speed, galaxy.potential.circularSpeed(atRadius: galaxy.diskScaleLength))
        }
        // Bracketed by the range self-gravitating runs have actually been stable over.
        return min(max(0.15 * recommendedSoftening / speed, 0.001), 0.012)
    }

    /// Applies both, called whenever the solver or the particle counts change.
    public mutating func retune() {
        softening = recommendedSoftening
        timeStep = recommendedTimeStep * max(timeStepScale, 0.01)
    }

    public var hasBlackHole: Bool { galaxies.contains { $0.kind == .blackHole } }

    /// Visible particles shared out by `weights`, shares that sum to one, every black hole
    /// taking exactly its one and the others sharing what is left in proportion. The first
    /// galaxy that is not a hole takes what rounding leaves. Without a hole this is the
    /// rounding the counts always had, so no scene drawn before holes moves a particle.
    static func sharedCounts(_ total: Int, weights: [Double], kinds: [GalaxyKind]) -> [Int] {
        let holes = kinds.filter { $0 == .blackHole }.count
        let rest = max(total - holes, 0)
        let sum =
            holes == 0
            ? 1 : zip(weights, kinds).reduce(0) { $0 + ($1.1 == .blackHole ? 0 : max($1.0, 0)) }
        var counts = zip(weights, kinds).map { weight, kind in
            kind == .blackHole ? 1 : sum > 0 ? Int((Double(rest) * max(weight, 0) / sum).rounded()) : 0
        }
        if let first = kinds.firstIndex(where: { $0 != .blackHole }) {
            let others = counts.indices.filter { $0 != first && kinds[$0] != .blackHole }
            counts[first] = max(rest - others.reduce(0) { $0 + counts[$1] }, 0)
        }
        return counts
    }

    public var hasLiveHalos: Bool {
        solver.isSelfGravitating && galaxies.contains { $0.haloParticleCount > 0 }
    }

    private enum CodingKeys: String, CodingKey {
        case name, galaxies, solver, seed, timeStep, centerSoftening, openingAngle, softening
        case timeStepScale, encounters, draw
    }

    /// Takes written before a scene could carry encounters still read.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        galaxies = try values.decode([GalaxyConfig].self, forKey: .galaxies)
        solver = try values.decode(SolverKind.self, forKey: .solver)
        seed = try values.decode(UInt64.self, forKey: .seed)
        timeStep = try values.decode(Float.self, forKey: .timeStep)
        centerSoftening = try values.decode(Float.self, forKey: .centerSoftening)
        openingAngle = try values.decode(Float.self, forKey: .openingAngle)
        softening = try values.decode(Float.self, forKey: .softening)
        timeStepScale = try values.decodeIfPresent(Float.self, forKey: .timeStepScale) ?? 1
        encounters = try values.decodeIfPresent([Encounter].self, forKey: .encounters) ?? []
        draw = try values.decodeIfPresent(SceneDraw.self, forKey: .draw)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> SceneConfig {
        try JSONDecoder().decode(SceneConfig.self, from: data)
    }
}
