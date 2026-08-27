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
    /// Barnes-Hut opening angle. Smaller is more accurate and slower.
    public var openingAngle: Float
    /// Force softening between particles, in kpc. It should sit near the mean interparticle
    /// separation: too small and two-body encounters heat the disk, too large and structure
    /// is washed out.
    public var softening: Float

    public init(
        name: String,
        galaxies: [GalaxyConfig],
        solver: SolverKind = .barnesHut,
        seed: UInt64 = 1,
        timeStep: Float = 0.01,
        centerSoftening: Float = 0.5,
        openingAngle: Float = 0.6,
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
        timeStep = recommendedTimeStep
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
