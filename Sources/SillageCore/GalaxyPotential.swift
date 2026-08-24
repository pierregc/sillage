import simd

public enum PotentialProfile: String, Codable, Sendable, CaseIterable {
    case plummer
    case hernquist
}

/// Spherical analytic potential standing in for a galaxy's bulge and dark halo.
/// Kept as a plain value type so it can be handed to a Metal kernel unchanged.
public struct GalaxyPotential: Codable, Sendable, Equatable {
    public var profile: PotentialProfile
    public var mass: Float
    public var scaleRadius: Float

    public init(profile: PotentialProfile, mass: Float, scaleRadius: Float) {
        self.profile = profile
        self.mass = mass
        self.scaleRadius = scaleRadius
    }

    public func acceleration(at offset: SIMD3<Float>) -> SIMD3<Float> {
        let a = scaleRadius
        switch profile {
        case .plummer:
            let d2 = simd_length_squared(offset) + a * a
            return -Physics.gravitationalConstant * mass * offset / (d2 * sqrt(d2))
        case .hernquist:
            let r = max(simd_length(offset), 1e-6)
            let s = r + a
            return -Physics.gravitationalConstant * mass * offset / (r * s * s)
        }
    }

    public func circularSpeed(atRadius radius: Float) -> Float {
        let a = scaleRadius
        let r = max(radius, 0)
        switch profile {
        case .plummer:
            let d2 = r * r + a * a
            return sqrt(Physics.gravitationalConstant * mass * r * r / (d2 * sqrt(d2)))
        case .hernquist:
            let s = r + a
            return sqrt(Physics.gravitationalConstant * mass * r / (s * s))
        }
    }

    public func escapeSpeed(atRadius radius: Float) -> Float {
        let a = scaleRadius
        switch profile {
        case .plummer:
            return sqrt(2 * Physics.gravitationalConstant * mass / sqrt(radius * radius + a * a))
        case .hernquist:
            return sqrt(2 * Physics.gravitationalConstant * mass / (radius + a))
        }
    }

    public func potential(at offset: SIMD3<Float>) -> Float {
        let a = scaleRadius
        switch profile {
        case .plummer:
            return -Physics.gravitationalConstant * mass / sqrt(simd_length_squared(offset) + a * a)
        case .hernquist:
            return -Physics.gravitationalConstant * mass / (simd_length(offset) + a)
        }
    }
}
