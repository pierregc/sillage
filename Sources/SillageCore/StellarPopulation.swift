import Foundation

/// What a population of stars of one age looks like, computed rather than chosen.
///
/// This replaces two invented numbers. The colour used to interpolate between 4100 K and
/// 13000 K on a hand-fitted log-age ramp, and the light per unit mass used to be a power law
/// with a hand-set exponent capped at twelve. Both were calibrated by eye against renders,
/// and both were wrong in the same direction: the real young end is 18000 to 21000 K rather
/// than 13000, and the real contrast between a ten-megayear population and a ten-gigayear one
/// is a factor of fifty rather than twelve. Young stars came out too red *and* too faint,
/// which is why a galaxy had no blue in it.
///
/// The method is the one the serious mock-image pipelines use, reduced to what a renderer
/// needs. FIRE Studio assigns every star particle a spectrum from STARBURST99 by age and
/// metallicity and pushes it through HST filters; the Illustris pipeline does the same with
/// GALAXEV and SKIRT. Neither uses a colour ramp. What is done here is the same idea with a
/// single metallicity and three sample wavelengths instead of a spectrum: enough to get a
/// colour temperature and a visible-band luminosity, which is all that reaches a pixel.
public enum StellarPopulation {
    /// Main sequence, from Pecaut & Mamajek's table of dwarf temperatures and luminosities.
    /// Mass in solar masses, effective temperature in kelvin, log of bolometric luminosity.
    private static let sequence: [(mass: Double, kelvin: Double, logLuminosity: Double)] = [
        (0.162, 3060, -2.52), (0.57, 3850, -1.16), (0.70, 4440, -0.76), (0.88, 5270, -0.34),
        (0.98, 5660, -0.05), (1.00, 5770, 0.01), (1.06, 5930, 0.13), (1.33, 6550, 0.56),
        (1.61, 7220, 0.86), (1.88, 8100, 1.09), (2.18, 9700, 1.58), (4.7, 15700, 2.77),
        (17.7, 31400, 4.65), (43, 41400, 5.54),
    ]

    /// Interpolated in log mass, which is what makes the sparse high-mass end behave.
    private static func star(_ mass: Double) -> (kelvin: Double, luminosity: Double) {
        if mass <= sequence[0].mass {
            return (sequence[0].kelvin, pow(10, sequence[0].logLuminosity))
        }
        for index in 1..<sequence.count where mass <= sequence[index].mass {
            let low = sequence[index - 1], high = sequence[index]
            let f = (log(mass) - log(low.mass)) / (log(high.mass) - log(low.mass))
            return (
                exp(log(low.kelvin) + f * (log(high.kelvin) - log(low.kelvin))),
                pow(10, low.logLuminosity + f * (high.logLuminosity - low.logLuminosity))
            )
        }
        return (sequence[sequence.count - 1].kelvin, pow(10, sequence[sequence.count - 1].logLuminosity))
    }

    /// Main-sequence lifetime in megayears. The fuel available goes as the mass and the rate
    /// it burns at as the luminosity, and the luminosity goes as roughly the three-and-a-half
    /// power of the mass over most of the sequence, which leaves this. Floored because the
    /// exponent flattens above about twenty solar masses and the law would otherwise give an
    /// O star well under a megayear.
    private static func lifetime(_ mass: Double) -> Double { max(10_000 * pow(mass, -2.5), 3) }

    /// Kroupa (2001), by number.
    private static func initialMassFunction(_ mass: Double) -> Double {
        mass < 0.5 ? pow(mass, -1.3) * pow(0.5, -1.0) : pow(mass, -2.3)
    }

    /// How long a star stays bright after the main sequence, as a fraction of the time it
    /// spent on it, and the ceiling that fraction runs into.
    ///
    /// A massive star's post-main-sequence life really is a fixed fraction of its main
    /// sequence — it is set by the same fuel in the same way. A low-mass star's is not: what
    /// it burns on the giant branch is a shell around a degenerate core, and how long that
    /// lasts has little to do with how long the star took to get there. Modelled as a fraction
    /// alone, the giant phase of an old population keeps lengthening with age, and the light
    /// per unit mass stops falling and starts *rising* past ten gigayears — measured, 0.295
    /// then 0.299 then 0.323 across the last four. No population brightens as it ages.
    ///
    /// The two numbers are the only free ones here and they are calibrated, not picked: they
    /// put a thirteen-gigayear population at a visible mass-to-light of three, against the
    /// three to five old populations are measured at, and a ten-megayear one at a twentieth,
    /// against the same figure for a starburst.
    private static let giantFraction = 0.10
    private static let giantCapMyr = 120.0

    /// Luminosity a low-mass star reaches on the giant branch, in solar luminosities. Below
    /// about two solar masses the helium core is degenerate, so what the star ends up shining
    /// at is set by that core rather than by anything it was doing before — which is how a
    /// star of one solar luminosity becomes one of several hundred.
    private static let giantLuminosity = 400.0

    private static func planck(_ nanometres: Double, _ kelvin: Double) -> Double {
        let metres = nanometres * 1e-9
        return 1 / (pow(metres, 5) * (exp(0.014_387_769_6 / (metres * kelvin)) - 1))
    }

