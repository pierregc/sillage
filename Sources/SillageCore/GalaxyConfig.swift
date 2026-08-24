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
    public var kind: GalaxyKind
    public var potential: GalaxyPotential

    /// Exponential surface density scale length, in kpc.
    public var diskScaleLength: Float
    /// Disk edge, expressed in scale lengths.
    public var diskTruncation: Float
    /// sech^2 vertical scale height, in kpc.
    public var diskThickness: Float
    /// Random velocity added to the circular orbit, as a fraction of the local circular speed.
    public var velocityDispersion: Float
    /// Number of spiral arms, used only by `.spiral`.
    public var armCount: Int
    /// Arm contrast, from 0 for none to 1 for arms on a near-empty disk.
    public var armStrength: Float
    /// Pitch angle of the arms in radians. Small values give tightly wound spirals.
    public var armPitch: Float
    /// Share of disk particles that trace absorbing dust instead of emitting starlight.
    public var dustFraction: Float
    /// Share of disk particles standing in for HII regions, the bright pink knots of Halpha.
    public var starFormingFraction: Float
    /// Radius of the old central population, in scale lengths.
    public var bulgeExtent: Float

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
        kind: GalaxyKind = .spiral,
        potential: GalaxyPotential,
        diskScaleLength: Float,
        diskTruncation: Float = 4,
        diskThickness: Float = 0.3,
        velocityDispersion: Float = 0.05,
        armCount: Int = 2,
        armStrength: Float = 0.82,
        armPitch: Float = 0.36,
        dustFraction: Float = 0.26,
        starFormingFraction: Float = 0.005,
        bulgeExtent: Float = 0.35,
        position: SIMD3<Float> = .zero,
        velocity: SIMD3<Float> = .zero,
        inclination: Float = 0,
        positionAngle: Float = 0,
        spin: Spin = .prograde
    ) {
        self.name = name
        self.particleCount = particleCount
        self.kind = kind
        self.potential = potential
        self.diskScaleLength = diskScaleLength
        self.diskTruncation = diskTruncation
        self.diskThickness = diskThickness
        self.velocityDispersion = velocityDispersion
        self.armCount = armCount
        self.armStrength = armStrength
        self.armPitch = armPitch
        self.dustFraction = dustFraction
        self.starFormingFraction = starFormingFraction
        self.bulgeExtent = bulgeExtent
        self.position = position
        self.velocity = velocity
        self.inclination = inclination
        self.positionAngle = positionAngle
        self.spin = spin
    }

    /// Maps the disk plane onto its world orientation.
    public var orientation: simd_float3x3 {
        let ci = cos(inclination)
        let si = sin(inclination)
        let cp = cos(positionAngle)
        let sp = sin(positionAngle)
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
