import Foundation
import Testing
import simd

@testable import SillageCore

@Suite("Story end")
struct StoryTests {
    /// Two softened points of mass 15 each, disks reaching 10 kpc: a pass inside 30 kpc collides.
    static let story = Story(
        profiles: Array(
            repeating: EncounterCentres.Profile(
                stellarMass: 15, stellarScale: 0.5, haloMass: 0, haloScale: 1, haloPlummer: false,
                haloEdge: nil), count: 2),
        reaches: [10, 10])

    /// A relative orbit in the pair's own potential, with a drag inside `dragInside` kpc standing in
    /// for dynamical friction, sampled every Myr from 80 Myr on. Tails and disruption rise for a
    /// while after each pericentre closer than 30 kpc, then hold.
    static func run(
        from position: SIMD3<Double>, velocity: SIMD3<Double>, drag: Double = 0, dragInside: Double = 20,
        untilMyr: Double
    ) -> (samples: [Story.Sample], pericentres: [Double]) {
        let unit = Physics.megayearsPerTimeUnit
        let dt = 0.002
        var x = position
        var v = velocity
        func acceleration(_ x: SIMD3<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
            let r2 = simd_length_squared(x) + 0.25
            var a = -30 * x / (r2 * r2.squareRoot())
            if simd_length(x) < dragInside { a -= drag * v }
            return a
        }
        var samples: [Story.Sample] = []
        var pericentres: [Double] = []
        var time = 80.0
        var previous = [Double.infinity, Double.infinity]
        // A pericentre counts once the pair has been apart since the last: a merged pair jitters.
        var apart = true
        var tails = 0.02
        var disruption = 0.0
        while time <= untilMyr {
            let r = simd_length(x)
            if r > 5 { apart = true }
            if apart, previous[1] < previous[0], previous[1] <= r, previous[1] < 30 {
                pericentres.append(time - 1)
                apart = false
            }
            previous = [previous[1], r]
            if let last = pericentres.last, time - last < 120 {
                tails += 0.001
                disruption = min(disruption + 0.01, 1)
            }
            let spread = 8.0
            samples.append(
                Story.Sample(
                    timeMyr: time, centres: [-x / 2, x / 2],
                    extent: (simd_length_squared(x) / 4 + spread * spread).squareRoot(), tails: tails,
                    disruption: [0, disruption]))
            for _ in 0..<Int((1 / unit / dt).rounded()) {
                v += acceleration(x, v) * dt / 2
                x += v * dt
                v += acceleration(x, v) * dt / 2
            }
            time += 1
        }
        return (samples, pericentres)
    }

    static func tracked(_ samples: [Story.Sample]) -> Story.Tracker {
        var tracker = Story.Tracker(story: story)
        for sample in samples { tracker.append(sample) }
        return tracker
    }

    @Test func aFlyByEndsOnceItsTailsHaveFormed() throws {
        let (samples, pericentres) = Self.run(
            from: [100, 8, 0], velocity: [-1.2, 0, 0], untilMyr: 1_200)
        let pericentre = try #require(pericentres.first)
        #expect(pericentres.count == 1)
        let tracker = Self.tracked(samples)
        #expect(tracker.activity.isEmpty, "\(tracker.activity)")
        let span = try #require(tracker.span(plannedFrames: 700))
        #expect(span.complete)
        #expect(abs(span.startMyr - (pericentre - 150)) <= 1)
        // Tails rise for 120 Myr, and the last 20 Myr of it fit in a quiet window of 150.
        #expect(abs(span.endMyr - (pericentre + 250)) <= 5)

        // On the way in it is a collision to come.
        let before = Self.story.activity(samples, at: Int(pericentre - 80) - 60)
        #expect(before.contains { if case .approaching = $0 { true } else { false } })
    }

