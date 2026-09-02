import Foundation
import Testing

@testable import SillageCore

struct StellarPopulationTests {
    /// The synthesis has to land on what populations are actually measured at, because that is
    /// the only thing that makes it better than the ramp it replaced.
    ///
    /// The ramp was fitted against renders and was wrong twice over: it put the young end at
    /// 13000 K when it is 18000, and capped the young-to-old brightness contrast at twelve
    /// when it is fifty. Young stars came out too red and too faint at once, and a galaxy had
    /// one and a half per cent blue in it.
    @Test func theCurveMatchesWhatPopulationsAreMeasuredAt() {
        // Mass to light in visible light. An old population is measured between three and
        // five; a starburst around a twentieth. These two anchors are what the single free
        // parameter — how long a star stays bright after the main sequence — is set by.
        let old = StellarPopulation.sampled(ageMyr: 13_000)
        #expect(1 / old.lightPerMass > 2 && 1 / old.lightPerMass < 6)
        let young = StellarPopulation.sampled(ageMyr: 10)
        #expect(1 / young.lightPerMass < 0.15)

        // An old population is a K giant's colour and a young one is hotter than any single
        // star the disk holds in quantity. The young end is the half that was wrong.
        #expect(old.kelvin > 3_800 && old.kelvin < 5_200)
        #expect(young.kelvin > 15_000)

        // And it only ever goes one way. A population that brightens or blues with age is a
        // sign the giant branch is carrying too much, which is exactly how the first cut of
        // this came out: light per unit mass fell to three gigayears and then rose again.
        var previous = StellarPopulation.sampled(ageMyr: 1)
        for step in 1..<60 {
            let age = pow(Float(14_000), Float(step) / 59)
            let now = StellarPopulation.sampled(ageMyr: age)
            #expect(now.lightPerMass <= previous.lightPerMass * 1.001)
            #expect(now.kelvin <= previous.kelvin * 1.001)
            previous = now
        }
    }

    /// The table and the function behind it are the same curve, so the renderer cannot drift
    /// from what this file derives.
    @Test func theTableIsTheFunctionItWasBuiltFrom() {
        for age in [1.0, 40.0, 900.0, 14_000.0] {
            let direct = StellarPopulation.evaluate(ageMyr: age)
            let looked = StellarPopulation.sampled(ageMyr: Float(age))
            #expect(abs(looked.kelvin - Float(direct.kelvin)) < 0.02 * Float(direct.kelvin))
            #expect(
                abs(looked.lightPerMass - Float(direct.lightPerMass))
                    < 0.05 * Float(direct.lightPerMass))
        }
    }
}
