import simd

/// Velocity structure for a self-gravitating disk.
///
/// A cold disk is violently unstable: turn on self-gravity and it fragments within an orbit.
/// Toomre's criterion says a disk resists that when its radial velocity dispersion exceeds
/// 3.36 G Sigma / kappa, and simulations are normally run at Q between 1.2 and 1.6.
/// Everything here follows from that single number, which is why the restricted and
/// self-gravitating modes need genuinely different initial conditions and not just a
/// different force law.
public struct DiskEquilibrium {
    public let config: GalaxyConfig
    private let centralDensity: Float

    public init(config: GalaxyConfig) {
        self.config = config
        let diskMass = config.potential.mass * config.diskMassFraction
        let scale = max(config.diskScaleLength, 1e-3)
        self.centralDensity = diskMass / (2 * .pi * scale * scale)
    }

    public func surfaceDensity(atRadius radius: Float) -> Float {
        centralDensity * exp(-radius / max(config.diskScaleLength, 1e-3))
    }

    public func circularSpeed(atRadius radius: Float) -> Float {
        config.potential.circularSpeed(atRadius: radius)
    }

    /// Epicyclic frequency, from the local shear of the rotation curve.
    public func epicyclicFrequency(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let step = max(r * 0.01, 1e-4)
        let speed = circularSpeed(atRadius: r)
        let ahead = circularSpeed(atRadius: r + step)
        let behind = circularSpeed(atRadius: max(r - step, 1e-5))
        let slope = (ahead - behind) / (2 * step)
        let omega = speed / r
        return sqrt(max(2 * omega * (omega + slope), 1e-8))
    }

    /// Radial dispersion required for the requested Toomre Q.
    public func radialDispersion(atRadius radius: Float) -> Float {
        let kappa = epicyclicFrequency(atRadius: radius)
        let sigma = surfaceDensity(atRadius: radius)
        return config.toomreQ * 3.36 * Physics.gravitationalConstant * sigma / max(kappa, 1e-6)
    }

    /// Azimuthal dispersion follows from the epicyclic ratio, not from a free choice.
    public func azimuthalDispersion(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let omega = circularSpeed(atRadius: r) / r
        let kappa = epicyclicFrequency(atRadius: r)
        return radialDispersion(atRadius: r) * kappa / max(2 * omega, 1e-6)
    }

    /// Vertical dispersion supporting an isothermal sech^2 layer of the configured height.
    public func verticalDispersion(atRadius radius: Float) -> Float {
        let height = max(config.diskThickness, 1e-3)
        return sqrt(
            .pi * Physics.gravitationalConstant * surfaceDensity(atRadius: radius) * height)
    }

    /// Mean streaming speed. Pressure support lets the mean rotation lag the circular speed,
    /// and ignoring that asymmetric drift makes the disk expand over its first orbit.
    public func streamingSpeed(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let circular = circularSpeed(atRadius: r)
        let dispersion = radialDispersion(atRadius: r)
        let drift = dispersion * dispersion * (2 * r / max(config.diskScaleLength, 1e-3) - 1)
        return sqrt(max(circular * circular - drift, 0))
    }

    /// Toomre Q actually realised by a given radial dispersion, for verification.
    public func toomreQ(atRadius radius: Float, radialDispersion sigma: Float) -> Float {
        let kappa = epicyclicFrequency(atRadius: radius)
        let density = surfaceDensity(atRadius: radius)
        return sigma * kappa / max(3.36 * Physics.gravitationalConstant * density, 1e-12)
    }
}