    /// The blackbody showing the same blue-to-green ratio as this spectrum. The renderer draws
    /// stars as Planckian radiators, so this is the temperature to hand it.
    private static func colourTemperature(blue: Double, green: Double) -> Double {
        guard green > 0, blue > 0 else { return 4000 }
        var low = 2000.0, high = 40000.0
        for _ in 0..<50 {
            let mid = (low + high) / 2
            if planck(440, mid) / planck(550, mid) < blue / green { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Colour temperature in kelvin, and visible light per unit of mass ever formed in solar
    /// units, for a population of this age.
    ///
    /// The weight is the *monochromatic* flux and not the bolometric luminosity, and that is
    /// not a detail: an O star puts almost all of its output in the ultraviolet, so weighting
    /// a population by total luminosity makes it far bluer and far brighter in visible light
    /// than it is. Planck over Stefan-Boltzmann is that correction.
    public static func evaluate(ageMyr: Double) -> (kelvin: Double, lightPerMass: Double) {
        var blue = 0.0, green = 0.0, mass = 0.0
        func add(_ weight: Double, _ luminosity: Double, _ kelvin: Double) {
            let visible = luminosity / pow(kelvin, 4)
            blue += weight * visible * planck(440, kelvin)
            green += weight * visible * planck(550, kelvin)
        }
        // Integrated in two pieces, and that is not tidiness. The giant phase is a per cent of
        // a star's life, so it is a sliver of the mass axis, and testing each bin for whether
        // it falls inside made the answer depend on the binning: at two thousand bins an old
        // population came out at a mass-to-light of 1.9 and at four thousand at 3.7, for the
        // same physics. Solving for the two ends of the sliver and integrating between them
        // gives the same answer at any resolution.
        // A star is a giant while its own life has run out but its giant phase has not, and
        // that phase is the shorter of a fixed fraction of its life and a fixed span. Solving
        // both for the life that just qualifies gives the older end of the sliver.
        let turnoff = min(mainSequenceMass(ageMyr: ageMyr), 60.0)
        let qualifying = Swift.max(ageMyr / (1 + giantFraction), ageMyr - giantCapMyr)
        let leaving = min(mainSequenceMass(ageMyr: qualifying), 60.0)

        // Everything still on the main sequence, and the whole of the mass ever formed.
        let low = 0.08, high = 60.0
        let bins = 2000
        for index in 0..<bins {
            let a = low * pow(high / low, Double(index) / Double(bins))
            let b = low * pow(high / low, Double(index + 1) / Double(bins))
            let m = (a + b) / 2
            let weight = initialMassFunction(m) * (b - a)
            mass += weight * m
            guard m < turnoff else { continue }
            let s = star(m)
            add(weight, s.luminosity, s.kelvin)
        }

        // And the sliver that has just left it.
        if leaving > turnoff {
            let steps = 200
            for index in 0..<steps {
                let a = turnoff + (leaving - turnoff) * Double(index) / Double(steps)
                let b = turnoff + (leaving - turnoff) * Double(index + 1) / Double(steps)
                let m = (a + b) / 2
                let weight = initialMassFunction(m) * (b - a)
                let s = star(m)
                // Below two solar masses the helium core is degenerate, so what the star ends
                // up shining at is set by that core and not by anything it was doing before —
                // which is how a star of one solar luminosity becomes one of several hundred.
                // Above it the core is not degenerate: the star crosses at roughly constant
                // luminosity and simply gets cooler. Blended across the boundary, because a
                // step there puts a cliff in the colour curve at one and a half gigayears.
                let degenerate = 1 - smoothstep(1.6, 2.4, m)
                let hot = 1.5 * s.luminosity
                let cool = Swift.max(s.luminosity, giantLuminosity)
                add(
                    weight, degenerate * cool + (1 - degenerate) * hot,
                    degenerate * 4300 + (1 - degenerate) * Swift.max(0.55 * s.kelvin, 4000))
            }
        }
        // Green is a monochromatic flux on an arbitrary scale; dividing by the Sun's makes the
        // result read as a solar visible luminosity per solar mass.
        let sun = planck(550, 5770) / pow(5770, 4)
        return (colourTemperature(blue: blue, green: green), green / mass / sun)
    }

    /// Mass whose main-sequence life is this long, the inverse of `lifetime`. Below the floor
    /// that relation stops being invertible, so nothing above sixty solar masses is resolved.
    private static func mainSequenceMass(ageMyr: Double) -> Double {
        ageMyr <= 3 ? .infinity : pow(10_000 / ageMyr, 1 / 2.5)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = Swift.min(Swift.max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Ends of the tabulated range, in megayears. Below the first nothing is resolved — a
    /// population younger than this is simply at its bluest and brightest — and the last is
    /// past a Hubble time on purpose so that the oldest thing in a galaxy is not pinned to the
    /// end of the table.
    public static let youngestMyr: Double = 1
    public static let oldestMyr: Double = 14_000
    public static let samples = 64

    /// The table the renderer uploads: colour temperature and light per unit mass, at
    /// `samples` ages spaced evenly in log age between the two bounds above.
    ///
    /// Computed once. It is a few hundred thousand floating point operations, which is nothing
    /// against sampling a galaxy, and it means the numbers in a frame are the ones this file
    /// derives rather than a copy of them that can drift.
    public static let table: [SIMD2<Float>] = (0..<samples).map { index in
        let f = Double(index) / Double(samples - 1)
        let age = youngestMyr * pow(oldestMyr / youngestMyr, f)
        let (kelvin, light) = evaluate(ageMyr: age)
        return SIMD2<Float>(Float(kelvin), Float(light))
    }

    /// The same lookup the shader does, on the CPU, so a test can check the curve.
    public static func sampled(ageMyr: Float) -> (kelvin: Float, lightPerMass: Float) {
        let span = log(Float(oldestMyr / youngestMyr))
        let f = log(max(ageMyr, Float(youngestMyr)) / Float(youngestMyr)) / span
        let position = min(max(f, 0), 1) * Float(samples - 1)
        let index = min(Int(position), samples - 2)
        let entry = table[index] + (table[index + 1] - table[index]) * (position - Float(index))
        return (entry.x, entry.y)
    }
}
