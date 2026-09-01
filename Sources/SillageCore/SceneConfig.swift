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
    /// Barnes-Hut opening angle. Smaller is more accurate and slower, and the trade is far
    /// steeper than it looks. Measured at 400 000 particles, against direct summation:
    ///
    ///     theta   mean force error   force pass   whole step   momentum drift
    ///     0.6            0.60 %         42.7 ms      67.0 ms       0.1376
    ///     0.7            0.78 %         29.7 ms      54.4 ms       0.1342
    ///     0.85           1.27 %         18.0 ms      42.4 ms       0.3128
    ///     1.0            1.87 %         12.9 ms      37.3 ms          —
    ///
    /// 0.7 rather than the 0.6 this used to be, and not 0.85, because there is a knee between
    /// them: momentum drift is flat to 0.7 and triples past it. That is the honest symptom of
    /// the approximation, since a monopole force is not symmetric between a particle and the
    /// cell standing in for its neighbours, and nothing else measured here shows it.
    ///
    /// Small-scale structure does not pay for a wider angle, and the reason is worth stating:
    /// an opening angle only decides how far a cell must be before its monopole stands in for
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

    public init(
        name: String,
        galaxies: [GalaxyConfig],
        solver: SolverKind = .barnesHut,
        seed: UInt64 = 1,
        timeStep: Float = 0.01,
        centerSoftening: Float = 0.5,
        openingAngle: Float = 0.7,
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
        for galaxy in galaxies where galaxy.particleCount > 0 {
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
        for galaxy in galaxies {
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

    public var hasLiveHalos: Bool {
        solver.isSelfGravitating && galaxies.contains { $0.haloParticleCount > 0 }
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
