#if canImport(simd)
    import simd
#else
    import Foundation
#endif

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
