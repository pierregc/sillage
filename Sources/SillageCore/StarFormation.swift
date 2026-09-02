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
    /// Megayears a knot stays ionised.
    ///
    /// A single HII region is lit for the eight megayears its O stars live, and that is what
    /// this used to be. But a particle here stands for a whole star-forming complex, and a
    /// complex keeps making stars for two or three times as long, so it keeps a lit region in
    /// it for as long. At eight the pink was there and measurable and could not be seen: the
    /// disk holds only a couple of hundred lit knots at a time out of a quarter of a million
    /// particles.
    public static let ionisedMyr: Float = 25

    /// Youngest age the initial conditions place anything at, in megayears.
    ///
    /// A particle stands for tens of thousands of stars, so it is never truly coeval, and a
    /// power law with no floor is a trap: ages drawn uniformly to zero would put most of a
    /// galaxy's light into a few hundred particles and the disk reads as a field of glints
    /// rather than as a disk. Measured that way once already. Anything younger than this comes
    /// from the star formation rule during the run, where it is meant to stand out.
    public static let youngestSampledMyr: Float = 60

    /// Oldest and youngest a disk gets, in megayears, from its centre to its edge. Disks form
    /// inside out, so the outskirts are the young part.
    public static let diskOldestMyr: Float = 12000
    public static let diskEdgeOldestMyr: Float = 3000
    /// A bulge is old everywhere and was made quickly.
    public static let bulgeAgeMyr: ClosedRange<Float> = 10000...12500

    /// Megayears the sampler spreads its seeded knots over.
    ///
    /// The sampler declares these particles HII regions, so they have to arrive lit. Spread
    /// over six hundred megayears only one in twenty-five still was, and the pink went out of
    /// the picture entirely. Spread over one ionised lifetime or so, they arrive as what they
    /// were placed to be, and the run's own star formation takes over from there.
    ///
    /// Not zero, though: seeding them all at the same instant gives every knot the same age
    /// and the whole disk goes out together a few tens of megayears in.
    public static let seedSpreadMyr: Float = 60

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

    /// When an old spheroid's stars formed. A bulge is old everywhere and was made quickly,
    /// so there is no gradient to draw from — only the width of the burst.
    public static func oldFormation(roll: Float) -> Float {
        let span = bulgeAgeMyr.upperBound - bulgeAgeMyr.lowerBound
        return -(bulgeAgeMyr.lowerBound + span * min(max(roll, 0), 1))
            / Float(Physics.megayearsPerTimeUnit)
    }

    /// Timescale over which a disk's star formation dies away, at its centre and at its edge,
    /// in megayears.
    ///
    /// A disk builds from the inside out, so the middle ran through its gas early and the
    /// outskirts are still going. Written as a declining exponential, which is the standard
    /// way to say that and the thing the ages are actually drawn from now.
    ///
    /// What was here before drew ages uniformly between a floor and an oldest, which is a
    /// *constant* rate of star formation at every radius. With a light per unit mass that
    /// falls steeply with age the young tail then dominates the light everywhere, and it did:
    /// measured, the disk was light-weighted at 396 Myr in the middle and 297 Myr three scale
    /// lengths out. No gradient, and a blue young disk laid over a red bulge — high red and
    /// high blue with nothing in the green, which is the one colour no star can be, and is
    /// exactly the magenta the picture had.
    public static let decayInnerMyr: Float = 1_800
    public static let decayOuterMyr: Float = 9_000

    /// Share of an arm's stars drawn from the recent past instead, and how far back that
    /// reaches. An arm is where the last few hundred megayears of star formation happened, and
    /// this is the whole of why an arm is bluer than the disk it sits in.
    public static let armYoungShare: Float = 0.40
    public static let armYoungMyr: Float = 900

    /// When a particle sampled at this radius and this close to an arm formed, in code units
    /// before t = 0.
    public static func sampledFormation(
        edge: Float, armProximity: Float, roll: Float
    ) -> Float {
        let reach = min(max(edge, 0), 1)
        let arm = min(max(armProximity, 0), 1)
        let span = diskOldestMyr - (diskOldestMyr - diskEdgeOldestMyr) * reach
        var age: Float
        if roll < armYoungShare * arm {
            // On an arm, and drawn from what the arm has just made. Rescaled so the draw is
            // still one uniform number: the sampler hands over exactly one per particle and
            // taking a second would shift every later draw in the galaxy.
            let inner = roll / max(armYoungShare * arm, 1e-6)
            age = youngestSampledMyr + (armYoungMyr - youngestSampledMyr) * inner
        } else {
            let inner = (roll - armYoungShare * arm) / max(1 - armYoungShare * arm, 1e-6)
            // Time since this disk started forming stars, drawn from a declining exponential
            // truncated at the disk's own age; the lookback age is what is left of the span.
            let decay = decayInnerMyr + (decayOuterMyr - decayInnerMyr) * reach
            let cut = exp(-span / decay)
            let since = -decay * log(max(1 - min(max(inner, 0), 1) * (1 - cut), 1e-9))
            age = max(span - since, youngestSampledMyr)
        }
        return -age / Float(Physics.megayearsPerTimeUnit)
    }

    /// The share of a knot's light still coming out in Halpha at this age.
    public static func ionised(ageMyr: Float) -> Float {
        ageMyr < 0 ? 0 : exp(-ageMyr / ionisedMyr)
    }
}
