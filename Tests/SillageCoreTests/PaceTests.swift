import Foundation
import Testing

@testable import SillageCore

@Suite("Pace")
struct PaceTests {
    static let pace = StoryPace(story: StoryTests.story)

    /// A flyby of 30 kpc reach that keeps its tails growing for 120 Myr after the pericentre.
    static func flyby(untilMyr: Double = 1_200) throws -> (samples: [Story.Sample], pericentre: Double) {
        let (samples, pericentres) = StoryTests.run(
            from: [100, 8, 0], velocity: [-1.2, 0, 0], untilMyr: untilMyr)
        return (samples, try #require(pericentres.first))
    }

    @Test func aPassKeepsItsPaceAndTheAftermathSpeedsUp() throws {
        let (samples, pericentre) = try Self.flyby()
        let times = samples.map(\.timeMyr)
        let speeds = Self.pace.speeds(Self.pace.trace(samples), atMyr: times)
        #expect(speeds.count == samples.count)
        for (time, speed) in zip(times, speeds) where time <= pericentre + 20 {
            #expect(speed == 1, "\(time) Myr at \(speed)x")
        }
        let last = try #require(speeds.last)
        #expect(last > 2 && last <= 8)
        #expect(speeds.allSatisfy { $0 >= 1 && $0 <= 8 })
    }

    @Test func aMergedPairStopsBeingEngagedOnceItsCentresStayClose() throws {
        // A bound pair spiralling in under drag, the way a merger ends.
        let (samples, pericentres) = StoryTests.run(
            from: [30, 5, 0], velocity: [-0.5, 0, 0], drag: 0.02, untilMyr: 2_000)
        let trace = Self.pace.trace(samples)
        let merged = try #require(Self.pace.mergeMoment(samples))
        let engaged = try #require(trace.engagedUntilMyr)
        #expect(engaged <= merged && pericentres.count >= 3)
        // Story alone would wait for the nuclei to settle; the pace does not.
        var tracker = Story.Tracker(story: StoryTests.story)
        for sample in samples { tracker.append(sample) }
        #expect(engaged <= (tracker.engagedMyr ?? 0))
        // A pair that parts has no merger.
        let (parting, _) = try Self.flyby()
        #expect(Self.pace.mergeMoment(parting) == nil)
    }

    @Test func partingGalaxiesDoNotKeepTheTakeSlowThroughTheirExtent() throws {
        let (samples, _) = try Self.flyby()
        let trace = Self.pace.trace(samples)
        // The pair is 600 kpc apart at the end and the extent still grows with it.
        let end = trace.extent.count - 1
        #expect(trace.extent[end] == 0)
        #expect(trace.activity[end] < 1)
    }

    @Test func aBoldPaceIsAtLeastAsFastAndTheTopCapsIt() throws {
        let (samples, _) = try Self.flyby()
        let trace = Self.pace.trace(samples)
        let times = samples.map(\.timeMyr)
        let ordinary = Self.pace.speeds(trace, atMyr: times)
        let bold = Self.pace.speeds(trace, atMyr: times, settings: .init(pace: 8, top: 12))
        for (a, b) in zip(ordinary, bold) { #expect(b >= a && b <= 12) }
        #expect(zip(ordinary, bold).contains { $1 > $0 })
        let capped = Self.pace.speeds(trace, atMyr: times, settings: .init(pace: 4, top: 2))
        #expect(capped.allSatisfy { $0 <= 2 })
    }

    @Test func aBurstOfStarsHoldsThePace() throws {
        var (samples, _) = try Self.flyby()
        for index in samples.indices {
            samples[index].formed = (500..<560).contains(index) ? 100 : 10
        }
        let trace = Self.pace.trace(samples)
        #expect(trace.held[530])
        #expect(!trace.held[samples.count - 1])
    }

    @Test func theWindowSlidesInwardsAtTheEndsOfTheTake() {
        let times = (0..<400).map(Double.init)
        let end = Self.pace.window(around: 399, in: times, width: 150)
        #expect(end == 249..<400)
        let start = Self.pace.window(around: 0, in: times, width: 150)
        #expect(start == 0..<151)
        #expect(Self.pace.window(around: 200, in: times, width: 50, shifted: false) == 175..<226)
    }

    @Test func speedsAreGeometricBetweenSamplesAndHeldAtTheEnds() {
        let speeds = StoryPace.interpolated([1, 4], at: [0, 10], for: [-5, 0, 5, 10, 20])
        #expect(speeds[0] == 1 && speeds[1] == 1 && abs(speeds[2] - 2) < 1e-12 && speeds[3] == 4)
        #expect(speeds[4] == 4)
    }

    @Test func aTrackIsBuiltFromAStoryPaceAtAnotherFrameRate() throws {
        let (samples, _) = try Self.flyby()
        // A take whose frames are not the curves' samples.
        let megayears = (0..<500).map { 85 + Double($0) * 2.1 }
        let speeds = Self.pace.speeds(Self.pace.trace(samples), atMyr: megayears)
        #expect(speeds.count == 500 && speeds.allSatisfy { $0 >= 1 && $0 <= 8 })
    }

    @Test func identicalFramesDoNotChangeAndBrighterOnesDo() {
        let dark = [UInt8](repeating: 20, count: 4 * 64)
        let bright = [UInt8](repeating: 200, count: 4 * 64)
        #expect(VisualPace.change(dark, dark) == VisualPace.Change())
        let change = VisualPace.change(dark, bright)
        #expect(change.all > 1 && change.lit > 1 && change.moving == 1)
        #expect(abs(change.all - VisualPace.change(bright, dark).all) < 1e-12)
        // A lit patch in a dark frame: the sky dilutes the mean over every pixel and not the lit one.
        var patch = dark
        for index in 0..<16 { for channel in 0..<3 { patch[index * 4 + channel] = 255 } }
        let local = VisualPace.change(dark, patch)
        #expect(local.lit > 3.5 * local.all && local.moving == 16.0 / 64)
    }

    @Test func theVisualPaceSlowsWhereTheChangeIsLarge() {
        let times = (0...400).map(Double.init)
        // The picture changes ten times faster in the middle.
        let changes = (0..<400).map { (150..<250).contains($0) ? 0.1 : 0.01 }
        let megayears = (0..<300).map { 50 + Double($0) * 1.2 }
        let speeds = VisualPace().speeds(changes: changes, times: times, megayears: megayears)
        #expect(speeds.count == 300 && speeds.allSatisfy { $0 >= 1 && $0 <= 8 })
        let busy = speeds[megayears.firstIndex { $0 >= 200 }!]
        let quiet = speeds[megayears.firstIndex { $0 >= 330 }!]
        #expect(busy == 1 && quiet > 7)
        // A quiet take with the same change everywhere plays at one speed.
        let flat = VisualPace().speeds(
            changes: [Double](repeating: 0.02, count: 400), times: times, megayears: megayears)
        #expect(flat.allSatisfy { abs($0 - flat[0]) < 1e-9 })
    }

    @Test func aPaceIsNamedByItsKindAndItsNumbers() {
        #expect(PaceSpec("story") == .story(StoryPace.Settings()))
        #expect(PaceSpec("story:8") == .story(StoryPace.Settings(pace: 8, top: 8)))
        #expect(PaceSpec("story:4:12") == .story(StoryPace.Settings(pace: 4, top: 12)))
        #expect(PaceSpec("visual:6:0.5") == .visual(VisualPace.Settings(top: 6, busiest: 0.5)))
        #expect(PaceSpec("visual") == .visual(VisualPace.Settings()))
        #expect(
            PaceSpec("visual-moving:6") == .visual(VisualPace.Settings(top: 6, metric: .moving)))
        for text in [
            "", "slow", "visual-foo", "story:x", "story:4:8:1", "story:0", "story:4:0.5", "visual:8:2",
        ] {
            #expect(PaceSpec(text) == nil, "\(text)")
        }
    }

    @Test func slowingAStretchOnlyLowersTheSpeeds() {
        let speeds = PaceSpec.slowed(
            [1, 2, 8, 8, 0.4], megayears: [0, 1, 2, 3, 4], from: 1, to: 4, speed: 0.5)
        #expect(speeds == [1, 0.5, 0.5, 0.5, 0.4])
    }
}
