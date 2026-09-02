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
    /// Megayears a star-forming region keeps a lit nebula in it.
    ///
    /// Not the life of one HII region, which is the eight megayears its O stars live, and not
    /// the life of one complex either, which is a few tens. What is drawn red here is a place
    /// several hundred parsecs across that is forming stars, and such a place keeps forming
    /// them — and so keeps a nebula lit somewhere inside itself — for as long as the gas
    /// concentration feeding it survives, which is one to a few hundred megayears.
    ///
    /// The number matters more than that argument does, because of the rate the thing is
    /// watched at. Four steps a frame at sixty frames a second is thirty-seven megayears of
    /// simulation every second of wall clock. At sixty megayears a knot came and went inside
    /// one and a half seconds, so every red patch in the picture was flickering — which is
    /// what a galaxy full of them looks like, and it is not what a galaxy looks like. At two
    /// hundred a region takes five or six seconds to swell and fade, which is slow enough to
    /// watch happen and still short enough that the disk turns over while you look at it.
    public static let ionisedMyr: Float = 200

    /// Youngest age the colour and brightness curves resolve, in megayears. Below it a knot
    /// is simply at its bluest and brightest: nothing here models the first few million years.
    public static let knotFloorMyr: Float = 3

    /// Megayears a region takes to reach full brightness. A cloud collapses and lights up
    /// over a few million years; switching it on between two frames is a light bulb. Set
    /// against the same wall clock as the window above — this is about half a second.
    public static let riseMyr: Float = 20

    /// The two ends of the colour ramp, in megayears, calibrated rather than chosen.
    ///
    /// A ramp running from three megayears to a Hubble time put every real disk age into its
    /// bottom fifth, so a whole galaxy came out orange and the only blue left in a picture was
    /// the per-galaxy tint. These two numbers instead fit what population synthesis actually
    /// gives — 13000 K at ten megayears, 5800 at three gigayears, 4750 at twelve — which is a
    /// power law in age with a much gentler slope than the old ramp had.
    ///
    /// The old end sits past a Hubble time on purpose: nothing in a galaxy is thirty gigayears
    /// old, and that is the point, because it leaves a twelve-gigayear bulge above the bottom
    /// of the ramp instead of pinned to it.
    public static let colourYoungMyr: Float = 10
    public static let colourOldMyr: Float = 30000

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

    /// Youngest age the initial conditions place an ordinary disk star at, in megayears.
    ///
    /// Has to stay above `ionisedMyr`, and that is the whole of why it is this number rather
    /// than a smaller one. Anything younger than the window reads as ionised, so if the disk
    /// is sampled down into it then the disk itself is what glows: measured at a two hundred
    /// megayear window against a sixty megayear floor, sixty-six thousand particles came out
    /// lit and carried seven tenths of the light, and the galaxy was uniformly pink. Only
    /// what a nursery or the run itself made should be able to be young enough to glow.
    ///
    /// It could not go much lower anyway. A particle stands for tens of thousands of stars,
    /// so it is never truly coeval, and a power law with no floor is a trap: ages drawn
    /// uniformly to zero would put most of a galaxy's light into a few hundred particles and
    /// the disk reads as a field of glints rather than as a disk. Measured that way once too.
    public static let youngestSampledMyr: Float = 250

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

    /// Megayears the sampler spreads its seeded knots over.
    ///
    /// Matched to the steady state the run itself settles at, which is what stops the picture
    /// thinning out. The sampler places two per cent of the disk as HII regions; if they all
    /// arrive lit, the galaxy holds four thousand knots at t = 0 and a thousand by six hundred
    /// megayears, and a viewer sees the pink drain away. Spread so that the number lit at the
    /// start is the number the disk's own formation rate sustains, the count is flat from the
    /// first frame and nothing drains.
    ///
    /// Not zero, though: seeding them all at the same instant gives every knot the same age
    /// and the whole disk goes out together a few tens of megayears in.
    ///
    /// Held at about half again `ionisedMyr`. Longer and the galaxy opens nearly white and
    /// reddens over its first two hundred megayears as the run catches up with itself, which
    /// is a transient nothing physical asks for: measured at three times the window, the
    /// ionised share of the light went 7 per cent, 16, and back to 10.
    public static let seedSpreadMyr: Float = 300

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
    public static let efficiency: Float = 0.002

    /// Density below which nothing forms, in code units of mass per cubic kiloparsec.
    ///
    /// Real star formation has a threshold — below a surface density of about ten solar masses
    /// a square parsec a disk forms almost nothing — and without one every particle in the
    /// outskirts slowly turns into a knot and the whole disk lights up evenly, which is the
    /// opposite of what an encounter should show.
    public static let thresholdDensity: Float = 0.03

    /// How much harder gas forms stars when it is being compressed, per unit of convergence
    /// measured against its own free-fall rate.
    ///
    /// Without this there is no starburst at all, which is the one thing an encounter is
    /// watched for. Density alone consumes the densest gas first, so a merger arrives at its
    /// pericentre with the nucleus already spent and the rate only ever falling. A real merger
    /// bursts because tidal torques drive fresh gas inward and shock it; the inflow is not
    /// modelled here, but the shock is visible in the flow itself.
    public static let compressionBoost: Float = 3

    /// Convergence a leaf has to exceed, in units of its own free-fall rate, before any of it
    /// counts as a shock.
    ///
    /// The estimator is a least-squares velocity gradient over sixteen particles, so it is
    /// noisy, and taking only the converging half of it rectifies that noise into a rate
    /// everywhere. With no floor a quiescent disk burned ninety-six per cent of its gas before
    /// the encounter even arrived. The noise sits at order unity — a disk in equilibrium has
    /// its dispersion over its scale height comparable to its own free-fall rate — so the
    /// floor has to sit above that, and only material converging faster than it falls counts.
    public static let compressionFloor: Float = 15

    /// Size of a star-forming zone, in kiloparsecs.
    ///
    /// A leaf is far smaller than a star-forming complex, and drawing each leaf independently
    /// scattered the new stars one at a time over the whole star-forming part of the disk: the
    /// count was right, the light was right, and what it read as was a pink haze rather than
    /// anything you could point at. Real star formation is clustered — a complex lights up as
    /// a unit and its neighbours with it — so the draw is made once per zone of this size and
    /// every leaf inside one answers to it. Set at the size of a large complex.
    public static let zoneSize: Float = 0.35

    /// Fraction of a zone's available gas that goes at once when it does go.
    ///
    /// Only the shape of the distribution, not its mean: a zone ignites at one over this times
    /// less often, so the rate the Schmidt law asks for is exactly preserved. What changes is
    /// that the stars arrive together, in one place, and are therefore visible as a place.
    public static let burstShare: Float = 0.45

    /// The colour age a population of this age reads as, on the sampler's own 0 old to 1
    /// young scale. Kept here rather than only in the shader so a test can check the curve.
    public static func population(ageMyr: Float) -> Float {
        let span = log(colourOldMyr / colourYoungMyr)
        return 1 - min(max(log(max(ageMyr, colourYoungMyr) / colourYoungMyr) / span, 0), 1)
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
        // Hard against the young end on an arm, and that steepness is now carrying the whole
        // of an arm's colour: the painted wave used to add its own bluing at draw time, which
        // is what made stars flash as they crossed it. Baked in here it cannot flash, because
        // a star's age never changes. On a ridge the median lands near four hundred megayears
        // and between the arms near six gigayears — white-blue against orange.
        let biased = pow(min(max(roll, 0), 1), 1 + 6 * min(max(armProximity, 0), 1))
        let age = youngestSampledMyr + (oldest - youngestSampledMyr) * biased
        return -age / Float(Physics.megayearsPerTimeUnit)
    }

    /// The share of a knot's light still coming out in Halpha at this age.
    public static func ionised(ageMyr: Float) -> Float {
        ageMyr < 0 ? 0 : exp(-ageMyr / ionisedMyr)
    }
}
