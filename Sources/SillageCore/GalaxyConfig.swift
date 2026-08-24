import simd

public enum Spin: String, Codable, Sendable, CaseIterable {
    /// Disk rotation aligned with the orbital angular momentum. Produces the long tidal tails.
    case prograde
    case retrograde

    public var sign: Float { self == .prograde ? 1 : -1 }
}

public struct GalaxyConfig: Codable, Sendable, Equatable {
    public var name: String
    public var particleCount: Int
    public var potential: GalaxyPotential

    /// Exponential surface density scale length, in kpc.
    public var diskScaleLength: Float
    /// Disk edge, expressed in scale lengths.
    public var diskTruncation: Float
    /// sech^2 vertical scale height, in kpc.
    public var diskThickness: Float
    /// Random velocity added to the circular orbit, as a fraction of the local circular speed.
    public var velocityDispersion: Float

    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    /// Tilt of the disk plane, in radians.
    public var inclination: Float
    /// Rotation of the tilted disk about the view axis, in radians.
    public var positionAngle: Float
    public var spin: Spin

    public init(
        name: String,
        particleCount: Int,
        potential: GalaxyPotential,
        diskScaleLength: Float,
        diskTruncation: Float = 4,
        diskThickness: Float = 0.3,
        velocityDispersion: Float = 0.05,
        position: SIMD3<Float> = .zero,
        velocity: SIMD3<Float> = .zero,
        inclination: Float = 0,
        positionAngle: Float = 0,
        spin: Spin = .prograde
    ) {
        self.name = name
        self.particleCount = particleCount
        self.potential = potential
        self.diskScaleLength = diskScaleLength
        self.diskTruncation = diskTruncation
        self.diskThickness = diskThickness
        self.velocityDispersion = velocityDispersion
        self.position = position
        self.velocity = velocity
        self.inclination = inclination
        self.positionAngle = positionAngle
        self.spin = spin
    }

    /// Maps the disk plane onto its world orientation.
    public var orientation: simd_float3x3 {
        let ci = cos(inclination), si = sin(inclination)
        let cp = cos(positionAngle), sp = sin(positionAngle)
        let tilt = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, ci, si),
            SIMD3<Float>(0, -si, ci)
        )
        let swing = simd_float3x3(
            SIMD3<Float>(cp, sp, 0),
            SIMD3<Float>(-sp, cp, 0),
            SIMD3<Float>(0, 0, 1)
        )
        return swing * tilt
    }
}
