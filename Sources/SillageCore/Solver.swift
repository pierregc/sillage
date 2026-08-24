import simd

/// Contract between the physics engine and anything that draws it. A renderer only ever
/// sees positions and per-particle attributes, never how the forces were obtained.
public protocol Solver: AnyObject {
    var kind: SolverKind { get }
    var scene: SceneConfig { get }
    var particles: ParticleSystem { get }
    /// Galaxy centres, exposed for camera framing and diagnostics.
    var centers: [SIMD3<Float>] { get }
    var time: Float { get }

    func step()
    func step(count: Int)
}

extension Solver {
    public func step(count: Int) {
        for _ in 0..<count { step() }
    }
}

public enum SolverFactory {
    public static func make(_ scene: SceneConfig) throws -> any Solver {
        switch scene.solver {
        case .restricted:
            return RestrictedSolver(scene: scene)
        case .barnesHut:
            // Needs a Metal device, so it is built through SillageRender instead.
            throw SillageError.solverNeedsGPU(.barnesHut)
        }
    }
}

public enum SillageError: Error, CustomStringConvertible {
    case solverNeedsGPU(SolverKind)
    case emptyScene

    public var description: String {
        switch self {
        case .solverNeedsGPU(let kind):
            "Solver \(kind.rawValue) runs on the GPU, build it through SillageRender"
        case .emptyScene:
            "Scene contains no galaxies"
        }
    }
}
