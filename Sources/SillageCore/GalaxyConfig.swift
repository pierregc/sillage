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
    ///
    /// Measured again with the calm-disk probe (docs/notes/lumpy-arms.md): the clumps carry
    /// the disk's own velocity dispersion, so they evaporate within fifteen megayears and heat
    /// nothing; what the knob sets is the first frame's graininess, and a real old disk has
    /// none. 0.05 now; the knots belong to `youngClumpiness`.
    public var clumpiness: Float
    /// Share of the gas and the young stars drawn in clumps, the knots of a real disk. Used
    /// to be `clumpiness` plus 0.3.
    public var youngClumpiness: Float
    /// Contrast of the painted pattern the old stars are placed at. The light keeps
    /// `armStrength` through the young population and the paint; the mass holds what a real
    /// old disk holds, an m = 2 of about 0.15, which is what keeps the disk from sharpening
    /// its own arms into a bar within three hundred megayears (docs/notes/lumpy-arms.md).
    public var armMassContrast: Float
    /// Share of the streaming a density wave needs that the disk is launched with: the
    /// linear tight-winding response to the painted pattern, inward at the crest inside
    /// corotation and faster ahead of the arm than behind. Zero launches every star on an
    /// axisymmetric orbit, which is what made the disk ring and contract
    /// (docs/notes/disk-settling.md).
    public var armStreaming: Float
    /// How much heavier one side of the old stars' pattern is than the other, per unit of
    /// `armIrregularity`. The light keeps the 0.30 the shader paints; at that in the mass the
    /// disk started with an m = 1 of 0.21, four times a real inner disk, and sloshed.
    public var massLopsidedness: Float
    /// What the painted pattern turns at, as a share of the circular frequency at two scale
    /// lengths (`DiskEquilibrium.patternSpeed`). The disk's own pattern turns at 0.8 to 1.0 of
    /// it; zero keeps the speed files written before this field used, half the analytic
    /// potential's, which beat against the matter.
    public var patternShare: Float

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
        clumpiness: Float = 0.05,
        youngClumpiness: Float = 0.5,
        armMassContrast: Float = 0.3,
        armStreaming: Float = 1,
        massLopsidedness: Float = 0.03,
        patternShare: Float = 0.9,
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
        self.youngClumpiness = youngClumpiness
        self.armMassContrast = armMassContrast
        self.armStreaming = armStreaming
        self.massLopsidedness = massLopsidedness
        self.patternShare = patternShare
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

    private enum CodingKeys: String, CodingKey {
        case name, particleCount, kind, potential, diskScaleLength, diskTruncation, diskThickness
        case velocityDispersion, armCount, armStrength, armPitch, dustFraction, starFormingFraction
        case bulgeExtent, bulgeFraction, bulgeFlattening, color, clumpiness, youngClumpiness
        case armMassContrast, armStreaming, massLopsidedness, patternShare, outskirtFraction
        case armIrregularity, diskMassFraction
        case toomreQ, haloParticleRatio, haloExtent, dissipationTime, position, velocity
        case inclination, positionAngle, spin
    }

    /// Takes and scene files written before the calm disk (#167) read as they were written:
    /// every star at the painted contrast, no streaming, the young population at the
    /// clumpiness plus 0.3, the full lopsided term and the old pattern speed, so a scene
    /// explored before it replays the same at any size and a take exports the same.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        particleCount = try values.decode(Int.self, forKey: .particleCount)
        kind = try values.decode(GalaxyKind.self, forKey: .kind)
        potential = try values.decode(GalaxyPotential.self, forKey: .potential)
        diskScaleLength = try values.decode(Float.self, forKey: .diskScaleLength)
        diskTruncation = try values.decode(Float.self, forKey: .diskTruncation)
        diskThickness = try values.decode(Float.self, forKey: .diskThickness)
        velocityDispersion = try values.decode(Float.self, forKey: .velocityDispersion)
        armCount = try values.decode(Int.self, forKey: .armCount)
        armStrength = try values.decode(Float.self, forKey: .armStrength)
        armPitch = try values.decode(Float.self, forKey: .armPitch)
        dustFraction = try values.decode(Float.self, forKey: .dustFraction)
        starFormingFraction = try values.decode(Float.self, forKey: .starFormingFraction)
        bulgeExtent = try values.decode(Float.self, forKey: .bulgeExtent)
        bulgeFraction = try values.decode(Float.self, forKey: .bulgeFraction)
        bulgeFlattening = try values.decode(Float.self, forKey: .bulgeFlattening)
        color = try values.decode(SIMD3<Float>.self, forKey: .color)
        clumpiness = try values.decode(Float.self, forKey: .clumpiness)
        let legacy = Self.legacy(clumpiness: clumpiness, armStrength: armStrength)
        youngClumpiness =
            try values.decodeIfPresent(Float.self, forKey: .youngClumpiness) ?? legacy.youngClumpiness
        armMassContrast =
            try values.decodeIfPresent(Float.self, forKey: .armMassContrast) ?? legacy.armMassContrast
        armStreaming = try values.decodeIfPresent(Float.self, forKey: .armStreaming) ?? 0
        massLopsidedness =
            try values.decodeIfPresent(Float.self, forKey: .massLopsidedness) ?? legacy.massLopsidedness
        patternShare = try values.decodeIfPresent(Float.self, forKey: .patternShare) ?? 0
        outskirtFraction = try values.decode(Float.self, forKey: .outskirtFraction)
        armIrregularity = try values.decode(Float.self, forKey: .armIrregularity)
        diskMassFraction = try values.decode(Float.self, forKey: .diskMassFraction)
        toomreQ = try values.decode(Float.self, forKey: .toomreQ)
        haloParticleRatio = try values.decode(Float.self, forKey: .haloParticleRatio)
        haloExtent = try values.decode(Float.self, forKey: .haloExtent)
        dissipationTime = try values.decode(Float.self, forKey: .dissipationTime)
        position = try values.decode(SIMD3<Float>.self, forKey: .position)
        velocity = try values.decode(SIMD3<Float>.self, forKey: .velocity)
        inclination = try values.decode(Float.self, forKey: .inclination)
        positionAngle = try values.decode(Float.self, forKey: .positionAngle)
        spin = try values.decode(Spin.self, forKey: .spin)
    }

    /// What a galaxy described before the calm disk carried, for the fields it lacks.
    public static func legacy(clumpiness: Float, armStrength: Float) -> (
        youngClumpiness: Float, armMassContrast: Float, massLopsidedness: Float
    ) {
        (min(min(max(clumpiness, 0), 1) + 0.3, 0.97), armStrength, 0.30)
    }

    /// The calm disk of #167 on a galaxy described before it: the old stars at a contrast
    /// they can hold, with the streaming, an even-handed mass, the young population's clumps
    /// and the pattern turning with the matter. The clumpiness is left as it was, and a galaxy
    /// already on the calm disk keeps what it was drawn with.
    public mutating func adoptCalmDisk() {
        guard patternShare <= 0 else { return }
        let calm = GalaxyConfig(
            name: name, particleCount: particleCount, potential: potential,
            diskScaleLength: diskScaleLength)
        youngClumpiness = calm.youngClumpiness
        armMassContrast = min(calm.armMassContrast, armStrength)
        armStreaming = calm.armStreaming
        massLopsidedness = calm.massLopsidedness
        patternShare = calm.patternShare
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
        kind.isRotating ? Int(Float(particleCount) * min(max(bulgeFraction, 0), 0.9)) : 0
    }

    /// Number of halo particles this galaxy contributes when self-gravitating.
    public var haloParticleCount: Int {
        haloParticleRatio > 0 && kind != .blackHole ? Int(Float(particleCount) * haloParticleRatio) : 0
    }

    /// A black hole of `mass`, softened at `softening` kpc. It is one particle carrying the
    /// whole mass, so `particleCount` is one whatever the scene's count.
    public static func blackHole(mass: Float, softening: Float) -> GalaxyConfig {
        GalaxyConfig(
            name: "", particleCount: 1, kind: .blackHole,
            potential: GalaxyPotential(profile: .plummer, mass: mass, scaleRadius: softening),
            diskScaleLength: softening, diskTruncation: 1, diskThickness: softening,
            velocityDispersion: 0, armStrength: 0, dustFraction: 0, starFormingFraction: 0,
            bulgeFraction: 0, clumpiness: 0, youngClumpiness: 0, armMassContrast: 0,
            armStreaming: 0, massLopsidedness: 0, outskirtFraction: 0, armIrregularity: 0,
            diskMassFraction: 1,
            haloParticleRatio: 0, dissipationTime: 0)
    }

    /// The softening a black hole of `mass` is drawn with, in kpc: a quarter of a kiloparsec
    /// at 10^10 solar masses, growing as the cube root, the way a galaxy's lengths follow its
    /// mass under `Encounter.massRatio`. See docs/notes/black-holes.md for the measurement.
    public static func blackHoleSoftening(mass: Float) -> Float {
        0.25 * cbrt(max(mass, 1e-6))
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
