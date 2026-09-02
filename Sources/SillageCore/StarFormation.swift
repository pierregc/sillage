import simd

/// Turning gas into stars, and what the result looks like while it is young.
///
/// There is no gas here, so this is a stand-in and says so. What it does reproduce is the
/// thing an encounter is watched for: a galaxy's new stars appear where its material has been
/// compressed, which in a merger means the nucleus at coalescence and the knots along a
/// bridge, and they announce themselves for a few million years and then stop.
///
/// What it replaces was decorative. The HII regions were placed by the sampler and then lit by
/// the *painted* spiral pattern, so the pink knots followed a texture rather than the physics,
/// sat wherever the sampler had left them an orbit earlier, and never appeared anywhere new
/// however violently the galaxy was disturbed.
public enum StarFormation {
    /// Megayears a knot stays ionised, which is the life of the O stars doing the ionising.
    /// Past this the Halpha goes out and what is left is a young blue cluster.
    public static let ionisedMyr: Float = 8

    /// Youngest age the colour and brightness curves resolve, in megayears. Below it a knot
    /// is simply at its bluest and brightest: nothing here models the first few million years.
    public static let knotFloorMyr: Float = 3

    /// Megayears over which a coeval population's colour runs from bluest to as red as the old
    /// disk. Three gigayears, and the ramp is logarithmic because that is how the light of a
    /// population actually evolves: most of the change happens in the first hundred megayears,
    /// as the stars that dominate it come off the main sequence in order of mass.
    public static let fadeMyr: Float = 13000

    /// How bright a knot is at birth against an ordinary disk particle of the same mass.
    ///
    /// A coeval population is dominated by its most massive stars for as long as it has any,
    /// so it starts an order of magnitude brighter and then falls off as a power law. A disk
    /// star here stands for a composite population already in steady state, which is what this
    /// is measured against.
    public static let youngLuminosity: Float = 12

    /// Age at which a population is as bright as the law says an average one is, in megayears.
    /// Roughly the light-weighted age of a spiral disk, so the exposure lands where it did.
    public static let referenceAgeMyr: Float = 3000

    /// Youngest age the initial conditions place anything at, in megayears.
    ///
    /// A particle stands for tens of thousands of stars, so it is never truly coeval, and a
    /// power law with no floor is a trap: ages drawn uniformly to zero would put most of a
    /// galaxy's light into a few hundred particles and the disk reads as a field of glints
    /// rather than as a disk. Measured that way once already. Anything younger than this comes
    /// from the star formation rule during the run, where it is meant to stand out.
    public static let youngestSampledMyr: Float = 600

    /// Oldest and youngest a disk gets, in megayears, from its centre to its edge. Disks form
    /// inside out, so the outskirts are the young part.
    public static let diskOldestMyr: Float = 12000
    public static let diskEdgeOldestMyr: Float = 5000
    /// A bulge is old everywhere and was made quickly.
    public static let bulgeAgeMyr: ClosedRange<Float> = 10000...12500

    /// Exponent of that decay, and the whole of what makes the young dominate a frame. It is
    /// one law for everything now: a knot three megayears old and a bulge star of eleven
    /// gigayears are the same formula at different ages. Capped at `youngLuminosity`, which
    /// the law reaches at about 170 Myr — without that cap the youngest few hundred particles
    /// carry most of the light and the disk turns to glitter.
    public static let luminosityDecay: Float = 0.9

    /// Megayears of star formation history the sampler seeds a disk with.
    ///
    /// A galaxy does not begin the run having formed nothing. Seeding the knots all at t = 0
    /// gave every one of them the same age, so the whole disk lit up at once and stayed at
    /// full brightness together — a field of identical blue glints rather than a population.
    /// At a constant rate the ages are uniform, so that is how they are drawn.
    public static let seedSpreadMyr: Float = 600

