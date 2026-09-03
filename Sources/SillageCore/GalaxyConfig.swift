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
    /// Bulge scale radius, in disk scale lengths. This is the Hernquist scale of the bulge,
    /// so the radius holding half its projected light is about 1.8 times it.
    public var bulgeExtent: Float
    /// Share of the galaxy's stars that sit in the bulge rather than the disk. Runs from a
    /// few per cent in a late-type spiral to about half in an early one.
    public var bulgeFraction: Float
    /// Short axis over long axis. A classical bulge is round but not spherical, and it is
    /// flattened along the same axis the disk turns about.
    public var bulgeFlattening: Float
    /// Emission colour of this galaxy's stars. One tint per galaxy makes it obvious which
    /// stars end up in the other galaxy after the encounter.
    public var color: SIMD3<Float>
    /// Share of stars placed in a hierarchy of clumps rather than smoothly. Real disks are
    /// patchy at every scale; a smooth draw looks airbrushed.
    ///
    /// It is also, by a long way, what heats the disk, and that is worth knowing before
    /// raising it. Clumps are self-gravitating overdensities that dissolve over the first few
    /// hundred megayears and scatter everything they pass. Measured on an isolated disk, the
    /// radial dispersion against the circular speed after 300 Myr: 0.156 at zero clumpiness,
    /// 0.185 at 0.12, and 0.309 at the 0.30 this used to be — against the 0.10 to 0.15 a real
    /// spiral lives at. Over 800 Myr the old value reached 0.55 and the disk stopped
    /// amplifying anything, which is what "the arms never form and it falls apart" was.
    ///
    /// The trade is real in both directions: clumps are also what seeds the spiral response,
    /// and at zero the m = 2 amplitude collapses to nothing. 0.12 keeps a flocculent disk.
    public var clumpiness: Float

    /// Share of a disk's stars belonging to the thick disk and inner halo rather than to the
    /// thin disk: old, metal-poor, spread wider and standing well off the plane.
    ///
    /// Without it a disk stops at a radius you can name, with a rim, which is the one thing no
    /// galaxy has. Real thick disks hold something like a tenth of a spiral's stellar mass and
    /// rather less of its light, since they are old.
    public var outskirtFraction: Float
    /// How far the arms wander from a perfect logarithmic spiral, and how much they break
    /// into segments.
    public var armIrregularity: Float
    /// Share of the galaxy's mass carried by the live disk particles under self-gravity. The
    /// remainder stays in the analytic halo. A real disk is roughly a fifth of the total.
    public var diskMassFraction: Float
    /// Toomre stability parameter used to set the velocity dispersion when the disk is
    /// self-gravitating. Below 1 the disk fragments; 1.2 to 1.6 is the usual working range.
    public var toomreQ: Float
    /// Halo particles per disk particle. A rigid halo carries mass but no inertia, so it
    /// raises no wake, exerts no dynamical friction, and two galaxies orbit forever instead
    /// of merging. Making it live costs particles that are never drawn. Zero keeps the old
    /// analytic halo.
    public var haloParticleRatio: Float
    /// Radius the halo is sampled out to, in scale radii.
    public var haloExtent: Float

    /// How fast the disk sheds the random motion it picks up, in Myr. Zero leaves it alone.
    ///
    /// A disk of stars alone can only heat: every spiral it raises stirs it further, the
    /// Toomre parameter climbs, and after about a gigayear it is a smooth featureless
    /// spheroid with no arms left. Measured here exactly that way. Real disks do not do this
    /// because their gas radiates the motion away and forms new stars on circular orbits,
    /// which resets the disk faster than the spirals heat it. Nothing in this simulation is
    /// gas, so the effect is put back directly.
    public var dissipationTime: Float

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
        armPitch: Float = 0.46,
        dustFraction: Float = 0.26,
        starFormingFraction: Float = 0.026,
        bulgeExtent: Float = 0.18,
        bulgeFraction: Float = 0.15,
        bulgeFlattening: Float = 0.7,
        color: SIMD3<Float> = SIMD3<Float>(1.0, 0.90, 0.74),
        clumpiness: Float = 0.12,
        outskirtFraction: Float = 0.12,
        armIrregularity: Float = 0.55,
        diskMassFraction: Float = 0.22,
        toomreQ: Float = 1.4,
        haloParticleRatio: Float = 1.5,
        haloExtent: Float = 12,
        dissipationTime: Float = 250,
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
        self.bulgeFraction = bulgeFraction
        self.bulgeFlattening = bulgeFlattening
        self.color = color
        self.clumpiness = clumpiness
        self.outskirtFraction = outskirtFraction
        self.armIrregularity = armIrregularity
        self.diskMassFraction = diskMassFraction
        self.toomreQ = toomreQ
        self.haloParticleRatio = haloParticleRatio
        self.haloExtent = haloExtent
        self.dissipationTime = dissipationTime
        self.position = position
        self.velocity = velocity
        self.inclination = inclination
        self.positionAngle = positionAngle
        self.spin = spin
    }

    /// Signed rate at which the spiral pattern winds, in radians per e-folding of radius.
    ///
    /// Arms trail: their tips point back against the way the disk turns. That is not a
    /// convention but what a spiral galaxy shows, so the winding takes its sign from the
    /// spin. Fixing the sign instead left every disk with leading arms, and reversing the
    /// spin turned the disk without turning the pattern with it.
    public var armWindRate: Float {
        -spin.sign / max(tan(armPitch), 1e-3)
    }

    /// Stars placed in the bulge. Spheroids have no bulge of their own to speak of.
    public var bulgeParticleCount: Int {
        kind == .globular ? 0 : Int(Float(particleCount) * min(max(bulgeFraction, 0), 0.9))
    }

    /// Number of halo particles this galaxy contributes when self-gravitating.
    public var haloParticleCount: Int {
        haloParticleRatio > 0 ? Int(Float(particleCount) * haloParticleRatio) : 0
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