    @Test func aMergerEndsOnceTheRemnantIsQuiet() throws {
        let (samples, pericentres) = Self.run(
            from: [30, 5, 0], velocity: [-0.5, 0, 0], drag: 0.02, untilMyr: 2_000)
        #expect(pericentres.count >= 3)
        let tracker = Self.tracked(samples)
        #expect(tracker.activity.isEmpty, "\(tracker.activity)")
        let span = try #require(tracker.span(plannedFrames: 700))
        #expect(span.complete)
        let last = try #require(pericentres.last)
        #expect(span.endMyr >= last + 150)
        #expect(span.endMyr < 2_000)
        // Between passages, still bound and coming back.
        let between = Self.story.activity(samples, at: Int(pericentres[0] - 80) + 40)
        #expect(between.contains { if case .returning = $0 { true } else { false } }, "\(between)")
    }

    @Test func aWideBoundOrbitIsStillGoingAtTheCap() throws {
        let (samples, _) = Self.run(from: [150, 0, 0], velocity: [0.3, 0.02, 0], untilMyr: 1_000)
        let tracker = Self.tracked(samples)
        #expect(!tracker.activity.isEmpty)
        #expect(tracker.activity.contains { if case .returning = $0 { true } else { false } })
        let span = try #require(tracker.span(plannedFrames: 700))
        #expect(!span.complete)
        #expect(span.endFrame == samples.count - 1)
    }

    @Test func debrisDriftingApartAfterAMergerIsNotAnOrbit() {
        // Bound by the potential, but the centres drift at constant speed instead of falling back.
        let samples = (0..<400).map { index -> Story.Sample in
            let offset = 25 + 0.01 * Double(index)
            return Story.Sample(
                timeMyr: 80 + Double(index), centres: [.zero, [offset, 0, 0]], extent: 20, tails: 0.1,
                disruption: [1, 1])
        }
        #expect(Self.story.activity(samples, at: samples.count - 1).isEmpty)
    }

    @Test func aLoneGalaxyKeepsItsPlannedClip() throws {
        let story = Story(profiles: [Self.story.profiles[0]], reaches: [10])
        var tracker = Story.Tracker(story: story)
        for index in 0..<900 {
            tracker.append(
                Story.Sample(
                    timeMyr: 80 + 0.8 * Double(index), centres: [.zero], extent: 15, tails: 0.02,
                    disruption: [0]))
        }
        let span = try #require(tracker.span(plannedFrames: 900))
        #expect(span.complete && span.startFrame == 0 && span.endFrame == 899)
    }

    @Test func generatedPericentresLeaveRoomForTheApproach() {
        var scene = SceneConfig.merger(particleCount: 100_000)
        scene.timeStepScale = 3.5
        let clip = scene.clipWindow(settleSteps: 400, steps: 3_600)
        let window = scene.encounterWindow(settleSteps: 400, steps: 3_600)
        #expect(window.lowerBound == clip.lowerBound + 150 && window.upperBound == clip.upperBound)
    }

    @Test func curvesAreReadByColumnName() throws {
        let csv = [
            "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction,disruption_0,"
                + "disruption_1,x_0,y_0,z_0,x_1,y_1,z_1",
            "0,71.658,100.7268,29.3923,10,100.7268,0.0218,0.000,0.500,4.5501,6.0406,-4.1085,-49.3954,"
                + "-67.1756,39.1947",
            "1,72.542,100.3703,29.2978,10,100.3703,0.0219,0.000,0.000,4.5316,6.0182,-4.0986,-49.2026,"
                + "-66.9514,39.0554",
        ].joined(separator: "\n")
        let samples = Story.samples(csv: csv)
        #expect(samples.count == 2)
        let first = try #require(samples.first)
        #expect(first.timeMyr == 71.658 && first.extent == 29.3923 && first.tails == 0.0218)
        #expect(first.disruption == [0, 0.5])
        #expect(first.centres[1] == SIMD3(-49.3954, -67.1756, 39.1947))
    }
}