    /// Star formation efficiency per free-fall time.
    ///
    /// The free-fall time goes as one over the square root of density, so the rate per unit
    /// gas mass follows the square root of it and the rate per unit volume follows the
    /// three-halves power. That is Schmidt's law, and it is the whole of the rule here.
    ///
    /// The observed efficiency is a percent or two, and this is deliberately below it. That
    /// number belongs to the dense molecular phase, on the free-fall time *of a cloud*; what
    /// is available here is the free-fall time of the mean density of a whole leaf, which is
    /// far longer, over gas that is mostly not in the star-forming phase at all. Using the
    /// observed value against a mean-density free-fall time gave a depletion time of 950 Myr
    /// against the two to three gigayears a real disk shows, and an isolated disk that burned
    /// four fifths of its gas in six hundred megayears. Calibrated instead against what a
    /// quiescent disk actually does: 1.2 Gyr, measured on the control run.
    public static var efficiency: Float = 0.002

    /// Density below which nothing forms, in code units of mass per cubic kiloparsec.
    ///
    /// Real star formation has a threshold — below a surface density of about ten solar masses
    /// a square parsec a disk forms almost nothing — and without one every particle in the
    /// outskirts slowly turns into a knot and the whole disk lights up evenly, which is the
    /// opposite of what an encounter should show.
    public static var thresholdDensity: Float = 0.03

    /// How much harder gas forms stars when it is being compressed, per unit of convergence
    /// measured against its own free-fall rate.
    ///
    /// Without this there is no starburst at all, which is the one thing an encounter is
    /// watched for. Density alone consumes the densest gas first, so a merger arrives at its
    /// pericentre with the nucleus already spent and the rate only ever falling. A real merger
    /// bursts because tidal torques drive fresh gas inward and shock it; the inflow is not
    /// modelled here, but the shock is visible in the flow itself.
    public static var compressionBoost: Float = 3

    /// Convergence a leaf has to exceed, in units of its own free-fall rate, before any of it
    /// counts as a shock.
    ///
    /// The estimator is a least-squares velocity gradient over sixteen particles, so it is
    /// noisy, and taking only the converging half of it rectifies that noise into a rate
    /// everywhere. With no floor a quiescent disk burned ninety-six per cent of its gas before
    /// the encounter even arrived. The noise sits at order unity — a disk in equilibrium has
    /// its dispersion over its scale height comparable to its own free-fall rate — so the
    /// floor has to sit above that, and only material converging faster than it falls counts.
    public static var compressionFloor: Float = 15

    /// The colour age a knot of this age reads as, on the sampler's own 0 old to 1 young
    /// scale. Kept here rather than only in the shader so a test can check the curve.
    public static func population(ageMyr: Float) -> Float {
        let floor = max(knotFloorMyr, 1e-3)
        let span = log(max(fadeMyr / floor, 1.001))
        return 1 - min(max(log(max(ageMyr, floor) / floor) / span, 0), 1)
    }

    /// Light per unit mass at this age, against a population of `referenceAgeMyr`.
    public static func luminosity(ageMyr: Float) -> Float {
        let resolved = max(ageMyr, knotFloorMyr)
        return min(pow(resolved / referenceAgeMyr, -luminosityDecay), youngLuminosity)
    }

    /// When an old spheroid's stars formed. A bulge is old everywhere and was made quickly,
    /// so there is no gradient to draw from — only the width of the burst.
    public static func oldFormation(roll: Float) -> Float {
        let span = bulgeAgeMyr.upperBound - bulgeAgeMyr.lowerBound
        return -(bulgeAgeMyr.lowerBound + span * min(max(roll, 0), 1))
            / Float(Physics.megayearsPerTimeUnit)
    }

    /// When a particle sampled at this radius and this close to an arm formed, in code units
    /// before t = 0. Uniform in age is what a steady rate gives; the arm bias pulls the draw
    /// young, because that is where the recent star formation was.
    public static func sampledFormation(
        edge: Float, armProximity: Float, roll: Float
    ) -> Float {
        let oldest = diskOldestMyr - (diskOldestMyr - diskEdgeOldestMyr) * min(max(edge, 0), 1)
        let biased = pow(min(max(roll, 0), 1), 1 + 2 * min(max(armProximity, 0), 1))
        let age = youngestSampledMyr + (oldest - youngestSampledMyr) * biased
        return -age / Float(Physics.megayearsPerTimeUnit)
    }

    /// The share of a knot's light still coming out in Halpha at this age.
    public static func ionised(ageMyr: Float) -> Float {
        ageMyr < 0 ? 0 : exp(-ageMyr / ionisedMyr)
    }
}
