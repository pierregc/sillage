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
        solver: SolverKind = .restricted,
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

    public var totalParticleCount: Int {
        galaxies.reduce(0) { $0 + $1.particleCount }
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
